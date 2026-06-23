//! Hyperliquid `l2Book` WebSocket consumer.
//!
//! Phase 3 (TASK-3.2): Subscribe to one or more HL coins, ingest snapshot
//! and incremental updates, expose thread-safe best-bid/ask/mid getters,
//! and reconnect with exponential backoff (1s → 30s) on disconnect. On
//! reconnect, all subscriptions are re-issued and books reload from the
//! next snapshot.
//!
//! Note: HL's public `l2Book` channel currently delivers full top-N
//! snapshots rather than per-level deltas, but this module supports both
//! shapes — `applyDelta` treats zero-size levels as removals and merges
//! everything else into the existing book. This means the same code path
//! handles future delta upgrades without API churn.

const std = @import("std");
const log = @import("logger.zig");
const ws_lib = @import("websocket");

pub const HL_WS_HOST_MAINNET = "api.hyperliquid.xyz";
pub const HL_WS_HOST_TESTNET = "api.hyperliquid-testnet.xyz";
pub const HL_WS_PATH = "/ws";

pub const MAX_LEVELS: usize = 20;
pub const MAX_SYMBOLS: usize = 64;
pub const MAX_SYMBOL_LEN: usize = 24;

pub const Level = struct {
    price: f64 = 0.0,
    size: f64 = 0.0,
};

pub const Book = struct {
    bids: [MAX_LEVELS]Level = [_]Level{.{}} ** MAX_LEVELS,
    n_bids: u8 = 0,
    asks: [MAX_LEVELS]Level = [_]Level{.{}} ** MAX_LEVELS,
    n_asks: u8 = 0,
    last_update_ns: i64 = 0,

    pub fn bestBid(self: *const Book) ?f64 {
        if (self.n_bids == 0) return null;
        return self.bids[0].price;
    }

    pub fn bestAsk(self: *const Book) ?f64 {
        if (self.n_asks == 0) return null;
        return self.asks[0].price;
    }

    pub fn mid(self: *const Book) ?f64 {
        const b = self.bestBid() orelse return null;
        const a = self.bestAsk() orelse return null;
        return (b + a) / 2.0;
    }
};

const SymbolEntry = struct {
    name_buf: [MAX_SYMBOL_LEN]u8 = [_]u8{0} ** MAX_SYMBOL_LEN,
    name_len: u8 = 0,
    book: Book = .{},

    pub fn name(self: *const SymbolEntry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Thread-safe HL orderbook cache. The websocket loop mutates `entries`
/// under `mu`; readers (strategy, dashboard) call best/mid getters which
/// take the same lock briefly.
pub const Orderbook = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    symbols: [][]const u8,
    mu: std.Thread.Mutex = .{},
    entries: [MAX_SYMBOLS]SymbolEntry = [_]SymbolEntry{.{}} ** MAX_SYMBOLS,
    n_entries: u8 = 0,

    snapshot_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    delta_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    reconnect_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    reconnect_delay_ms: u64 = 1_000,
    max_reconnect_delay_ms: u64 = 30_000,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Optional persistence callback — called once per applied snapshot/delta.
    persist_cb: ?*const fn (ctx: ?*anyopaque, symbol: []const u8, book: *const Book) void = null,
    persist_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, symbols: [][]const u8) Orderbook {
        var ob = Orderbook{
            .allocator = allocator,
            .host = host,
            .symbols = symbols,
        };
        for (symbols) |sym| {
            if (ob.n_entries >= MAX_SYMBOLS) {
                log.warn("hl_ob", "symbol dropped: reason=max_symbols name={s}", .{sym});
                break;
            }
            if (sym.len > MAX_SYMBOL_LEN) {
                log.warn("hl_ob", "symbol dropped: reason=max_len name={s} len={d}", .{ sym, sym.len });
                continue;
            }
            var e: SymbolEntry = .{};
            @memcpy(e.name_buf[0..sym.len], sym);
            e.name_len = @intCast(sym.len);
            ob.entries[ob.n_entries] = e;
            ob.n_entries += 1;
        }
        return ob;
    }

    pub fn deinit(_: *Orderbook) void {
        // entries are inline; nothing to free.
    }

    pub fn stop(self: *Orderbook) void {
        self.should_stop.store(true, .seq_cst);
    }

    pub fn setPersistCallback(
        self: *Orderbook,
        cb: *const fn (ctx: ?*anyopaque, symbol: []const u8, book: *const Book) void,
        ctx: ?*anyopaque,
    ) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.persist_cb = cb;
        self.persist_ctx = ctx;
    }

    fn findEntry(self: *Orderbook, symbol: []const u8) ?*SymbolEntry {
        var i: u8 = 0;
        while (i < self.n_entries) : (i += 1) {
            if (std.mem.eql(u8, self.entries[i].name(), symbol)) return &self.entries[i];
        }
        return null;
    }

    pub fn bestBid(self: *Orderbook, symbol: []const u8) ?f64 {
        self.mu.lock();
        defer self.mu.unlock();
        const e = self.findEntry(symbol) orelse return null;
        return e.book.bestBid();
    }

    pub fn bestAsk(self: *Orderbook, symbol: []const u8) ?f64 {
        self.mu.lock();
        defer self.mu.unlock();
        const e = self.findEntry(symbol) orelse return null;
        return e.book.bestAsk();
    }

    pub fn mid(self: *Orderbook, symbol: []const u8) ?f64 {
        self.mu.lock();
        defer self.mu.unlock();
        const e = self.findEntry(symbol) orelse return null;
        return e.book.mid();
    }

    /// Replace the entire book for `symbol` with `bids`/`asks` (sorted
    /// descending bids, ascending asks). Truncates to MAX_LEVELS.
    pub fn applySnapshot(
        self: *Orderbook,
        symbol: []const u8,
        bids: []const Level,
        asks: []const Level,
        ts_ns: i64,
    ) void {
        self.mu.lock();
        defer self.mu.unlock();
        const e = self.findEntry(symbol) orelse return;

        e.book.n_bids = 0;
        for (bids) |lvl| {
            if (e.book.n_bids >= MAX_LEVELS) break;
            if (lvl.size <= 0) continue;
            e.book.bids[e.book.n_bids] = lvl;
            e.book.n_bids += 1;
        }
        sortBids(e.book.bids[0..e.book.n_bids]);

        e.book.n_asks = 0;
        for (asks) |lvl| {
            if (e.book.n_asks >= MAX_LEVELS) break;
            if (lvl.size <= 0) continue;
            e.book.asks[e.book.n_asks] = lvl;
            e.book.n_asks += 1;
        }
        sortAsks(e.book.asks[0..e.book.n_asks]);
        e.book.last_update_ns = ts_ns;

        _ = self.snapshot_count.fetchAdd(1, .seq_cst);

        if (self.persist_cb) |cb| cb(self.persist_ctx, symbol, &e.book);
    }

    /// Apply a list of incremental level updates. Zero-size entries are
    /// removed; non-zero entries insert or update at the matching price.
    pub fn applyDelta(
        self: *Orderbook,
        symbol: []const u8,
        bid_updates: []const Level,
        ask_updates: []const Level,
        ts_ns: i64,
    ) void {
        self.mu.lock();
        defer self.mu.unlock();
        const e = self.findEntry(symbol) orelse return;

        for (bid_updates) |lvl| applyOne(&e.book.bids, &e.book.n_bids, lvl);
        sortBids(e.book.bids[0..e.book.n_bids]);

        for (ask_updates) |lvl| applyOne(&e.book.asks, &e.book.n_asks, lvl);
        sortAsks(e.book.asks[0..e.book.n_asks]);

        e.book.last_update_ns = ts_ns;
        _ = self.delta_count.fetchAdd(1, .seq_cst);

        if (self.persist_cb) |cb| cb(self.persist_ctx, symbol, &e.book);
    }

    /// WebSocket loop with auto-reconnect (1s..30s exponential). Resubscribes
    /// to all configured symbols on every successful connect.
    pub fn run(self: *Orderbook) void {
        while (!self.should_stop.load(.seq_cst)) {
            log.info("hl_ob", "connecting wss://{s}{s} (n_symbols={d})", .{
                self.host, HL_WS_PATH, self.n_entries,
            });

            self.runConnection() catch |e| {
                log.warn("hl_ob", "connection error: {s}", .{@errorName(e)});
            };

            if (self.should_stop.load(.seq_cst)) break;
            _ = self.reconnect_count.fetchAdd(1, .seq_cst);

            log.warn("hl_ob", "reconnecting in {d}ms", .{self.reconnect_delay_ms});
            std.Thread.sleep(self.reconnect_delay_ms * std.time.ns_per_ms);
            self.reconnect_delay_ms = @min(self.reconnect_delay_ms * 2, self.max_reconnect_delay_ms);
        }
    }

    fn runConnection(self: *Orderbook) !void {
        var client = try ws_lib.Client.init(self.allocator, .{
            .host = self.host,
            .port = 443,
            .tls = true,
            .max_size = 8 * 1024 * 1024,
        });
        defer client.deinit();

        // The websocket library expects "Host:" in headers; format on stack.
        var host_buf: [128]u8 = undefined;
        const host_hdr = std.fmt.bufPrint(&host_buf, "Host: {s}\r\n", .{self.host}) catch unreachable;

        try client.handshake(HL_WS_PATH, .{
            .timeout_ms = 10_000,
            .headers = host_hdr,
        });

        // Subscribe to each configured symbol.
        var i: u8 = 0;
        while (i < self.n_entries) : (i += 1) {
            const sym = self.entries[i].name();
            var sub_buf: [256]u8 = undefined;
            const sub_msg = std.fmt.bufPrint(
                &sub_buf,
                "{{\"method\":\"subscribe\",\"subscription\":{{\"type\":\"l2Book\",\"coin\":\"{s}\"}}}}",
                .{sym},
            ) catch continue;
            // ws_lib mutates the buffer; copy into a local mutable buffer.
            var send_buf: [256]u8 = undefined;
            @memcpy(send_buf[0..sub_msg.len], sub_msg);
            client.write(send_buf[0..sub_msg.len]) catch |e| {
                log.err("hl_ob", "subscribe write failed for {s}: {s}", .{ sym, @errorName(e) });
                return e;
            };
        }
        // Reset backoff on successful connect+subscribe.
        self.reconnect_delay_ms = 1_000;
        log.info("hl_ob", "subscribed to {d} HL l2Book channels", .{self.n_entries});

        try client.readTimeout(5_000);
        while (!self.should_stop.load(.seq_cst)) {
            const message = client.read() catch |err| switch (err) {
                // Zig 0.15 TLS surfaces socket read timeouts as ReadFailed
                // here. An idle HL book is not a broken connection.
                error.ReadFailed => continue,
                error.Closed => return,
                else => return err,
            } orelse continue;

            defer client.done(message);

            switch (message.type) {
                .text, .binary => self.handleMessage(message.data),
                .close => return,
                .ping, .pong => {},
            }
        }
    }

    fn handleMessage(self: *Orderbook, data: []const u8) void {
        // HL frames look like: { "channel": "l2Book", "data": { ... } }
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
            log.warn("hl_ob", "failed to parse WS frame", .{});
            return;
        };
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };
        const channel = if (root.get("channel")) |v| switch (v) {
            .string => |s| s,
            else => return,
        } else return;
        if (!std.mem.eql(u8, channel, "l2Book")) return;

        const payload_val = root.get("data") orelse return;
        const payload = switch (payload_val) {
            .object => |o| o,
            else => return,
        };

        const coin = if (payload.get("coin")) |v| switch (v) {
            .string => |s| s,
            else => return,
        } else return;

        const ts_now: i128 = std.time.nanoTimestamp();
        const ts_ns: i64 = @intCast(@max(@as(i128, 0), @min(@as(i128, std.math.maxInt(i64)), ts_now)));

        // Parse "levels": [ [bids...], [asks...] ] where each level is
        // {"px": "...", "sz": "...", "n": N}.
        const levels_val = payload.get("levels") orelse return;
        const levels_arr = switch (levels_val) {
            .array => |a| a,
            else => return,
        };
        if (levels_arr.items.len < 2) return;

        var bid_buf: [MAX_LEVELS]Level = [_]Level{.{}} ** MAX_LEVELS;
        var ask_buf: [MAX_LEVELS]Level = [_]Level{.{}} ** MAX_LEVELS;

        const n_bids = parseLevels(levels_arr.items[0], &bid_buf);
        const n_asks = parseLevels(levels_arr.items[1], &ask_buf);

        // HL `l2Book` currently always sends a snapshot. Future delta
        // payloads can be detected by an explicit `type: "delta"` field.
        const is_delta = if (payload.get("type")) |v| switch (v) {
            .string => |s| std.mem.eql(u8, s, "delta"),
            else => false,
        } else false;

        if (is_delta) {
            self.applyDelta(coin, bid_buf[0..n_bids], ask_buf[0..n_asks], ts_ns);
        } else {
            self.applySnapshot(coin, bid_buf[0..n_bids], ask_buf[0..n_asks], ts_ns);
        }
    }
};

/// Parse a JSON array of {"px","sz"} entries into a Level buffer.
/// Returns the number of levels parsed.
fn parseLevels(side_val: std.json.Value, out: []Level) usize {
    const arr = switch (side_val) {
        .array => |a| a,
        else => return 0,
    };
    var n: usize = 0;
    for (arr.items) |entry| {
        if (n >= out.len) break;
        const obj = switch (entry) {
            .object => |o| o,
            else => continue,
        };
        const px_val = obj.get("px") orelse continue;
        const sz_val = obj.get("sz") orelse continue;

        const px = parseNumeric(px_val) orelse continue;
        const sz = parseNumeric(sz_val) orelse continue;

        out[n] = .{ .price = px, .size = sz };
        n += 1;
    }
    return n;
}

fn parseNumeric(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn applyOne(levels: []Level, n: *u8, update: Level) void {
    // Find the matching price.
    var i: u8 = 0;
    while (i < n.*) : (i += 1) {
        if (priceEq(levels[i].price, update.price)) {
            if (update.size <= 0) {
                // Remove: shift left.
                var j: u8 = i;
                while (j + 1 < n.*) : (j += 1) levels[j] = levels[j + 1];
                n.* -= 1;
            } else {
                levels[i].size = update.size;
            }
            return;
        }
    }
    // Insert if non-zero and capacity available.
    if (update.size <= 0) return;
    if (n.* >= levels.len) return;
    levels[n.*] = update;
    n.* += 1;
}

fn priceEq(a: f64, b: f64) bool {
    return @abs(a - b) < 1e-12;
}

fn sortBids(slice: []Level) void {
    std.mem.sort(Level, slice, {}, struct {
        fn lt(_: void, a: Level, b: Level) bool {
            return a.price > b.price;
        }
    }.lt);
}

fn sortAsks(slice: []Level) void {
    std.mem.sort(Level, slice, {}, struct {
        fn lt(_: void, a: Level, b: Level) bool {
            return a.price < b.price;
        }
    }.lt);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "hl_orderbook: snapshot ingestion sorts bids desc and asks asc" {
    var syms = [_][]const u8{"BTC"};
    var ob = Orderbook.init(testing.allocator, HL_WS_HOST_TESTNET, &syms);
    defer ob.deinit();

    const bids = [_]Level{
        .{ .price = 100.0, .size = 1.0 },
        .{ .price = 102.0, .size = 2.0 },
        .{ .price = 101.0, .size = 3.0 },
    };
    const asks = [_]Level{
        .{ .price = 105.0, .size = 1.0 },
        .{ .price = 104.0, .size = 2.0 },
        .{ .price = 106.0, .size = 3.0 },
    };
    ob.applySnapshot("BTC", &bids, &asks, 1);

    try testing.expectEqual(@as(?f64, 102.0), ob.bestBid("BTC"));
    try testing.expectEqual(@as(?f64, 104.0), ob.bestAsk("BTC"));
    try testing.expectEqual(@as(?f64, 103.0), ob.mid("BTC"));
}

test "hl_orderbook: delta zero-size removes level" {
    var syms = [_][]const u8{"ETH"};
    var ob = Orderbook.init(testing.allocator, HL_WS_HOST_TESTNET, &syms);
    defer ob.deinit();

    const bids = [_]Level{
        .{ .price = 100.0, .size = 1.0 },
        .{ .price = 99.0, .size = 2.0 },
    };
    const asks = [_]Level{
        .{ .price = 101.0, .size = 1.0 },
    };
    ob.applySnapshot("ETH", &bids, &asks, 1);
    try testing.expectEqual(@as(?f64, 100.0), ob.bestBid("ETH"));

    // Remove top bid, add a new better ask, update existing ask size.
    const bid_upd = [_]Level{
        .{ .price = 100.0, .size = 0.0 },
    };
    const ask_upd = [_]Level{
        .{ .price = 100.5, .size = 5.0 },
        .{ .price = 101.0, .size = 7.0 },
    };
    ob.applyDelta("ETH", &bid_upd, &ask_upd, 2);

    try testing.expectEqual(@as(?f64, 99.0), ob.bestBid("ETH"));
    try testing.expectEqual(@as(?f64, 100.5), ob.bestAsk("ETH"));
}

test "hl_orderbook: mid returns null when one side empty" {
    var syms = [_][]const u8{"SOL"};
    var ob = Orderbook.init(testing.allocator, HL_WS_HOST_TESTNET, &syms);
    defer ob.deinit();

    const bids = [_]Level{};
    const asks = [_]Level{.{ .price = 100.0, .size = 1.0 }};
    ob.applySnapshot("SOL", &bids, &asks, 1);
    try testing.expect(ob.mid("SOL") == null);
}

test "hl_orderbook: parseLevels handles string and number prices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var arr = std.json.Array.init(a);
    var e1 = std.json.ObjectMap.init(a);
    try e1.put("px", .{ .string = "100.5" });
    try e1.put("sz", .{ .string = "2.0" });
    try arr.append(.{ .object = e1 });

    var e2 = std.json.ObjectMap.init(a);
    try e2.put("px", .{ .float = 99.25 });
    try e2.put("sz", .{ .float = 1.0 });
    try arr.append(.{ .object = e2 });

    var out: [4]Level = [_]Level{.{}} ** 4;
    const n = parseLevels(.{ .array = arr }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectApproxEqAbs(@as(f64, 100.5), out[0].price, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 99.25), out[1].price, 1e-9);
}
