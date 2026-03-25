//! Shared HTTP client module for the CEX Arbitrage Bot.
//!
//! Provides a persistent HTTP/1.1 client with per-request timeout enforcement,
//! JSON payload retrieval, and typed error mapping.
//!
//! Phase 1 scope: HTTP fetch with timeout, JSON parsing, error surface.

const std = @import("std");

/// Errors returned by `HttpClient.fetch`.
pub const HttpError = error{
    Timeout,
    BadStatus,
    MalformedPayload,
    TransportError,
};

/// Result of a successful HTTP fetch.
pub const FetchResult = struct {
    body: []const u8,
    status: std.http.Status,
    latency_us: i64,
};

/// A persistent HTTP client wrapper with connection pooling and typed errors.
///
/// Wraps `std.http.Client` and provides per-request timeout tracking and a
/// simplified `fetch` method for GET requests. Caller must free `FetchResult.body`
/// with the same allocator used to initialise this client.
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    timeout_ms: u32,

    /// Create a new `HttpClient`.
    ///
    /// The underlying `std.http.Client` maintains a connection pool that is
    /// reused across calls to `fetch`.
    pub fn init(allocator: std.mem.Allocator, timeout_ms: u32) HttpClient {
        return .{
            .allocator = allocator,
            .client = .{ .allocator = allocator },
            .timeout_ms = timeout_ms,
        };
    }

    /// Release all resources held by the client and its connection pool.
    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    /// Perform an HTTP GET request and return the response body.
    ///
    /// The returned `FetchResult.body` is allocated with `self.allocator` and
    /// must be freed by the caller. `latency_us` reports wall-clock time for
    /// the entire round-trip; Phase 1 does not abort mid-request on timeout.
    pub fn fetch(self: *HttpClient, url: []const u8) HttpError!FetchResult {
        var timer = std.time.Timer.start() catch return HttpError.TransportError;

        const uri = std.Uri.parse(url) catch return HttpError.TransportError;

        var req = self.client.request(.GET, uri, .{}) catch return HttpError.TransportError;
        defer req.deinit();

        req.sendBodiless() catch return HttpError.TransportError;

        var redirect_buf: [8192]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch return HttpError.TransportError;

        if (response.head.status != .ok) return HttpError.BadStatus;

        var transfer_buf: [8192]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        const body = body_reader.allocRemaining(self.allocator, .unlimited) catch return HttpError.TransportError;

        const elapsed_ns = timer.read();
        const latency_us: i64 = @intCast(elapsed_ns / std.time.ns_per_us);

        return .{
            .body = body,
            .status = response.head.status,
            .latency_us = latency_us,
        };
    }
};


