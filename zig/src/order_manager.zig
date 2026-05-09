//! Order manager — lifecycle management, signed Hyperliquid `/exchange`
//! submission, and staleness handling. Phase 2 of the HL migration replaces
//! the Polymarket CTF/CLOB submission path with the HL msgpack + EIP-712
//! signed action envelope. The retry policy (7-step exponential backoff)
//! and risk-gate integration are preserved.
const std = @import("std");
const log = @import("logger.zig");
const db_mod = @import("db.zig");
const http = @import("http_client.zig");
const crypto = @import("crypto.zig");
const hl_auth = @import("hl_auth.zig");
const msgpack = @import("msgpack.zig");
const risk = @import("risk_gate.zig");
const ipc = @import("ipc.zig");
const ipc_types = @import("ipc_types.zig");
const crash_trace = @import("crash_trace.zig");
const c = db_mod.c;

pub const HL_API_BASE_MAINNET = "https://api.hyperliquid.xyz";
pub const HL_API_BASE_TESTNET = "https://api.hyperliquid-testnet.xyz";

fn applyCancelledUpdate(stmt: *c.sqlite3_stmt, order_id: []const u8) bool {
    if (order_id.len == 0) return false;

    _ = c.sqlite3_reset(stmt);
    _ = c.sqlite3_clear_bindings(stmt);

    if (c.sqlite3_bind_text(stmt, 1, order_id.ptr, @intCast(order_id.len), null) != c.SQLITE_OK) {
        return false;
    }

    return c.sqlite3_step(stmt) == c.SQLITE_DONE;
}

fn parseOrderStatus(raw: []const u8) ?OrderStatus {
    if (std.mem.eql(u8, raw, "pending")) return .pending;
    if (std.mem.eql(u8, raw, "placed")) return .placed;
    if (std.mem.eql(u8, raw, "partially_filled")) return .partially_filled;
    if (std.mem.eql(u8, raw, "filled")) return .filled;
    if (std.mem.eql(u8, raw, "cancelled")) return .cancelled;
    if (std.mem.eql(u8, raw, "rejected")) return .rejected;
    return null;
}

pub const OrderSide = enum { buy, sell };

pub const OrderType = enum { limit, market, GTC, FOK };

pub const OrderStatus = enum {
    pending,
    placed,
    partially_filled,
    filled,
    cancelled,
    rejected,
};

pub const Order = struct {
    id: []const u8,
    market_id: []const u8,
    client_order_id: []const u8,
    side: OrderSide,
    size: []const u8,
    price: []const u8,
    order_type: OrderType,
    status: OrderStatus,
    created_at: i64,
};

const CancelCandidate = struct {
    id: []u8,
    should_cancel_remote: bool,
};

pub const OrderResult = union(enum) {
    success: struct {
        // Heap-owned order id. Caller must free with OrderManager allocator.
        order_id: []u8,
    },
    rejected: struct {
        reason: []const u8,
    },
    failed: struct {
        reason: []const u8,
    },
};

/// Hyperliquid signing/connection config. Empty by default so existing tests
/// (which don't exercise the live path) keep working.
pub const HlConfig = struct {
    enabled: bool = false,
    network: hl_auth.Network = .testnet,
    private_key: [32]u8 = [_]u8{0} ** 32,
    signer_address: [20]u8 = [_]u8{0} ** 20,
    chain_id: u64 = hl_auth.CHAIN_ID_TESTNET,
    domain_name: []const u8 = "Exchange",
    domain_version: []const u8 = "1",
    verifying_contract: [20]u8 = [_]u8{0} ** 20,
    api_base: []const u8 = HL_API_BASE_TESTNET,
};

pub const OrderManagerConfig = struct {
    max_order_age_hours: u32 = 24,
    stale_scan_interval_min: u32 = 5,
    max_retry_attempts: u32 = 7,
    hl: HlConfig = .{},
};

pub const OrderManager = struct {
    allocator: std.mem.Allocator,
    database: *db_mod.DB,
    risk_config: risk.RiskConfig,
    config: OrderManagerConfig,
    halted: std.atomic.Value(bool),
    paused: std.atomic.Value(bool),
    should_stop: std.atomic.Value(bool),
    reconciliation_complete: std.atomic.Value(bool),
    domain_separator: [32]u8,

    pub fn init(
        allocator: std.mem.Allocator,
        database: *db_mod.DB,
        risk_config: risk.RiskConfig,
        config: OrderManagerConfig,
    ) OrderManager {
        const ds = hl_auth.buildDomainSeparator(
            config.hl.domain_name,
            config.hl.domain_version,
            config.hl.chain_id,
            config.hl.verifying_contract,
        );
        return .{
            .allocator = allocator,
            .database = database,
            .risk_config = risk_config,
            .config = config,
            .halted = std.atomic.Value(bool).init(false),
            .paused = std.atomic.Value(bool).init(false),
            .should_stop = std.atomic.Value(bool).init(false),
            .reconciliation_complete = std.atomic.Value(bool).init(false),
            .domain_separator = ds,
        };
    }

    /// Place an order after passing through the risk gate.
    /// This is the ONLY path to submit orders - ensures non-bypassability.
    pub fn placeOrder(
        self: *OrderManager,
        market_id: []const u8,
        side: []const u8,
        size: []const u8,
        price: []const u8,
        order_type: []const u8,
        strategy_origin: ?[]const u8,
    ) OrderResult {
        crash_trace.breadcrumb("order_mgr", "placeOrder enter market={s} side={s} size={s} price={s}", .{
            market_id[0..@min(market_id.len, 24)],
            side,
            size,
            price,
        });
        // Block if halted
        if (self.halted.load(.seq_cst)) {
            log.warn("order_mgr", "order rejected: engine is halted", .{});
            return .{ .rejected = .{ .reason = "engine_halted" } };
        }

        // Block until startup reconciliation completes
        if (!self.reconciliation_complete.load(.seq_cst)) {
            log.warn("order_mgr", "order rejected: reconciliation pending", .{});
            return .{ .rejected = .{ .reason = "reconciliation_pending" } };
        }

        // Block if paused
        if (self.paused.load(.seq_cst)) {
            log.warn("order_mgr", "order rejected: engine is PAUSED", .{});
            return .{ .rejected = .{ .reason = "engine_paused" } };
        }

        // Generate client order ID
        var id_buf: [64]u8 = undefined;
        const client_order_id = std.fmt.bufPrint(&id_buf, "cex-{d}-{d}", .{
            std.time.milliTimestamp(),
            std.time.nanoTimestamp() & 0xFFFF,
        }) catch "cex-unknown";

        // Build risk gate request
        const order_request = risk.OrderRequest{
            .market_id = market_id,
            .side = side,
            .size = size,
            .price = price,
            .order_type = order_type,
            .client_order_id = client_order_id,
        };

        // MANDATORY risk gate check.
        // Note: risk.validateOrder already persists the rejection AND publishes
        // the event_risk_rejection IPC event. We don't double-publish here.
        const validation = risk.validateOrder(order_request, self.database, self.risk_config);
        switch (validation) {
            .reject => |rejection| {
                const reason_name = risk.rejectionReasonName(rejection.reason);
                log.warn("order_mgr", "risk gate rejected: {s}", .{reason_name});
                return .{ .rejected = .{ .reason = reason_name } };
            },
            .pass => {},
        }

        if (strategy_origin) |so| {
            log.info("order_mgr", "order from strategy: {s}", .{so});
        }

        // Persist order as pending
        self.database.insertOrder(
            client_order_id,
            market_id,
            client_order_id,
            order_type,
            side,
            size,
            price,
            strategy_origin,
        ) catch |e| {
            log.err("order_mgr", "failed to persist order: {any}", .{e});
            return .{ .failed = .{ .reason = "db_error" } };
        };
        crash_trace.breadcrumb("order_mgr", "pending persisted id={s}", .{
            client_order_id[0..@min(client_order_id.len, 32)],
        });

        // Submit to HL with 429 retry
        const submit_result = self.submitToHL(market_id, side, size, price, order_type);
        if (!submit_result) {
            self.database.updateOrderStatus(client_order_id, "rejected") catch {};
            return .{ .failed = .{ .reason = "hl_submission_failed" } };
        }

        // Update status to placed
        self.database.updateOrderStatus(client_order_id, "placed") catch |e| {
            log.err("order_mgr", "failed to mark order as placed in DB: order_id={s} err={any}", .{ client_order_id, e });
            return .{ .failed = .{ .reason = "db_status_update_failed" } };
        };
        crash_trace.breadcrumb("order_mgr", "placed id={s}", .{
            client_order_id[0..@min(client_order_id.len, 32)],
        });
        log.info("order_mgr", "order placed: {s} {s} {s}@{s} on {s}", .{
            order_type, side, size, price, market_id,
        });
        // Publish order placed event
        const evt_payload = std.json.Stringify.valueAlloc(self.allocator, .{
            .order_id = client_order_id,
            .market_id = market_id,
            .side = side,
            .size = size,
            .price = price,
            .order_type = order_type,
        }, .{}) catch |e| {
            log.err("order_mgr", "failed to serialize order placed event: {s}", .{@errorName(e)});
            const order_id_owned = self.allocator.dupe(u8, client_order_id) catch {
                log.err("order_mgr", "failed to allocate order_id result", .{});
                return .{ .failed = .{ .reason = "oom" } };
            };
            return .{ .success = .{ .order_id = order_id_owned } };
        };
        defer self.allocator.free(evt_payload);
        ipc.publishEvent(ipc_types.T.event_order_placed, evt_payload);

        const order_id_owned = self.allocator.dupe(u8, client_order_id) catch {
            log.err("order_mgr", "failed to allocate order_id result", .{});
            return .{ .failed = .{ .reason = "oom" } };
        };

        return .{ .success = .{ .order_id = order_id_owned } };
    }

    /// Cancel a specific order by ID.
    pub fn cancelOrder(self: *OrderManager, order_id: []const u8) bool {
        var should_cancel_remote = true;
        const status_sql = "SELECT status FROM orders WHERE id=? LIMIT 1;" ++ &[_:0]u8{};
        var status_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, status_sql.ptr, -1, &status_stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(status_stmt);
            if (c.sqlite3_bind_text(status_stmt, 1, order_id.ptr, @intCast(order_id.len), null) == c.SQLITE_OK and
                c.sqlite3_step(status_stmt) == c.SQLITE_ROW)
            {
                const status_raw = c.sqlite3_column_text(status_stmt, 0);
                const status_str = if (status_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
                if (parseOrderStatus(status_str)) |status| {
                    should_cancel_remote = switch (status) {
                        .placed, .partially_filled => true,
                        .pending => false,
                        .filled, .cancelled, .rejected => {
                            log.warn("order_mgr", "cancel ignored for non-open order {s} status={s}", .{ order_id, status_str });
                            return false;
                        },
                    };
                }
            }
        }

        if (should_cancel_remote and !self.cancelOnHL(order_id)) {
            log.err("order_mgr", "failed to cancel order on HL: {s}", .{order_id});
            return false;
        }

        // Update DB status
        self.database.updateOrderStatus(order_id, "cancelled") catch |e| {
            log.err("order_mgr", "failed to cancel order {s}: {any}", .{ order_id, e });
            return false;
        };

        log.info("order_mgr", "order cancelled: {s}", .{order_id});
        var cancel_evt_buf: [256]u8 = undefined;
        const cancel_evt_payload = std.fmt.bufPrint(
            &cancel_evt_buf,
            "{{\"order_id\":\"{s}\"}}",
            .{order_id},
        ) catch "{}";
        ipc.publishEvent(ipc_types.T.event_order_cancelled, cancel_evt_payload);
        return true;
    }

    /// Cancel all open orders. Used by /halt and /cancel_all.
    /// Returns the number of orders cancelled.
    pub fn cancelAll(self: *OrderManager) u32 {
        const pre_open_count = self.database.queryOpenOrderCount() catch |e| {
            log.err("order_mgr", "cancelAll failed to query open-order count: {any}", .{e});
            return 0;
        };

        if (pre_open_count == 0) {
            log.info("order_mgr", "cancelAll complete: open_before=0 cancelled=0", .{});
            return 0;
        }

        const select_sql = "SELECT id, status FROM orders WHERE status NOT IN ('filled','cancelled','rejected');" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, select_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("order_mgr", "cancelAll failed: unable to prepare open-order query", .{});
            return pre_open_count;
        }
        defer _ = c.sqlite3_finalize(stmt);

        var candidates: std.ArrayList(CancelCandidate) = .empty;
        defer {
            for (candidates.items) |candidate| self.allocator.free(candidate.id);
            candidates.deinit(self.allocator);
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const order_id_raw = c.sqlite3_column_text(stmt, 0);
            const order_id_ptr: [*c]const u8 = @ptrCast(order_id_raw orelse @as([*c]const u8, ""));
            const order_id = std.mem.span(order_id_ptr);
            if (order_id.len == 0) continue;

            const status_raw = c.sqlite3_column_text(stmt, 1);
            const status_str = if (status_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
            const should_cancel_remote = if (parseOrderStatus(status_str)) |status|
                status != .pending
            else
                true;

            const owned_id = self.allocator.dupe(u8, order_id) catch {
                log.err("order_mgr", "cancelAll failed to allocate order id copy", .{});
                continue;
            };
            candidates.append(self.allocator, .{
                .id = owned_id,
                .should_cancel_remote = should_cancel_remote,
            }) catch {
                self.allocator.free(owned_id);
                log.err("order_mgr", "cancelAll failed to append order candidate", .{});
                continue;
            };
        }

        var cancelled_count: u32 = 0;

        const update_sql = "UPDATE orders SET status='cancelled', updated_at=unixepoch() WHERE id=?;" ++ &[_:0]u8{};
        var upd_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, update_sql.ptr, -1, &upd_stmt, null) != c.SQLITE_OK) {
            log.err("order_mgr", "cancelAll failed to prepare UPDATE", .{});
            return 0;
        }
        defer _ = c.sqlite3_finalize(upd_stmt);

        for (candidates.items) |candidate| {
            if (candidate.should_cancel_remote and !self.cancelOnHL(candidate.id)) {
                log.err("order_mgr", "cancelAll failed HL cancel for order {s}", .{candidate.id});
                continue;
            }

            if (!applyCancelledUpdate(upd_stmt.?, candidate.id)) {
                log.err("order_mgr", "cancelAll DB update failed for order {s}", .{candidate.id});
                continue;
            }

            log.info("order_mgr", "cancelAll: cancelled order {s} on HL", .{candidate.id});
            cancelled_count += 1;
        }

        log.info("order_mgr", "cancelAll complete: open_before={d} cancelled={d}", .{ pre_open_count, cancelled_count });
        return cancelled_count;
    }

    /// Scan for stale GTC orders older than max_order_age_hours and cancel them.
    pub fn scanStaleOrders(self: *OrderManager) void {
        const max_age_seconds: i64 = @as(i64, @intCast(self.config.max_order_age_hours)) * 3600;
        const cutoff = std.time.timestamp() - max_age_seconds;

        const sql = "SELECT id, status FROM orders WHERE status IN ('placed','pending') AND created_at < ?;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("order_mgr", "scanStaleOrders failed: unable to prepare stale-order query", .{});
            return;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_int64(stmt, 1, cutoff) != c.SQLITE_OK) {
            log.err("order_mgr", "scanStaleOrders failed: unable to bind cutoff", .{});
            return;
        }

        const update_sql = "UPDATE orders SET status='cancelled', updated_at=unixepoch() WHERE id=?;" ++ &[_:0]u8{};
        var upd_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, update_sql.ptr, -1, &upd_stmt, null) != c.SQLITE_OK) {
            log.err("order_mgr", "scanStaleOrders failed: unable to prepare stale-order update", .{});
            return;
        }
        defer _ = c.sqlite3_finalize(upd_stmt);

        var cancelled_count: u32 = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const order_id_raw = c.sqlite3_column_text(stmt, 0);
            const order_id_ptr: [*c]const u8 = @ptrCast(order_id_raw orelse @as([*c]const u8, ""));
            const order_id = std.mem.span(order_id_ptr);
            if (order_id.len == 0) continue;

            const status_raw = c.sqlite3_column_text(stmt, 1);
            const status_str = if (status_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
            const is_pending = std.mem.eql(u8, status_str, "pending");

            if (!is_pending) {
                if (!self.cancelOnHL(order_id)) {
                    log.err("order_mgr", "failed stale-order cancel on HL: {s}", .{order_id});
                    continue;
                }
            }

            if (!applyCancelledUpdate(upd_stmt.?, order_id)) {
                log.err("order_mgr", "failed DB update after stale-order cancel {s}", .{order_id});
                continue;
            }

            cancelled_count += 1;
        }

        log.info("order_mgr", "stale order scan complete (cutoff={d}, cancelled={d})", .{ cutoff, cancelled_count });
    }

    /// Enter halt state: cancel all orders and block new placements.
    pub fn halt(self: *OrderManager) u32 {
        self.halted.store(true, .seq_cst);
        const cancelled = self.cancelAll();
        log.info("order_mgr", "HALT: engine halted, all orders cancelled", .{});
        var halt_evt_buf: [128]u8 = undefined;
        const halt_evt_payload = std.fmt.bufPrint(
            &halt_evt_buf,
            "{{\"status\":\"halted\",\"cancelled_orders\":{d}}}",
            .{cancelled},
        ) catch "{}";
        ipc.publishEvent(ipc_types.T.event_engine_halted, halt_evt_payload);
        return cancelled;
    }

    /// Resume from halt state.
    pub fn @"resume"(self: *OrderManager) void {
        self.halted.store(false, .seq_cst);
        self.paused.store(false, .seq_cst);
        log.info("order_mgr", "RESUME: engine resumed", .{});
        ipc.publishEvent(ipc_types.T.event_engine_resumed, "{\"status\":\"resumed\"}");
    }

    pub fn setPaused(self: *OrderManager, value: bool) void {
        self.paused.store(value, .seq_cst);
        if (value) {
            log.info("order_mgr", "PAUSE: strategy evaluation paused, open orders preserved", .{});
        } else {
            log.info("order_mgr", "UNPAUSE: strategy evaluation resumed", .{});
        }
    }

    pub fn isPaused(self: *OrderManager) bool {
        return self.paused.load(.seq_cst);
    }

    pub fn isHalted(self: *OrderManager) bool {
        return self.halted.load(.seq_cst);
    }

    /// Build the action JSON for an HL order (Phase 2 minimal shape).
    /// Returns an arena-allocated `std.json.Value`. Caller must keep the
    /// arena alive until the value is fully consumed.
    fn buildOrderAction(
        arena: std.mem.Allocator,
        market_id: []const u8,
        side: []const u8,
        size: []const u8,
        price: []const u8,
        order_type: []const u8,
    ) !std.json.Value {
        // Phase 2 stub: asset index defaults to 0; resolution will land in
        // Phase 3 via hl_market_meta. Strings are encoded as msgpack strings
        // for size/price so the operator can pass HL's expected decimal text.
        _ = market_id;
        var orders = std.json.Array.init(arena);
        var ord = std.json.ObjectMap.init(arena);
        try ord.put("a", .{ .integer = 0 }); // asset index (stub)
        try ord.put("b", .{ .bool = std.mem.eql(u8, side, "buy") });
        try ord.put("p", .{ .string = price });
        try ord.put("s", .{ .string = size });
        try ord.put("r", .{ .bool = false }); // reduce_only
        var t = std.json.ObjectMap.init(arena);
        var lim = std.json.ObjectMap.init(arena);
        const tif: []const u8 = if (std.mem.eql(u8, order_type, "limit") or std.mem.eql(u8, order_type, "GTC"))
            "Gtc"
        else
            "Ioc";
        try lim.put("tif", .{ .string = tif });
        try t.put("limit", .{ .object = lim });
        try ord.put("t", .{ .object = t });
        try orders.append(.{ .object = ord });

        var action = std.json.ObjectMap.init(arena);
        try action.put("type", .{ .string = "order" });
        try action.put("orders", .{ .array = orders });
        try action.put("grouping", .{ .string = "na" });
        return .{ .object = action };
    }

    /// Build the cancel action JSON for a single order id.
    fn buildCancelAction(
        arena: std.mem.Allocator,
        order_id: []const u8,
    ) !std.json.Value {
        var cancels = std.json.Array.init(arena);
        var item = std.json.ObjectMap.init(arena);
        try item.put("a", .{ .integer = 0 });
        try item.put("o", .{ .string = order_id });
        try cancels.append(.{ .object = item });

        var action = std.json.ObjectMap.init(arena);
        try action.put("type", .{ .string = "cancel" });
        try action.put("cancels", .{ .array = cancels });
        return .{ .object = action };
    }

    /// Build the signed-envelope JSON {action, nonce, signature}. Returned
    /// slice is owned by the caller (allocator-allocated).
    pub fn buildHlEnvelope(
        self: *OrderManager,
        action: std.json.Value,
        nonce: u64,
    ) ![]u8 {
        const action_msgpack = try msgpack.encodeActionForSigning(self.allocator, action);
        defer self.allocator.free(action_msgpack);

        const source = hl_auth.resolveSource(self.config.hl.network);
        const digest = hl_auth.buildActionDigest(action_msgpack, nonce, null, source, self.domain_separator);

        var key_copy: [32]u8 = self.config.hl.private_key;
        defer std.crypto.secureZero(u8, key_copy[0..]);

        const signed = try hl_auth.signDigest(digest, key_copy);

        // Hand-build the JSON envelope — std.json.Value can't carry the
        // r/s hex prefix as integers.
        const action_json = try std.json.Stringify.valueAlloc(self.allocator, action, .{});
        defer self.allocator.free(action_json);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "{\"action\":");
        try buf.appendSlice(self.allocator, action_json);
        try buf.appendSlice(self.allocator, ",\"nonce\":");
        var nonce_buf: [24]u8 = undefined;
        const nonce_str = try std.fmt.bufPrint(&nonce_buf, "{d}", .{nonce});
        try buf.appendSlice(self.allocator, nonce_str);
        try buf.appendSlice(self.allocator, ",\"signature\":{\"r\":\"");
        try buf.appendSlice(self.allocator, signed.r_hex[0..]);
        try buf.appendSlice(self.allocator, "\",\"s\":\"");
        try buf.appendSlice(self.allocator, signed.s_hex[0..]);
        try buf.appendSlice(self.allocator, "\",\"v\":");
        var v_buf: [4]u8 = undefined;
        const v_str = try std.fmt.bufPrint(&v_buf, "{d}", .{signed.v});
        try buf.appendSlice(self.allocator, v_str);
        try buf.appendSlice(self.allocator, "}}");

        return buf.toOwnedSlice(self.allocator);
    }

    /// Submit a signed HL order to `${api_base}/exchange` with retries.
    /// Returns true on success, false on failure after exhausting retries.
    fn submitToHL(
        self: *OrderManager,
        market_id: []const u8,
        side: []const u8,
        size: []const u8,
        price: []const u8,
        order_type: []const u8,
    ) bool {
        crash_trace.breadcrumb("order_mgr", "hl submit enter market={s} side={s} size={s} price={s}", .{
            market_id[0..@min(market_id.len, 24)],
            side,
            size,
            price,
        });

        if (!self.config.hl.enabled) {
            log.warn("order_mgr", "HL submission skipped: hl.enabled=false (Phase 2 stub)", .{});
            return false;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const action = buildOrderAction(arena.allocator(), market_id, side, size, price, order_type) catch |e| {
            log.err("order_mgr", "failed to build HL order action: {s}", .{@errorName(e)});
            return false;
        };

        const nonce: u64 = @intCast(@max(std.time.milliTimestamp(), 1));
        const envelope = self.buildHlEnvelope(action, nonce) catch |e| {
            log.err("order_mgr", "failed to build HL signed envelope: {s}", .{@errorName(e)});
            return false;
        };
        defer self.allocator.free(envelope);

        log.debug("order_mgr", "HL payload: action=order nonce={d} market={s} side={s} size={s} price={s} order_type={s} signature=redacted", .{
            nonce,
            market_id,
            side,
            size,
            price,
            order_type,
        });

        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/exchange", .{self.config.hl.api_base}) catch {
            log.err("order_mgr", "failed to format HL url", .{});
            return false;
        };

        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        var delay_ms: u64 = 1000;
        const max_delay_ms: u64 = 60_000;

        var attempt: u32 = 0;
        while (attempt < self.config.max_retry_attempts) : (attempt += 1) {
            crash_trace.breadcrumb("order_mgr", "hl submit attempt={d}", .{attempt + 1});

            var response = client.postJsonWithHeaders(url, envelope, &.{
                .{ .name = "Content-Type", .value = "application/json" },
            }) catch |e| {
                if (e == error.ClientError) {
                    log.warn("order_mgr", "HL submission 429/client error, backoff {d}ms (attempt {d}/{d})", .{
                        delay_ms, attempt + 1, self.config.max_retry_attempts,
                    });
                    std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                    delay_ms = @min(delay_ms * 2, max_delay_ms);
                    continue;
                }
                log.err("order_mgr", "HL submission failed: {s}", .{@errorName(e)});
                return false;
            };
            defer response.deinit();

            if (response.status == .too_many_requests) {
                log.warn("order_mgr", "HL 429, backoff {d}ms (attempt {d}/{d})", .{
                    delay_ms, attempt + 1, self.config.max_retry_attempts,
                });
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                delay_ms = @min(delay_ms * 2, max_delay_ms);
                continue;
            }

            if (response.status.class() == .success) {
                crash_trace.breadcrumb("order_mgr", "hl submit success", .{});
                log.info("order_mgr", "HL order submitted: market={s} side={s} price={s} size={s}", .{
                    market_id, side, price, size,
                });
                return true;
            }

            log.err("order_mgr", "HL rejected: status={d} body={s}", .{
                @intFromEnum(response.status), response.body,
            });
            return false;
        }

        log.err("order_mgr", "HL submission failed after {d} retries", .{self.config.max_retry_attempts});
        return false;
    }

    /// Cancel an order on HL via the `/exchange` endpoint.
    fn cancelOnHL(self: *OrderManager, order_id: []const u8) bool {
        if (!self.config.hl.enabled) {
            log.warn("order_mgr", "HL cancel skipped: hl.enabled=false (Phase 2 stub)", .{});
            return false;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const action = buildCancelAction(arena.allocator(), order_id) catch |e| {
            log.err("order_mgr", "failed to build HL cancel action: {s}", .{@errorName(e)});
            return false;
        };

        const nonce: u64 = @intCast(@max(std.time.milliTimestamp(), 1));
        const envelope = self.buildHlEnvelope(action, nonce) catch |e| {
            log.err("order_mgr", "failed to build HL cancel envelope: {s}", .{@errorName(e)});
            return false;
        };
        defer self.allocator.free(envelope);

        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/exchange", .{self.config.hl.api_base}) catch {
            log.err("order_mgr", "failed to format HL cancel url", .{});
            return false;
        };

        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        var delay_ms: u64 = 1000;
        const max_delay_ms: u64 = 60_000;

        var attempt: u32 = 0;
        while (attempt < self.config.max_retry_attempts) : (attempt += 1) {
            var response = client.postJsonWithHeaders(url, envelope, &.{
                .{ .name = "Content-Type", .value = "application/json" },
            }) catch |e| {
                if (e == error.ClientError) {
                    log.warn("order_mgr", "HL cancel 429/client error, backoff {d}ms (attempt {d}/{d})", .{
                        delay_ms, attempt + 1, self.config.max_retry_attempts,
                    });
                    std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                    delay_ms = @min(delay_ms * 2, max_delay_ms);
                    continue;
                }
                log.err("order_mgr", "HL cancel request failed: {s}", .{@errorName(e)});
                return false;
            };
            defer response.deinit();

            if (response.status == .too_many_requests) {
                log.warn("order_mgr", "HL cancel 429, backoff {d}ms (attempt {d}/{d})", .{
                    delay_ms, attempt + 1, self.config.max_retry_attempts,
                });
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                delay_ms = @min(delay_ms * 2, max_delay_ms);
                continue;
            }

            if (response.status.class() == .success) {
                log.info("order_mgr", "HL order cancelled: {s}", .{order_id});
                return true;
            }

            log.err("order_mgr", "HL cancel rejected: status={d} body={s}", .{
                @intFromEnum(response.status), response.body,
            });
            return false;
        }

        log.err("order_mgr", "HL cancel failed after {d} retries", .{self.config.max_retry_attempts});
        return false;
    }

    /// Compute the backoff delay for a given attempt (exposed for testing).
    pub fn backoffDelayMs(attempt: u32) u64 {
        const base: u64 = 1000;
        const max: u64 = 60_000;
        const shift: u6 = @intCast(@min(attempt, 63));
        return @min(base << shift, max);
    }
};

test "order_manager: applyCancelledUpdate handles quoted and escaped ids" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.insertOrder("ord'one", "m1", "co-1", "limit", "buy", "10", "0.50", null);
    try database.insertOrder("ord\\two", "m1", "co-2", "limit", "sell", "9", "0.49", null);

    const update_sql = "UPDATE orders SET status='cancelled', updated_at=unixepoch() WHERE id=?;" ++ &[_:0]u8{};
    var upd_stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expect(c.sqlite3_prepare_v2(database.handle, update_sql.ptr, -1, &upd_stmt, null) == c.SQLITE_OK);
    defer _ = c.sqlite3_finalize(upd_stmt);

    try std.testing.expect(applyCancelledUpdate(upd_stmt.?, "ord'one"));
    try std.testing.expect(applyCancelledUpdate(upd_stmt.?, "ord\\two"));

    const count_sql = "SELECT COUNT(*) FROM orders WHERE status='cancelled';" ++ &[_:0]u8{};
    var count_stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expect(c.sqlite3_prepare_v2(database.handle, count_sql.ptr, -1, &count_stmt, null) == c.SQLITE_OK);
    defer _ = c.sqlite3_finalize(count_stmt);

    try std.testing.expect(c.sqlite3_step(count_stmt) == c.SQLITE_ROW);
    try std.testing.expectEqual(@as(c_int, 2), c.sqlite3_column_int(count_stmt, 0));
}

test "order_manager: applyCancelledUpdate rejects empty id" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    const update_sql = "UPDATE orders SET status='cancelled', updated_at=unixepoch() WHERE id=?;" ++ &[_:0]u8{};
    var upd_stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expect(c.sqlite3_prepare_v2(database.handle, update_sql.ptr, -1, &upd_stmt, null) == c.SQLITE_OK);
    defer _ = c.sqlite3_finalize(upd_stmt);

    try std.testing.expect(!applyCancelledUpdate(upd_stmt.?, ""));
}
