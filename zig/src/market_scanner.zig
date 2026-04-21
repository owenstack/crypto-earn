//! Market scanner — polls Gamma API, manages in-memory market registry,
//! subscribes to CLOB WebSocket for real-time price feeds.
const std = @import("std");
const log = @import("logger.zig");
const db = @import("db.zig");
const gamma = @import("gamma_api.zig");
const clob = @import("clob_orderbook.zig");
const http = @import("http_client.zig");
const ws = @import("websocket.zig");
const news = @import("news_sources.zig");
const atomic = std.atomic;

pub const ScannerConfig = struct {
    poll_interval_min: u32 = 10,
    filter: gamma.FilterConfig = .{},
};

pub const Scanner = struct {
    allocator: std.mem.Allocator,
    database: *db.DB,
    config: ScannerConfig,
    markets: []gamma.GammaMarket,
    last_poll_ts: i64,
    running: atomic.Value(bool),
    ws_client: ?*ws.WebSocketClient,
    news_client: ?*news.NewsClient,

    pub fn init(allocator: std.mem.Allocator, database: *db.DB, config: ScannerConfig) Scanner {
        return .{
            .allocator = allocator,
            .database = database,
            .config = config,
            .markets = &.{},
            .last_poll_ts = 0,
            .running = atomic.Value(bool).init(false),
            .ws_client = null,
            .news_client = null,
        };
    }

    pub fn deinit(self: *Scanner) void {
        if (self.markets.len > 0) {
            gamma.freeMarkets(self.allocator, self.markets);
            self.markets = &.{};
        }
    }

    /// Attach a WebSocket client for real-time subscriptions.
    pub fn setWebSocketClient(self: *Scanner, wsc: *ws.WebSocketClient) void {
        self.ws_client = wsc;
    }

    /// Attach a news client for probability estimate updates.
    pub fn setNewsClient(self: *Scanner, nc: *news.NewsClient) void {
        self.news_client = nc;
    }

    /// Run the scanner loop. Blocks until stopped.
    /// Call from a dedicated thread.
    pub fn run(self: *Scanner) void {
        self.running.store(true, .seq_cst);
        log.info("scanner", "starting market scanner (poll every {d}min)", .{self.config.poll_interval_min});

        // Ensure orderbooks table exists
        self.database.execZ(clob.CREATE_ORDERBOOKS_TABLE ++ &[_:0]u8{}) catch |e| {
            log.err("scanner", "failed to create orderbooks table: {any}", .{e});
            return;
        };

        while (self.running.load(.seq_cst)) {
            self.pollOnce();
            // Use short retry interval (30s) if no markets loaded yet, normal interval otherwise
            const sleep_s: u64 = if (self.markets.len == 0) 30 else @as(u64, self.config.poll_interval_min) * 60;
            const sleep_ns: u64 = sleep_s * std.time.ns_per_s;
            std.Thread.sleep(sleep_ns);
        }

        log.info("scanner", "scanner stopped", .{});
    }

    /// Execute a single poll cycle.
    pub fn pollOnce(self: *Scanner) void {
        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        const new_markets = gamma.pollMarkets(self.allocator, &client, self.config.filter) catch |e| {
            log.err("scanner", "poll failed: {any}", .{e});
            return;
        };

        // Log changes
        if (self.markets.len > 0) {
            const added = countNew(self.markets, new_markets);
            const removed = countNew(new_markets, self.markets);
            if (added > 0 or removed > 0) {
                log.info("scanner", "registry update: +{d} -{d} markets (total {d})", .{ added, removed, new_markets.len });
            }
            gamma.freeMarkets(self.allocator, self.markets);
        } else {
            log.info("scanner", "initial poll: {d} markets", .{new_markets.len});
        }

        self.markets = new_markets;
        self.last_poll_ts = std.time.timestamp();

        // Persist to SQLite
        self.persistMarkets();

        // Subscribe new token IDs to WebSocket for real-time updates
        self.subscribeTokenIds();

        // Update news client with probability estimates from polled markets
        if (self.news_client) |nc| {
            nc.updateFromGammaMarkets(self.markets);
        }
    }

    /// Extract CLOB token IDs from markets and subscribe them to the WebSocket.
    fn subscribeTokenIds(self: *Scanner) void {
        const wsc = self.ws_client orelse return;

        var subscribed: usize = 0;
        for (self.markets) |m| {
            // clob_token_ids is a JSON array string like '["token1","token2"]'
            const token_ids = parseTokenIdArray(self.allocator, m.clob_token_ids) catch continue;
            defer self.allocator.free(token_ids);

            for (token_ids) |tid| {
                defer self.allocator.free(tid);
                wsc.subscribe(tid) catch |e| {
                    log.warn("scanner", "ws subscribe failed: {s}", .{@errorName(e)});
                    continue;
                };
                subscribed += 1;
            }
        }
        if (subscribed > 0) {
            log.info("scanner", "subscribed {d} token IDs to WebSocket", .{subscribed});
        }
    }

    fn persistMarket(self: *Scanner, m: gamma.GammaMarket) !void {
        const sql =
            "INSERT OR REPLACE INTO markets(id,symbol,base,quote,status,condition_id,clob_token_ids,outcomes,neg_risk,min_tick_size)" ++
            "VALUES(?,?,?,?,?,?,?,?,?,?);" ++ &[_:0]u8{};
        var stmt: ?*db.c.sqlite3_stmt = null;
        if (db.c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != db.c.SQLITE_OK)
            return error.DBExecFailed;
        defer _ = db.c.sqlite3_finalize(stmt);

        const status = if (m.active) "active" else "inactive";
        const quote = "USDC";
        const default_min_tick = "0.01";
        if (db.c.sqlite3_bind_text(stmt, 1, m.id.ptr, @intCast(m.id.len), null) != db.c.SQLITE_OK or
            db.c.sqlite3_bind_text(stmt, 2, m.slug.ptr, @intCast(m.slug.len), null) != db.c.SQLITE_OK or
            db.c.sqlite3_bind_text(stmt, 3, m.question.ptr, @intCast(m.question.len), null) != db.c.SQLITE_OK or
            db.c.sqlite3_bind_text(stmt, 4, quote.ptr, @intCast(quote.len), null) != db.c.SQLITE_OK or
            db.c.sqlite3_bind_text(stmt, 5, status.ptr, @intCast(status.len), null) != db.c.SQLITE_OK or
            db.c.sqlite3_bind_text(stmt, 6, m.condition_id.ptr, @intCast(m.condition_id.len), null) != db.c.SQLITE_OK or
            db.c.sqlite3_bind_text(stmt, 7, m.clob_token_ids.ptr, @intCast(m.clob_token_ids.len), null) != db.c.SQLITE_OK or
            db.c.sqlite3_bind_text(stmt, 8, m.outcomes.ptr, @intCast(m.outcomes.len), null) != db.c.SQLITE_OK or
            db.c.sqlite3_bind_int(stmt, 9, if (m.neg_risk) @as(c_int, 1) else @as(c_int, 0)) != db.c.SQLITE_OK or
            db.c.sqlite3_bind_text(stmt, 10, default_min_tick.ptr, @intCast(default_min_tick.len), null) != db.c.SQLITE_OK)
            return error.DBExecFailed;

        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE)
            return error.DBExecFailed;
    }

    fn persistMarkets(self: *Scanner) void {
        for (self.markets) |m| {
            self.persistMarket(m) catch |e| {
                log.warn("scanner", "persist market failed: {s} market_id={s}", .{ @errorName(e), m.id });
            };
        }
    }

    pub fn stop(self: *Scanner) void {
        self.running.store(false, .seq_cst);
    }
};

/// Parse a JSON array of strings (e.g. '["a","b"]') into an owned slice.
/// Caller owns each string and the slice itself.
fn parseTokenIdArray(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    if (raw.len < 2) return error.ParseFailed;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch
        return error.ParseFailed;
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.ParseFailed,
    };

    if (arr.items.len == 0) return error.ParseFailed;

    var result = try allocator.alloc([]const u8, arr.items.len);
    var count: usize = 0;
    errdefer {
        for (result[0..count]) |s| allocator.free(s);
        allocator.free(result);
    }

    for (arr.items) |item| {
        switch (item) {
            .string => |s| {
                result[count] = try allocator.dupe(u8, s);
                count += 1;
            },
            else => {},
        }
    }

    if (count == 0) {
        return error.ParseFailed;
    }
    if (count < result.len) {
        result = try allocator.realloc(result, count);
    }
    return result;
}

/// Count how many markets in `new` are not in `old` (by id).
fn countNew(old: []const gamma.GammaMarket, new: []const gamma.GammaMarket) usize {
    var n: usize = 0;
    for (new) |nm| {
        var found = false;
        for (old) |om| {
            if (std.mem.eql(u8, nm.id, om.id)) {
                found = true;
                break;
            }
        }
        if (!found) n += 1;
    }
    return n;
}

test "scanner: init and deinit" {
    var database = try db.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    var scanner_inst = Scanner.init(std.testing.allocator, &database, .{});
    defer scanner_inst.deinit();

    try std.testing.expectEqual(@as(usize, 0), scanner_inst.markets.len);
    try std.testing.expect(!scanner_inst.running.load(.seq_cst));
}

test "scanner: ScannerConfig defaults" {
    const config = ScannerConfig{};
    try std.testing.expectEqual(@as(u32, 10), config.poll_interval_min);
    try std.testing.expectEqual(@as(f64, 5000.0), config.filter.min_volume_24h);
}

test "scanner: parseTokenIdArray" {
    const raw = "[\"token_a\",\"token_b\"]";
    const result = try parseTokenIdArray(std.testing.allocator, raw);
    defer {
        for (result) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("token_a", result[0]);
    try std.testing.expectEqualStrings("token_b", result[1]);
}

test "scanner: parseTokenIdArray empty" {
    const result = parseTokenIdArray(std.testing.allocator, "[]");
    try std.testing.expectError(error.ParseFailed, result);
}

test "scanner: parseTokenIdArray invalid" {
    const result = parseTokenIdArray(std.testing.allocator, "bad");
    try std.testing.expectError(error.ParseFailed, result);
}
