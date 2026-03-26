//! Structured JSON-line logger with in-memory ring buffer for /logs endpoint.
const std = @import("std");

var g_start_ms: i64 = 0;
var g_mutex: std.Thread.Mutex = .{};

const RING_SIZE: usize = 200;
const MAX_LINE: usize = 512;
var g_ring: [RING_SIZE][MAX_LINE]u8 = undefined;
var g_ring_len: [RING_SIZE]usize = [_]usize{0} ** RING_SIZE;
var g_head: usize = 0;
var g_count: usize = 0;

pub fn init() void {
    g_start_ms = std.time.milliTimestamp();
}

pub fn uptimeMs() i64 {
    return std.time.milliTimestamp() - g_start_ms;
}

fn writeRaw(level: []const u8, component: []const u8, msg: []const u8) void {
    var line_buf: [MAX_LINE]u8 = undefined;
    const ts = std.time.milliTimestamp();
    const line = std.fmt.bufPrint(
        &line_buf,
        "{{\"ts\":{d},\"level\":{f},\"component\":{f},\"msg\":{f}}}",
        .{
            ts,
            std.json.fmt(level, .{}),
            std.json.fmt(component, .{}),
            std.json.fmt(msg, .{}),
        },
    ) catch return;

    g_mutex.lock();
    defer g_mutex.unlock();

    @memcpy(g_ring[g_head][0..line.len], line);
    g_ring_len[g_head] = line.len;
    g_head = (g_head + 1) % RING_SIZE;
    if (g_count < RING_SIZE) g_count += 1;

    std.debug.print("{s}\n", .{line});
}

pub fn debug(component: []const u8, comptime fmt: []const u8, args: anytype) void {
    var b: [400]u8 = undefined;
    const msg = std.fmt.bufPrint(&b, fmt, args) catch "<overflow>";
    writeRaw("DEBUG", component, msg);
}

pub fn info(component: []const u8, comptime fmt: []const u8, args: anytype) void {
    var b: [400]u8 = undefined;
    const msg = std.fmt.bufPrint(&b, fmt, args) catch "<overflow>";
    writeRaw("INFO", component, msg);
}

pub fn warn(component: []const u8, comptime fmt: []const u8, args: anytype) void {
    var b: [400]u8 = undefined;
    const msg = std.fmt.bufPrint(&b, fmt, args) catch "<overflow>";
    writeRaw("WARN", component, msg);
}

pub fn err(component: []const u8, comptime fmt: []const u8, args: anytype) void {
    var b: [400]u8 = undefined;
    const msg = std.fmt.bufPrint(&b, fmt, args) catch "<overflow>";
    writeRaw("ERROR", component, msg);
}

/// Write JSON array of recent log lines to `writer`.
pub fn writeRecentLogs(writer: anytype) !void {
    g_mutex.lock();
    defer g_mutex.unlock();

    try writer.writeAll("[");
    const start: usize = if (g_count < RING_SIZE) 0 else g_head;
    var i: usize = 0;
    while (i < g_count) : (i += 1) {
        const idx = (start + i) % RING_SIZE;
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll(g_ring[idx][0..g_ring_len[idx]]);
    }
    try writer.writeAll("]");
}
