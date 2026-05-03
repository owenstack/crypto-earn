//! Kalshi WebSocket client — streams real-time market probability data.
//! Primary probability source for the news-repricing strategy.
const std = @import("std");
const log = @import("logger.zig");
const db_mod = @import("db.zig");
const ws_lib = @import("websocket");
const c = db_mod.c;

const KALSHI_WS_HOST = "api.elections.kalshi.com";
const KALSHI_WS_PATH = "/trade-api/ws/v2";

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
};

pub const MAX_ESTIMATES = 256;

pub const KalshiWsClient = struct {
    allocator: std.mem.Allocator,
    database: *db_mod.DB,
    should_stop: std.atomic.Value(bool),
    connected: std.atomic.Value(bool),
    mu: std.Thread.Mutex,
    estimates: [MAX_ESTIMATES]?ExternalEstimate,
    estimate_count: usize,
    auto_map_tickers: [MAX_ESTIMATES][64]u8,
    auto_map_ticker_lens: [MAX_ESTIMATES]usize,
    auto_map_market_ids: [MAX_ESTIMATES][64]u8,
    auto_map_market_id_lens: [MAX_ESTIMATES]usize,
    auto_map_count: usize,

    const INITIAL_RECONNECT_MS: u64 = 1_000;
    const MAX_RECONNECT_MS: u64 = 30_000;
    const MAX_RECONNECT_ATTEMPTS: u32 = 10;

    pub fn init(allocator: std.mem.Allocator, database: *db_mod.DB) KalshiWsClient {
        return .{
            .allocator = allocator,
            .database = database,
            .should_stop = std.atomic.Value(bool).init(false),
            .connected = std.atomic.Value(bool).init(false),
            .mu = .{},
            .estimates = [_]?ExternalEstimate{null} ** MAX_ESTIMATES,
            .estimate_count = 0,
            .auto_map_tickers = [_][64]u8{[_]u8{0} ** 64} ** MAX_ESTIMATES,
            .auto_map_ticker_lens = [_]usize{0} ** MAX_ESTIMATES,
            .auto_map_market_ids = [_][64]u8{[_]u8{0} ** 64} ** MAX_ESTIMATES,
            .auto_map_market_id_lens = [_]usize{0} ** MAX_ESTIMATES,
            .auto_map_count = 0,
        };
    }

    pub fn stop(self: *KalshiWsClient) void {
        self.should_stop.store(true, .seq_cst);
    }

    pub fn isConnected(self: *KalshiWsClient) bool {
        return self.connected.load(.seq_cst);
    }

    /// Get a snapshot of current estimates. Returns the count written.
    pub fn snapshot(self: *KalshiWsClient, out: *[MAX_ESTIMATES]ExternalEstimate) usize {
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

    /// Seed or update a runtime ticker -> Gamma market mapping discovered via REST.
    pub fn upsertAutoMapping(self: *KalshiWsClient, ticker: []const u8, market_id: []const u8) void {
        if (ticker.len == 0 or market_id.len == 0) return;

        self.mu.lock();
        defer self.mu.unlock();

        for (0..self.auto_map_count) |i| {
            if (std.mem.eql(u8, self.auto_map_tickers[i][0..self.auto_map_ticker_lens[i]], ticker)) {
                const len = @min(market_id.len, self.auto_map_market_ids[i].len);
                @memset(&self.auto_map_market_ids[i], 0);
                @memcpy(self.auto_map_market_ids[i][0..len], market_id[0..len]);
                self.auto_map_market_id_lens[i] = len;
                return;
            }
        }

        if (self.auto_map_count >= MAX_ESTIMATES) return;

        const idx = self.auto_map_count;
        const ticker_len = @min(ticker.len, self.auto_map_tickers[idx].len);
        const market_len = @min(market_id.len, self.auto_map_market_ids[idx].len);
        @memset(&self.auto_map_tickers[idx], 0);
        @memset(&self.auto_map_market_ids[idx], 0);
        @memcpy(self.auto_map_tickers[idx][0..ticker_len], ticker[0..ticker_len]);
        @memcpy(self.auto_map_market_ids[idx][0..market_len], market_id[0..market_len]);
        self.auto_map_ticker_lens[idx] = ticker_len;
        self.auto_map_market_id_lens[idx] = market_len;
        self.auto_map_count += 1;
    }

    /// Get estimate for a specific market_id. Returns null if not found or stale.
    pub fn getEstimate(self: *KalshiWsClient, market_id: []const u8) ?ExternalEstimate {
        self.mu.lock();
        defer self.mu.unlock();
        const now = std.time.timestamp();
        for (self.estimates[0..self.estimate_count]) |slot| {
            if (slot) |est| {
                if (std.mem.eql(u8, est.market_id[0..est.market_id_len], market_id)) {
                    // Stale if older than 120 seconds
                    if (now - est.fetched_at > 120) return null;
                    return est;
                }
            }
        }
        return null;
    }

    /// Main WebSocket loop with auto-reconnect. Call from a dedicated thread.
    pub fn run(self: *KalshiWsClient) void {
        var reconnect_delay_ms: u64 = INITIAL_RECONNECT_MS;
        var consecutive_failures: u32 = 0;

        while (!self.should_stop.load(.seq_cst)) {
            // Read API key from runtime_config
            var api_key_buf: [256]u8 = undefined;
            const api_key = self.database.getConfig("kalshi_api_key", &api_key_buf) orelse {
                log.warn("kalshi_ws", "kalshi_api_key not set in runtime_config, waiting...", .{});
                std.Thread.sleep(30 * std.time.ns_per_s);
                continue;
            };

            if (api_key.len == 0) {
                log.warn("kalshi_ws", "kalshi_api_key is empty, waiting...", .{});
                std.Thread.sleep(30 * std.time.ns_per_s);
                continue;
            }

            if (consecutive_failures >= MAX_RECONNECT_ATTEMPTS) {
                log.err("kalshi_ws", "max reconnect attempts ({d}) reached, pausing for 60s", .{MAX_RECONNECT_ATTEMPTS});
                std.Thread.sleep(60 * std.time.ns_per_s);
                consecutive_failures = 0;
            }

            log.info("kalshi_ws", "connecting to Kalshi WebSocket...", .{});

            const run_result = self.runConnection(api_key);
            if (run_result) {
                reconnect_delay_ms = INITIAL_RECONNECT_MS;
                consecutive_failures = 0;
            } else |e| {
                log.err("kalshi_ws", "connection error: {s}", .{@errorName(e)});
                consecutive_failures += 1;
            }

            self.connected.store(false, .seq_cst);

            if (self.should_stop.load(.seq_cst)) break;

            log.warn("kalshi_ws", "disconnected, reconnecting in {d}ms (attempt {d})", .{ reconnect_delay_ms, consecutive_failures });
            std.Thread.sleep(reconnect_delay_ms * std.time.ns_per_ms);
            reconnect_delay_ms = @min(reconnect_delay_ms * 2, MAX_RECONNECT_MS);
        }
    }

    fn runConnection(self: *KalshiWsClient, api_key: []const u8) !void {
        var client = try ws_lib.Client.init(self.allocator, .{
            .host = KALSHI_WS_HOST,
            .port = 443,
            .tls = true,
            .max_size = 1 * 1024 * 1024,
        });
        defer client.deinit();

        // Build timestamp for auth
        var ts_buf: [32]u8 = undefined;
        const ts_ms = std.time.milliTimestamp();
        const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{ts_ms}) catch return error.BufferOverflow;

        // Build auth headers string for handshake
        var header_buf: [1024]u8 = undefined;
        const headers = std.fmt.bufPrint(&header_buf, "Host: {s}\r\nKALSHI-ACCESS-KEY: {s}\r\nKALSHI-ACCESS-TIMESTAMP: {s}\r\n", .{ KALSHI_WS_HOST, api_key, ts }) catch return error.BufferOverflow;

        try client.handshake(KALSHI_WS_PATH, .{
            .timeout_ms = 10_000,
            .headers = headers,
        });

        self.connected.store(true, .seq_cst);
        log.info("kalshi_ws", "connected to Kalshi WebSocket", .{});

        // Subscribe to ticker plus lifecycle channels. Ticker messages carry
        // prices; lifecycle messages carry titles/subtitles needed to discover
        // ticker -> Gamma mappings without manual config.
        var sub_buf: [512]u8 = undefined;
        const sub_msg = std.fmt.bufPrint(&sub_buf,
            \\{{"id":1,"cmd":"subscribe","params":{{"channels":["ticker","market_lifecycle_v2","multivariate_market_lifecycle"]}}}}
        , .{}) catch return error.BufferOverflow;
        const sub_len = sub_msg.len;
        var send_buf: [512]u8 = undefined;
        @memcpy(send_buf[0..sub_len], sub_msg);
        try client.write(send_buf[0..sub_len]);

        log.info("kalshi_ws", "subscribed to Kalshi ticker and lifecycle channels", .{});

        // Read loop with periodic pings
        try client.readTimeout(5_000);
        var last_ping_ns: i128 = std.time.nanoTimestamp();
        const ping_interval_ns: i128 = 15 * std.time.ns_per_s;

        while (!self.should_stop.load(.seq_cst)) {
            const now_ns = std.time.nanoTimestamp();
            if (now_ns - last_ping_ns >= ping_interval_ns) {
                var ping_buf = [_]u8{ 'P', 'I', 'N', 'G' };
                client.write(&ping_buf) catch |e| {
                    log.err("kalshi_ws", "failed to send PING: {s}", .{@errorName(e)});
                    return e;
                };
                last_ping_ns = now_ns;
            }

            const message = client.read() catch |err| switch (err) {
                error.Closed => return,
                else => return err,
            } orelse continue;
            defer client.done(message);

            switch (message.type) {
                .text, .binary => self.handleMessage(message.data),
                .close => return,
                .ping => {
                    var pong_buf: [128]u8 = undefined;
                    const pong_len = @min(message.data.len, pong_buf.len);
                    @memcpy(pong_buf[0..pong_len], message.data[0..pong_len]);
                    try client.writePong(pong_buf[0..pong_len]);
                },
                .pong => {},
            }
        }
    }

    fn handleMessage(self: *KalshiWsClient, data: []const u8) void {
        if (data.len <= 2) return;
        if (data.len == 4 and std.mem.eql(u8, data, "PONG")) return;

        // Parse message type
        const msg_type = extractJsonString(data, "type") orelse return;

        if (std.mem.eql(u8, msg_type, "ticker")) {
            self.handleTickerMessage(data);
        } else if (std.mem.eql(u8, msg_type, "market_lifecycle_v2") or
            std.mem.eql(u8, msg_type, "multivariate_market_lifecycle"))
        {
            self.handleMarketLifecycleMessage(data);
        } else if (std.mem.eql(u8, msg_type, "error")) {
            const code = extractNestedJsonString(data, "msg", "code") orelse "?";
            const msg = extractNestedJsonString(data, "msg", "msg") orelse "";
            log.warn("kalshi_ws", "Kalshi websocket error code={s} msg={s}", .{ code, msg });
        }
    }

    fn handleTickerMessage(self: *KalshiWsClient, data: []const u8) void {
        // Extract ticker from nested msg object
        // Format: {"type":"ticker","msg":{"market_ticker":"...","yes_bid":"...","yes_ask":"..."}}
        // Find the "msg" object and extract fields from it
        const market_ticker = extractNestedJsonString(data, "msg", "market_ticker") orelse return;

        const yes_bid_str = extractNestedJsonString(data, "msg", "yes_bid_dollars") orelse
            extractNestedJsonString(data, "msg", "yes_bid") orelse "0";
        const yes_ask_str = extractNestedJsonString(data, "msg", "yes_ask_dollars") orelse
            extractNestedJsonString(data, "msg", "yes_ask") orelse "0";

        const yes_bid = std.fmt.parseFloat(f64, yes_bid_str) catch 0.0;
        const yes_ask = std.fmt.parseFloat(f64, yes_ask_str) catch 0.0;

        const bid_prob = if (yes_bid > 1.0) yes_bid / 100.0 else yes_bid;
        const ask_prob = if (yes_ask > 1.0) yes_ask / 100.0 else yes_ask;
        const mid_prob = if (bid_prob > 0.0 and ask_prob > 0.0)
            (bid_prob + ask_prob) / 2.0
        else if (extractNestedJsonString(data, "msg", "price_dollars")) |price_str|
            normalizeProbability(std.fmt.parseFloat(f64, price_str) catch 0.0) orelse 0.0
        else
            0.0;

        if (mid_prob <= 0.0 or mid_prob >= 1.0) return;

        var gamma_id_buf: [64]u8 = undefined;
        const gamma_id = self.resolveGammaId(market_ticker, &gamma_id_buf) orelse return;

        const now = std.time.timestamp();
        const confidence = 0.85; // Kalshi is a regulated exchange

        self.mu.lock();
        defer self.mu.unlock();

        // Update existing or add new estimate
        var found = false;
        for (&self.estimates) |*slot| {
            if (slot.*) |*est| {
                if (std.mem.eql(u8, est.market_id[0..est.market_id_len], gamma_id)) {
                    est.probability = mid_prob;
                    est.confidence = confidence;
                    est.fetched_at = now;
                    found = true;
                    break;
                }
            }
        }

        if (!found and self.estimate_count < MAX_ESTIMATES) {
            var mid: [64]u8 = undefined;
            const mid_len = @min(gamma_id.len, 64);
            @memcpy(mid[0..mid_len], gamma_id[0..mid_len]);

            var src: [32]u8 = undefined;
            const src_str = "kalshi";
            @memcpy(src[0..src_str.len], src_str);

            self.estimates[self.estimate_count] = ExternalEstimate{
                .market_id = mid,
                .market_id_len = mid_len,
                .condition_id = [_]u8{0} ** 128,
                .condition_id_len = 0,
                .probability = mid_prob,
                .confidence = confidence,
                .source = src,
                .source_len = src_str.len,
                .fetched_at = now,
            };
            self.estimate_count += 1;
        }

        log.debug("kalshi_ws", "ticker update: {s} prob={d:.4}", .{ market_ticker, mid_prob });
    }

    fn handleMarketLifecycleMessage(self: *KalshiWsClient, data: []const u8) void {
        const market_ticker = extractNestedJsonString(data, "msg", "market_ticker") orelse return;
        const title = extractNestedJsonString(data, "additional_metadata", "title") orelse
            extractNestedJsonString(data, "additional_metadata", "name");
        const yes_sub_title = extractNestedJsonString(data, "additional_metadata", "yes_sub_title");
        const no_sub_title = extractNestedJsonString(data, "additional_metadata", "no_sub_title");

        var gamma_id_buf: [64]u8 = undefined;
        const gamma_id =
            (if (title) |t| self.queryMarketIdByQuestion(t, &gamma_id_buf) else null) orelse
            (if (yes_sub_title) |s| self.queryMarketIdByQuestion(s, &gamma_id_buf) else null) orelse
            (if (no_sub_title) |s| self.queryMarketIdByQuestion(s, &gamma_id_buf) else null) orelse
            return;

        self.database.upsertKalshiMapping(market_ticker, gamma_id, 0.75, "ws_lifecycle_match") catch |err| {
            log.warn("kalshi_ws", "failed to persist lifecycle mapping for {s}: {s}", .{ market_ticker, @errorName(err) });
        };
        self.upsertAutoMapping(market_ticker, gamma_id);
        log.info("kalshi_ws", "mapped Kalshi ticker {s} to Gamma market {s} from lifecycle metadata", .{ market_ticker, gamma_id });
    }

    fn resolveGammaId(self: *KalshiWsClient, market_ticker: []const u8, buf: *[64]u8) ?[]const u8 {
        if (self.database.lookupKalshiMapping(market_ticker, buf)) |gamma_id| {
            return gamma_id;
        }

        var map_buf: [4096]u8 = undefined;
        if (self.database.getConfig("kalshi_market_map", &map_buf)) |market_map| {
            if (lookupTickerMapping(market_map, market_ticker, buf)) |gamma_id| {
                return gamma_id;
            }
        }

        self.mu.lock();
        defer self.mu.unlock();
        for (0..self.auto_map_count) |i| {
            if (std.mem.eql(u8, self.auto_map_tickers[i][0..self.auto_map_ticker_lens[i]], market_ticker)) {
                const len = self.auto_map_market_id_lens[i];
                @memcpy(buf[0..len], self.auto_map_market_ids[i][0..len]);
                return buf[0..len];
            }
        }

        return null;
    }

    fn queryMarketIdByQuestion(self: *KalshiWsClient, question: []const u8, out: *[64]u8) ?[]const u8 {
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
};

// ---------------------------------------------------------------------------
// JSON helpers (zero-alloc)
// ---------------------------------------------------------------------------

fn extractJsonString(data: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + key.len + 4 < data.len) : (i += 1) {
        if (data[i] != '"') continue;
        if (i + 1 + key.len + 1 >= data.len) continue;
        if (!std.mem.eql(u8, data[i + 1 .. i + 1 + key.len], key)) continue;
        if (data[i + 1 + key.len] != '"') continue;

        var j = i + 1 + key.len + 1;
        while (j < data.len and (data[j] == ':' or data[j] == ' ')) : (j += 1) {}
        if (j >= data.len) return null;

        if (data[j] == '"') {
            const start = j + 1;
            var end = start;
            while (end < data.len) : (end += 1) {
                if (data[end] != '"') continue;

                var backslash_count: usize = 0;
                var k = end;
                while (k > start and data[k - 1] == '\\') : (k -= 1) {
                    backslash_count += 1;
                }

                if (backslash_count % 2 == 0) break;
            }
            return data[start..end];
        }

        const start = j;
        var end = start;
        while (end < data.len and data[end] != ',' and data[end] != '}' and data[end] != ' ') : (end += 1) {}
        return data[start..end];
    }
    return null;
}

/// Extract a string value from a nested JSON object.
/// Looks for "outer_key":{..."inner_key":"value"...}
fn extractNestedJsonString(data: []const u8, outer_key: []const u8, inner_key: []const u8) ?[]const u8 {
    // Find the outer key's object
    var i: usize = 0;
    while (i + outer_key.len + 4 < data.len) : (i += 1) {
        if (data[i] != '"') continue;
        if (i + 1 + outer_key.len + 1 >= data.len) continue;
        if (!std.mem.eql(u8, data[i + 1 .. i + 1 + outer_key.len], outer_key)) continue;
        if (data[i + 1 + outer_key.len] != '"') continue;

        // Skip to the value (past ":" and whitespace)
        var j = i + 1 + outer_key.len + 1;
        while (j < data.len and (data[j] == ':' or data[j] == ' ')) : (j += 1) {}
        if (j >= data.len or data[j] != '{') continue;

        // Find the nested key within this object
        const obj_start = j;
        var depth: usize = 0;
        var obj_end = obj_start;
        var k = obj_start;
        while (k < data.len) : (k += 1) {
            if (data[k] == '{') depth += 1;
            if (data[k] == '}') {
                depth -= 1;
                if (depth == 0) {
                    obj_end = k + 1;
                    break;
                }
            }
        }
        if (obj_end <= obj_start) return null;
        return extractJsonString(data[obj_start..obj_end], inner_key);
    }
    return null;
}

/// Look up a Kalshi ticker in a JSON map like {"TICKER":"gamma-id","TICKER2":"gamma-id2"}.
fn lookupTickerMapping(map_json: []const u8, ticker: []const u8, buf: *[64]u8) ?[]const u8 {
    // Search for "ticker":"value" pattern
    var i: usize = 0;
    while (i + ticker.len + 4 < map_json.len) : (i += 1) {
        if (map_json[i] != '"') continue;
        if (i + 1 + ticker.len + 1 >= map_json.len) continue;
        if (!std.mem.eql(u8, map_json[i + 1 .. i + 1 + ticker.len], ticker)) continue;
        if (map_json[i + 1 + ticker.len] != '"') continue;

        var j = i + 1 + ticker.len + 1;
        while (j < map_json.len and (map_json[j] == ':' or map_json[j] == ' ')) : (j += 1) {}
        if (j >= map_json.len or map_json[j] != '"') return null;

        const start = j + 1;
        var end = start;
        while (end < map_json.len and map_json[end] != '"') : (end += 1) {}
        const val = map_json[start..end];
        if (val.len > buf.len) return null;
        @memcpy(buf[0..val.len], val);
        return buf[0..val.len];
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "kalshi_ws: extractJsonString basic" {
    const json = "{\"type\":\"ticker\",\"id\":42}";
    const t = extractJsonString(json, "type");
    try std.testing.expect(t != null);
    try std.testing.expectEqualStrings("ticker", t.?);
}

test "kalshi_ws: extractJsonString handles escaped quotes" {
    const json = "{\"type\":\"ticker\",\"msg\":\"say \\\"hello\\\" and \\\\\\\"bye\\\\\\\"\"}";
    const msg = extractJsonString(json, "msg");
    try std.testing.expect(msg != null);
    try std.testing.expectEqualStrings("say \\\"hello\\\" and \\\\\\\"bye\\\\\\\"", msg.?);
}

test "kalshi_ws: extractNestedJsonString" {
    const json = "{\"type\":\"ticker\",\"msg\":{\"market_ticker\":\"ABC\",\"yes_bid\":\"45\"}}";
    const ticker = extractNestedJsonString(json, "msg", "market_ticker");
    try std.testing.expect(ticker != null);
    try std.testing.expectEqualStrings("ABC", ticker.?);

    const bid = extractNestedJsonString(json, "msg", "yes_bid");
    try std.testing.expect(bid != null);
    try std.testing.expectEqualStrings("45", bid.?);
}

test "kalshi_ws: ticker message accepts documented dollar fields" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();
    try database.execZ("INSERT INTO markets(id,symbol,base,quote,status,clob_token_ids) VALUES('m1','fed-cuts','Will the Fed cut rates?','USDC','active','[\"yes-1\"]');");
    try database.upsertKalshiMapping("FED-23DEC-T3.00", "m1", 1.0, "test");

    var client = KalshiWsClient.init(std.testing.allocator, &database);
    client.handleMessage(
        \\{"type":"ticker","sid":11,"msg":{"market_ticker":"FED-23DEC-T3.00","market_id":"9b0f6b43","price_dollars":"0.480","yes_bid_dollars":"0.450","yes_ask_dollars":"0.530","volume_fp":"33896.00","open_interest_fp":"20422.00","ts":1669149841}}
    );

    try std.testing.expectEqual(@as(usize, 1), client.estimate_count);
    try std.testing.expect(client.estimates[0].?.probability > 0.48 and client.estimates[0].?.probability < 0.50);
}

test "kalshi_ws: lifecycle message seeds ticker mapping" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();
    try database.execZ("INSERT INTO markets(id,symbol,base,quote,status,clob_token_ids) VALUES('m1','fed-cuts','Will the Fed cut rates?','USDC','active','[\"yes-1\"]');");

    var client = KalshiWsClient.init(std.testing.allocator, &database);
    client.handleMessage(
        \\{"type":"market_lifecycle_v2","sid":13,"msg":{"market_ticker":"KXFEDCUT","event_type":"created","additional_metadata":{"title":"Will the Fed cut rates?","yes_sub_title":"Fed cuts","no_sub_title":"Fed does not cut","event_ticker":"KXFED"}}}
    );

    var buf: [64]u8 = undefined;
    const gamma_id = database.lookupKalshiMapping("KXFEDCUT", &buf);
    try std.testing.expect(gamma_id != null);
    try std.testing.expectEqualStrings("m1", gamma_id.?);
}

test "kalshi_ws: lifecycle message matches by fuzzy subtitle" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();
    try database.execZ("INSERT INTO markets(id,symbol,base,quote,status,clob_token_ids) VALUES('m1','fed-cuts-september','Will the Fed cut rates in September 2026?','USDC','active','[\"yes-1\"]');");

    var client = KalshiWsClient.init(std.testing.allocator, &database);
    client.handleMessage(
        \\{"type":"market_lifecycle_v2","sid":13,"msg":{"market_ticker":"KXFEDCUTSEP","event_type":"created","additional_metadata":{"title":"Fed September decision","yes_sub_title":"Will the Fed cut rates in September 2026?","no_sub_title":"The Fed does not cut rates in September 2026","event_ticker":"KXFED"}}}
    );

    var buf: [64]u8 = undefined;
    const gamma_id = database.lookupKalshiMapping("KXFEDCUTSEP", &buf);
    try std.testing.expect(gamma_id != null);
    try std.testing.expectEqualStrings("m1", gamma_id.?);
}

test "kalshi_ws: lookupTickerMapping" {
    const map = "{\"KXABC\":\"gamma-123\",\"KXDEF\":\"gamma-456\"}";
    var buf: [64]u8 = undefined;
    const result = lookupTickerMapping(map, "KXABC", &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("gamma-123", result.?);

    const result2 = lookupTickerMapping(map, "KXDEF", &buf);
    try std.testing.expect(result2 != null);
    try std.testing.expectEqualStrings("gamma-456", result2.?);

    const result3 = lookupTickerMapping(map, "MISSING", &buf);
    try std.testing.expect(result3 == null);
}

test "kalshi_ws: init and basic state" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    var client = KalshiWsClient.init(std.testing.allocator, &database);
    try std.testing.expect(!client.isConnected());
    try std.testing.expectEqual(@as(usize, 0), client.estimate_count);
}
