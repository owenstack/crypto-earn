//! Unit tests for the HTTP client wrapper.

const std = @import("std");
const testing = std.testing;
const http = @import("cex_zig").http;
const HttpClient = http.HttpClient;
const HttpError = http.HttpError;

test "HttpClient init and deinit" {
    var client = HttpClient.init(testing.allocator, 500);
    defer client.deinit();

    try testing.expectEqual(@as(u32, 500), client.timeout_ms);
}

test "HttpClient.fetch returns TransportError for invalid URL" {
    var client = HttpClient.init(testing.allocator, 500);
    defer client.deinit();

    const result = client.fetch("not-a-url");
    try testing.expectError(HttpError.TransportError, result);
}
