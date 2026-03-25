//! Unit tests for the structured JSON logger.

const std = @import("std");
const testing = std.testing;
const log = @import("cex_zig").log;
const Logger = log.Logger;
const Level = log.Level;

fn parseJsonField(json: []const u8, comptime key: []const u8) ?[]const u8 {
    const needle = "\"" ++ key ++ "\":";
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const after_key = start + needle.len;
    if (after_key >= json.len) return null;

    if (json[after_key] == '"') {
        const str_start = after_key + 1;
        var i = str_start;
        while (i < json.len) : (i += 1) {
            if (json[i] == '\\') {
                i += 1;
                continue;
            }
            if (json[i] == '"') return json[str_start..i];
        }
        return null;
    }
    // Non-string value: read until , or }
    var end = after_key;
    while (end < json.len and json[end] != ',' and json[end] != '}') : (end += 1) {}
    return json[after_key..end];
}

test "JSON schema contains required fields" {
    var buf: [4096]u8 = undefined;
    var w: std.io.Writer = .fixed(&buf);
    var logger = Logger.init("test-component", .debug, &w);

    logger.info("hello world", .{});

    const output = w.buffered();
    try testing.expect(output.len > 0);

    try testing.expect(parseJsonField(output, "timestamp") != null);
    try testing.expect(parseJsonField(output, "level") != null);
    try testing.expect(parseJsonField(output, "component") != null);
    try testing.expect(parseJsonField(output, "msg") != null);

    const level_val = parseJsonField(output, "level").?;
    try testing.expectEqualStrings("INFO", level_val);

    const comp_val = parseJsonField(output, "component").?;
    try testing.expectEqualStrings("test-component", comp_val);

    const msg_val = parseJsonField(output, "msg").?;
    try testing.expectEqualStrings("hello world", msg_val);
}

test "level gating suppresses lower levels" {
    var buf: [4096]u8 = undefined;
    var w: std.io.Writer = .fixed(&buf);
    var logger = Logger.init("gate-test", .info, &w);

    logger.debug("should not appear", .{});
    try testing.expectEqual(@as(usize, 0), w.buffered().len);

    logger.info("should appear", .{});
    try testing.expect(w.buffered().len > 0);
}

test "string escaping in msg" {
    var buf: [4096]u8 = undefined;
    var w: std.io.Writer = .fixed(&buf);
    var logger = Logger.init("escape-test", .debug, &w);

    logger.info("line1\nline2\ttab\"quote\\back", .{});

    const output = w.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\\t") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\\\\") != null);
}

test "key-value context fields appear in output" {
    var buf: [4096]u8 = undefined;
    var w: std.io.Writer = .fixed(&buf);
    var logger = Logger.init("kv-test", .debug, &w);

    logger.info("arb detected", .{
        .exchange = "binance",
        .profit_pct = @as(f64, 0.23),
        .pairs = @as(u32, 4),
        .active = true,
    });

    const output = w.buffered();
    try testing.expect(parseJsonField(output, "exchange") != null);
    try testing.expectEqualStrings("binance", parseJsonField(output, "exchange").?);
    try testing.expect(parseJsonField(output, "profit_pct") != null);
    try testing.expect(parseJsonField(output, "pairs") != null);
    try testing.expect(parseJsonField(output, "active") != null);
    try testing.expectEqualStrings("true", parseJsonField(output, "active").?);
}

test "timestamp format is ISO 8601" {
    var buf: [4096]u8 = undefined;
    var w: std.io.Writer = .fixed(&buf);
    var logger = Logger.init("ts-test", .debug, &w);

    logger.info("check timestamp", .{});

    const ts = parseJsonField(w.buffered(), "timestamp").?;
    // Expect format: YYYY-MM-DDTHH:MM:SSZ (20 chars)
    try testing.expectEqual(@as(usize, 20), ts.len);
    try testing.expectEqual(@as(u8, '-'), ts[4]);
    try testing.expectEqual(@as(u8, '-'), ts[7]);
    try testing.expectEqual(@as(u8, 'T'), ts[10]);
    try testing.expectEqual(@as(u8, ':'), ts[13]);
    try testing.expectEqual(@as(u8, ':'), ts[16]);
    try testing.expectEqual(@as(u8, 'Z'), ts[19]);
}

test "all log levels produce correct level string" {
    const levels = [_]struct { lvl: Level, expected: []const u8 }{
        .{ .lvl = .debug, .expected = "DEBUG" },
        .{ .lvl = .info, .expected = "INFO" },
        .{ .lvl = .warn, .expected = "WARN" },
        .{ .lvl = .err, .expected = "ERROR" },
    };

    for (levels) |case| {
        var buf: [4096]u8 = undefined;
        var w: std.io.Writer = .fixed(&buf);
        var logger = Logger.init("lvl-test", .debug, &w);

        switch (case.lvl) {
            .debug => logger.debug("test", .{}),
            .info => logger.info("test", .{}),
            .warn => logger.warn("test", .{}),
            .err => logger.err("test", .{}),
        }

        const output = w.buffered();
        const level_val = parseJsonField(output, "level").?;
        try testing.expectEqualStrings(case.expected, level_val);
    }
}

test "control characters are escaped" {
    var buf: [4096]u8 = undefined;
    var w: std.io.Writer = .fixed(&buf);
    var logger = Logger.init("ctrl-test", .debug, &w);

    // Embed a NUL and BEL character in the message
    logger.info("before\x00after\x07end", .{});

    const output = w.buffered();
    // NUL should be escaped as \u0000
    try testing.expect(std.mem.indexOf(u8, output, "\\u0000") != null);
    // BEL should be escaped as \u0007
    try testing.expect(std.mem.indexOf(u8, output, "\\u0007") != null);
}
