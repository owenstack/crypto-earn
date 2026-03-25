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


