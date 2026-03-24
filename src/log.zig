//! Structured JSON logger for the CEX arbitrage bot.
//!
//! All log output is structured JSON to stdout. Each line contains:
//! `timestamp` (ISO 8601), `level`, `component`, `msg`, plus optional
//! contextual key-value pairs.
//!
//! Thread-safe via mutex. No allocator needed — uses stack buffers.

const std = @import("std");
const epoch = std.time.epoch;

pub const Level = enum {
    debug,
    info,
    warn,
    err,

    fn order(self: Level) u2 {
        return switch (self) {
            .debug => 0,
            .info => 1,
            .warn => 2,
            .err => 3,
        };
    }

    pub fn string(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

pub const Logger = struct {
    min_level: Level,
    component: []const u8,
    mutex: std.Thread.Mutex,
    writer: *std.io.Writer,

    pub fn init(component: []const u8, min_level: Level, writer: *std.io.Writer) Logger {
        return .{
            .min_level = min_level,
            .component = component,
            .mutex = .{},
            .writer = writer,
        };
    }

    pub fn debug(self: *Logger, msg: []const u8, kvs: anytype) void {
        self.writeLog(.debug, msg, kvs);
    }

    pub fn info(self: *Logger, msg: []const u8, kvs: anytype) void {
        self.writeLog(.info, msg, kvs);
    }

    pub fn warn(self: *Logger, msg: []const u8, kvs: anytype) void {
        self.writeLog(.warn, msg, kvs);
    }

    pub fn err(self: *Logger, msg: []const u8, kvs: anytype) void {
        self.writeLog(.err, msg, kvs);
    }

    fn writeLog(self: *Logger, level: Level, msg: []const u8, kvs: anytype) void {
        if (level.order() < self.min_level.order()) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.writeLogInner(level, msg, kvs) catch {};
    }

    fn writeLogInner(self: *Logger, level: Level, msg: []const u8, kvs: anytype) !void {
        const w = self.writer;

        try w.writeAll("{\"timestamp\":\"");
        try writeTimestamp(w);
        try w.writeAll("\",\"level\":\"");
        try w.writeAll(level.string());
        try w.writeAll("\",\"component\":");
        try writeJsonString(w, self.component);
        try w.writeAll(",\"msg\":");
        try writeJsonString(w, msg);

        const K = @TypeOf(kvs);
        const fields = @typeInfo(K).@"struct".fields;
        inline for (fields) |field| {
            try w.writeAll(",");
            try writeJsonString(w, field.name);
            try w.writeAll(":");
            const val = @field(kvs, field.name);
            try writeValue(w, val);
        }

        try w.writeAll("}\n");
        try w.flush();
    }
};

fn writeValue(w: *std.io.Writer, val: anytype) !void {
    const T = @TypeOf(val);
    switch (@typeInfo(T)) {
        .int, .comptime_int => {
            try w.print("{d}", .{val});
        },
        .float, .comptime_float => {
            try w.print("{d}", .{val});
        },
        .bool => {
            try w.writeAll(if (val) "true" else "false");
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try writeJsonString(w, val);
            } else if (ptr.size == .one and @typeInfo(ptr.child) == .array) {
                const child_info = @typeInfo(ptr.child).array;
                if (child_info.child == u8) {
                    try writeJsonString(w, val);
                } else {
                    try w.print("\"{any}\"", .{val});
                }
            } else {
                try w.print("\"{any}\"", .{val});
            }
        },
        .@"enum" => {
            try w.print("\"{s}\"", .{@tagName(val)});
        },
        else => {
            try w.print("\"{any}\"", .{val});
        },
    }
}

fn writeJsonString(w: *std.io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{@as(u16, c)});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

fn writeTimestamp(w: *std.io.Writer) !void {
    const secs: u64 = @intCast(@max(std.time.timestamp(), 0));
    const es = epoch.EpochSeconds{ .secs = secs };
    const epoch_day = es.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = es.getDaySeconds();

    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u16, year_day.year),
        @as(u8, month_day.month.numeric()),
        @as(u8, month_day.day_index + 1),
        @as(u8, day_seconds.getHoursIntoDay()),
        @as(u8, day_seconds.getMinutesIntoHour()),
        @as(u8, day_seconds.getSecondsIntoMinute()),
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

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

        logger.writeLog(case.lvl, "test", .{});

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
