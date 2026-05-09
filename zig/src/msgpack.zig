//! Minimal deterministic MessagePack encoder used by the Hyperliquid
//! signing path. Produces canonical bytes with sorted map keys so that the
//! resulting digest is stable across reruns.
//!
//! Only the subset of msgpack required for HL action payloads is implemented:
//!   - nil, bool
//!   - int / uint (positive fixint, uint8/16/32/64, negative fixint, int8/16/32/64)
//!   - float64
//!   - str (fixstr, str8, str16, str32)
//!   - array (fixarray, array16, array32)
//!   - map (fixmap, map16, map32)
//!
//! High-level encoders accept `std.json.Value` so the caller can hand in a
//! parsed JSON action and receive the canonical msgpack preimage.

const std = @import("std");

pub const Error = error{
    OutOfMemory,
    StringTooLong,
    ArrayTooLong,
    MapTooLong,
    UnsupportedJsonType,
};

/// Streaming msgpack writer that appends into an ArrayList(u8).
pub const Writer = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.allocator);
    }

    /// Take ownership of the encoded bytes; the writer is reset to empty.
    pub fn toOwnedSlice(self: *Writer) ![]u8 {
        return self.buf.toOwnedSlice(self.allocator);
    }

    pub fn bytes(self: *const Writer) []const u8 {
        return self.buf.items;
    }

    pub fn encodeNil(self: *Writer) !void {
        try self.buf.append(self.allocator, 0xc0);
    }

    pub fn encodeBool(self: *Writer, b: bool) !void {
        try self.buf.append(self.allocator, if (b) 0xc3 else 0xc2);
    }

    pub fn encodeUint(self: *Writer, v: u64) !void {
        if (v <= 0x7f) {
            try self.buf.append(self.allocator, @intCast(v));
        } else if (v <= std.math.maxInt(u8)) {
            try self.buf.append(self.allocator, 0xcc);
            try self.buf.append(self.allocator, @intCast(v));
        } else if (v <= std.math.maxInt(u16)) {
            try self.buf.append(self.allocator, 0xcd);
            var be: [2]u8 = undefined;
            std.mem.writeInt(u16, &be, @intCast(v), .big);
            try self.buf.appendSlice(self.allocator, &be);
        } else if (v <= std.math.maxInt(u32)) {
            try self.buf.append(self.allocator, 0xce);
            var be: [4]u8 = undefined;
            std.mem.writeInt(u32, &be, @intCast(v), .big);
            try self.buf.appendSlice(self.allocator, &be);
        } else {
            try self.buf.append(self.allocator, 0xcf);
            var be: [8]u8 = undefined;
            std.mem.writeInt(u64, &be, v, .big);
            try self.buf.appendSlice(self.allocator, &be);
        }
    }

    pub fn encodeInt(self: *Writer, v: i64) !void {
        if (v >= 0) return self.encodeUint(@intCast(v));
        if (v >= -32) {
            // negative fixint: 111xxxxx (5-bit signed)
            const byte: u8 = @bitCast(@as(i8, @intCast(v)));
            try self.buf.append(self.allocator, byte);
            return;
        }
        if (v >= std.math.minInt(i8)) {
            try self.buf.append(self.allocator, 0xd0);
            try self.buf.append(self.allocator, @bitCast(@as(i8, @intCast(v))));
        } else if (v >= std.math.minInt(i16)) {
            try self.buf.append(self.allocator, 0xd1);
            var be: [2]u8 = undefined;
            std.mem.writeInt(i16, &be, @intCast(v), .big);
            try self.buf.appendSlice(self.allocator, &be);
        } else if (v >= std.math.minInt(i32)) {
            try self.buf.append(self.allocator, 0xd2);
            var be: [4]u8 = undefined;
            std.mem.writeInt(i32, &be, @intCast(v), .big);
            try self.buf.appendSlice(self.allocator, &be);
        } else {
            try self.buf.append(self.allocator, 0xd3);
            var be: [8]u8 = undefined;
            std.mem.writeInt(i64, &be, v, .big);
            try self.buf.appendSlice(self.allocator, &be);
        }
    }

    pub fn encodeFloat(self: *Writer, v: f64) !void {
        try self.buf.append(self.allocator, 0xcb);
        var be: [8]u8 = undefined;
        const bits: u64 = @bitCast(v);
        std.mem.writeInt(u64, &be, bits, .big);
        try self.buf.appendSlice(self.allocator, &be);
    }

    pub fn encodeStr(self: *Writer, s: []const u8) !void {
        if (s.len <= 31) {
            try self.buf.append(self.allocator, 0xa0 | @as(u8, @intCast(s.len)));
        } else if (s.len <= std.math.maxInt(u8)) {
            try self.buf.append(self.allocator, 0xd9);
            try self.buf.append(self.allocator, @intCast(s.len));
        } else if (s.len <= std.math.maxInt(u16)) {
            try self.buf.append(self.allocator, 0xda);
            var be: [2]u8 = undefined;
            std.mem.writeInt(u16, &be, @intCast(s.len), .big);
            try self.buf.appendSlice(self.allocator, &be);
        } else if (s.len <= std.math.maxInt(u32)) {
            try self.buf.append(self.allocator, 0xdb);
            var be: [4]u8 = undefined;
            std.mem.writeInt(u32, &be, @intCast(s.len), .big);
            try self.buf.appendSlice(self.allocator, &be);
        } else {
            return error.StringTooLong;
        }
        try self.buf.appendSlice(self.allocator, s);
    }

    pub fn encodeArrayHeader(self: *Writer, n: usize) !void {
        if (n <= 15) {
            try self.buf.append(self.allocator, 0x90 | @as(u8, @intCast(n)));
        } else if (n <= std.math.maxInt(u16)) {
            try self.buf.append(self.allocator, 0xdc);
            var be: [2]u8 = undefined;
            std.mem.writeInt(u16, &be, @intCast(n), .big);
            try self.buf.appendSlice(self.allocator, &be);
        } else if (n <= std.math.maxInt(u32)) {
            try self.buf.append(self.allocator, 0xdd);
            var be: [4]u8 = undefined;
            std.mem.writeInt(u32, &be, @intCast(n), .big);
            try self.buf.appendSlice(self.allocator, &be);
        } else {
            return error.ArrayTooLong;
        }
    }

    pub fn encodeMapHeader(self: *Writer, n: usize) !void {
        if (n <= 15) {
            try self.buf.append(self.allocator, 0x80 | @as(u8, @intCast(n)));
        } else if (n <= std.math.maxInt(u16)) {
            try self.buf.append(self.allocator, 0xde);
            var be: [2]u8 = undefined;
            std.mem.writeInt(u16, &be, @intCast(n), .big);
            try self.buf.appendSlice(self.allocator, &be);
        } else if (n <= std.math.maxInt(u32)) {
            try self.buf.append(self.allocator, 0xdf);
            var be: [4]u8 = undefined;
            std.mem.writeInt(u32, &be, @intCast(n), .big);
            try self.buf.appendSlice(self.allocator, &be);
        } else {
            return error.MapTooLong;
        }
    }

    pub fn encodeJson(self: *Writer, v: std.json.Value) Error!void {
        switch (v) {
            .null => try self.encodeNil(),
            .bool => |b| try self.encodeBool(b),
            .integer => |i| try self.encodeInt(i),
            .number_string => |s| {
                // Treat number_string as a numeric where possible; fall back to string.
                if (std.fmt.parseInt(i64, s, 10)) |i| {
                    try self.encodeInt(i);
                } else |_| if (std.fmt.parseInt(u64, s, 10)) |u| {
                    try self.encodeUint(u);
                } else |_| if (std.fmt.parseFloat(f64, s)) |f| {
                    try self.encodeFloat(f);
                } else |_| {
                    try self.encodeStr(s);
                }
            },
            .float => |f| try self.encodeFloat(f),
            .string => |s| try self.encodeStr(s),
            .array => |arr| {
                try self.encodeArrayHeader(arr.items.len);
                for (arr.items) |item| try self.encodeJson(item);
            },
            .object => |obj| {
                // Deterministic: sort keys lexicographically.
                const KV = struct { k: []const u8, v: std.json.Value };
                var entries = self.allocator.alloc(KV, obj.count()) catch return error.OutOfMemory;
                defer self.allocator.free(entries);
                var it = obj.iterator();
                var idx: usize = 0;
                while (it.next()) |e| : (idx += 1) {
                    entries[idx] = .{ .k = e.key_ptr.*, .v = e.value_ptr.* };
                }
                std.mem.sort(KV, entries, {}, struct {
                    fn lt(_: void, a: KV, b: KV) bool {
                        return std.mem.lessThan(u8, a.k, b.k);
                    }
                }.lt);

                try self.encodeMapHeader(entries.len);
                for (entries) |kv| {
                    try self.encodeStr(kv.k);
                    try self.encodeJson(kv.v);
                }
            },
        }
    }
};

/// Convenience: msgpack-encode a parsed JSON value using deterministic
/// (sorted) map ordering. Caller owns the returned slice.
pub fn encodeActionForSigning(allocator: std.mem.Allocator, action: std.json.Value) ![]u8 {
    var w = Writer.init(allocator);
    errdefer w.deinit();
    try w.encodeJson(action);
    return w.toOwnedSlice();
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "msgpack: empty map encodes to 0x80" {
    var w = Writer.init(testing.allocator);
    defer w.deinit();
    try w.encodeMapHeader(0);
    try testing.expectEqualSlices(u8, &[_]u8{0x80}, w.bytes());
}

test "msgpack: positive fixint" {
    var w = Writer.init(testing.allocator);
    defer w.deinit();
    try w.encodeUint(0);
    try w.encodeUint(0x7f);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x7f }, w.bytes());
}

test "msgpack: uint8/16/32/64 boundaries" {
    var w = Writer.init(testing.allocator);
    defer w.deinit();
    try w.encodeUint(0x80);
    try w.encodeUint(0x100);
    try w.encodeUint(0x10000);
    try w.encodeUint(0x100000000);
    try testing.expectEqualSlices(u8, &[_]u8{
        0xcc, 0x80,
        0xcd, 0x01,
        0x00, 0xce,
        0x00, 0x01,
        0x00, 0x00,
        0xcf, 0x00,
        0x00, 0x00,
        0x01, 0x00,
        0x00, 0x00,
        0x00,
    }, w.bytes());
}

test "msgpack: negative fixint and int8" {
    var w = Writer.init(testing.allocator);
    defer w.deinit();
    try w.encodeInt(-1);
    try w.encodeInt(-32);
    try w.encodeInt(-33);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0xe0, 0xd0, 0xdf }, w.bytes());
}

test "msgpack: fixstr" {
    var w = Writer.init(testing.allocator);
    defer w.deinit();
    try w.encodeStr("hello");
    try testing.expectEqualSlices(u8, &[_]u8{ 0xa5, 'h', 'e', 'l', 'l', 'o' }, w.bytes());
}

test "msgpack: float64 zero" {
    var w = Writer.init(testing.allocator);
    defer w.deinit();
    try w.encodeFloat(0.0);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xcb, 0, 0, 0, 0, 0, 0, 0, 0 }, w.bytes());
}

test "msgpack: deterministic map key ordering" {
    // Build a JSON object with keys inserted in non-sorted order; ensure the
    // encoded bytes have keys sorted lexicographically.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var obj = std.json.ObjectMap.init(a);
    try obj.put("b", .{ .integer = 2 });
    try obj.put("a", .{ .integer = 1 });
    const value: std.json.Value = .{ .object = obj };

    const out = try encodeActionForSigning(testing.allocator, value);
    defer testing.allocator.free(out);

    // map of size 2, then ("a"=>1) then ("b"=>2)
    try testing.expectEqualSlices(u8, &[_]u8{
        0x82, // fixmap size 2
        0xa1,
        'a',
        0x01,
        0xa1,
        'b',
        0x02,
    }, out);
}

test "msgpack: array of mixed primitives" {
    var w = Writer.init(testing.allocator);
    defer w.deinit();
    try w.encodeArrayHeader(3);
    try w.encodeBool(true);
    try w.encodeNil();
    try w.encodeStr("x");
    try testing.expectEqualSlices(u8, &[_]u8{ 0x93, 0xc3, 0xc0, 0xa1, 'x' }, w.bytes());
}
