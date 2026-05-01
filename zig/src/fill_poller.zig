//! Fill poller — WebSocket-based fill detection with REST polling fallback.
//! Connects to the Polymarket user-channel WebSocket for real-time fill/cancel events.
//! Falls back to REST polling if the WebSocket is unavailable.
const std = @import("std");
const log = @import("logger.zig");
const db_mod = @import("db.zig");
const http = @import("http_client.zig");
const poly_auth = @import("polymarket_auth.zig");
const order_mgr = @import("order_manager.zig");
const portfolio = @import("portfolio_tracker.zig");
const strategy = @import("strategy_engine.zig");
const ipc = @import("ipc.zig");
const ipc_types = @import("ipc_types.zig");
const ws_lib = @import("websocket");
const c = db_mod.c;

const CLOB_API_BASE = "https://clob.polymarket.com";
const USER_WS_HOST = "ws-subscriptions-clob.polymarket.com";
const USER_WS_PATH = "/ws/user";

// ---------------------------------------------------------------------------
// Fill check result (from REST polling)
// ---------------------------------------------------------------------------

pub const FillCheckResult = struct {
    status_buf: [32]u8,
    status_len: usize,
    size_matched_buf: [32]u8,
    size_matched_len: usize,
    price_buf: [32]u8,
    price_len: usize,
    original_size_buf: [32]u8,
    original_size_len: usize,
    has_new_fill: bool,

    pub fn status(self: *const FillCheckResult) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn sizeMatched(self: *const FillCheckResult) []const u8 {
        return self.size_matched_buf[0..self.size_matched_len];
    }

    pub fn price(self: *const FillCheckResult) []const u8 {
        return self.price_buf[0..self.price_len];
    }

    pub fn originalSize(self: *const FillCheckResult) []const u8 {
        return self.original_size_buf[0..self.original_size_len];
    }
};

// ---------------------------------------------------------------------------
// Reconciliation result
// ---------------------------------------------------------------------------

pub const ReconcileResult = struct {
    adopted: u32,
    closed: u32,
    unchanged: u32,
};

// ---------------------------------------------------------------------------
// FillPoller
// ---------------------------------------------------------------------------

pub const FillPoller = struct {
    allocator: std.mem.Allocator,
    database: *db_mod.DB,
    om: *order_mgr.OrderManager,
    pt: *portfolio.PortfolioTracker,
    se: ?*strategy.StrategyEngine,
    should_stop: std.atomic.Value(bool),
    ws_connected: std.atomic.Value(bool),
    ws_disconnect_ts: std.atomic.Value(i64),
    last_reconcile_result: ?ReconcileResult,
    consecutive_http_failures: u32,
    circuit_breaker_until: i64,

    const WS_FALLBACK_TIMEOUT_S: i64 = 30;
    const POLL_INTERVAL_NS: u64 = 3 * std.time.ns_per_s;
    const MAX_WS_RECONNECT_ATTEMPTS: u32 = 5;

    pub fn init(
        allocator: std.mem.Allocator,
        database: *db_mod.DB,
        om: *order_mgr.OrderManager,
        pt: *portfolio.PortfolioTracker,
        se: ?*strategy.StrategyEngine,
    ) FillPoller {
        return .{
            .allocator = allocator,
            .database = database,
            .om = om,
            .pt = pt,
            .se = se,
            .should_stop = std.atomic.Value(bool).init(false),
            .ws_connected = std.atomic.Value(bool).init(false),
            .ws_disconnect_ts = std.atomic.Value(i64).init(0),
            .last_reconcile_result = null,
            .consecutive_http_failures = 0,
            .circuit_breaker_until = 0,
        };
    }

    /// Shared fill-confirmation handler called from both REST and WebSocket
    /// fill paths so inventory + paired-order cancel logic is never duplicated.
    fn onFillConfirmed(
        self: *FillPoller,
        order_id: []const u8,
        market_id: []const u8,
        direction: []const u8,
        fill_size_f: f64,
        is_fully_filled: bool,
    ) void {
        const se = self.se orelse return;

        // Update per-market inventory regardless of fill type.
        const dir: strategy.SignalDirection = if (std.mem.eql(u8, direction, "buy"))
            .buy
        else
            .sell;
        se.updateInventory(market_id, dir, fill_size_f);

        // On full fill, cancel the paired LP order (if any) and untrack both.
        if (is_fully_filled) {
            if (se.findPairedOrder(order_id)) |paired_id| {
                if (self.om.cancelOrder(paired_id)) {
                    se.untrackOrder(paired_id);
                    se.incrementCancels(.liquidity_provision);
                    log.info("fill_poller", "cancelled LP pair: {s}", .{paired_id});
                }
            }
            se.untrackOrder(order_id);
        }
    }

    pub fn stop(self: *FillPoller) void {
        self.should_stop.store(true, .seq_cst);
    }

    // -----------------------------------------------------------------------
    // REST-based fill checking
    // -----------------------------------------------------------------------

    /// Check a single order's fill status via REST API.
    pub fn checkOrderFills(self: *FillPoller, order_id: []const u8) ?FillCheckResult {
        const creds = self.om.config.api_creds orelse {
            log.err("fill_poller", "no API credentials for fill check", .{});
            return null;
        };

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/order/{s}", .{ CLOB_API_BASE, order_id }) catch {
            log.err("fill_poller", "failed to format order URL", .{});
            return null;
        };

        // Build HMAC auth headers
        var ts_buf: [32]u8 = undefined;
        const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch return null;

        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/order/{s}", .{order_id}) catch return null;

        const hmac_result = poly_auth.buildHmacSignature(
            creds.secret[0..creds.secret_len],
            ts,
            "GET",
            path,
            null,
        ) catch |e| {
            log.err("fill_poller", "failed to compute HMAC: {s}", .{@errorName(e)});
            return null;
        };

        var addr_hex: [42]u8 = undefined;
        addr_hex[0] = '0';
        addr_hex[1] = 'x';
        const charset = "0123456789abcdef";
        for (self.om.config.signer_address, 0..) |b, i| {
            addr_hex[2 + i * 2] = charset[b >> 4];
            addr_hex[2 + i * 2 + 1] = charset[b & 0x0f];
        }

        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        var response = client.getWithHeaders(url, &.{
            .{ .name = "POLY_ADDRESS", .value = &addr_hex },
            .{ .name = "POLY_SIGNATURE", .value = hmac_result.slice() },
            .{ .name = "POLY_TIMESTAMP", .value = ts },
            .{ .name = "POLY_API_KEY", .value = creds.api_key[0..creds.api_key_len] },
            .{ .name = "POLY_PASSPHRASE", .value = creds.passphrase[0..creds.passphrase_len] },
        }) catch |e| {
            log.err("fill_poller", "order check request failed: {s}", .{@errorName(e)});
            return null;
        };
        defer response.deinit();

        if (response.status.class() != .success) {
            log.err("fill_poller", "order check returned status {d}", .{@intFromEnum(response.status)});
            return null;
        }

        return parseOrderResponse(response.body);
    }

    /// Parse order response JSON into FillCheckResult.
    pub fn parseOrderResponse(body: []const u8) ?FillCheckResult {
        var result: FillCheckResult = .{
            .status_buf = undefined,
            .status_len = 0,
            .size_matched_buf = undefined,
            .size_matched_len = 0,
            .price_buf = undefined,
            .price_len = 0,
            .original_size_buf = undefined,
            .original_size_len = 0,
            .has_new_fill = false,
        };

        // Manual JSON field extraction (avoid heap allocation)
        if (extractJsonString(body, "status")) |status| {
            const len = @min(status.len, result.status_buf.len);
            @memcpy(result.status_buf[0..len], status[0..len]);
            result.status_len = len;
        }

        if (extractJsonString(body, "size_matched")) |sm| {
            const len = @min(sm.len, result.size_matched_buf.len);
            @memcpy(result.size_matched_buf[0..len], sm[0..len]);
            result.size_matched_len = len;
        }

        if (extractJsonString(body, "price")) |p| {
            const len = @min(p.len, result.price_buf.len);
            @memcpy(result.price_buf[0..len], p[0..len]);
            result.price_len = len;
        }

        if (extractJsonString(body, "original_size")) |os| {
            const len = @min(os.len, result.original_size_buf.len);
            @memcpy(result.original_size_buf[0..len], os[0..len]);
            result.original_size_len = len;
        }

        // Determine if there's a new fill based on size_matched > 0
        if (result.size_matched_len > 0) {
            const sm_f = std.fmt.parseFloat(f64, result.size_matched_buf[0..result.size_matched_len]) catch 0.0;
            result.has_new_fill = sm_f > 0.0;
        }

        if (result.status_len == 0) return null;
        return result;
    }

    // -----------------------------------------------------------------------
    // REST polling loop (fallback)
    // -----------------------------------------------------------------------

    /// Run a single fill check cycle for all open orders.
    pub fn runFillCheck(self: *FillPoller) void {
        // Circuit-breaker: pause polling after consecutive failures
        if (std.time.timestamp() < self.circuit_breaker_until) {
            log.debug("fill_poller", "circuit-breaker active, skipping fill check", .{});
            return;
        }

        // Query all placed/partially_filled orders not checked recently
        const sql = "SELECT id, market_id, side, size, filled_size FROM orders WHERE status IN ('placed','partially_filled') AND last_checked_at < unixepoch() - 3 LIMIT 20;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("fill_poller", "failed to prepare open-order query", .{});
            return;
        }
        defer _ = c.sqlite3_finalize(stmt);

        var order_ids: [20][128]u8 = undefined;
        var order_id_lens: [20]usize = undefined;
        var market_ids: [20][128]u8 = undefined;
        var market_id_lens: [20]usize = undefined;
        var sides: [20][8]u8 = undefined;
        var side_lens: [20]usize = undefined;
        var sizes: [20][32]u8 = undefined;
        var size_lens: [20]usize = undefined;
        var filled_sizes: [20][32]u8 = undefined;
        var filled_size_lens: [20]usize = undefined;
        var count: usize = 0;

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW and count < 20) {
            const id_raw = c.sqlite3_column_text(stmt, 0);
            const id = if (id_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;
            const mid_raw = c.sqlite3_column_text(stmt, 1);
            const mid = if (mid_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;
            const side_raw = c.sqlite3_column_text(stmt, 2);
            const side = if (side_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;
            const sz_raw = c.sqlite3_column_text(stmt, 3);
            const sz = if (sz_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "0";
            const fs_raw = c.sqlite3_column_text(stmt, 4);
            const fs = if (fs_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "0";

            const id_len = @min(id.len, 128);
            @memcpy(order_ids[count][0..id_len], id[0..id_len]);
            order_id_lens[count] = id_len;

            const mid_len = @min(mid.len, 128);
            @memcpy(market_ids[count][0..mid_len], mid[0..mid_len]);
            market_id_lens[count] = mid_len;

            const side_len = @min(side.len, 8);
            @memcpy(sides[count][0..side_len], side[0..side_len]);
            side_lens[count] = side_len;

            const sz_len = @min(sz.len, 32);
            @memcpy(sizes[count][0..sz_len], sz[0..sz_len]);
            size_lens[count] = sz_len;

            const fs_len = @min(fs.len, 32);
            @memcpy(filled_sizes[count][0..fs_len], fs[0..fs_len]);
            filled_size_lens[count] = fs_len;

            count += 1;
        }

        for (0..count) |i| {
            const oid = order_ids[i][0..order_id_lens[i]];
            const mid = market_ids[i][0..market_id_lens[i]];
            const side = sides[i][0..side_lens[i]];
            const size = sizes[i][0..size_lens[i]];
            const prev_filled = filled_sizes[i][0..filled_size_lens[i]];

            const check = self.checkOrderFills(oid) orelse {
                self.database.updateOrderLastChecked(oid) catch {};
                self.consecutive_http_failures += 1;
                if (self.consecutive_http_failures >= 5) {
                    self.circuit_breaker_until = std.time.timestamp() + 60;
                    log.warn("fill_poller", "circuit-breaker triggered: pausing polling for 60s after {d} consecutive failures", .{self.consecutive_http_failures});
                    return;
                }
                continue;
            };

            self.consecutive_http_failures = 0;
            self.database.updateOrderLastChecked(oid) catch {};

            const status = check.status();
            const size_matched = check.sizeMatched();
            const fill_price = check.price();
            const original_size = if (check.original_size_len > 0) check.originalSize() else size;

            // Determine if there's a new fill by comparing with previous filled_size
            const prev_f = std.fmt.parseFloat(f64, prev_filled) catch 0.0;
            const new_f = std.fmt.parseFloat(f64, size_matched) catch 0.0;

            if (new_f > prev_f) {
                // New fill detected
                var fill_size_buf: [32]u8 = undefined;
                const fill_size = std.fmt.bufPrint(&fill_size_buf, "{d:.6}", .{new_f - prev_f}) catch "0";

                // Generate fill ID
                var fill_id_buf: [64]u8 = undefined;
                const fill_id = std.fmt.bufPrint(&fill_id_buf, "fill-{s}-{d}", .{ oid[0..@min(oid.len, 16)], std.time.milliTimestamp() }) catch "fill-unknown";

                // Call processFill on portfolio tracker
                self.pt.processFill(oid, fill_id, fill_size, fill_price, true);

                // Determine new status
                const orig_f = std.fmt.parseFloat(f64, original_size) catch 0.0;
                const is_fully_filled = new_f >= orig_f - 0.0001;

                const new_status: []const u8 = if (is_fully_filled) "filled" else "partially_filled";

                // Update DB atomically
                self.database.updateOrderFillStatus(oid, new_status, size_matched, fill_price) catch |e| {
                    log.err("fill_poller", "failed to update fill status: {s}", .{@errorName(e)});
                };

                var side_lower_buf: [8]u8 = undefined;
                var side_lower: []const u8 = side;
                if (side.len > 0 and side.len <= side_lower_buf.len) {
                    for (side, 0..) |ch, si| {
                        side_lower_buf[si] = std.ascii.toLower(ch);
                    }
                    side_lower = side_lower_buf[0..side.len];
                }

                // Notify strategy engine: update inventory + cancel paired LP order
                self.onFillConfirmed(oid, mid, side_lower, new_f - prev_f, is_fully_filled);

                // Compute realized PnL for the event
                var pnl_buf: [32]u8 = undefined;
                const pnl_str = std.fmt.bufPrint(&pnl_buf, "{d:.2}", .{self.pt.realized_pnl_today}) catch "0.00";

                // Publish IPC event
                if (is_fully_filled) {
                    var evt_buf: [512]u8 = undefined;
                    const evt = std.fmt.bufPrint(&evt_buf,
                        "{{\"order_id\":\"{s}\",\"market_id\":\"{s}\",\"side\":\"{s}\",\"fill_size\":\"{s}\",\"fill_price\":\"{s}\",\"realized_pnl\":\"{s}\"}}",
                        .{ oid, mid, side, fill_size, fill_price, pnl_str },
                    ) catch "{}";
                    ipc.publishEvent(ipc_types.T.event_order_filled, evt);
                    log.info("fill_poller", "order filled: {s} {s}@{s}", .{ oid, fill_size, fill_price });
                } else {
                    var remaining_buf: [32]u8 = undefined;
                    const remaining = std.fmt.bufPrint(&remaining_buf, "{d:.6}", .{orig_f - new_f}) catch "0";
                    var evt_buf: [512]u8 = undefined;
                    const evt = std.fmt.bufPrint(&evt_buf,
                        "{{\"order_id\":\"{s}\",\"market_id\":\"{s}\",\"side\":\"{s}\",\"fill_size\":\"{s}\",\"fill_price\":\"{s}\",\"remaining_size\":\"{s}\"}}",
                        .{ oid, mid, side, fill_size, fill_price, remaining },
                    ) catch "{}";
                    ipc.publishEvent(ipc_types.T.event_order_partially_filled, evt);
                    log.info("fill_poller", "order partially filled: {s} {s}@{s} (remaining {s})", .{ oid, fill_size, fill_price, remaining });
                }
                log.info("fill_poller", "fill_latency_ms: order={s} detected_at={d}", .{ oid, std.time.timestamp() * 1000 });
            } else if (std.mem.eql(u8, status, "CANCELED") or std.mem.eql(u8, status, "canceled")) {
                // Order cancelled on CLOB, update local status
                self.database.updateOrderStatus(oid, "cancelled") catch |e| {
                    log.err("fill_poller", "failed to update cancelled status: {s}", .{@errorName(e)});
                };
                log.info("fill_poller", "order cancelled on CLOB: {s}", .{oid});
            } else if (std.mem.eql(u8, status, "MATCHED") or std.mem.eql(u8, status, "matched")) {
                // Fully matched, ensure we have the fill recorded
                self.database.updateOrderFillStatus(oid, "filled", size_matched, fill_price) catch {};
                log.info("fill_poller", "order matched on CLOB: {s}", .{oid});
            }
        }
    }

    // -----------------------------------------------------------------------
    // REST polling thread
    // -----------------------------------------------------------------------

    /// Polling loop thread. Runs as fallback when WebSocket is unavailable.
    pub fn pollLoop(self: *FillPoller) void {
        log.info("fill_poller", "REST polling loop started (3s interval)", .{});
        while (!self.should_stop.load(.seq_cst)) {
            // Only poll if WebSocket is not connected or has been down too long
            const ws_up = self.ws_connected.load(.seq_cst);
            if (!ws_up) {
                self.runFillCheck();
            }

            std.Thread.sleep(POLL_INTERVAL_NS);
        }
        log.info("fill_poller", "REST polling loop stopped", .{});
    }

    // -----------------------------------------------------------------------
    // WebSocket user-channel
    // -----------------------------------------------------------------------

    /// WebSocket loop thread. Primary fill detection method.
    pub fn wsLoop(self: *FillPoller) void {
        log.info("fill_poller", "WebSocket user-channel loop started", .{});
        var reconnect_delay_ms: u64 = 1_000;
        const max_reconnect_ms: u64 = 30_000;
        var consecutive_failures: u32 = 0;

        while (!self.should_stop.load(.seq_cst)) {
            if (consecutive_failures >= FillPoller.MAX_WS_RECONNECT_ATTEMPTS) {
                log.err("fill_poller", "max WebSocket reconnect attempts ({d}) reached, switching to REST-only mode", .{FillPoller.MAX_WS_RECONNECT_ATTEMPTS});
                break;
            }
            const creds = self.om.config.api_creds orelse {
                log.warn("fill_poller", "no API credentials for user-channel WS, waiting...", .{});
                std.Thread.sleep(10 * std.time.ns_per_s);
                continue;
            };

            log.info("fill_poller", "connecting to user-channel WebSocket...", .{});

            self.runWsConnection(creds) catch |e| {
                log.err("fill_poller", "user-channel WS error: {s}", .{@errorName(e)});
            };

            self.ws_connected.store(false, .seq_cst);
            self.ws_disconnect_ts.store(std.time.timestamp(), .seq_cst);
            consecutive_failures += 1;

            if (self.should_stop.load(.seq_cst)) break;

            log.warn("fill_poller", "user-channel WS disconnected, reconnecting in {d}ms (attempt {d})", .{ reconnect_delay_ms, consecutive_failures });
            std.Thread.sleep(reconnect_delay_ms * std.time.ns_per_ms);
            reconnect_delay_ms = @min(reconnect_delay_ms * 2, max_reconnect_ms);
        }
        log.info("fill_poller", "WebSocket user-channel loop stopped", .{});
    }

    fn runWsConnection(self: *FillPoller, creds: poly_auth.ApiCredentials) !void {
        var client = try ws_lib.Client.init(self.allocator, .{
            .host = USER_WS_HOST,
            .port = 443,
            .tls = true,
            .max_size = 1 * 1024 * 1024,
        });
        defer client.deinit();

        try client.handshake(USER_WS_PATH, .{
            .timeout_ms = 10_000,
            .headers = "Host: " ++ USER_WS_HOST ++ "\r\n",
        });

        // Build and send auth subscription message
        var sub_buf: [1024]u8 = undefined;
        const sub_msg = std.fmt.bufPrint(&sub_buf,
            \\{{"auth":{{"apiKey":"{s}","secret":"{s}","passphrase":"{s}"}},"type":"user"}}
        , .{
            creds.api_key[0..creds.api_key_len],
            creds.secret[0..creds.secret_len],
            creds.passphrase[0..creds.passphrase_len],
        }) catch return error.BufferOverflow;

        const len = sub_msg.len;
        var send_buf: [1024]u8 = undefined;
        @memcpy(send_buf[0..len], sub_msg);
        try client.write(send_buf[0..len]);

        self.ws_connected.store(true, .seq_cst);
        log.info("fill_poller", "user-channel WebSocket connected and authenticated", .{});

        // Read loop with periodic pings
        try client.readTimeout(5_000);
        var last_ping_ns: i128 = std.time.nanoTimestamp();
        const ping_interval_ns: i128 = 8 * std.time.ns_per_s;

        while (!self.should_stop.load(.seq_cst)) {
            const now_ns = std.time.nanoTimestamp();
            if (now_ns - last_ping_ns >= ping_interval_ns) {
                var ping_buf = [_]u8{ 'P', 'I', 'N', 'G' };
                client.write(&ping_buf) catch |e| {
                    log.err("fill_poller", "failed to send PING: {s}", .{@errorName(e)});
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
                .text, .binary => self.handleWsMessage(message.data),
                .close => return,
                .ping, .pong => {},
            }
        }
    }

    /// Handle a user-channel WebSocket message.
    fn handleWsMessage(self: *FillPoller, data: []const u8) void {
        if (data.len == 4 and std.mem.eql(u8, data, "PONG")) return;
        if (data.len <= 2) return;

        // Parse the event_type to determine what kind of event this is
        const event_type = extractJsonString(data, "event_type") orelse return;

        if (!std.mem.eql(u8, event_type, "order")) return;

        // Parse the "type" field (PLACEMENT, UPDATE, CANCELLATION)
        const order_type = extractJsonString(data, "type") orelse return;

        const order_id = extractJsonString(data, "id") orelse return;

        if (std.mem.eql(u8, order_type, "UPDATE") or std.mem.eql(u8, order_type, "CANCELLATION")) {
            // For UPDATE events (partial/full fill) and CANCELLATION, check via REST for accurate data
            log.info("fill_poller", "WS event: {s} for order {s}", .{ order_type, order_id[0..@min(order_id.len, 32)] });

            // Parse fields directly from the WS message
            const size_matched_str = extractJsonString(data, "size_matched") orelse "0";
            const price_str = extractJsonString(data, "price") orelse "0";
            const original_size_str = extractJsonString(data, "original_size") orelse "0";
            const side_str = extractJsonString(data, "side") orelse "";
            const market_str = extractJsonString(data, "market") orelse "";

            if (std.mem.eql(u8, order_type, "CANCELLATION")) {
                self.database.updateOrderStatus(order_id, "cancelled") catch |e| {
                    log.err("fill_poller", "WS: failed to update cancelled status: {s}", .{@errorName(e)});
                };
                log.info("fill_poller", "WS: order cancelled: {s}", .{order_id[0..@min(order_id.len, 32)]});
                return;
            }

            // UPDATE — process fill
            const sm_f = std.fmt.parseFloat(f64, size_matched_str) catch 0.0;
            if (sm_f <= 0.0) return;

            // Query current DB filled_size to compute the delta
            var prev_filled_buf: [32]u8 = undefined;
            var prev_filled: []const u8 = "0";
            {
                const q_sql = "SELECT filled_size FROM orders WHERE id=?;" ++ &[_:0]u8{};
                var q_stmt: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self.database.handle, q_sql.ptr, -1, &q_stmt, null) == c.SQLITE_OK) {
                    defer _ = c.sqlite3_finalize(q_stmt);
                    if (c.sqlite3_bind_text(q_stmt, 1, order_id.ptr, @intCast(order_id.len), null) == c.SQLITE_OK) {
                        if (c.sqlite3_step(q_stmt) == c.SQLITE_ROW) {
                            const fs_raw = c.sqlite3_column_text(q_stmt, 0);
                            if (fs_raw) |p| {
                                const fs = std.mem.span(@as([*c]const u8, @ptrCast(p)));
                                const fs_len = @min(fs.len, prev_filled_buf.len);
                                @memcpy(prev_filled_buf[0..fs_len], fs[0..fs_len]);
                                prev_filled = prev_filled_buf[0..fs_len];
                            }
                        }
                    }
                }
            }

            const prev_f = std.fmt.parseFloat(f64, prev_filled) catch 0.0;
            if (sm_f <= prev_f) return;

            const fill_delta = sm_f - prev_f;
            var fill_size_buf: [32]u8 = undefined;
            const fill_size = std.fmt.bufPrint(&fill_size_buf, "{d:.6}", .{fill_delta}) catch "0";

            var fill_id_buf: [64]u8 = undefined;
            const fill_id = std.fmt.bufPrint(&fill_id_buf, "fill-{s}-{d}", .{ order_id[0..@min(order_id.len, 16)], std.time.milliTimestamp() }) catch "fill-unknown";

            self.pt.processFill(order_id, fill_id, fill_size, price_str, true);

            const orig_f = std.fmt.parseFloat(f64, original_size_str) catch 0.0;
            const is_fully_filled = sm_f >= orig_f - 0.0001;

            const new_status: []const u8 = if (is_fully_filled) "filled" else "partially_filled";
            self.database.updateOrderFillStatus(order_id, new_status, size_matched_str, price_str) catch |e| {
                log.err("fill_poller", "WS: failed to update fill status: {s}", .{@errorName(e)});
            };

            // Resolve market_id (Gamma id) from condition_id
            var gamma_id_buf: [128]u8 = undefined;
            var gamma_id: []const u8 = market_str;
            // Will be re-set after lookup; declared here so onFillConfirmed sees Gamma id below.
            if (market_str.len > 0) {
                const lookup_sql = "SELECT id FROM markets WHERE condition_id=? LIMIT 1;" ++ &[_:0]u8{};
                var lookup_stmt: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self.database.handle, lookup_sql.ptr, -1, &lookup_stmt, null) == c.SQLITE_OK) {
                    defer _ = c.sqlite3_finalize(lookup_stmt);
                    if (c.sqlite3_bind_text(lookup_stmt, 1, market_str.ptr, @intCast(market_str.len), null) == c.SQLITE_OK) {
                        if (c.sqlite3_step(lookup_stmt) == c.SQLITE_ROW) {
                            const gid_raw = c.sqlite3_column_text(lookup_stmt, 0);
                            if (gid_raw) |p| {
                                const gid = std.mem.span(@as([*c]const u8, @ptrCast(p)));
                                const gid_len = @min(gid.len, gamma_id_buf.len);
                                @memcpy(gamma_id_buf[0..gid_len], gid[0..gid_len]);
                                gamma_id = gamma_id_buf[0..gid_len];
                            }
                        }
                    }
                }
            }

            // Normalize side for IPC event
            var side_lower_buf: [8]u8 = undefined;
            var side_lower: []const u8 = side_str;
            if (side_str.len > 0 and side_str.len <= 8) {
                for (side_str, 0..) |ch, si| {
                    side_lower_buf[si] = std.ascii.toLower(ch);
                }
                side_lower = side_lower_buf[0..side_str.len];
            }

            // Notify strategy engine: update inventory + cancel paired LP order
            self.onFillConfirmed(order_id, gamma_id, side_lower, fill_delta, is_fully_filled);

            var pnl_buf: [32]u8 = undefined;
            const pnl_str = std.fmt.bufPrint(&pnl_buf, "{d:.2}", .{self.pt.realized_pnl_today}) catch "0.00";

            if (is_fully_filled) {
                var evt_buf: [512]u8 = undefined;
                const evt = std.fmt.bufPrint(&evt_buf,
                    "{{\"order_id\":\"{s}\",\"market_id\":\"{s}\",\"side\":\"{s}\",\"fill_size\":\"{s}\",\"fill_price\":\"{s}\",\"realized_pnl\":\"{s}\"}}",
                    .{ order_id, gamma_id, side_lower, fill_size, price_str, pnl_str },
                ) catch "{}";
                ipc.publishEvent(ipc_types.T.event_order_filled, evt);
                log.info("fill_poller", "WS: order filled: {s}", .{order_id[0..@min(order_id.len, 32)]});
            } else {
                var remaining_buf: [32]u8 = undefined;
                const remaining = std.fmt.bufPrint(&remaining_buf, "{d:.6}", .{orig_f - sm_f}) catch "0";
                var evt_buf: [512]u8 = undefined;
                const evt = std.fmt.bufPrint(&evt_buf,
                    "{{\"order_id\":\"{s}\",\"market_id\":\"{s}\",\"side\":\"{s}\",\"fill_size\":\"{s}\",\"fill_price\":\"{s}\",\"remaining_size\":\"{s}\"}}",
                    .{ order_id, gamma_id, side_lower, fill_size, price_str, remaining },
                ) catch "{}";
                ipc.publishEvent(ipc_types.T.event_order_partially_filled, evt);
                log.info("fill_poller", "WS: order partially filled: {s}", .{order_id[0..@min(order_id.len, 32)]});
            }
            log.info("fill_poller", "fill_latency_ms: order={s} detected_at={d}", .{ order_id, std.time.timestamp() * 1000 });
        }
    }

    // -----------------------------------------------------------------------
    // Startup reconciliation
    // -----------------------------------------------------------------------

    /// Reconcile local DB state with CLOB on startup.
    pub fn reconcileOnStartup(self: *FillPoller) ReconcileResult {
        log.info("fill_poller", "starting reconciliation...", .{});
        var result = ReconcileResult{ .adopted = 0, .closed = 0, .unchanged = 0 };

        const creds = self.om.config.api_creds orelse {
            log.err("fill_poller", "no API credentials for reconciliation", .{});
            return result;
        };

        // Step 1: Fetch all open orders from CLOB
        var addr_hex: [42]u8 = undefined;
        addr_hex[0] = '0';
        addr_hex[1] = 'x';
        const charset = "0123456789abcdef";
        for (self.om.config.signer_address, 0..) |b, i| {
            addr_hex[2 + i * 2] = charset[b >> 4];
            addr_hex[2 + i * 2 + 1] = charset[b & 0x0f];
        }

        // Use ArrayList for dynamic order id storage
        var clob_order_ids: std.ArrayList([]const u8) = .empty;
        defer clob_order_ids.deinit(self.allocator);
        var next_cursor: [256]u8 = undefined;
        var next_cursor_len: usize = 0;

        var page: u32 = 0;
        while (page < 25) : (page += 1) {
            var url_buf: [512]u8 = undefined;
            const url = if (next_cursor_len > 0)
                std.fmt.bufPrint(&url_buf, "{s}/orders?maker_address={s}&status=open&next_cursor={s}", .{
                    CLOB_API_BASE, &addr_hex, next_cursor[0..next_cursor_len],
                }) catch break
            else
                std.fmt.bufPrint(&url_buf, "{s}/orders?maker_address={s}&status=open", .{
                    CLOB_API_BASE, &addr_hex,
                }) catch break;

            var ts_buf: [32]u8 = undefined;
            const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch break;

            var path_buf: [512]u8 = undefined;
            const req_path = if (next_cursor_len > 0)
                std.fmt.bufPrint(&path_buf, "/orders?maker_address={s}&status=open&next_cursor={s}", .{
                    &addr_hex, next_cursor[0..next_cursor_len],
                }) catch break
            else
                std.fmt.bufPrint(&path_buf, "/orders?maker_address={s}&status=open", .{&addr_hex}) catch break;

            const hmac = poly_auth.buildHmacSignature(
                creds.secret[0..creds.secret_len],
                ts,
                "GET",
                req_path,
                null,
            ) catch break;

            var client = http.HttpClient.init(self.allocator);
            defer client.deinit();

            var response = client.getWithHeaders(url, &.{
                .{ .name = "POLY_ADDRESS", .value = &addr_hex },
                .{ .name = "POLY_SIGNATURE", .value = hmac.slice() },
                .{ .name = "POLY_TIMESTAMP", .value = ts },
                .{ .name = "POLY_API_KEY", .value = creds.api_key[0..creds.api_key_len] },
                .{ .name = "POLY_PASSPHRASE", .value = creds.passphrase[0..creds.passphrase_len] },
            }) catch |e| {
                log.err("fill_poller", "reconciliation: failed to fetch open orders: {s}", .{@errorName(e)});
                break;
            };
            defer response.deinit();

            if (response.status.class() != .success) {
                log.err("fill_poller", "reconciliation: CLOB returned status {d}", .{@intFromEnum(response.status)});
                break;
            }

            // Parse order IDs from response (JSON array of order objects)
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{}) catch break;
            defer parsed.deinit();

            // Handle paginated response: {"data": [...], "next_cursor": "..."}
            var orders_array: ?std.json.Array = null;
            next_cursor_len = 0;

            switch (parsed.value) {
                .array => |arr| {
                    orders_array = arr;
                },
                .object => |obj| {
                    if (obj.get("data")) |data_val| {
                        if (data_val == .array) orders_array = data_val.array;
                    }
                    if (obj.get("next_cursor")) |nc_val| {
                        if (nc_val == .string and nc_val.string.len > 0) {
                            const nc_len = @min(nc_val.string.len, next_cursor.len);
                            @memcpy(next_cursor[0..nc_len], nc_val.string[0..nc_len]);
                            next_cursor_len = nc_len;
                        }
                    }
                },
                else => break,
            }

            const arr = orders_array orelse break;
            if (arr.items.len == 0) break;

            for (arr.items) |item| {
                if (item != .object) continue;
                const id_val = item.object.get("id") orelse continue;
                if (id_val != .string) continue;
                // Copy id string into allocator-backed buffer
                const id_str = id_val.string;
                const id_copy = self.allocator.dupe(u8, id_str) catch |e| {
                    log.err("fill_poller", "reconciliation: failed to copy order id: {s}", .{@errorName(e)});
                    break;
                };
                clob_order_ids.append(self.allocator, id_copy) catch |e| {
                    log.err("fill_poller", "reconciliation: failed to append order id: {s}", .{@errorName(e)});
                    self.allocator.free(id_copy);
                };
            }

            if (next_cursor_len == 0) break;
        }

        log.info("fill_poller", "reconciliation: fetched {d} open orders from CLOB", .{clob_order_ids.items.len});

        // Step 2: For each CLOB order absent from DB, adopt it
        for (clob_order_ids.items) |clob_id| {
            // Check if order exists in DB
            const exists_sql = "SELECT 1 FROM orders WHERE id=?;" ++ &[_:0]u8{};
            var exists_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.database.handle, exists_sql.ptr, -1, &exists_stmt, null) != c.SQLITE_OK) continue;
            defer _ = c.sqlite3_finalize(exists_stmt);
            if (c.sqlite3_bind_text(exists_stmt, 1, clob_id.ptr, @intCast(clob_id.len), null) != c.SQLITE_OK) continue;

            if (c.sqlite3_step(exists_stmt) == c.SQLITE_ROW) {
                result.unchanged += 1;
                continue;
            }

            // Fetch order details from CLOB
            var url_buf: [512]u8 = undefined;
            const order_url = std.fmt.bufPrint(&url_buf, "{s}/order/{s}", .{ CLOB_API_BASE, clob_id }) catch null;
            var ts_buf: [32]u8 = undefined;
            const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch null;
            var path_buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/order/{s}", .{clob_id}) catch null;
            var market_id: []const u8 = "unknown";
            var size: []const u8 = "0";
            var price: []const u8 = "0";
            var side: []const u8 = "buy";
            var order_type: []const u8 = "limit";
            var details_found = false;
            var reconciled_missing_details = false;

            if (order_url != null and ts != null and path != null) {
                const hmac_result = poly_auth.buildHmacSignature(
                    creds.secret[0..creds.secret_len],
                    ts.?,
                    "GET",
                    path.?,
                    null,
                ) catch null;
                if (hmac_result) |hmac| {
                    var client = http.HttpClient.init(self.allocator);
                    defer client.deinit();
                    var response = client.getWithHeaders(order_url.?, &.{
                        .{ .name = "POLY_ADDRESS", .value = &addr_hex },
                        .{ .name = "POLY_SIGNATURE", .value = hmac.slice() },
                        .{ .name = "POLY_TIMESTAMP", .value = ts.? },
                        .{ .name = "POLY_API_KEY", .value = creds.api_key[0..creds.api_key_len] },
                        .{ .name = "POLY_PASSPHRASE", .value = creds.passphrase[0..creds.passphrase_len] },
                    }) catch null;
                    if (response) |*resp| {
                        defer resp.deinit();
                        if (resp.status.class() == .success) {
                            // Parse JSON for market_id, size, price, side, type
                            if (extractJsonString(resp.body, "market")) |mid| market_id = mid;
                            if (extractJsonString(resp.body, "size")) |sz| size = sz;
                            if (extractJsonString(resp.body, "price")) |pr| price = pr;
                            if (extractJsonString(resp.body, "side")) |sd| side = sd;
                            if (extractJsonString(resp.body, "type")) |tp| order_type = tp;
                            details_found = true;
                        }
                    }
                }
            }
            if (!details_found or std.mem.eql(u8, market_id, "unknown") or std.mem.eql(u8, size, "0")) {
                reconciled_missing_details = true;
            }

            // Insert with status placed, strategy_origin = 'reconciled', and flag if missing details
            self.database.insertOrder(
                clob_id,
                market_id,
                clob_id,
                order_type,
                side,
                size,
                price,
                if (reconciled_missing_details) "reconciled_missing_details" else "reconciled"
            ) catch |e| {
                log.err("fill_poller", "reconciliation: failed to adopt order {s}: {s}", .{ clob_id, @errorName(e) });
                continue;
            };
            self.database.updateOrderStatus(clob_id, "placed") catch {};
            result.adopted += 1;
            log.info("fill_poller", "reconciliation: adopted order {s}{s}", .{ clob_id, if (reconciled_missing_details) " (missing details)" else "" });
        }

        // Step 3: For each DB order in placed/partially_filled that's absent from CLOB, resolve
        const local_sql = "SELECT id FROM orders WHERE status IN ('placed','partially_filled');" ++ &[_:0]u8{};
        var local_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, local_sql.ptr, -1, &local_stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(local_stmt);

            while (c.sqlite3_step(local_stmt) == c.SQLITE_ROW) {
                const db_id_raw = c.sqlite3_column_text(local_stmt, 0);
                const db_id = if (db_id_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;

                // Check if this order is in the CLOB open list
                var found = false;
                for (clob_order_ids.items) |clob_id| {
                    if (std.mem.eql(u8, db_id, clob_id)) {
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    // Order not on CLOB — check its final status
                    if (self.checkOrderFills(db_id)) |check| {
                        const status = check.status();
                        if (std.mem.eql(u8, status, "MATCHED") or std.mem.eql(u8, status, "matched")) {
                            self.database.updateOrderFillStatus(db_id, "filled", check.sizeMatched(), check.price()) catch {};
                        } else {
                            self.database.updateOrderStatus(db_id, "cancelled") catch {};
                        }
                    } else {
                        // Cannot determine status, mark as cancelled
                        self.database.updateOrderStatus(db_id, "cancelled") catch {};
                    }
                    result.closed += 1;
                    log.info("fill_poller", "reconciliation: closed stale order {s}", .{db_id});
                }
            }
        }

        // Step 4: Sync portfolio tracker
        self.pt.syncFromDB();

        self.last_reconcile_result = result;

        log.info("fill_poller", "reconciliation complete: adopted={d} closed={d} unchanged={d}", .{
            result.adopted, result.closed, result.unchanged,
        });

        // Publish IPC event for Telegram
        var evt_buf: [256]u8 = undefined;
        const evt = std.fmt.bufPrint(&evt_buf,
            "{{\"adopted\":{d},\"closed\":{d},\"unchanged\":{d},\"status\":\"complete\"}}",
            .{ result.adopted, result.closed, result.unchanged },
        ) catch "{}";
        ipc.publishEvent(ipc_types.T.reconcile_status, evt);

        return result;
    }
};

// ---------------------------------------------------------------------------
// JSON helpers (zero-alloc field extraction)
// ---------------------------------------------------------------------------

/// Extract a string value for a key from JSON without heap allocation.
/// Returns a slice into `data`. Only works for simple flat JSON objects.
fn extractJsonString(data: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key":"value" pattern
    var i: usize = 0;
    while (i + key.len + 4 < data.len) : (i += 1) {
        if (data[i] != '"') continue;
        if (i + 1 + key.len + 1 >= data.len) continue;
        if (!std.mem.eql(u8, data[i + 1 .. i + 1 + key.len], key)) continue;
        if (data[i + 1 + key.len] != '"') continue;

        // Found the key, look for ":"
        var j = i + 1 + key.len + 1;
        while (j < data.len and (data[j] == ':' or data[j] == ' ')) : (j += 1) {}

        if (j >= data.len) return null;

        if (data[j] == '"') {
            // String value
            const start = j + 1;
            var end = start;
            while (end < data.len and data[end] != '"') : (end += 1) {}
            return data[start..end];
        }

        // Non-string value (number, bool, null) — return until , or }
        const start = j;
        var end = start;
        while (end < data.len and data[end] != ',' and data[end] != '}' and data[end] != ' ') : (end += 1) {}
        return data[start..end];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "fill_poller: extractJsonString extracts string field" {
    const json = "{\"status\":\"MATCHED\",\"size_matched\":\"5.5\",\"price\":\"0.55\"}";
    const status = extractJsonString(json, "status");
    try std.testing.expect(status != null);
    try std.testing.expectEqualStrings("MATCHED", status.?);

    const sm = extractJsonString(json, "size_matched");
    try std.testing.expect(sm != null);
    try std.testing.expectEqualStrings("5.5", sm.?);

    const p = extractJsonString(json, "price");
    try std.testing.expect(p != null);
    try std.testing.expectEqualStrings("0.55", p.?);
}

test "fill_poller: extractJsonString returns null for missing field" {
    const json = "{\"status\":\"MATCHED\"}";
    const missing = extractJsonString(json, "nonexistent");
    try std.testing.expect(missing == null);
}

test "fill_poller: parseOrderResponse handles MATCHED status" {
    const json = "{\"status\":\"MATCHED\",\"size_matched\":\"10.0\",\"price\":\"0.50\",\"original_size\":\"10.0\"}";
    const result = FillPoller.parseOrderResponse(json);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expectEqualStrings("MATCHED", r.status());
    try std.testing.expectEqualStrings("10.0", r.sizeMatched());
    try std.testing.expectEqualStrings("0.50", r.price());
    try std.testing.expectEqualStrings("10.0", r.originalSize());
    try std.testing.expect(r.has_new_fill);
}

test "fill_poller: parseOrderResponse handles CANCELED status" {
    const json = "{\"status\":\"CANCELED\",\"size_matched\":\"0\",\"price\":\"0.55\"}";
    const result = FillPoller.parseOrderResponse(json);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("CANCELED", result.?.status());
    try std.testing.expect(!result.?.has_new_fill);
}

test "fill_poller: parseOrderResponse handles live order" {
    const json = "{\"status\":\"live\",\"size_matched\":\"0\",\"price\":\"0.45\",\"original_size\":\"20.0\"}";
    const result = FillPoller.parseOrderResponse(json);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("live", result.?.status());
    try std.testing.expect(!result.?.has_new_fill);
}

test "fill_poller: parseOrderResponse returns null for invalid json" {
    const result = FillPoller.parseOrderResponse("not json");
    try std.testing.expect(result == null);
}

test "fill_poller: parseOrderResponse handles partial fill" {
    const json = "{\"status\":\"live\",\"size_matched\":\"5.0\",\"price\":\"0.50\",\"original_size\":\"10.0\"}";
    const result = FillPoller.parseOrderResponse(json);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.has_new_fill);
    try std.testing.expectEqualStrings("5.0", result.?.sizeMatched());
}
