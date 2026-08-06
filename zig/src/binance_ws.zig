//! Binance Futures `bookTicker` consumer.
//!
//! Phase 3 (TASK-3.3): Subscribe to a configurable list of Binance USDT-M
//! futures symbols, parse the bookTicker frames into mid/bid/ask + a
//! nanosecond receive timestamp, expose a thread-safe getter, reconnect
//! with a fixed 2-second delay, and emit a feed-down signal when the
//! engine has not received any frame for >30 seconds.

const std = @import("std");
const log = @import("logger.zig");
const ws_lib = @import("websocket");

pub const BINANCE_WS_HOST = "fstream.binance.com";
pub const BINANCE_WS_PORT: u16 = 443;
pub const RECONNECT_DELAY_MS: u64 = 2_000;
pub const FEED_DOWN_THRESHOLD_NS: i64 = 30 * std.time.ns_per_s;
pub const MAX_SYMBOLS: usize = 64;
pub const MAX_SYMBOL_LEN: usize = 24;

pub const Quote = struct {
    bid: f64 = 0.0,
    ask: f64 = 0.0,
    mid: f64 = 0.0,
    ts_ns: i64 = 0,
};

const SymbolEntry = struct {
    name_buf: [MAX_SYMBOL_LEN]u8 = [_]u8{0} ** MAX_SYMBOL_LEN,
    name_len: u8 = 0,
    quote: Quote = .{},

    pub fn name(self: *const SymbolEntry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const BinanceFeed = struct {
    allocator: std.mem.Allocator,
    symbols: [][]const u8,
    mu: std.Thread.Mutex = .{},
    entries: [MAX_SYMBOLS]SymbolEntry = [_]SymbolEntry{.{}} ** MAX_SYMBOLS,
    n_entries: u8 = 0,

    last_msg_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    feed_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reconnect_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    msg_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Optional persistence callback invoked once per accepted bookTicker
    /// frame. Allows main.zig to write into binance_prices without coupling
    /// the feed module to db.zig.
    persist_cb: ?*const fn (ctx: ?*anyopaque, symbol: []const u8, q: Quote) void = null,
    persist_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, symbols: [][]const u8) BinanceFeed {
        var f = BinanceFeed{
            .allocator = allocator,
            .symbols = symbols,
        };
        for (symbols) |s| {
            if (f.n_entries >= MAX_SYMBOLS) break;
            if (s.len == 0 or s.len > MAX_SYMBOL_LEN) continue;
            var e: SymbolEntry = .{};
            // Symbols are normalised to UPPER for the binance API and stored
            // verbatim for matching incoming `s` field (which is upper-case).
            for (s, 0..) |ch, i| {
                e.name_buf[i] = std.ascii.toUpper(ch);
            }
            e.name_len = @intCast(s.len);
            f.entries[f.n_entries] = e;
            f.n_entries += 1;
        }
        return f;
    }

    pub fn deinit(_: *BinanceFeed) void {}

    pub fn stop(self: *BinanceFeed) void {
        self.should_stop.store(true, .seq_cst);
    }

    pub fn setPersistCallback(
        self: *BinanceFeed,
        cb: *const fn (ctx: ?*anyopaque, symbol: []const u8, q: Quote) void,
        ctx: ?*anyopaque,
    ) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.persist_cb = cb;
        self.persist_ctx = ctx;
    }

    fn findEntry(self: *BinanceFeed, symbol: []const u8) ?*SymbolEntry {
        var i: u8 = 0;
        while (i < self.n_entries) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(self.entries[i].name(), symbol)) return &self.entries[i];
        }
        return null;
    }

    /// Latest cached quote for `symbol`, or null if no frame received yet.
    pub fn quote(self: *BinanceFeed, symbol: []const u8) ?Quote {
        self.mu.lock();
        defer self.mu.unlock();
        const e = self.findEntry(symbol) orelse return null;
        if (e.quote.ts_ns == 0) return null;
        return e.quote;
    }

    pub fn updateQuote(self: *BinanceFeed, symbol: []const u8, bid: f64, ask: f64) void {
        const ts_now: i128 = std.time.nanoTimestamp();
        const ts_ns: i64 = @intCast(@max(@as(i128, 0), @min(@as(i128, std.math.maxInt(i64)), ts_now)));
        const mid = (bid + ask) / 2.0;
        var emit_q: ?Quote = null;
        var emit_sym: []const u8 = symbol;
        var callback: ?*const fn (ctx: ?*anyopaque, symbol: []const u8, q: Quote) void = null;
        var callback_ctx: ?*anyopaque = null;
        {
            self.mu.lock();
            defer self.mu.unlock();
            const e = self.findEntry(symbol) orelse return;
            e.quote = .{ .bid = bid, .ask = ask, .mid = mid, .ts_ns = ts_ns };
            emit_q = e.quote;
            emit_sym = e.name();
            callback = self.persist_cb;
            callback_ctx = self.persist_ctx;
        }
        self.last_msg_ns.store(ts_ns, .seq_cst);
        _ = self.msg_count.fetchAdd(1, .seq_cst);
        // Clear any prior feed-down condition.
        const was_down = self.feed_down.swap(false, .seq_cst);
        if (was_down) {
            log.info("binance", "feed restored after outage", .{});
        }
        if (callback) |cb| if (emit_q) |q| cb(callback_ctx, emit_sym, q);
    }

    /// Build the multi-stream URL path: /stream?streams=btcusdt@bookTicker/...
    pub fn buildStreamPath(self: *BinanceFeed, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.writeAll("/stream?streams=");
        var i: u8 = 0;
        while (i < self.n_entries) : (i += 1) {
            if (i > 0) try w.writeAll("/");
            const sym = self.entries[i].name();
            // Symbol stream name is lowercase + "@bookTicker".
            for (sym) |ch| try w.writeByte(std.ascii.toLower(ch));
            try w.writeAll("@bookTicker");
        }
        return fbs.getWritten();
    }

    /// Background watchdog that flips `feed_down` if no message has arrived
    /// in the last FEED_DOWN_THRESHOLD_NS. Emits a single warning per
    /// transition. Safe to run in its own thread.
    pub fn watchdogLoop(self: *BinanceFeed) void {
        while (!self.should_stop.load(.seq_cst)) {
            std.Thread.sleep(2 * std.time.ns_per_s);
            const last = self.last_msg_ns.load(.seq_cst);
            if (last == 0) continue;
            const now_i128: i128 = std.time.nanoTimestamp();
            const now_i64: i64 = @intCast(@max(@as(i128, 0), @min(@as(i128, std.math.maxInt(i64)), now_i128)));
            const age = now_i64 - last;
            if (age >= FEED_DOWN_THRESHOLD_NS) {
                const was_down = self.feed_down.swap(true, .seq_cst);
                if (!was_down) {
                    log.warn("binance", "feed-down: no frame in {d}ms", .{@divTrunc(age, std.time.ns_per_ms)});
                }
            }
        }
    }

    /// Connect+read loop with fixed 2-second reconnect delay. Safe to run
    /// in its own thread.
    pub fn run(self: *BinanceFeed) void {
        if (self.n_entries == 0) {
            log.warn("binance", "no symbols configured; feed thread idle", .{});
            return;
        }

        while (!self.should_stop.load(.seq_cst)) {
            self.runConnection() catch |e| {
                log.warn("binance", "connection error: {s}", .{@errorName(e)});
            };
            if (self.should_stop.load(.seq_cst)) break;
            _ = self.reconnect_count.fetchAdd(1, .seq_cst);
            std.Thread.sleep(RECONNECT_DELAY_MS * std.time.ns_per_ms);
        }
    }

    fn runConnection(self: *BinanceFeed) !void {
        var path_buf: [4096]u8 = undefined;
        const path = try self.buildStreamPath(&path_buf);

        var client = try ws_lib.Client.init(self.allocator, .{
            .host = BINANCE_WS_HOST,
            .port = BINANCE_WS_PORT,
            .tls = true,
            .max_size = 4 * 1024 * 1024,
        });
        defer client.deinit();

        try client.handshake(path, .{
            .timeout_ms = 10_000,
            .headers = "Host: " ++ BINANCE_WS_HOST ++ "\r\n",
        });
        log.info("binance", "connected, streaming {d} symbols", .{self.n_entries});

        try client.readTimeout(5_000);
        while (!self.should_stop.load(.seq_cst)) {
            const message = client.read() catch |err| switch (err) {
                error.Closed => return,
                else => return err,
            } orelse continue;
            defer client.done(message);

            switch (message.type) {
                .text, .binary => self.handleMessage(message.data),
                .close => return,
                .ping => try client.writePong(message.data),
                .pong => {},
            }
        }
    }

    fn handleMessage(self: *BinanceFeed, data: []const u8) void {
        const parsed = parseBookTicker(self.allocator, data) catch |e| {
            log.warn("binance", "parse failed: {s}", .{@errorName(e)});
            return;
        };
        if (parsed) |p| {
            defer self.allocator.free(p.symbol);
            self.updateQuote(p.symbol, p.bid, p.ask);
        }
    }
};

pub const ParsedBookTicker = struct {
    symbol: []const u8,
    bid: f64,
    ask: f64,
};

pub const ParseError = error{
    InvalidJson,
    OutOfMemory,
    MissingFields,
};

/// Parse a Binance Futures bookTicker frame. Accepts both the multi-stream
/// envelope ({"stream":"...","data":{...}}) and a bare bookTicker payload.
/// The returned `symbol` slice references the parser's owned JSON storage —
/// callers must consume it before the parser is dropped, OR (as we do
/// internally) copy the value before the parser scope ends. The frame
/// returns `null` when no symbol/bid/ask is present.
pub fn parseBookTicker(allocator: std.mem.Allocator, body: []const u8) ParseError!?ParsedBookTicker {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidJson,
    };

    // Multi-stream envelope: { "stream": "...", "data": {...} }
    const payload = if (root.get("data")) |dv| switch (dv) {
        .object => |o| o,
        else => return error.InvalidJson,
    } else root;

    const sym_val = payload.get("s") orelse return null;
    const sym = switch (sym_val) {
        .string => |s| s,
        else => return null,
    };
    const bid = parseNumeric(payload.get("b")) orelse return null;
    const ask = parseNumeric(payload.get("a")) orelse return null;

    // Use a static buffer since parsed JSON storage will free; copy bytes
    // for the caller. We allocate via the caller's allocator so the value
    // outlives the JSON parser.
    const sym_owned = allocator.dupe(u8, sym) catch return error.OutOfMemory;
    return ParsedBookTicker{ .symbol = sym_owned, .bid = bid, .ask = ask };
}

fn parseNumeric(v: ?std.json.Value) ?f64 {
    const val = v orelse return null;
    return switch (val) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "binance_ws: parse bookTicker bare payload" {
    const body =
        \\{"e":"bookTicker","u":1234,"s":"BTCUSDT","b":"60000.10","B":"1.5","a":"60000.20","A":"2.0","T":1700000000000,"E":1700000000050}
    ;
    const parsed = try parseBookTicker(testing.allocator, body);
    try testing.expect(parsed != null);
    defer testing.allocator.free(parsed.?.symbol);
    try testing.expectEqualStrings("BTCUSDT", parsed.?.symbol);
    try testing.expectApproxEqAbs(@as(f64, 60000.10), parsed.?.bid, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 60000.20), parsed.?.ask, 1e-6);
}

test "binance_ws: parse bookTicker multi-stream envelope" {
    const body =
        \\{"stream":"btcusdt@bookTicker","data":{"s":"BTCUSDT","b":"100.0","a":"101.0","u":1}}
    ;
    const parsed = try parseBookTicker(testing.allocator, body);
    try testing.expect(parsed != null);
    defer testing.allocator.free(parsed.?.symbol);
    const mid = (parsed.?.bid + parsed.?.ask) / 2.0;
    try testing.expectApproxEqAbs(@as(f64, 100.5), mid, 1e-9);
}

test "binance_ws: BinanceFeed.updateQuote round-trip" {
    var syms = [_][]const u8{"BTCUSDT"};
    var feed = BinanceFeed.init(testing.allocator, &syms);
    defer feed.deinit();

    feed.updateQuote("BTCUSDT", 100.0, 101.0);
    const q = feed.quote("BTCUSDT").?;
    try testing.expectApproxEqAbs(@as(f64, 100.0), q.bid, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 101.0), q.ask, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 100.5), q.mid, 1e-9);
    try testing.expect(q.ts_ns > 0);
}

test "binance_ws: buildStreamPath joins symbols lowercase" {
    var syms = [_][]const u8{ "BTCUSDT", "ETHUSDT" };
    var feed = BinanceFeed.init(testing.allocator, &syms);
    defer feed.deinit();
    var buf: [256]u8 = undefined;
    const path = try feed.buildStreamPath(&buf);
    try testing.expectEqualStrings(
        "/stream?streams=btcusdt@bookTicker/ethusdt@bookTicker",
        path,
    );
}

test "binance_ws: parseBookTicker returns null on missing fields" {
    const body =
        \\{"foo":"bar"}
    ;
    const parsed = try parseBookTicker(testing.allocator, body);
    try testing.expect(parsed == null);
}
