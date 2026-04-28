//! Structured JSON-line logger with in-memory ring buffer for /logs endpoint.
const std = @import("std");

var g_start_ms: i64 = 0;
var g_mutex: std.Thread.Mutex = .{};

// Smaller ring + line size: lowers steady-state memory footprint for very
// long-running deployments. 128 * 320 = ~40 KiB instead of ~100 KiB.
const RING_SIZE: usize = 128;
const MAX_LINE: usize = 320;
var g_ring: [RING_SIZE][MAX_LINE]u8 = undefined;
var g_ring_len: [RING_SIZE]usize = [_]usize{0} ** RING_SIZE;
var g_head: usize = 0;
var g_count: usize = 0;

const Level = enum(u8) { debug = 0, info = 1, warn = 2, err = 3 };

/// Minimum level emitted to stdout AND the ring buffer. Anything below this
/// is dropped entirely so it never costs any memory or disk space (when
/// captured by the logging driver). Configurable via LOG_LEVEL env var.
var g_min_level: Level = .info;

fn parseLevel(s: []const u8) ?Level {
    if (std.ascii.eqlIgnoreCase(s, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(s, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(s, "warn") or std.ascii.eqlIgnoreCase(s, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(s, "error") or std.ascii.eqlIgnoreCase(s, "err")) return .err;
    return null;
}

pub fn init() void {
    g_start_ms = std.time.milliTimestamp();
    if (std.posix.getenv("LOG_LEVEL")) |env| {
        if (parseLevel(env)) |lvl| g_min_level = lvl;
    }
}

pub fn uptimeMs() i64 {
    return std.time.milliTimestamp() - g_start_ms;
}

fn writeRaw(level_enum: Level, level: []const u8, component: []const u8, msg: []const u8) void {
    if (@intFromEnum(level_enum) < @intFromEnum(g_min_level)) return;
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
    if (@intFromEnum(Level.debug) < @intFromEnum(g_min_level)) return;
    var b: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&b, fmt, args) catch "<overflow>";
    writeRaw(.debug, "DEBUG", component, msg);
}

pub fn info(component: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(Level.info) < @intFromEnum(g_min_level)) return;
    var b: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&b, fmt, args) catch "<overflow>";
    writeRaw(.info, "INFO", component, msg);
}

pub fn warn(component: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(Level.warn) < @intFromEnum(g_min_level)) return;
    var b: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&b, fmt, args) catch "<overflow>";
    writeRaw(.warn, "WARN", component, msg);
}

pub fn err(component: []const u8, comptime fmt: []const u8, args: anytype) void {
    var b: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&b, fmt, args) catch "<overflow>";
    writeRaw(.err, "ERROR", component, msg);
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
