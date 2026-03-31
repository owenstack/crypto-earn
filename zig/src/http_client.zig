//! HTTP client wrapper for Gamma API and CLOB REST calls.
const std = @import("std");
const log = @import("logger.zig");

pub const HttpError = error{
    RequestFailed,
    InvalidUrl,
    Timeout,
    ServerError,
    ClientError,
    ConnectionFailed,
};

pub const Response = struct {
    status: std.http.Status,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
    }
};

pub const HttpClient = struct {
    client: std.http.Client,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{
            .client = .{ .allocator = allocator },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    /// GET request, returns owned Response. Caller must call response.deinit().
    pub fn get(self: *HttpClient, url: []const u8) HttpError!Response {
        return self.doRequest(.GET, url, null);
    }

    /// POST request with JSON body.
    pub fn postJson(self: *HttpClient, url: []const u8, json_body: []const u8) HttpError!Response {
        return self.doRequest(.POST, url, json_body);
    }

    /// POST request with JSON body and additional headers.
    pub fn postJsonWithHeaders(self: *HttpClient, url: []const u8, json_body: []const u8, headers: []const std.http.Header) HttpError!Response {
        const uri = std.Uri.parse(url) catch {
            log.err("http", "invalid url: {s}", .{url});
            return error.InvalidUrl;
        };

        var merged_headers: std.ArrayList(std.http.Header) = .empty;
        defer merged_headers.deinit(self.allocator);

        // Append caller headers except any Content-Type (case-insensitive)
        for (headers) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "Content-Type")) {
                merged_headers.append(self.allocator, h) catch {
                    return error.RequestFailed;
                };
            }
        }
        // Append authoritative Content-Type header
        merged_headers.append(self.allocator, .{ .name = "Content-Type", .value = "application/json" }) catch {
            return error.RequestFailed;
        };

        var body_writer = std.Io.Writer.Allocating.init(self.allocator);
        errdefer body_writer.deinit();

        const result = self.client.fetch(.{
            .location = .{ .uri = uri },
            .method = .POST,
            .payload = json_body,
            .response_writer = &body_writer.writer,
            .extra_headers = merged_headers.items,
        }) catch {
            log.err("http", "POST {s} failed", .{url});
            return error.RequestFailed;
        };

        const status_class = result.status.class();
        if (status_class == .server_error) {
            log.err("http", "POST {s} -> {d}", .{ url, @intFromEnum(result.status) });
            return error.ServerError;
        }
        if (status_class == .client_error) {
            log.warn("http", "POST {s} -> {d}", .{ url, @intFromEnum(result.status) });
            return error.ClientError;
        }

        const body = body_writer.toOwnedSlice() catch {
            return error.RequestFailed;
        };

        return .{
            .status = result.status,
            .body = body,
            .allocator = self.allocator,
        };
    }

    fn doRequest(self: *HttpClient, method: std.http.Method, url: []const u8, payload: ?[]const u8) HttpError!Response {
        const uri = std.Uri.parse(url) catch {
            log.err("http", "invalid url: {s}", .{url});
            return error.InvalidUrl;
        };

        var body_writer = std.Io.Writer.Allocating.init(self.allocator);
        errdefer body_writer.deinit();

        const result = self.client.fetch(.{
            .location = .{ .uri = uri },
            .method = method,
            .payload = payload,
            .response_writer = &body_writer.writer,
            .extra_headers = if (payload != null) &.{.{
                .name = "Content-Type",
                .value = "application/json",
            }} else &.{},
        }) catch {
            log.err("http", "{s} {s} failed", .{ @tagName(method), url });
            return error.RequestFailed;
        };

        const status_class = result.status.class();
        if (status_class == .server_error) {
            log.err("http", "{s} {s} -> {d}", .{ @tagName(method), url, @intFromEnum(result.status) });
            return error.ServerError;
        }
        if (status_class == .client_error) {
            log.warn("http", "{s} {s} -> {d}", .{ @tagName(method), url, @intFromEnum(result.status) });
            return error.ClientError;
        }

        const body = body_writer.toOwnedSlice() catch {
            return error.RequestFailed;
        };

        return .{
            .status = result.status,
            .body = body,
            .allocator = self.allocator,
        };
    }
};

test "http_client: init and deinit" {
    var client = HttpClient.init(std.testing.allocator);
    defer client.deinit();
}
