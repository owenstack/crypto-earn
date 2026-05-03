//! Probability provider with an opinionated fallback chain:
//! Kalshi WebSocket -> Kalshi REST -> Manifold polling.
const std = @import("std");
const log = @import("logger.zig");
const db_mod = @import("db.zig");
const http = @import("http_client.zig");
const kalshi_ws = @import("kalshi_ws.zig");
const c = db_mod.c;

const KALSHI_EVENTS_URL = "https://api.elections.kalshi.com/trade-api/v2/events";
const MANIFOLD_MARKETS_URL = "https://api.manifold.markets/v0/markets";
const KALSHI_REST_PAGE_LIMIT = 200;
const KALSHI_REST_MAX_PAGES = 8;

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
        }

        self.fallback_active.store(true, .seq_cst);
        if (self.pollKalshiRest()) return;

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

    fn pollKalshiRest(self: *ProbabilityProvider) bool {
        // Use configurable series tickers to avoid pulling 1000s of irrelevant sports markets.
        // runtime_config key "kalshi_series_tickers": comma-separated, e.g. "KXFED,KXBITCOIN,KXGDP"
        // If empty/unset, falls back to unfiltered endpoint (usually unhelpful).
        var series_buf: [512]u8 = undefined;
        const series_cfg = self.database.getConfig("kalshi_series_tickers", &series_buf);

        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        var acc = [_]?ExternalEstimate{null} ** MAX_ESTIMATES;
        var acc_count: usize = 0;

        if (series_cfg) |series_str| {
            // Poll each series ticker individually
            var it = std.mem.splitScalar(u8, series_str, ',');
            while (it.next()) |raw_ticker| {
                const ticker = std.mem.trim(u8, raw_ticker, " ");
                if (ticker.len == 0) continue;

                var base_url_buf: [256]u8 = undefined;
                const base_url = std.fmt.bufPrint(
                    &base_url_buf,
                    KALSHI_EVENTS_URL ++ "?status=open&with_nested_markets=true&limit={d}&series_ticker={s}",
                    .{ KALSHI_REST_PAGE_LIMIT, ticker },
                ) catch continue;

                self.pollKalshiRestPages(&client, base_url, ticker, &acc, &acc_count);
            }
        } else {
            // Fallback: unfiltered. Walk several cursor pages so overlap is not
            // limited to whatever happens to be in Kalshi's first page.
            self.pollKalshiRestPages(
                &client,
                KALSHI_EVENTS_URL ++ "?status=open&with_nested_markets=true&limit=200",
                null,
                &acc,
                &acc_count,
            );
        }

        if (acc_count > 0) {
            self.publishEstimates(acc, acc_count);
        }

        if (acc_count == 0) {
            log.warn("prob_provider", "Kalshi REST parse produced zero estimates", .{});
            return false;
        }

        self.last_poll_ts = std.time.timestamp();
        self.current_mode = .kalshi_rest;
        return true;
    }

    fn pollKalshiRestPages(
        self: *ProbabilityProvider,
        client: *http.HttpClient,
        base_url: []const u8,
        series_ticker: ?[]const u8,
        acc: *[MAX_ESTIMATES]?ExternalEstimate,
        acc_count: *usize,
    ) void {
        var cursor_buf: [256]u8 = undefined;
        var url_buf: [512]u8 = undefined;
        var cursor: ?[]const u8 = null;
        var page_count: usize = 0;

        while (page_count < KALSHI_REST_MAX_PAGES and acc_count.* < MAX_ESTIMATES) : (page_count += 1) {
            const url = if (cursor) |next_cursor|
                std.fmt.bufPrint(&url_buf, "{s}&cursor={s}", .{ base_url, next_cursor }) catch break
            else
                base_url;

            var response = client.get(url) catch {
                if (series_ticker) |ticker| {
                    log.warn("prob_provider", "Kalshi REST poll failed for series {s} page {d}", .{ ticker, page_count + 1 });
                } else {
                    log.err("prob_provider", "Kalshi REST poll failed on page {d}", .{page_count + 1});
                }
                return;
            };
            defer response.deinit();

            const page = self.parseKalshiRestInto(response.body, &acc, &acc_count, &cursor_buf) catch |err| {
                if (series_ticker) |ticker| {
                    log.warn("prob_provider", "Kalshi REST parse failed for series {s} page {d}: {s}", .{
                        ticker,
                        page_count + 1,
                        @errorName(err),
                    });
                } else {
                    log.err("prob_provider", "Kalshi REST parse failed on page {d}: {s}", .{ page_count + 1, @errorName(err) });
                }
                return;
            };

            if (page.cursor_len == 0) break;
            cursor = cursor_buf[0..page.cursor_len];
        }
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

    const KalshiRestPageResult = struct {
        added: usize,
        cursor_len: usize,
    };

    /// Parse Kalshi REST response and append estimates to an accumulator array.
    /// Returns the number of estimates appended plus the next-page cursor length.
    fn parseKalshiRestInto(
        self: *ProbabilityProvider,
        body: []const u8,
        acc: *[MAX_ESTIMATES]?ExternalEstimate,
        acc_count: *usize,
        cursor_out: ?[]u8,
    ) !KalshiRestPageResult {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        var cursor_len: usize = 0;
        var added: usize = 0;
        var skip_no_prob: usize = 0;
        var skip_no_market: usize = 0;
        const now = std.time.timestamp();

        if (cursor_out) |buf| {
            if (extractCursor(parsed.value, buf)) |cursor| {
                cursor_len = cursor.len;
            }
        }

        if (extractArray(parsed.value, &.{"events"})) |events| {
            for (events) |event_item| {
                const event_obj = switch (event_item) {
                    .object => |o| o,
                    else => continue,
                };
                const markets_value = event_obj.get("markets") orelse continue;
                const markets = switch (markets_value) {
                    .array => |a| a.items,
                    else => continue,
                };

                for (markets) |market_item| {
                    const outcome = self.appendKalshiMarketEstimate(market_item, event_obj, acc, acc_count, now);
                    switch (outcome) {
                        .added => added += 1,
                        .no_probability => skip_no_prob += 1,
                        .no_market => skip_no_market += 1,
                        .ignored => {},
                    }
                }
            }

            log.info("prob_provider", "Kalshi REST events: {d} events, {d} published (skipped: {d} no-prob, {d} no-market)", .{
                events.len, added, skip_no_prob, skip_no_market,
            });
            return .{ .added = added, .cursor_len = cursor_len };
        }

        const items = extractArray(parsed.value, &.{ "markets", "data", "trades" }) orelse
            return error.MissingMarketsArray;

        for (items) |item| {
            if (acc_count.* >= MAX_ESTIMATES) break;
            const outcome = self.appendKalshiMarketEstimate(item, null, acc, acc_count, now);
            switch (outcome) {
                .added => added += 1,
                .no_probability => skip_no_prob += 1,
                .no_market => skip_no_market += 1,
                .ignored => {},
            }
        }

        log.info("prob_provider", "Kalshi REST: {d} items, {d} published (skipped: {d} no-prob, {d} no-market)", .{
            items.len, added, skip_no_prob, skip_no_market,
        });
        return .{ .added = added, .cursor_len = cursor_len };
    }

    const KalshiAppendOutcome = enum {
        added,
        no_probability,
        no_market,
        ignored,
    };

    fn appendKalshiMarketEstimate(
        self: *ProbabilityProvider,
        item: std.json.Value,
        event_obj: ?std.json.ObjectMap,
        acc: *[MAX_ESTIMATES]?ExternalEstimate,
        acc_count: *usize,
        now: i64,
    ) KalshiAppendOutcome {
        if (acc_count.* >= MAX_ESTIMATES) return .ignored;
        const obj = switch (item) {
            .object => |o| o,
            else => return .ignored,
        };

        const ticker = objectString(obj, "ticker") orelse return .ignored;
        const slug = objectString(obj, "slug");
        const title = objectString(obj, "title") orelse objectString(obj, "question");
        const subtitle = objectString(obj, "subtitle") orelse
            objectString(obj, "yes_sub_title") orelse
            objectString(obj, "no_sub_title");
        const event_title = if (event_obj) |ev| objectString(ev, "title") else null;
        const event_subtitle = if (event_obj) |ev| objectString(ev, "sub_title") else null;
        const probability = extractProbability(obj) orelse return .no_probability;

        var market_id_buf: [64]u8 = undefined;
        const market_id = self.resolveKalshiTickerWithEventContext(
            ticker,
            slug,
            title,
            subtitle,
            event_title,
            event_subtitle,
            &market_id_buf,
        ) orelse return .no_market;

        acc[acc_count.*] = self.buildEstimate(market_id, probability, 0.85, "kalshi_rest", now);
        acc_count.* += 1;
        return .added;
    }

    /// Backward-compatible wrapper used by tests.
    fn parseKalshiRestResponse(self: *ProbabilityProvider, body: []const u8) !usize {
        var acc = [_]?ExternalEstimate{null} ** MAX_ESTIMATES;
        var count: usize = 0;
        const page = try self.parseKalshiRestInto(body, &acc, &count, null);
        self.publishEstimates(acc, count);
        return page.added;
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
        var skip_no_prob: usize = 0;
        var skip_no_market: usize = 0;
        const now = std.time.timestamp();

        for (items) |item| {
            if (count >= MAX_ESTIMATES) break;
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };

            // Skip non-binary markets (MULTIPLE_CHOICE, etc.) - they don't have a simple probability
            const outcome_type = objectString(obj, "outcomeType");
            if (outcome_type) |ot| {
                if (!std.mem.eql(u8, ot, "BINARY")) continue;
            }

            const probability = extractProbability(obj) orelse {
                skip_no_prob += 1;
                continue;
            };
            const slug = objectString(obj, "slug") orelse objectString(obj, "id");
            const question = objectString(obj, "question");
            var market_id_buf: [64]u8 = undefined;
            const market_id = self.resolveMarketId(slug, question, null, &market_id_buf) orelse {
                skip_no_market += 1;
                continue;
            };

            next[count] = self.buildEstimate(market_id, probability, 0.70, "manifold", now);
            count += 1;
        }

        self.publishEstimates(next, count);
        log.info("prob_provider", "Manifold: {d} items, {d} published (skipped: {d} no-prob, {d} no-market)", .{
            items.len, count, skip_no_prob, skip_no_market,
        });
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

    /// Three-tier Kalshi ticker resolver:
    ///   1. DB-persisted mapping from `kalshi_market_map` (highest confidence,
    ///      survives restarts).
    ///   2. In-memory auto-mapping seeded by the live Kalshi WS during the
    ///      current session.
    ///   3. Fuzzy match against the local `markets` table by slug/title/subtitle.
    /// On a successful tier-3 match, the result is persisted to both the DB
    /// and the in-memory map so subsequent lookups are O(1).
    fn resolveKalshiTicker(
        self: *ProbabilityProvider,
        ticker: []const u8,
        slug: ?[]const u8,
        title: ?[]const u8,
        subtitle: ?[]const u8,
        out: *[64]u8,
    ) ?[]const u8 {
        // Tier 1: DB-persisted mapping
        if (self.database.lookupKalshiMapping(ticker, out)) |id| return id;

        // Tier 2: In-memory auto-map seeded during current session
        if (self.kalshi) |kws| {
            kws.mu.lock();
            for (0..kws.auto_map_count) |i| {
                const t = kws.auto_map_tickers[i][0..kws.auto_map_ticker_lens[i]];
                if (std.mem.eql(u8, t, ticker)) {
                    const len = kws.auto_map_market_id_lens[i];
                    @memcpy(out[0..len], kws.auto_map_market_ids[i][0..len]);
                    kws.mu.unlock();
                    return out[0..len];
                }
            }
            kws.mu.unlock();
        }

        // Tier 3: Fuzzy match against markets table
        if (slug) |s| {
            if (self.queryMarketIdBySymbol(s, out)) |id| {
                self.database.upsertKalshiMapping(ticker, id, 0.90, "slug_match") catch {};
                if (self.kalshi) |kws| kws.upsertAutoMapping(ticker, id);
                return id;
            }
        }
        if (title) |t| {
            if (self.queryMarketIdByQuestion(t, out)) |id| {
                self.database.upsertKalshiMapping(ticker, id, 0.75, "title_match") catch {};
                if (self.kalshi) |kws| kws.upsertAutoMapping(ticker, id);
                return id;
            }
        }
        if (subtitle) |s| {
            if (self.queryMarketIdByQuestion(s, out)) |id| {
                self.database.upsertKalshiMapping(ticker, id, 0.60, "subtitle_match") catch {};
                if (self.kalshi) |kws| kws.upsertAutoMapping(ticker, id);
                return id;
            }
        }

        return null;
    }

    fn resolveKalshiTickerWithEventContext(
        self: *ProbabilityProvider,
        ticker: []const u8,
        slug: ?[]const u8,
        title: ?[]const u8,
        subtitle: ?[]const u8,
        event_title: ?[]const u8,
        event_subtitle: ?[]const u8,
        out: *[64]u8,
    ) ?[]const u8 {
        if (self.resolveKalshiTicker(ticker, slug, title, subtitle, out)) |id| return id;

        if (event_title) |t| {
            if (self.queryMarketIdByQuestion(t, out)) |id| {
                self.database.upsertKalshiMapping(ticker, id, 0.70, "event_title_match") catch {};
                if (self.kalshi) |kws| kws.upsertAutoMapping(ticker, id);
                return id;
            }
        }
        if (event_subtitle) |s| {
            if (self.queryMarketIdByQuestion(s, out)) |id| {
                self.database.upsertKalshiMapping(ticker, id, 0.65, "event_subtitle_match") catch {};
                if (self.kalshi) |kws| kws.upsertAutoMapping(ticker, id);
                return id;
            }
        }

        return null;
    }

    /// Backward-compat: legacy runtime-config based lookup. Retained so an
    /// operator can still pin specific tickers via the `kalshi_market_map`
    /// runtime_config key as a manual override (no longer required for
    /// normal operation).
    fn queryKalshiMappedMarketId(self: *ProbabilityProvider, ticker: []const u8, out: *[64]u8) ?[]const u8 {
        var map_buf: [4096]u8 = undefined;
        const market_map = self.database.getConfig("kalshi_market_map", &map_buf) orelse return null;

        // Parse JSON map: {"TICKER":"gamma-id",...}
        // Search for "ticker":"value" pattern (same logic as kalshi_ws lookupTickerMapping)
        var i: usize = 0;
        while (i + ticker.len + 4 < market_map.len) : (i += 1) {
            if (market_map[i] != '"') continue;
            if (i + 1 + ticker.len + 1 >= market_map.len) continue;
            if (!std.mem.eql(u8, market_map[i + 1 .. i + 1 + ticker.len], ticker)) continue;
            if (market_map[i + 1 + ticker.len] != '"') continue;

            var j = i + 1 + ticker.len + 1;
            while (j < market_map.len and (market_map[j] == ':' or market_map[j] == ' ')) : (j += 1) {}
            if (j >= market_map.len or market_map[j] != '"') return null;

            const start = j + 1;
            var end = start;
            while (end < market_map.len and market_map[end] != '"') : (end += 1) {}
            const val = market_map[start..end];
            if (val.len > out.len) return null;
            @memcpy(out[0..val.len], val);
            return out[0..val.len];
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

        var best_score: u32 = 0;
        var best_len: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_ptr = c.sqlite3_column_text(stmt, 0);
            const base_ptr = c.sqlite3_column_text(stmt, 1);
            const symbol_ptr = c.sqlite3_column_text(stmt, 2);
            const id = if (id_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;
            const base = if (base_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
            const symbol = if (symbol_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";

            const score = @max(matchScore(base, question), matchScore(symbol, question));
            if (score < best_score or score < 60) continue;

            best_score = score;
            best_len = @min(id.len, out.len);
            @memcpy(out[0..best_len], id[0..best_len]);
        }

        if (best_score == 0) return null;
        return out[0..best_len];
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

fn extractCursor(root: std.json.Value, buf: []u8) ?[]const u8 {
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    const value = obj.get("cursor") orelse return null;
    const cursor = switch (value) {
        .string => |s| s,
        else => return null,
    };
    if (cursor.len == 0 or cursor.len > buf.len) return null;
    @memcpy(buf[0..cursor.len], cursor);
    return buf[0..cursor.len];
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
    // Kalshi REST uses "yes_bid_dollars" / "yes_ask_dollars" (string dollar amounts like "0.61")
    const bid_dollars = objectNumber(obj, "yes_bid_dollars");
    const ask_dollars = objectNumber(obj, "yes_ask_dollars");
    if (bid_dollars != null and ask_dollars != null) {
        const prob = normalizeProbability((bid_dollars.? + ask_dollars.?) / 2.0) orelse return null;
        return prob;
    }

    const bid = objectNumber(obj, "yes_bid");
    const ask = objectNumber(obj, "yes_ask");
    if (bid != null and ask != null) {
        const prob = normalizeProbability((bid.? + ask.?) / 2.0) orelse return null;
        return prob;
    }

    const candidates = [_][]const u8{
        "probability",
        "last_price",
        "last_price_dollars",
        "yes_price",
        "yes_price_dollars",
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

fn matchScore(candidate: []const u8, query: []const u8) u32 {
    if (candidate.len == 0 or query.len == 0) return 0;
    if (normalizedEql(candidate, query)) return 100;

    var candidate_norm_buf: [256]u8 = undefined;
    var query_norm_buf: [256]u8 = undefined;
    const candidate_norm = normalizeForMatch(candidate, &candidate_norm_buf);
    const query_norm = normalizeForMatch(query, &query_norm_buf);

    if (candidate_norm.len == 0 or query_norm.len == 0) return 0;
    if (std.mem.indexOf(u8, candidate_norm, query_norm) != null or
        std.mem.indexOf(u8, query_norm, candidate_norm) != null)
    {
        return 90;
    }

    const shared = sharedTokenCount(candidate_norm, query_norm);
    if (shared >= 5) return 80;
    if (shared >= 4) return 72;
    if (shared >= 3) return 64;
    if (shared >= 2) return 52;
    return 0;
}

fn normalizeForMatch(src: []const u8, buf: []u8) []const u8 {
    var j: usize = 0;
    var prev_space = true;
    for (src) |ch| {
        const lowered = std.ascii.toLower(ch);
        if (std.ascii.isAlphanumeric(lowered)) {
            if (j >= buf.len) break;
            buf[j] = lowered;
            j += 1;
            prev_space = false;
        } else if (!prev_space) {
            if (j >= buf.len) break;
            buf[j] = ' ';
            j += 1;
            prev_space = true;
        }
    }
    if (j > 0 and buf[j - 1] == ' ') j -= 1;
    return buf[0..j];
}

fn sharedTokenCount(a_norm: []const u8, b_norm: []const u8) u32 {
    var count: u32 = 0;
    var it = std.mem.tokenizeScalar(u8, a_norm, ' ');
    while (it.next()) |token| {
        if (token.len < 3) continue;
        var bit = std.mem.tokenizeScalar(u8, b_norm, ' ');
        while (bit.next()) |other| {
            if (std.mem.eql(u8, token, other)) {
                count += 1;
                break;
            }
        }
    }
    return count;
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
    _ = pp.parseKalshiRestResponse("{\"markets\":[{\"ticker\":\"KXFEDCUT\",\"title\":\"Will the Fed cut rates?\",\"yes_bid\":61,\"yes_ask\":65}]}") catch 0;

    try std.testing.expectEqual(@as(usize, 1), pp.estimate_count);
    try std.testing.expect(pp.estimates[0].?.probability > 0.62 and pp.estimates[0].?.probability < 0.64);
}

test "probability_provider: kalshi events response flattens nested markets" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();
    try database.execZ("INSERT INTO markets(id,symbol,base,quote,status,clob_token_ids) VALUES('m1','fed-cuts','Will the Fed cut rates?','USDC','active','[\"yes-1\"]');");

    var kws = kalshi_ws.KalshiWsClient.init(std.testing.allocator, &database);
    var pp = ProbabilityProvider.init(std.testing.allocator, &database, &kws);
    _ = try pp.parseKalshiRestResponse(
        \\{"events":[{"event_ticker":"KXFED","title":"Will the Fed cut rates?","markets":[{"ticker":"KXFEDCUT","yes_bid_dollars":"0.6100","yes_ask_dollars":"0.6500"}]}],"cursor":""}
    );

    try std.testing.expectEqual(@as(usize, 1), pp.estimate_count);
    try std.testing.expectEqualStrings("m1", pp.estimates[0].?.market_id[0..pp.estimates[0].?.market_id_len]);
    try std.testing.expect(pp.estimates[0].?.probability > 0.62 and pp.estimates[0].?.probability < 0.64);
}

test "probability_provider: kalshi trades response uses persisted ticker mapping" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();
    try database.execZ("INSERT INTO markets(id,symbol,base,quote,status,clob_token_ids) VALUES('m1','fed-cuts','Will the Fed cut rates?','USDC','active','[\"yes-1\"]');");
    try database.upsertKalshiMapping("KXFEDCUT", "m1", 1.0, "test");

    var pp = ProbabilityProvider.init(std.testing.allocator, &database, null);
    _ = try pp.parseKalshiRestResponse(
        \\{"trades":[{"trade_id":"t1","ticker":"KXFEDCUT","count_fp":"10.00","yes_price_dollars":"0.5600","no_price_dollars":"0.4400","taker_side":"yes","created_time":"2023-11-07T05:31:56Z"}],"cursor":""}
    );

    try std.testing.expectEqual(@as(usize, 1), pp.estimate_count);
    try std.testing.expect(pp.estimates[0].?.probability > 0.55 and pp.estimates[0].?.probability < 0.57);
}

test "probability_provider: normalizedEql ignores punctuation and case" {
    try std.testing.expect(normalizedEql("Will the Fed cut rates?", "will-the-fed-cut-rates"));
    try std.testing.expect(!normalizedEql("A", "B"));
}

test "probability_provider: kalshi rest response matches by event context subtitle" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();
    try database.execZ("INSERT INTO markets(id,symbol,base,quote,status,clob_token_ids) VALUES('m1','fed-cuts-september','Will the Fed cut rates in September 2026?','USDC','active','[\"yes-1\"]');");

    var kws = kalshi_ws.KalshiWsClient.init(std.testing.allocator, &database);
    var pp = ProbabilityProvider.init(std.testing.allocator, &database, &kws);
    _ = try pp.parseKalshiRestResponse(
        \\{"events":[{"event_ticker":"KXFED","title":"Fed September decision","sub_title":"Will the Fed cut rates in September 2026?","markets":[{"ticker":"KXFEDCUTSEP","title":"Fed cut in September","yes_bid_dollars":"0.6100","yes_ask_dollars":"0.6500"}]}],"cursor":""}
    );

    try std.testing.expectEqual(@as(usize, 1), pp.estimate_count);
    var buf: [64]u8 = undefined;
    try std.testing.expect(database.lookupKalshiMapping("KXFEDCUTSEP", &buf) != null);
}
