//! Fill poller — Phase 5 Hyperliquid fill ingestion wrapper.
//!
//! Keeps the public API used by `main.zig` while delegating fill parsing and
//! persistence to `hl_fill_poller.zig`. The live path uses Hyperliquid's REST
//! `userFills` endpoint as the fallback/portable ingestion source; parsed fills
//! update local `orders`/`fills`, refresh the in-memory portfolio cache, and
//! publish the standard order fill events.
const std = @import("std");
const log = @import("logger.zig");
const db_mod = @import("db.zig");
const order_mgr = @import("order_manager.zig");
const portfolio = @import("portfolio_tracker.zig");
const strategy = @import("strategy_engine.zig");
const cex_dex_arb = @import("cex_dex_arb.zig");
const ipc = @import("ipc.zig");
const ipc_types = @import("ipc_types.zig");
const http = @import("http_client.zig");
const hl_auth = @import("hl_auth.zig");
const hl_fill = @import("hl_fill_poller.zig");
const ws_lib = @import("websocket");
const c = db_mod.c;

// ---------------------------------------------------------------------------
// Fill check result (kept for parseOrderResponse test parity)
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

pub const ReconcileResult = struct {
    adopted: u32,
    closed: u32,
    unchanged: u32,
    remote_checked: bool = false,
    complete: bool = false,
    error_buf: [96]u8 = [_]u8{0} ** 96,
    error_len: usize = 0,

    pub fn status(self: *const ReconcileResult) []const u8 {
        if (self.complete) return "complete";
        if (self.error_len > 0) return "error";
        return "pending";
    }

    pub fn errorText(self: *const ReconcileResult) []const u8 {
        return self.error_buf[0..self.error_len];
    }
};

const MAX_RECONCILE_OPEN_ORDERS = 256;

const RemoteOpenOrder = struct {
    oid_buf: [48]u8 = [_]u8{0} ** 48,
    oid_len: usize = 0,
    cloid_buf: [80]u8 = [_]u8{0} ** 80,
    cloid_len: usize = 0,
    coin_buf: [32]u8 = [_]u8{0} ** 32,
    coin_len: usize = 0,
    side_buf: [8]u8 = [_]u8{0} ** 8,
    side_len: usize = 0,
    size_buf: [32]u8 = [_]u8{0} ** 32,
    size_len: usize = 0,
    price_buf: [32]u8 = [_]u8{0} ** 32,
    price_len: usize = 0,

    fn oid(self: *const RemoteOpenOrder) []const u8 {
        return self.oid_buf[0..self.oid_len];
    }

    fn cloid(self: *const RemoteOpenOrder) []const u8 {
        return self.cloid_buf[0..self.cloid_len];
    }

    fn coin(self: *const RemoteOpenOrder) []const u8 {
        return self.coin_buf[0..self.coin_len];
    }

    fn side(self: *const RemoteOpenOrder) []const u8 {
        return self.side_buf[0..self.side_len];
    }

    fn size(self: *const RemoteOpenOrder) []const u8 {
        return self.size_buf[0..self.size_len];
    }

    fn price(self: *const RemoteOpenOrder) []const u8 {
        return self.price_buf[0..self.price_len];
    }
};

const LocalOpenOrder = struct {
    id_buf: [80]u8 = [_]u8{0} ** 80,
    id_len: usize = 0,
    client_order_id_buf: [80]u8 = [_]u8{0} ** 80,
    client_order_id_len: usize = 0,
    exchange_order_id_buf: [80]u8 = [_]u8{0} ** 80,
    exchange_order_id_len: usize = 0,

    fn id(self: *const LocalOpenOrder) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    fn clientOrderId(self: *const LocalOpenOrder) []const u8 {
        return self.client_order_id_buf[0..self.client_order_id_len];
    }

    fn exchangeOrderId(self: *const LocalOpenOrder) []const u8 {
        return self.exchange_order_id_buf[0..self.exchange_order_id_len];
    }
};

pub const FillPoller = struct {
    allocator: std.mem.Allocator,
    database: *db_mod.DB,
    om: *order_mgr.OrderManager,
    pt: *portfolio.PortfolioTracker,
    se: ?*strategy.StrategyEngine,
    arb_runtime: ?*cex_dex_arb.ArbRuntime,
    should_stop: std.atomic.Value(bool),
    ws_connected: std.atomic.Value(bool),
    ws_disconnect_ts: std.atomic.Value(i64),
    last_reconcile_result: ?ReconcileResult,
    consecutive_http_failures: u32,
    circuit_breaker_until: i64,

    const POLL_INTERVAL_NS: u64 = 5 * std.time.ns_per_s;

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
            .arb_runtime = null,
            .should_stop = std.atomic.Value(bool).init(false),
            .ws_connected = std.atomic.Value(bool).init(false),
            .ws_disconnect_ts = std.atomic.Value(i64).init(0),
            .last_reconcile_result = null,
            .consecutive_http_failures = 0,
            .circuit_breaker_until = 0,
        };
    }

    pub fn setArbRuntime(self: *FillPoller, arb_runtime: *cex_dex_arb.ArbRuntime) void {
        self.arb_runtime = arb_runtime;
    }

    pub fn stop(self: *FillPoller) void {
        self.should_stop.store(true, .seq_cst);
    }

    pub fn pollLoop(self: *FillPoller) void {
        if (!self.om.config.hl.enabled or self.om.config.dry_run_enabled) {
            log.info("fill_poller", "HL REST fill polling idle (hl_enabled={any} dry_run={any})", .{ self.om.config.hl.enabled, self.om.config.dry_run_enabled });
            while (!self.should_stop.load(.seq_cst)) {
                std.Thread.sleep(POLL_INTERVAL_NS);
            }
            return;
        }

        log.info("fill_poller", "HL REST fill polling started", .{});
        while (!self.should_stop.load(.seq_cst)) {
            const now = std.time.timestamp();
            if (self.circuit_breaker_until > now) {
                std.Thread.sleep(POLL_INTERVAL_NS);
                continue;
            }

            const applied = self.pollUserFillsOnce() catch |e| {
                self.consecutive_http_failures += 1;
                log.warn("fill_poller", "HL userFills poll failed ({d}): {s}", .{ self.consecutive_http_failures, @errorName(e) });
                if (self.consecutive_http_failures >= 5) {
                    self.circuit_breaker_until = now + 30;
                    log.warn("fill_poller", "HL fill poll circuit breaker open for 30s", .{});
                }
                std.Thread.sleep(POLL_INTERVAL_NS);
                continue;
            };
            self.consecutive_http_failures = 0;
            if (applied > 0) {
                log.info("fill_poller", "applied {d} HL fills", .{applied});
            }
            std.Thread.sleep(POLL_INTERVAL_NS);
        }
        log.info("fill_poller", "HL REST fill polling stopped", .{});
    }

    pub fn wsLoop(self: *FillPoller) void {
        if (!self.om.config.hl.enabled or self.om.config.dry_run_enabled) {
            log.info("fill_poller", "HL user WebSocket idle (hl_enabled={any} dry_run={any})", .{ self.om.config.hl.enabled, self.om.config.dry_run_enabled });
            while (!self.should_stop.load(.seq_cst)) {
                std.Thread.sleep(5 * std.time.ns_per_s);
            }
            return;
        }

        var reconnect_ms: u64 = 1_000;
        while (!self.should_stop.load(.seq_cst)) {
            self.runUserWsConnection() catch |e| {
                self.ws_connected.store(false, .seq_cst);
                self.ws_disconnect_ts.store(std.time.timestamp(), .seq_cst);
                log.warn("fill_poller", "HL user WebSocket connection ended: {s}", .{@errorName(e)});
            };
            if (self.should_stop.load(.seq_cst)) break;
            std.Thread.sleep(reconnect_ms * std.time.ns_per_ms);
            reconnect_ms = @min(reconnect_ms * 2, @as(u64, 30_000));
        }
        log.info("fill_poller", "HL user WebSocket stopped", .{});
    }

    /// Startup reconciliation ingests fills, then compares local open orders
    /// with Hyperliquid's live open-order set. Remote orders missing locally
    /// are adopted; local orders missing remotely are closed so capacity and
    /// exposure gates do not carry stale state across restarts.
    pub fn reconcileOnStartup(self: *FillPoller) ReconcileResult {
        var result = ReconcileResult{ .adopted = 0, .closed = 0, .unchanged = 0 };
        if (self.om.config.hl.enabled and !self.om.config.dry_run_enabled) {
            _ = self.pollUserFillsOnce() catch |e| {
                log.warn("fill_poller", "startup userFills reconciliation failed: {s}", .{@errorName(e)});
            };

            result = self.reconcileRemoteOpenOrders() catch |e| blk: {
                log.warn("fill_poller", "startup open-order reconciliation failed: {s}", .{@errorName(e)});
                var failed = ReconcileResult{ .adopted = 0, .closed = 0, .unchanged = 0, .remote_checked = false, .complete = false };
                const err = std.fmt.bufPrint(&failed.error_buf, "{s}", .{@errorName(e)}) catch "";
                failed.error_len = err.len;
                break :blk failed;
            };
        } else {
            log.info("fill_poller", "reconciliation: offline/dry-run mode, no remote HL sweep", .{});
            result.unchanged = self.countLocalOpenOrders();
            result.complete = true;
        }
        self.last_reconcile_result = result;
        ipc.setReconcileStatus(.{
            .adopted = result.adopted,
            .closed = result.closed,
            .unchanged = result.unchanged,
            .remote_checked = result.remote_checked,
            .complete = result.complete,
            .error_buf = result.error_buf,
            .error_len = result.error_len,
        });

        var evt_buf: [384]u8 = undefined;
        const evt = if (result.error_len > 0)
            std.fmt.bufPrint(
                &evt_buf,
                "{{\"adopted\":{d},\"closed\":{d},\"unchanged\":{d},\"remote_checked\":{},\"status\":\"{s}\",\"error\":\"{s}\"}}",
                .{ result.adopted, result.closed, result.unchanged, result.remote_checked, result.status(), result.errorText() },
            ) catch "{}"
        else
            std.fmt.bufPrint(
                &evt_buf,
                "{{\"adopted\":{d},\"closed\":{d},\"unchanged\":{d},\"remote_checked\":{},\"status\":\"{s}\"}}",
                .{ result.adopted, result.closed, result.unchanged, result.remote_checked, result.status() },
            ) catch "{}";
        ipc.publishEvent(ipc_types.T.reconcile_status, evt);
        return result;
    }

    fn reconcileRemoteOpenOrders(self: *FillPoller) !ReconcileResult {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/info", .{self.om.config.hl.api_base}) catch return error.HttpFailed;
        const user_addr = hl_auth.formatAddressEip55(self.om.config.hl.signer_address);

        var body_buf: [160]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"type\":\"openOrders\",\"user\":\"{s}\"}}",
            .{user_addr[0..]},
        ) catch return error.HttpFailed;

        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();
        var response = client.postJson(url, body) catch return error.HttpFailed;
        defer response.deinit();
        if (response.status.class() != .success) return error.HttpFailed;

        return self.reconcileOpenOrdersBody(response.body);
    }

    fn reconcileOpenOrdersBody(self: *FillPoller, body: []const u8) !ReconcileResult {
        var remote: [MAX_RECONCILE_OPEN_ORDERS]RemoteOpenOrder = undefined;
        const remote_count = try parseOpenOrdersResponse(self.allocator, body, &remote);
        var matched_remote = [_]bool{false} ** MAX_RECONCILE_OPEN_ORDERS;

        var local: [MAX_RECONCILE_OPEN_ORDERS]LocalOpenOrder = undefined;
        const local_count = try self.loadLocalOpenOrders(&local);

        var result = ReconcileResult{
            .adopted = 0,
            .closed = 0,
            .unchanged = 0,
            .remote_checked = true,
            .complete = true,
        };

        for (local[0..local_count]) |lo| {
            if (findRemoteOrder(remote[0..remote_count], lo)) |idx| {
                matched_remote[idx] = true;
                result.unchanged += 1;
                self.database.updateOrderLastChecked(lo.id()) catch |e| {
                    log.warn("fill_poller", "failed to mark reconciled order {s}: {s}", .{ lo.id(), @errorName(e) });
                };
            } else {
                try self.closeLocalOpenOrder(lo.id());
                result.closed += 1;
            }
        }

        for (remote[0..remote_count], 0..) |ro, idx| {
            if (matched_remote[idx]) continue;
            if (ro.oid_len == 0 or ro.coin_len == 0) continue;
            try self.adoptRemoteOpenOrder(ro);
            result.adopted += 1;
        }

        log.info("fill_poller", "reconciliation complete: adopted={d} closed={d} unchanged={d}", .{
            result.adopted, result.closed, result.unchanged,
        });
        return result;
    }

    fn runUserWsConnection(self: *FillPoller) !void {
        const host = hyperliquidWsHost(self.om.config.hl.api_base);
        var client = try ws_lib.Client.init(self.allocator, .{
            .host = host,
            .port = 443,
            .tls = true,
            .max_size = 8 * 1024 * 1024,
        });
        defer client.deinit();

        var host_buf: [128]u8 = undefined;
        const host_hdr = std.fmt.bufPrint(&host_buf, "Host: {s}\r\n", .{host}) catch unreachable;
        try client.handshake("/ws", .{ .timeout_ms = 10_000, .headers = host_hdr });

        const user_addr = hl_auth.formatAddressEip55(self.om.config.hl.signer_address);
        var sub_buf: [256]u8 = undefined;
        const sub_msg = std.fmt.bufPrint(
            &sub_buf,
            "{{\"method\":\"subscribe\",\"subscription\":{{\"type\":\"userEvents\",\"user\":\"{s}\"}}}}",
            .{user_addr[0..]},
        ) catch return error.WsFailed;
        var send_buf: [256]u8 = undefined;
        @memcpy(send_buf[0..sub_msg.len], sub_msg);
        try client.write(send_buf[0..sub_msg.len]);

        self.ws_connected.store(true, .seq_cst);
        log.info("fill_poller", "HL user WebSocket subscribed user={s}", .{user_addr[0..]});

        try client.readTimeout(5_000);
        while (!self.should_stop.load(.seq_cst)) {
            const message = client.read() catch |err| switch (err) {
                // User-events streams are often idle; the TLS layer reports
                // the read timeout as ReadFailed instead of WouldBlock.
                error.ReadFailed => continue,
                error.Closed => return,
                else => return err,
            } orelse continue;
            defer client.done(message);

            switch (message.type) {
                .text, .binary => {
                    const n = self.applyFillFrame(message.data) catch |e| {
                        log.warn("fill_poller", "HL user WS frame apply failed: {s}", .{@errorName(e)});
                        continue;
                    };
                    if (n > 0) log.info("fill_poller", "applied {d} HL WS fills", .{n});
                },
                .close => return,
                .ping, .pong => {},
            }
        }
    }

    fn pollUserFillsOnce(self: *FillPoller) !usize {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/info", .{self.om.config.hl.api_base}) catch return error.HttpFailed;
        const user_addr = hl_auth.formatAddressEip55(self.om.config.hl.signer_address);

        var body_buf: [160]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"type\":\"userFills\",\"user\":\"{s}\"}}",
            .{user_addr[0..]},
        ) catch return error.HttpFailed;

        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();
        var response = client.postJson(url, body) catch return error.HttpFailed;
        defer response.deinit();
        if (response.status.class() != .success) return error.HttpFailed;

        return self.applyFillFrame(response.body);
    }

    fn applyFillFrame(self: *FillPoller, body: []const u8) !usize {
        const parsed = hl_fill.parseUserChannelFills(body) orelse return 0;
        var applied: usize = 0;
        for (parsed.fills[0..parsed.count]) |fill| {
            if (self.applyFill(fill)) applied += 1;
        }
        return applied;
    }

    fn applyFill(self: *FillPoller, fill: hl_fill.HlFill) bool {
        var local = self.resolveLocalOrder(fill.id());
        const result = hl_fill.applyFillToDb(self.database, fill) catch |e| {
            log.warn("fill_poller", "failed to apply HL fill oid={s}: {s}", .{ fill.id(), @errorName(e) });
            return false;
        };
        if (!result.updated) return false;

        if (local.market_id_len > 0 and local.side_len > 0) {
            const arb_pnl = if (local.isArb())
                self.computeRealizedPnl(local.marketId(), local.side(), fill.sz, fill.px)
            else
                null;

            self.pt.applyFillDelta(local.marketId(), fill.sz, fill.px, local.side());

            // Phase 6 engine integration: feed market-making fills into the
            // strategy engine's per-market inventory + skew state machine so
            // live quoting reacts to accumulated inventory. Only runs when a
            // strategy engine is wired and the order was an MM order; other
            // origins (e.g. arb takers) do not touch MM inventory. Inventory
            // is mutated only here, where `applyFillToDb` reported
            // `updated=true`, so duplicate WS/REST fill events (which return
            // `updated=false` on the second sighting) cannot double-count.
            if (self.se) |se| {
                if (local.isMarketMaking()) {
                    const dir: strategy.SignalDirection =
                        if (std.mem.eql(u8, local.side(), "buy")) .buy else .sell;
                    se.recordMarketMakingFill(local.marketId(), dir, fill.sz, fill.px);
                    if (std.mem.eql(u8, result.new_status, "filled")) {
                        self.cancelPairedMarketMakingOrder(se, local.id());
                        se.untrackOrder(local.id());
                    }
                }
            }

            if (local.isArb()) {
                if (arb_pnl) |pnl| {
                    if (self.arb_runtime) |arb| {
                        arb.recordTradeResult(pnl, std.time.timestamp());
                    }
                    const fill_ns_i128 = std.time.nanoTimestamp();
                    const fill_ns: i64 = if (fill_ns_i128 > std.math.maxInt(i64))
                        std.math.maxInt(i64)
                    else if (fill_ns_i128 < std.math.minInt(i64))
                        std.math.minInt(i64)
                    else
                        @intCast(fill_ns_i128);
                    self.database.updateArbEventFill(fill.id(), pnl, fill_ns) catch |e| {
                        log.warn("fill_poller", "failed to backfill arb event pnl oid={s}: {s}", .{ fill.id(), @errorName(e) });
                    };
                    log.info("fill_poller", "arb fill feedback: order={s} market={s} pnl={d:.6}", .{
                        fill.id(), local.marketId(), pnl,
                    });
                } else {
                    log.debug("fill_poller", "arb fill has no realized pnl yet: order={s} market={s}", .{
                        fill.id(), local.marketId(),
                    });
                }
            }
        }
        hl_fill.emitFillEvent(fill, result.new_status);
        return true;
    }

    const LocalOrderRef = struct {
        id_buf: [128]u8 = [_]u8{0} ** 128,
        id_len: usize = 0,
        market_id_buf: [128]u8 = [_]u8{0} ** 128,
        market_id_len: usize = 0,
        side_buf: [8]u8 = [_]u8{0} ** 8,
        side_len: usize = 0,
        origin_buf: [32]u8 = [_]u8{0} ** 32,
        origin_len: usize = 0,

        fn id(self: *const LocalOrderRef) []const u8 {
            return self.id_buf[0..self.id_len];
        }

        fn marketId(self: *const LocalOrderRef) []const u8 {
            return self.market_id_buf[0..self.market_id_len];
        }

        fn side(self: *const LocalOrderRef) []const u8 {
            return self.side_buf[0..self.side_len];
        }

        fn origin(self: *const LocalOrderRef) []const u8 {
            return self.origin_buf[0..self.origin_len];
        }

        /// True when the originating order was placed by the market-making
        /// strategy (current tag) or the legacy `liquidity_provision`
        /// alias retained for orders predating the Phase 6 rename.
        fn isMarketMaking(self: *const LocalOrderRef) bool {
            const o = self.origin();
            return std.mem.eql(u8, o, "market_making") or
                std.mem.eql(u8, o, "liquidity_provision");
        }

        fn isArb(self: *const LocalOrderRef) bool {
            return std.mem.eql(u8, self.origin(), "cex_dex_arb");
        }
    };

    fn cancelPairedMarketMakingOrder(
        self: *FillPoller,
        se: *strategy.StrategyEngine,
        filled_order_id: []const u8,
    ) void {
        const paired = se.findPairedOrder(filled_order_id) orelse return;
        var paired_buf: [68]u8 = undefined;
        const paired_len = @min(paired.len, paired_buf.len);
        @memcpy(paired_buf[0..paired_len], paired[0..paired_len]);
        const paired_id = paired_buf[0..paired_len];

        if (self.om.cancelOrder(paired_id)) {
            se.untrackOrder(paired_id);
            se.incrementCancels(.market_making);
            log.info("fill_poller", "cancelled paired LP order after fill: filled={s} paired={s}", .{
                filled_order_id,
                paired_id,
            });
        } else {
            log.warn("fill_poller", "failed to cancel paired LP order after fill: filled={s} paired={s}", .{
                filled_order_id,
                paired_id,
            });
        }
    }

    fn computeRealizedPnl(
        self: *FillPoller,
        market_id: []const u8,
        order_side: []const u8,
        fill_size: f64,
        fill_price: f64,
    ) ?f64 {
        const position_side: []const u8 = if (std.mem.eql(u8, order_side, "sell"))
            "long"
        else if (std.mem.eql(u8, order_side, "buy"))
            "short"
        else
            return null;

        const sql =
            "SELECT entry_price FROM positions " ++
            "WHERE market_id=? AND status='open' AND side=? " ++
            "ORDER BY updated_at DESC LIMIT 1;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, market_id.ptr, @intCast(market_id.len), null) != c.SQLITE_OK) return null;
        if (c.sqlite3_bind_text(stmt, 2, position_side.ptr, @intCast(position_side.len), null) != c.SQLITE_OK) return null;
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const raw = c.sqlite3_column_text(stmt, 0) orelse return null;
        const entry_price = std.fmt.parseFloat(f64, std.mem.span(@as([*c]const u8, @ptrCast(raw)))) catch return null;

        if (std.mem.eql(u8, order_side, "sell")) {
            return (fill_price - entry_price) * fill_size;
        }
        return (entry_price - fill_price) * fill_size;
    }

    fn resolveLocalOrder(self: *FillPoller, oid: []const u8) LocalOrderRef {
        var out = LocalOrderRef{};
        const sql = "SELECT id, market_id, side, COALESCE(strategy_origin,'') FROM orders WHERE id=? OR client_order_id=? OR exchange_order_id=? LIMIT 1;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return out;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, oid.ptr, @intCast(oid.len), null);
        _ = c.sqlite3_bind_text(stmt, 2, oid.ptr, @intCast(oid.len), null);
        _ = c.sqlite3_bind_text(stmt, 3, oid.ptr, @intCast(oid.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return out;

        if (c.sqlite3_column_text(stmt, 0)) |p| {
            const span = std.mem.span(@as([*c]const u8, @ptrCast(p)));
            const n = @min(span.len, out.id_buf.len);
            @memcpy(out.id_buf[0..n], span[0..n]);
            out.id_len = n;
        }
        if (c.sqlite3_column_text(stmt, 1)) |p| {
            const span = std.mem.span(@as([*c]const u8, @ptrCast(p)));
            const n = @min(span.len, out.market_id_buf.len);
            @memcpy(out.market_id_buf[0..n], span[0..n]);
            out.market_id_len = n;
        }
        if (c.sqlite3_column_text(stmt, 2)) |p| {
            const span = std.mem.span(@as([*c]const u8, @ptrCast(p)));
            const n = @min(span.len, out.side_buf.len);
            @memcpy(out.side_buf[0..n], span[0..n]);
            out.side_len = n;
        }
        if (c.sqlite3_column_text(stmt, 3)) |p| {
            const span = std.mem.span(@as([*c]const u8, @ptrCast(p)));
            const n = @min(span.len, out.origin_buf.len);
            @memcpy(out.origin_buf[0..n], span[0..n]);
            out.origin_len = n;
        }
        return out;
    }

    fn countLocalOpenOrders(self: *FillPoller) u32 {
        const sql = "SELECT count(*) FROM orders WHERE status IN ('placed','partially_filled');" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return 0;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        const n = c.sqlite3_column_int64(stmt, 0);
        return if (n < 0) 0 else @intCast(@min(n, std.math.maxInt(u32)));
    }

    fn loadLocalOpenOrders(self: *FillPoller, out: []LocalOpenOrder) !usize {
        const sql = "SELECT id, COALESCE(client_order_id,''), COALESCE(exchange_order_id,'') FROM orders WHERE status IN ('placed','partially_filled') ORDER BY created_at ASC LIMIT ?;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_int(stmt, 1, @intCast(out.len)) != c.SQLITE_OK) return error.DBExecFailed;

        var count: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW and count < out.len) : (count += 1) {
            out[count] = .{};
            copyColumnText(stmt.?, 0, &out[count].id_buf, &out[count].id_len);
            copyColumnText(stmt.?, 1, &out[count].client_order_id_buf, &out[count].client_order_id_len);
            copyColumnText(stmt.?, 2, &out[count].exchange_order_id_buf, &out[count].exchange_order_id_len);
        }
        return count;
    }

    fn closeLocalOpenOrder(self: *FillPoller, order_id: []const u8) !void {
        const sql = "UPDATE orders SET status='cancelled', last_checked_at=unixepoch(), updated_at=unixepoch() WHERE id=? AND status IN ('placed','partially_filled');" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, order_id.ptr, @intCast(order_id.len), null) != c.SQLITE_OK) return error.DBExecFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DBExecFailed;
    }

    fn adoptRemoteOpenOrder(self: *FillPoller, order: RemoteOpenOrder) !void {
        try self.ensureMarket(order.coin());

        const id = order.oid();
        const cloid = if (order.cloid_len > 0) order.cloid() else order.oid();
        const side = normalizeRemoteSide(order.side());
        const size = if (order.size_len > 0) order.size() else "0";
        const price = if (order.price_len > 0) order.price() else "0";

        if (order.cloid_len > 0 and !std.mem.eql(u8, order.cloid(), order.oid())) {
            if (try self.reopenRemoteOrderByClientId(order, side, size, price)) return;
        }

        const sql =
            "INSERT INTO orders(id,market_id,client_order_id,exchange_order_id,type,side,size,price,status,filled_size,last_checked_at,updated_at) " ++
            "VALUES(?,?,?,?,?,?,?,?,'placed','0',unixepoch(),unixepoch()) " ++
            "ON CONFLICT(id) DO UPDATE SET status='placed', exchange_order_id=excluded.exchange_order_id, last_checked_at=unixepoch(), updated_at=unixepoch();" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, order.coin().ptr, @intCast(order.coin().len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 3, cloid.ptr, @intCast(cloid.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 4, order.oid().ptr, @intCast(order.oid().len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 5, "limit", 5, null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 6, side.ptr, @intCast(side.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 7, size.ptr, @intCast(size.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 8, price.ptr, @intCast(price.len), null) != c.SQLITE_OK)
        {
            return error.DBExecFailed;
        }
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DBExecFailed;
    }

    fn reopenRemoteOrderByClientId(
        self: *FillPoller,
        order: RemoteOpenOrder,
        side: []const u8,
        size: []const u8,
        price: []const u8,
    ) !bool {
        const sql =
            "UPDATE orders SET market_id=?, exchange_order_id=?, type='limit', side=?, size=?, price=?, status='placed', last_checked_at=unixepoch(), updated_at=unixepoch() " ++
            "WHERE client_order_id=?;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, order.coin().ptr, @intCast(order.coin().len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, order.oid().ptr, @intCast(order.oid().len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 3, side.ptr, @intCast(side.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 4, size.ptr, @intCast(size.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 5, price.ptr, @intCast(price.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 6, order.cloid().ptr, @intCast(order.cloid().len), null) != c.SQLITE_OK)
        {
            return error.DBExecFailed;
        }
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DBExecFailed;
        return c.sqlite3_changes(self.database.handle) > 0;
    }

    fn ensureMarket(self: *FillPoller, market_id: []const u8) !void {
        const sql = "INSERT OR IGNORE INTO markets(id,symbol,base,quote,status) VALUES(?,?,?,'USDC','active');" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, market_id.ptr, @intCast(market_id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, market_id.ptr, @intCast(market_id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 3, market_id.ptr, @intCast(market_id.len), null) != c.SQLITE_OK)
        {
            return error.DBExecFailed;
        }
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DBExecFailed;
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

        if (result.size_matched_len > 0) {
            const sm_f = std.fmt.parseFloat(f64, result.size_matched_buf[0..result.size_matched_len]) catch 0.0;
            result.has_new_fill = sm_f > 0.0;
        }

        if (result.status_len == 0) return null;
        return result;
    }
};

fn hyperliquidWsHost(api_base: []const u8) []const u8 {
    if (std.mem.indexOf(u8, api_base, "testnet") != null) return "api.hyperliquid-testnet.xyz";
    return "api.hyperliquid.xyz";
}

fn copyColumnText(stmt: *c.sqlite3_stmt, col: c_int, buf: *[80]u8, len: *usize) void {
    const raw = c.sqlite3_column_text(stmt, col) orelse return;
    const span = std.mem.span(@as([*c]const u8, @ptrCast(raw)));
    const n = @min(span.len, buf.len);
    @memcpy(buf[0..n], span[0..n]);
    len.* = n;
}

fn normalizeRemoteSide(side: []const u8) []const u8 {
    if (std.mem.eql(u8, side, "B") or std.ascii.eqlIgnoreCase(side, "buy")) return "buy";
    if (std.mem.eql(u8, side, "A") or std.ascii.eqlIgnoreCase(side, "sell")) return "sell";
    return "buy";
}

fn findRemoteOrder(remote: []const RemoteOpenOrder, local: LocalOpenOrder) ?usize {
    for (remote, 0..) |ro, idx| {
        if (ro.oid_len > 0 and std.mem.eql(u8, ro.oid(), local.id())) return idx;
        if (ro.oid_len > 0 and local.client_order_id_len > 0 and std.mem.eql(u8, ro.oid(), local.clientOrderId())) return idx;
        if (ro.oid_len > 0 and local.exchange_order_id_len > 0 and std.mem.eql(u8, ro.oid(), local.exchangeOrderId())) return idx;
        if (ro.cloid_len > 0 and std.mem.eql(u8, ro.cloid(), local.id())) return idx;
        if (ro.cloid_len > 0 and local.client_order_id_len > 0 and std.mem.eql(u8, ro.cloid(), local.clientOrderId())) return idx;
    }
    return null;
}

fn parseOpenOrdersResponse(allocator: std.mem.Allocator, body: []const u8, out: []RemoteOpenOrder) !usize {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidJson;
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.InvalidJson,
    };

    var count: usize = 0;
    for (arr.items) |item| {
        if (count >= out.len) break;
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        var order = RemoteOpenOrder{};
        if (obj.get("oid")) |v| copyJsonScalar(v, &order.oid_buf, &order.oid_len) catch continue;
        if (obj.get("cloid")) |v| copyJsonScalar(v, &order.cloid_buf, &order.cloid_len) catch {};
        if (obj.get("coin")) |v| copyJsonScalar(v, &order.coin_buf, &order.coin_len) catch continue;
        if (obj.get("side")) |v| copyJsonScalar(v, &order.side_buf, &order.side_len) catch {};
        if (obj.get("sz")) |v| copyJsonScalar(v, &order.size_buf, &order.size_len) catch {};
        if (obj.get("limitPx")) |v| copyJsonScalar(v, &order.price_buf, &order.price_len) catch {};

        if (order.oid_len == 0 or order.coin_len == 0) continue;
        out[count] = order;
        count += 1;
    }
    return count;
}

fn copyJsonScalar(value: std.json.Value, buf: []u8, len: *usize) !void {
    len.* = 0;
    const written = switch (value) {
        .string => |s| try copySlice(s, buf),
        .number_string => |s| try copySlice(s, buf),
        .integer => |i| try std.fmt.bufPrint(buf, "{d}", .{i}),
        .float => |f| try std.fmt.bufPrint(buf, "{d}", .{f}),
        .null => return,
        else => return error.InvalidJson,
    };
    len.* = written.len;
}

fn copySlice(src: []const u8, buf: []u8) ![]const u8 {
    if (src.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[0..src.len], src);
    return buf[0..src.len];
}

/// Extract a string value for a key from a flat JSON object without heap
/// allocation. Returns a slice into `data`.
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
            while (end < data.len and data[end] != '"') : (end += 1) {}
            return data[start..end];
        }

        const start = j;
        var end = start;
        while (end < data.len and data[end] != ',' and data[end] != '}' and data[end] != ' ') : (end += 1) {}
        return data[start..end];
    }
    return null;
}

test "fill_poller: extractJsonString extracts string field" {
    const json = "{\"status\":\"MATCHED\",\"size_matched\":\"5.5\",\"price\":\"0.55\"}";
    const status = extractJsonString(json, "status");
    try std.testing.expect(status != null);
    try std.testing.expectEqualStrings("MATCHED", status.?);
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

test "fill_poller: parseOrderResponse returns null for invalid json" {
    const result = FillPoller.parseOrderResponse("not json");
    try std.testing.expect(result == null);
}

// ─── Phase 6: market-making inventory wiring through fills ───────────────────

fn mkFill(oid: []const u8, side: []const u8, sz: f64, px: f64, time_ms: i64) hl_fill.HlFill {
    var f = hl_fill.HlFill{
        .oid = [_]u8{0} ** 40,
        .oid_len = 0,
        .sz = sz,
        .px = px,
        .side = [_]u8{0} ** 4,
        .side_len = @intCast(side.len),
        .time_ms = time_ms,
    };
    @memcpy(f.oid[0..oid.len], oid);
    f.oid_len = oid.len;
    @memcpy(f.side[0..side.len], side);
    return f;
}

/// Test harness for the fill → inventory path. OrderManager, PortfolioTracker
/// and StrategyEngine are large fixed-array structs, so they are heap-allocated
/// to keep the test's stack frame small (the parallel test runner gives each
/// test thread a modest stack). None of the inits allocate, so destroy is the
/// only cleanup required.
const FillHarness = struct {
    om: *order_mgr.OrderManager,
    pt: *portfolio.PortfolioTracker,
    se: *strategy.StrategyEngine,
    fp: FillPoller,

    fn init(database: *db_mod.DB) !FillHarness {
        const a = std.testing.allocator;
        const om = try a.create(order_mgr.OrderManager);
        om.* = order_mgr.OrderManager.init(a, database, .{}, .{});
        const pt = try a.create(portfolio.PortfolioTracker);
        pt.* = portfolio.PortfolioTracker.init(a, database, .{});
        const se = try a.create(strategy.StrategyEngine);
        se.* = strategy.StrategyEngine.init(.{});
        return .{ .om = om, .pt = pt, .se = se, .fp = FillPoller.init(a, database, om, pt, se) };
    }

    fn deinit(self: *FillHarness) void {
        const a = std.testing.allocator;
        a.destroy(self.om);
        a.destroy(self.pt);
        a.destroy(self.se);
    }
};

test "fill_poller: market-making fill updates strategy inventory + skew" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('M-BTC','BTC','BTC','USDC');");
    // market_id is the HL coin symbol; strategy_origin marks it as MM.
    try database.execZ(
        "INSERT INTO orders(id,market_id,client_order_id,type,side,size,price,status,filled_size,strategy_origin) " ++
            "VALUES('order-mm','BTC','77001','limit','buy','0.10','45000','placed','0','market_making');",
    );

    var h = try FillHarness.init(&database);
    defer h.deinit();

    // Default lp_max_position_usd=50 → enter threshold 25. One buy fill of
    // 0.001 BTC @ 45000 = $45 exposure crosses it → long_skewed.
    try std.testing.expect(h.fp.applyFill(mkFill("77001", "buy", 0.001, 45000.0, 1)));
    try std.testing.expectEqual(strategy.SkewState.long_skewed, h.se.skewStateFor("BTC"));
}

test "fill_poller: non market-making fill leaves MM inventory untouched" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('M-BTC','BTC','BTC','USDC');");
    try database.execZ(
        "INSERT INTO orders(id,market_id,client_order_id,type,side,size,price,status,filled_size,strategy_origin) " ++
            "VALUES('order-arb','BTC','77002','limit','buy','0.10','45000','placed','0','cex_dex_arb');",
    );

    var h = try FillHarness.init(&database);
    defer h.deinit();

    try std.testing.expect(h.fp.applyFill(mkFill("77002", "buy", 0.001, 45000.0, 1)));
    // Arb fill must not seed MM inventory.
    try std.testing.expectEqual(strategy.SkewState.normal, h.se.skewStateFor("BTC"));
}

test "fill_poller: arb closing fill records pnl feedback" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('M-BTC','BTC','BTC','USDC');");
    try database.execZ(
        "INSERT INTO positions(id,market_id,side,size,entry_price,current_price,pnl,status) " ++
            "VALUES('pos-short','BTC','short','0.001','45000','45000','0','open');",
    );
    try database.execZ(
        "INSERT INTO orders(id,market_id,client_order_id,type,side,size,price,status,filled_size,strategy_origin) " ++
            "VALUES('order-arb-close','BTC','77004','market','buy','0.001','44000','placed','0','cex_dex_arb');",
    );
    try database.insertArbEvent("BTC", 44100.0, 44000.0, -22.6, "77004");

    var h = try FillHarness.init(&database);
    defer h.deinit();
    var arb_runtime = cex_dex_arb.ArbRuntime.init(.{});
    arb_runtime.state.loss_streak = 1;
    h.fp.setArbRuntime(&arb_runtime);

    try std.testing.expect(h.fp.applyFill(mkFill("77004", "buy", 0.001, 44000.0, 1)));

    const events = try database.queryArbEvents(std.testing.allocator, 1);
    defer std.testing.allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), events[0].realised_pnl, 1e-9);
    try std.testing.expect(events[0].fill_ns > 0);

    arb_runtime.mu.lock();
    defer arb_runtime.mu.unlock();
    try std.testing.expectEqual(@as(u32, 0), arb_runtime.state.loss_streak);
}

test "fill_poller: duplicate fill does not double-count MM inventory" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('M-BTC','BTC','BTC','USDC');");
    try database.execZ(
        "INSERT INTO orders(id,market_id,client_order_id,type,side,size,price,status,filled_size,strategy_origin) " ++
            "VALUES('order-mm','BTC','77003','limit','buy','0.10','45000','placed','0','market_making');",
    );

    var h = try FillHarness.init(&database);
    defer h.deinit();

    // First fill: $18 exposure (0.0004 * 45000) — below the $25 enter
    // threshold, so state stays normal.
    try std.testing.expect(h.fp.applyFill(mkFill("77003", "buy", 0.0004, 45000.0, 1)));
    try std.testing.expectEqual(strategy.SkewState.normal, h.se.skewStateFor("BTC"));

    // Exact replay (same oid + time_ms) is deduped by applyFillToDb and must
    // NOT touch inventory; otherwise the doubled $36 exposure would flip the
    // state to long_skewed.
    try std.testing.expect(!h.fp.applyFill(mkFill("77003", "buy", 0.0004, 45000.0, 1)));
    try std.testing.expectEqual(strategy.SkewState.normal, h.se.skewStateFor("BTC"));

    // A genuinely new fill (distinct time_ms) does count: net $36 crosses
    // the enter threshold → long_skewed.
    try std.testing.expect(h.fp.applyFill(mkFill("77003", "buy", 0.0004, 45000.0, 2)));
    try std.testing.expectEqual(strategy.SkewState.long_skewed, h.se.skewStateFor("BTC"));
}

test "fill_poller: parseOpenOrdersResponse handles numeric oid and cloid" {
    const body =
        \\[
        \\  {"coin":"BTC","side":"B","limitPx":"45000","sz":"0.01","oid":12345,"cloid":"0xabc"},
        \\  {"coin":"ETH","side":"A","limitPx":"2500","sz":"0.2","oid":"67890"}
        \\]
    ;
    var orders: [4]RemoteOpenOrder = undefined;
    const count = try parseOpenOrdersResponse(std.testing.allocator, body, &orders);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("12345", orders[0].oid());
    try std.testing.expectEqualStrings("0xabc", orders[0].cloid());
    try std.testing.expectEqualStrings("BTC", orders[0].coin());
    try std.testing.expectEqualStrings("B", orders[0].side());
    try std.testing.expectEqualStrings("67890", orders[1].oid());
}

test "fill_poller: reconcileOpenOrdersBody adopts, closes, and preserves orders" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote,status) VALUES('BTC','BTC','BTC','USDC','active');");
    try database.execZ("INSERT INTO markets(id,symbol,base,quote,status) VALUES('ETH','ETH','ETH','USDC','active');");
    try database.execZ(
        "INSERT INTO orders(id,market_id,client_order_id,type,side,size,price,status,filled_size) " ++
            "VALUES('local-keep','BTC','111','limit','buy','0.01','45000','placed','0');",
    );
    try database.execZ(
        "INSERT INTO orders(id,market_id,client_order_id,type,side,size,price,status,filled_size) " ++
            "VALUES('local-close','ETH','222','limit','sell','0.1','2500','placed','0');",
    );

    var h = try FillHarness.init(&database);
    defer h.deinit();

    const body =
        \\[
        \\  {"coin":"BTC","side":"B","limitPx":"45000","sz":"0.01","oid":111},
        \\  {"coin":"SOL","side":"A","limitPx":"140","sz":"1.5","oid":333,"cloid":"remote-sol"}
        \\]
    ;
    const result = try h.fp.reconcileOpenOrdersBody(body);
    try std.testing.expect(result.complete);
    try std.testing.expect(result.remote_checked);
    try std.testing.expectEqual(@as(u32, 1), result.unchanged);
    try std.testing.expectEqual(@as(u32, 1), result.closed);
    try std.testing.expectEqual(@as(u32, 1), result.adopted);

    try expectOrderStatus(&database, "local-keep", "placed");
    try expectOrderStatus(&database, "local-close", "cancelled");
    try expectOrderStatus(&database, "333", "placed");
}

test "fill_poller: reconcileOpenOrdersBody reopens local order matched by cloid" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote,status) VALUES('BTC','BTC','BTC','USDC','active');");
    try database.execZ(
        "INSERT INTO orders(id,market_id,client_order_id,type,side,size,price,status,filled_size) " ++
            "VALUES('local-stale','BTC','cloid-1','limit','buy','0.01','45000','cancelled','0');",
    );

    var h = try FillHarness.init(&database);
    defer h.deinit();

    const body =
        \\[
        \\  {"coin":"BTC","side":"A","limitPx":"45100","sz":"0.02","oid":999,"cloid":"cloid-1"}
        \\]
    ;
    const result = try h.fp.reconcileOpenOrdersBody(body);
    try std.testing.expect(result.complete);
    try std.testing.expectEqual(@as(u32, 1), result.adopted);
    try std.testing.expectEqual(@as(u32, 0), result.closed);
    try std.testing.expectEqual(@as(u32, 0), result.unchanged);

    try expectOrderStatus(&database, "local-stale", "placed");
    try expectOrderField(&database, "local-stale", "side", "sell");
    try expectOrderField(&database, "local-stale", "size", "0.02");
    try expectOrderField(&database, "local-stale", "price", "45100");
}

fn expectOrderStatus(database: *db_mod.DB, order_id: []const u8, expected: []const u8) !void {
    try expectOrderField(database, order_id, "status", expected);
}

fn expectOrderField(database: *db_mod.DB, order_id: []const u8, comptime field: []const u8, expected: []const u8) !void {
    const sql = "SELECT " ++ field ++ " FROM orders WHERE id=? LIMIT 1;" ++ &[_:0]u8{};
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expect(c.sqlite3_prepare_v2(database.handle, sql.ptr, -1, &stmt, null) == c.SQLITE_OK);
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expect(c.sqlite3_bind_text(stmt, 1, order_id.ptr, @intCast(order_id.len), null) == c.SQLITE_OK);
    try std.testing.expect(c.sqlite3_step(stmt) == c.SQLITE_ROW);
    const raw = c.sqlite3_column_text(stmt, 0) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(expected, std.mem.span(@as([*c]const u8, @ptrCast(raw))));
}
