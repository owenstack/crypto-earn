//! Probability provider with an opinionated fallback chain:
//! Kalshi WebSocket -> Kalshi REST -> Manifold polling.
const std = @import("std");
const log = @import("logger.zig");
const db_mod = @import("db.zig");
const http = @import("http_client.zig");
const kalshi_ws = @import("kalshi_ws.zig");
const c = db_mod.c;

const KALSHI_REST_URL = "https://api.elections.kalshi.com/trade-api/v2/markets";
const MANIFOLD_MARKETS_URL = "https://api.manifold.markets/v0/markets";

pub const ExternalEstimate = struct {
    market_id: [64]u8,
    market_id_len: usize,
    condition_id: [128]u8,
    condition_id_len: usize,
    probability: f64,
    confidence: f64,
    source: [32]u8,
    source_len: usize,
    fetched_at: i64,
    yes_token_id: [80]u8,
    yes_token_id_len: usize,
};

pub const MAX_ESTIMATES = 256;

pub const ProviderMode = enum {
    kalshi_ws,
    kalshi_rest,
    manifold,
};

pub const ProbabilityProvider = struct {
    allocator: std.mem.Allocator,
    database: *db_mod.DB,
    kalshi: ?*kalshi_ws.KalshiWsClient,
    should_stop: std.atomic.Value(bool),
    fallback_active: std.atomic.Value(bool),
    mu: std.Thread.Mutex,
    estimates: [MAX_ESTIMATES]?ExternalEstimate,
    estimate_count: usize,
    last_poll_ts: i64,
    current_mode: ProviderMode,

    pub fn init(
        allocator: std.mem.Allocator,
        database: *db_mod.DB,
        kalshi: ?*kalshi_ws.KalshiWsClient,
    ) ProbabilityProvider {
        return .{
            .allocator = allocator,
            .database = database,
            .kalshi = kalshi,
            .should_stop = std.atomic.Value(bool).init(false),
            .fallback_active = std.atomic.Value(bool).init(false),
            .mu = .{},
            .estimates = [_]?ExternalEstimate{null} ** MAX_ESTIMATES,
            .estimate_count = 0,
            .last_poll_ts = 0,
            .current_mode = .manifold,
        };
    }

    pub fn stop(self: *ProbabilityProvider) void {
        self.should_stop.store(true, .seq_cst);
    }

    pub fn isFallbackActive(self: *ProbabilityProvider) bool {
        return self.fallback_active.load(.seq_cst);
    }

    pub fn snapshot(self: *ProbabilityProvider, out: *[MAX_ESTIMATES]ExternalEstimate) usize {
        self.mu.lock();
        defer self.mu.unlock();

        const count = self.estimate_count;
        for (0..count) |i| {
            if (self.estimates[i]) |est| {
                out[i] = est;
            }
        }
        return count;
    }

    pub fn run(self: *ProbabilityProvider) void {
        log.info("prob_provider", "probability provider started", .{});

        while (!self.should_stop.load(.seq_cst)) {
            var poll_buf: [16]u8 = undefined;
            const poll_str = self.database.getConfig("prob_source_poll_seconds", &poll_buf) orelse "60";
            const poll_seconds = std.fmt.parseInt(u32, poll_str, 10) catch 60;
            const clamped_poll = std.math.clamp(poll_seconds, 10, 3600);

            self.refreshOnce();

            const sleep_ns: u64 = @as(u64, clamped_poll) * std.time.ns_per_s;
            var slept: u64 = 0;
            while (slept < sleep_ns and !self.should_stop.load(.seq_cst)) {
                std.Thread.sleep(std.time.ns_per_s);
                slept += std.time.ns_per_s;
            }
        }

        log.info("prob_provider", "probability provider stopped", .{});
    }

    fn refreshOnce(self: *ProbabilityProvider) void {
        var api_key_buf: [256]u8 = undefined;
        const api_key = self.database.getConfig("kalshi_api_key", &api_key_buf);
        const has_kalshi_api_key = api_key != null and api_key.?.len > 0;

        if (has_kalshi_api_key) {
            if (self.kalshi) |kws| {
                if (kws.isConnected()) {
                    const ws_count = self.updateFromKalshi(kws);
                    if (ws_count > 0) {
                        self.fallback_active.store(false, .seq_cst);
                        self.current_mode = .kalshi_ws;
                        return;
                    }
                }
            }

            self.fallback_active.store(true, .seq_cst);
            self.pollKalshiRest(api_key.?);
            return;
        }

        self.fallback_active.store(true, .seq_cst);
        self.pollManifold();
    }

    fn updateFromKalshi(self: *ProbabilityProvider, kws: *kalshi_ws.KalshiWsClient) usize {
        var kalshi_snap: [kalshi_ws.MAX_ESTIMATES]kalshi_ws.ExternalEstimate = undefined;
        const count = kws.snapshot(&kalshi_snap);
        if (count == 0) return 0;

        var next = [_]?ExternalEstimate{null} ** MAX_ESTIMATES;
        var next_count: usize = 0;

        for (0..count) |i| {
            if (next_count >= MAX_ESTIMATES) break;
            const ke = kalshi_snap[i];

            var est = ExternalEstimate{
                .market_id = ke.market_id,
                .market_id_len = ke.market_id_len,
                .condition_id = ke.condition_id,
                .condition_id_len = ke.condition_id_len,
                .probability = ke.probability,
                .confidence = ke.confidence,
                .source = ke.source,
                .source_len = ke.source_len,
                .fetched_at = ke.fetched_at,
                .yes_token_id = [_]u8{0} ** 80,
                .yes_token_id_len = 0,
            };

            self.resolveTokenId(est.market_id[0..est.market_id_len], &est.yes_token_id, &est.yes_token_id_len);
            if (est.yes_token_id_len == 0) continue;

            next[next_count] = est;
            next_count += 1;
        }

        self.publishEstimates(next, next_count);
        log.debug("prob_provider", "updated {d} estimates from Kalshi WS", .{next_count});
        return next_count;
    }

    fn pollKalshiRest(self: *ProbabilityProvider, api_key: []const u8) void {
        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        var auth_buf: [512]u8 = undefined;
        var headers = [_]std.http.Header{
            .{
                .name = "KALSHI-ACCESS-KEY",
                .value = std.fmt.bufPrint(&auth_buf, "{s}", .{api_key}) catch api_key,
            },
        };

        var response = client.getWithHeaders(KALSHI_REST_URL, &headers) catch {
            log.err("prob_provider", "Kalshi REST poll failed", .{});
            return;
        };
        defer response.deinit();

        const parsed_count = self.parseKalshiRestResponse(response.body) catch |err| {
            log.err("prob_provider", "Kalshi REST parse failed: {s}", .{@errorName(err)});
            return;
        };

        if (parsed_count == 0) {
            log.warn("prob_provider", "Kalshi REST parse produced zero estimates", .{});
            return;
        }

        self.last_poll_ts = std.time.timestamp();
        self.current_mode = .kalshi_rest;
    }

    fn pollManifold(self: *ProbabilityProvider) void {
        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        var response = client.get(MANIFOLD_MARKETS_URL) catch {
            log.err("prob_provider", "Manifold poll failed", .{});
            return;
        };
        defer response.deinit();

        self.parseManifoldResponse(response.body);
        self.last_poll_ts = std.time.timestamp();
        self.current_mode = .manifold;
    }

    fn parseKalshiRestResponse(self: *ProbabilityProvider, body: []const u8) !usize {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        const items = extractArray(parsed.value, &.{ "markets", "data" }) orelse
            return error.MissingMarketsArray;

        var next = [_]?ExternalEstimate{null} ** MAX_ESTIMATES;
        var count: usize = 0;
        const now = std.time.timestamp();

        for (items) |item| {
            if (count >= MAX_ESTIMATES) break;
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };

            const ticker = objectString(obj, "ticker") orelse continue;
            const slug = objectString(obj, "slug");
            const title = objectString(obj, "title") orelse objectString(obj, "question");
            const subtitle = objectString(obj, "subtitle");
            const probability = extractProbability(obj) orelse continue;

            var market_id_buf: [64]u8 = undefined;
            const market_id = self.resolveMarketId(slug, title, subtitle, &market_id_buf) orelse continue;

            if (self.kalshi) |kws| {
                kws.upsertAutoMapping(ticker, market_id);
            }

            next[count] = self.buildEstimate(market_id, probability, 0.85, "kalshi_rest", now);
            count += 1;
        }

        self.publishEstimates(next, count);
        log.info("prob_provider", "parsed {d} estimates from Kalshi REST", .{count});
        return count;
    }

    fn parseManifoldResponse(self: *ProbabilityProvider, body: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
            log.err("prob_provider", "failed to parse Manifold response", .{});
            return;
        };
        defer parsed.deinit();

        const items = extractArray(parsed.value, &.{ "markets", "data" }) orelse switch (parsed.value) {
            .array => |a| a.items,
            else => {
                log.warn("prob_provider", "Manifold response was not an array", .{});
                return;
            },
        };

        var next = [_]?ExternalEstimate{null} ** MAX_ESTIMATES;
        var count: usize = 0;
        const now = std.time.timestamp();

        for (items) |item| {
            if (count >= MAX_ESTIMATES) break;
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };

            const probability = extractProbability(obj) orelse continue;
            const slug = objectString(obj, "slug") orelse objectString(obj, "id");
            const question = objectString(obj, "question");
            var market_id_buf: [64]u8 = undefined;
            const market_id = self.resolveMarketId(slug, question, null, &market_id_buf) orelse continue;

            next[count] = self.buildEstimate(market_id, probability, 0.70, "manifold", now);
            count += 1;
        }

        self.publishEstimates(next, count);
        log.info("prob_provider", "parsed {d} estimates from Manifold", .{count});
    }

    fn publishEstimates(self: *ProbabilityProvider, next: [MAX_ESTIMATES]?ExternalEstimate, count: usize) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.estimates = next;
        self.estimate_count = count;
    }

    fn buildEstimate(
        self: *ProbabilityProvider,
        market_id: []const u8,
        probability: f64,
        confidence: f64,
        source_name: []const u8,
        fetched_at: i64,
    ) ExternalEstimate {
        var est = ExternalEstimate{
            .market_id = [_]u8{0} ** 64,
            .market_id_len = 0,
            .condition_id = [_]u8{0} ** 128,
            .condition_id_len = 0,
            .probability = probability,
            .confidence = confidence,
            .source = [_]u8{0} ** 32,
            .source_len = 0,
            .fetched_at = fetched_at,
            .yes_token_id = [_]u8{0} ** 80,
            .yes_token_id_len = 0,
        };

        const mid_len = @min(market_id.len, est.market_id.len);
        @memcpy(est.market_id[0..mid_len], market_id[0..mid_len]);
        est.market_id_len = mid_len;

        const source_len = @min(source_name.len, est.source.len);
        @memcpy(est.source[0..source_len], source_name[0..source_len]);
        est.source_len = source_len;

        self.resolveTokenId(market_id, &est.yes_token_id, &est.yes_token_id_len);
        return est;
    }

    fn resolveMarketId(
        self: *ProbabilityProvider,
        slug: ?[]const u8,
        title: ?[]const u8,
        subtitle: ?[]const u8,
        out: *[64]u8,
    ) ?[]const u8 {
        if (slug) |candidate| {
            if (self.queryMarketIdBySymbol(candidate, out)) |market_id| return market_id;
        }

        if (title) |candidate| {
            if (self.queryMarketIdByQuestion(candidate, out)) |market_id| return market_id;
        }

        if (subtitle) |candidate| {
            if (self.queryMarketIdByQuestion(candidate, out)) |market_id| return market_id;
        }

        return null;
    }

    fn queryMarketIdBySymbol(self: *ProbabilityProvider, symbol: []const u8, out: *[64]u8) ?[]const u8 {
        const sql = "SELECT id FROM markets WHERE symbol=? LIMIT 1;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, symbol.ptr, @intCast(symbol.len), null) != c.SQLITE_OK) return null;
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        const raw_ptr = c.sqlite3_column_text(stmt, 0);
        const raw = if (raw_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else return null;
        const len = @min(raw.len, out.len);
        @memcpy(out[0..len], raw[0..len]);
        return out[0..len];
    }

    fn queryMarketIdByQuestion(self: *ProbabilityProvider, question: []const u8, out: *[64]u8) ?[]const u8 {
        const sql = "SELECT id, base, symbol FROM markets;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_ptr = c.sqlite3_column_text(stmt, 0);
            const base_ptr = c.sqlite3_column_text(stmt, 1);
            const symbol_ptr = c.sqlite3_column_text(stmt, 2);
            const id = if (id_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;
            const base = if (base_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
            const symbol = if (symbol_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";

            if (!normalizedEql(base, question) and !normalizedEql(symbol, question)) continue;

            const len = @min(id.len, out.len);
            @memcpy(out[0..len], id[0..len]);
            return out[0..len];
        }

        return null;
    }

    fn resolveTokenId(self: *ProbabilityProvider, market_id: []const u8, buf: *[80]u8, len: *usize) void {
        const sql = "SELECT clob_token_ids FROM markets WHERE id=? LIMIT 1;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, market_id.ptr, @intCast(market_id.len), null) != c.SQLITE_OK) return;
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return;

        const raw_ptr = c.sqlite3_column_text(stmt, 0);
        const raw = if (raw_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else return;

        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] != '"') continue;
            const start = i + 1;
            i += 1;
            while (i < raw.len and raw[i] != '"') : (i += 1) {}
            const token = raw[start..i];
            const token_len = @min(token.len, buf.len);
            @memcpy(buf[0..token_len], token[0..token_len]);
            len.* = token_len;
            return;
        }
    }
};

fn extractArray(root: std.json.Value, keys: []const []const u8) ?[]const std.json.Value {
    return switch (root) {
        .array => |a| a.items,
        .object => |o| blk: {
            for (keys) |key| {
                if (o.get(key)) |value| {
                    switch (value) {
                        .array => |arr| break :blk arr.items,
                        else => {},
                    }
                }
            }
            break :blk null;
        },
        else => null,
    };
}

fn objectString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn objectNumber(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn extractProbability(obj: std.json.ObjectMap) ?f64 {
    const bid = objectNumber(obj, "yes_bid");
    const ask = objectNumber(obj, "yes_ask");
    if (bid != null and ask != null) {
        const prob = normalizeProbability((bid.? + ask.?) / 2.0) orelse return null;
        return prob;
    }

    const candidates = [_][]const u8{
        "probability",
        "last_price",
        "yes_price",
        "yes_bid",
        "yes_ask",
    };
    for (candidates) |key| {
        if (objectNumber(obj, key)) |value| {
            if (normalizeProbability(value)) |prob| return prob;
        }
    }
    return null;
}

fn normalizeProbability(raw: f64) ?f64 {
    var prob = raw;
    if (prob > 1.0) prob /= 100.0;
    if (prob <= 0.0 or prob >= 1.0) return null;
    return prob;
}

fn normalizedEql(a: []const u8, b: []const u8) bool {
    var ia: usize = 0;
    var ib: usize = 0;

    while (true) {
        while (ia < a.len and !std.ascii.isAlphanumeric(a[ia])) : (ia += 1) {}
        while (ib < b.len and !std.ascii.isAlphanumeric(b[ib])) : (ib += 1) {}

        if (ia >= a.len or ib >= b.len) break;

        if (std.ascii.toLower(a[ia]) != std.ascii.toLower(b[ib])) return false;
        ia += 1;
        ib += 1;
    }

    while (ia < a.len and !std.ascii.isAlphanumeric(a[ia])) : (ia += 1) {}
    while (ib < b.len and !std.ascii.isAlphanumeric(b[ib])) : (ib += 1) {}
    return ia == a.len and ib == b.len;
}

test "probability_provider: manifold response maps by slug" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();
    try database.execZ("INSERT INTO markets(id,symbol,base,quote,status,clob_token_ids) VALUES('m1','fed-cuts','Will the Fed cut rates?','USDC','active','[\"yes-1\"]');");

    var pp = ProbabilityProvider.init(std.testing.allocator, &database, null);
    pp.parseManifoldResponse("[{\"slug\":\"fed-cuts\",\"question\":\"Will the Fed cut rates?\",\"probability\":0.63}]");

    try std.testing.expectEqual(@as(usize, 1), pp.estimate_count);
    try std.testing.expectEqualStrings("m1", pp.estimates[0].?.market_id[0..pp.estimates[0].?.market_id_len]);
    try std.testing.expectEqualStrings("manifold", pp.estimates[0].?.source[0..pp.estimates[0].?.source_len]);
}

test "probability_provider: kalshi rest response matches by title" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();
    try database.execZ("INSERT INTO markets(id,symbol,base,quote,status,clob_token_ids) VALUES('m1','fed-cuts','Will the Fed cut rates?','USDC','active','[\"yes-1\"]');");

    var kws = kalshi_ws.KalshiWsClient.init(std.testing.allocator, &database);
    var pp = ProbabilityProvider.init(std.testing.allocator, &database, &kws);
    pp.parseKalshiRestResponse("{\"markets\":[{\"ticker\":\"KXFEDCUT\",\"title\":\"Will the Fed cut rates?\",\"yes_bid\":61,\"yes_ask\":65}]}");

    try std.testing.expectEqual(@as(usize, 1), pp.estimate_count);
    try std.testing.expect(pp.estimates[0].?.probability > 0.62 and pp.estimates[0].?.probability < 0.64);
}

test "probability_provider: normalizedEql ignores punctuation and case" {
    try std.testing.expect(normalizedEql("Will the Fed cut rates?", "will-the-fed-cut-rates"));
    try std.testing.expect(!normalizedEql("A", "B"));
}
