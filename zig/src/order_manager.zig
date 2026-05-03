//! Order manager — lifecycle management, signed CLOB submission, staleness handling.
//! Retry policy (429 backoff) is kept here, not in http_client.zig.
const std = @import("std");
const log = @import("logger.zig");
const db_mod = @import("db.zig");
const http = @import("http_client.zig");
const crypto = @import("crypto.zig");
const poly_auth = @import("polymarket_auth.zig");
const risk = @import("risk_gate.zig");
const ipc = @import("ipc.zig");
const ipc_types = @import("ipc_types.zig");
const crash_trace = @import("crash_trace.zig");
const c = db_mod.c;

const CLOB_API_BASE = "https://clob.polymarket.com";

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

pub const OrderManagerConfig = struct {
    max_order_age_hours: u32 = 24,
    stale_scan_interval_min: u32 = 5,
    max_retry_attempts: u32 = 7,
    private_key: [32]u8 = [_]u8{0} ** 32,
    signer_address: [20]u8 = [_]u8{0} ** 20,
    funder_address: ?[20]u8 = null,
    signature_type: u8 = 0, // 0=EOA, 1=POLY_PROXY, 2=GNOSIS_SAFE
    api_creds: ?poly_auth.ApiCredentials = null,
};

pub const OrderManager = struct {
    allocator: std.mem.Allocator,
    database: *db_mod.DB,
    risk_config: risk.RiskConfig,
    config: OrderManagerConfig,
    halted: std.atomic.Value(bool),
    paused: std.atomic.Value(bool),
    should_stop: std.atomic.Value(bool),
    lastFeeRateByToken: std.StringHashMap(u256),
    defaultFeeRateBps: u256,
    reconciliation_complete: std.atomic.Value(bool),

    pub fn init(
        allocator: std.mem.Allocator,
        database: *db_mod.DB,
        risk_config: risk.RiskConfig,
        config: OrderManagerConfig,
    ) OrderManager {
        return .{
            .allocator = allocator,
            .database = database,
            .risk_config = risk_config,
            .config = config,
            .halted = std.atomic.Value(bool).init(false),
            .paused = std.atomic.Value(bool).init(false),
            .should_stop = std.atomic.Value(bool).init(false),
            .lastFeeRateByToken = std.StringHashMap(u256).init(allocator),
            .defaultFeeRateBps = 1000, // Set a sensible default, can be overridden
            .reconciliation_complete = std.atomic.Value(bool).init(false),
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

        // Submit to CLOB with 429 retry
        const submit_result = self.submitToCLOB(market_id, side, size, price, order_type);
        if (!submit_result) {
            self.database.updateOrderStatus(client_order_id, "rejected") catch {};
            return .{ .failed = .{ .reason = "clob_submission_failed" } };
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

        if (should_cancel_remote and !self.cancelOnCLOB(order_id)) {
            log.err("order_mgr", "failed to cancel order on CLOB: {s}", .{order_id});
            return false;
        }

        // Update DB status
        self.database.updateOrderStatus(order_id, "cancelled") catch |e| {
            log.err("order_mgr", "failed to cancel order {s}: {any}", .{ order_id, e });
            return false;
        };

        log.info("order_mgr", "order cancelled: {s}", .{order_id});
        // Publish order cancelled event
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
            if (candidate.should_cancel_remote and !self.cancelOnCLOB(candidate.id)) {
                log.err("order_mgr", "cancelAll failed CLOB cancel for order {s}", .{candidate.id});
                continue;
            }

            if (!applyCancelledUpdate(upd_stmt.?, candidate.id)) {
                log.err("order_mgr", "cancelAll DB update failed for order {s}", .{candidate.id});
                continue;
            }

            log.info("order_mgr", "cancelAll: cancelled order {s} on CLOB", .{candidate.id});
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

            // Pending orders were never submitted to CLOB — just mark cancelled locally.
            // Placed orders need CLOB cancellation first.
            if (!is_pending) {
                if (!self.cancelOnCLOB(order_id)) {
                    log.err("order_mgr", "failed stale-order cancel on CLOB: {s}", .{order_id});
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
        // Publish engine halted event
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
        // Publish engine resumed event
        ipc.publishEvent(ipc_types.T.event_engine_resumed, "{\"status\":\"resumed\"}");
    }

    /// Pause strategy evaluation without cancelling orders.
    pub fn setPaused(self: *OrderManager, value: bool) void {
        self.paused.store(value, .seq_cst);
        if (value) {
            log.info("order_mgr", "PAUSE: strategy evaluation paused, open orders preserved", .{});
        } else {
            log.info("order_mgr", "UNPAUSE: strategy evaluation resumed", .{});
        }
    }

    /// Check if the engine is paused.
    pub fn isPaused(self: *OrderManager) bool {
        return self.paused.load(.seq_cst);
    }

    /// Check if the engine is halted.
    pub fn isHalted(self: *OrderManager) bool {
        return self.halted.load(.seq_cst);
    }

    /// Submit a signed CTF Exchange order to the CLOB REST API with L2 HMAC auth.
    /// Backoff schedule: 1s, 2s, 4s, 8s, 16s, 32s, 60s (capped).
    /// Returns true on success, false on failure after exhausting retries.
    fn submitToCLOB(
        self: *OrderManager,
        market_id: []const u8,
        side: []const u8,
        size: []const u8,
        price: []const u8,
        order_type: []const u8,
    ) bool {
        crash_trace.breadcrumb("order_mgr", "submit enter market={s} side={s} size={s} price={s}", .{
            market_id[0..@min(market_id.len, 24)],
            side,
            size,
            price,
        });
        const creds = self.config.api_creds orelse {
            log.err("order_mgr", "no API credentials — cannot submit order", .{});
            return false;
        };

        // Resolve token_id from market/condition_id
        var token_id_buf: [128]u8 = undefined;
        const token_id = self.resolveTokenId(market_id, side, &token_id_buf) orelse {
            log.err("order_mgr", "failed to resolve token_id for market={s} side={s}", .{ market_id, side });
            return false;
        };
        crash_trace.breadcrumb("order_mgr", "token resolved market={s} token={s}", .{
            market_id[0..@min(market_id.len, 24)],
            token_id[0..@min(token_id.len, 24)],
        });

        // Parse price/size as f64
        const price_f = std.fmt.parseFloat(f64, price) catch {
            log.err("order_mgr", "invalid price: {s}", .{price});
            return false;
        };
        const size_f = std.fmt.parseFloat(f64, size) catch {
            log.err("order_mgr", "invalid size: {s}", .{size});
            return false;
        };

        const side_u8: u8 = if (std.mem.eql(u8, side, "buy")) 0 else 1;
        const amounts = poly_auth.computeOrderAmounts(side_u8, price_f, size_f) catch {
            log.err("order_mgr", "invalid order amounts: side={d} price={d} size={d}", .{ side_u8, price_f, size_f });
            return false;
        };

        // Parse token_id string to u256
        const token_id_u256: u256 = std.fmt.parseInt(u256, token_id, 10) catch {
            log.err("order_mgr", "invalid token_id: {s}", .{token_id});
            return false;
        };

        const maker = self.config.funder_address orelse self.config.signer_address;
        const order_signer = if (self.config.signature_type == 3)
            maker
        else
            self.config.signer_address;

        // Build CTF Order struct
        // Match the official client: salt is a random integer bounded by Date.now().
        const ts_ms_i64 = std.time.milliTimestamp();
        const ts_ms: u64 = @intCast(@max(ts_ms_i64, 1));
        var rand_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&rand_bytes);
        const rand_val = std.mem.readInt(u64, &rand_bytes, .big);
        const salt: u256 = @as(u256, rand_val % ts_ms + 1);

        const order = poly_auth.CtfOrder{
            .salt = salt,
            .maker = maker,
            .signer = order_signer,
            .taker = [_]u8{0} ** 20,
            .token_id = token_id_u256,
            .maker_amount = amounts.maker_amount,
            .taker_amount = amounts.taker_amount,
            .expiration = 0,
            .nonce = 0,
            .fee_rate_bps = 0,
            .side = side_u8,
            .signature_type = self.config.signature_type,
            .timestamp = ts_ms,
            .metadata = [_]u8{0} ** 32,
            .builder = [_]u8{0} ** 32,
        };

        // EIP-712 sign the order (use neg-risk exchange for neg-risk markets)
        const is_neg_risk = self.isNegRiskMarket(market_id);
        const exchange = if (is_neg_risk) poly_auth.NEG_RISK_CTF_EXCHANGE else poly_auth.CTF_EXCHANGE;
        const order_digest = poly_auth.buildOrderDigest(order, poly_auth.CHAIN_ID, exchange);
        var key_copy: [32]u8 = self.config.private_key;
        defer std.crypto.secureZero(u8, key_copy[0..]);

        const order_sig_hex_dyn = if (self.config.signature_type == 3)
            poly_auth.buildPoly1271OrderSignature(order, poly_auth.CHAIN_ID, exchange, key_copy) catch |e| {
                log.err("order_mgr", "failed to build POLY_1271 order signature: {s}", .{@errorName(e)});
                return false;
            }
        else
            null;
        defer if (order_sig_hex_dyn) |sig_hex| std.heap.page_allocator.free(sig_hex);
        crash_trace.breadcrumb("order_mgr", "order signed market={s}", .{
            market_id[0..@min(market_id.len, 24)],
        });
        var order_sig_hex_buf: [132]u8 = undefined;
        const order_sig_hex = if (order_sig_hex_dyn) |sig_hex|
            sig_hex
        else blk: {
            const order_sig = crypto.signEip712(order_digest, key_copy) catch |e| {
                log.err("order_mgr", "failed to sign order: {s}", .{@errorName(e)});
                return false;
            };
            order_sig_hex_buf = poly_auth.formatSignature(order_sig);
            break :blk order_sig_hex_buf[0..];
        };

        // L2 authenticated requests always identify the signer EOA associated
        // with the API key. The funded Safe/proxy is inferred server-side from
        // signatureType and is not sent in POLY_ADDRESS.
        const auth_address = self.config.signer_address;
        const addr_hex = poly_auth.formatAddressEip55(auth_address);

        // Format maker address
        const maker_hex = poly_auth.formatAddressEip55(maker);

        // Format order signer address
        const order_signer_hex = poly_auth.formatAddressEip55(order_signer);

        // Format taker address
        const taker_hex = poly_auth.formatAddressEip55(order.taker);

        // Build the SendOrder JSON body
        var salt_buf: [80]u8 = undefined;
        const salt_str = std.fmt.bufPrint(&salt_buf, "{d}", .{order.salt}) catch "0";
        var maker_amt_buf: [32]u8 = undefined;
        const maker_amt_str = std.fmt.bufPrint(&maker_amt_buf, "{d}", .{amounts.maker_amount}) catch "0";
        var taker_amt_buf: [32]u8 = undefined;
        const taker_amt_str = std.fmt.bufPrint(&taker_amt_buf, "{d}", .{amounts.taker_amount}) catch "0";
        var timestamp_buf: [32]u8 = undefined;
        const timestamp_str = std.fmt.bufPrint(&timestamp_buf, "{d}", .{order.timestamp}) catch "0";
        const zero_bytes32 = "0x0000000000000000000000000000000000000000000000000000000000000000";
        var body_buf: [2048]u8 = undefined;
        // Map internal order types to CLOB-compatible types
        const clob_order_type: []const u8 = if (std.mem.eql(u8, order_type, "limit") or std.mem.eql(u8, order_type, "GTC"))
            "GTC"
        else if (std.mem.eql(u8, order_type, "market") or std.mem.eql(u8, order_type, "FOK"))
            "FOK"
        else
            order_type;
        // owner = API key (UUID), not the signer address
        const api_key = creds.api_key[0..creds.api_key_len];
        const json_body = std.fmt.bufPrint(&body_buf,
            \\{{"deferExec":false,"postOnly":false,"order":{{"salt":{s},"maker":"{s}","signer":"{s}","taker":"{s}","tokenId":"{s}","makerAmount":"{s}","takerAmount":"{s}","side":"{s}","signatureType":{d},"timestamp":"{s}","expiration":"0","metadata":"{s}","builder":"{s}","signature":"{s}"}},"owner":"{s}","orderType":"{s}"}}
        , .{
            salt_str,
            &maker_hex,
            &order_signer_hex,
            &taker_hex,
            token_id,
            maker_amt_str,
            taker_amt_str,
            if (side_u8 == 0) "BUY" else "SELL",
            self.config.signature_type,
            timestamp_str,
            zero_bytes32,
            zero_bytes32,
            order_sig_hex,
            api_key,
            clob_order_type,
        }) catch {
            log.err("order_mgr", "failed to format order JSON", .{});
            return false;
        };
        crash_trace.breadcrumb("order_mgr", "json ready market={s} order_type={s}", .{
            market_id[0..@min(market_id.len, 24)],
            clob_order_type,
        });

        log.debug("order_mgr", "CLOB payload: {s}", .{json_body});

        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        const url = CLOB_API_BASE ++ "/order";

        var delay_ms: u64 = 1000;
        const max_delay_ms: u64 = 60_000;

        var attempt: u32 = 0;
        while (attempt < self.config.max_retry_attempts) : (attempt += 1) {
            crash_trace.breadcrumb("order_mgr", "submit attempt={d} market={s}", .{
                attempt + 1,
                market_id[0..@min(market_id.len, 24)],
            });
            // Build L2 HMAC headers per attempt
            var ts_buf: [32]u8 = undefined;
            const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch {
                log.err("order_mgr", "failed to format timestamp", .{});
                return false;
            };

            const hmac_result = poly_auth.buildHmacSignature(
                creds.secret[0..creds.secret_len],
                ts,
                "POST",
                "/order",
                json_body,
            ) catch |e| {
                log.err("order_mgr", "failed to compute HMAC: {s}", .{@errorName(e)});
                return false;
            };

            var response = client.postJsonWithHeaders(url, json_body, &.{
                .{ .name = "POLY_ADDRESS", .value = &addr_hex },
                .{ .name = "POLY_SIGNATURE", .value = hmac_result.slice() },
                .{ .name = "POLY_TIMESTAMP", .value = ts },
                .{ .name = "POLY_API_KEY", .value = creds.api_key[0..creds.api_key_len] },
                .{ .name = "POLY_PASSPHRASE", .value = creds.passphrase[0..creds.passphrase_len] },
            }) catch |e| {
                if (e == error.ClientError) {
                    log.warn("order_mgr", "CLOB submission 429/client error, backoff {d}ms (attempt {d}/{d})", .{
                        delay_ms, attempt + 1, self.config.max_retry_attempts,
                    });
                    std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                    delay_ms = @min(delay_ms * 2, max_delay_ms);
                    continue;
                }
                log.err("order_mgr", "CLOB submission failed: {s}", .{@errorName(e)});
                return false;
            };
            defer response.deinit();

            if (response.status == .too_many_requests) {
                log.warn("order_mgr", "CLOB 429, backoff {d}ms (attempt {d}/{d})", .{
                    delay_ms, attempt + 1, self.config.max_retry_attempts,
                });
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                delay_ms = @min(delay_ms * 2, max_delay_ms);
                continue;
            }

            if (response.status.class() == .success) {
                crash_trace.breadcrumb("order_mgr", "submit success market={s}", .{
                    market_id[0..@min(market_id.len, 24)],
                });
                log.info("order_mgr", "CLOB order submitted: market={s} side={s} price={s} size={s}", .{
                    market_id, side, price, size,
                });
                return true;
            }

            crash_trace.breadcrumb("order_mgr", "submit rejected status={d} market={s}", .{
                @intFromEnum(response.status),
                market_id[0..@min(market_id.len, 24)],
            });
            log.err("order_mgr", "CLOB rejected: status={d} body={s}", .{
                @intFromEnum(response.status), response.body,
            });
            return false;
        }

        log.err("order_mgr", "CLOB submission failed after {d} retries", .{self.config.max_retry_attempts});
        return false;
    }

    /// Check if a market is neg-risk by querying the DB (by Gamma market id).
    fn isNegRiskMarket(self: *OrderManager, market_id: []const u8) bool {
        const sql = "SELECT neg_risk FROM markets WHERE id=? LIMIT 1;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return false;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, market_id.ptr, @intCast(market_id.len), null) != c.SQLITE_OK) return false;
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return false;
        return c.sqlite3_column_int(stmt, 0) != 0;
    }

    /// Resolve token_id from market_id (Gamma id) by looking up clob_token_ids in DB.
    fn resolveTokenId(self: *OrderManager, market_id: []const u8, _: []const u8, buf: *[128]u8) ?[]const u8 {
        const sql = "SELECT clob_token_ids FROM markets WHERE id=? LIMIT 1;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, market_id.ptr, @intCast(market_id.len), null) != c.SQLITE_OK) return null;
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
            log.warn("order_mgr", "resolveTokenId: no market found for id={s}", .{market_id});
            return null;
        }

        const raw_ptr = c.sqlite3_column_text(stmt, 0);
        const raw = if (raw_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else return null;

        // Always use token [0] (Yes token). The order side (BUY/SELL) determines direction
        // on the same token, not which token to pick.
        return extractJsonArrayElement(raw, 0, buf);
    }

    /// Extract element at `idx` from a JSON string array like '["a","b"]'.
    fn extractJsonArrayElement(raw: []const u8, idx: usize, buf: *[128]u8) ?[]const u8 {
        if (raw.len < 2) return null;
        var count: usize = 0;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '"') {
                const start = i + 1;
                i += 1;
                while (i < raw.len and raw[i] != '"') : (i += 1) {}
                if (count == idx) {
                    const token = raw[start..i];
                    if (token.len > buf.len) return null;
                    @memcpy(buf[0..token.len], token);
                    return buf[0..token.len];
                }
                count += 1;
            }
        }
        return null;
    }

    /// Fetch the per-market fee rate from GET /fee-rate?token_id=TOKEN_ID.
    /// Returns the base_fee value (e.g. 0 or 1000), or error on failure.
    fn fetchFeeRate(self: *OrderManager, token_id: []const u8) !u256 {
        var url_buf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}/fee-rate?token_id={s}", .{
            CLOB_API_BASE,
            token_id,
        });

        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        var response = client.get(url) catch {
            return error.FetchFailed;
        };
        defer response.deinit();

        // Parse {"base_fee": 1000}
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{}) catch {
            return error.ParseFailed;
        };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidResponse,
        };

        const base_fee = obj.get("base_fee") orelse return error.MissingBaseFee;
        return switch (base_fee) {
            .integer => |v| if (v >= 0) @intCast(v) else error.NegativeFee,
            .float => |v| {
                if (std.math.isNan(v) or std.math.isInf(v)) return 0;
                if (v < 0) return 0;
                if (v > std.math.floatMax(f64)) return 0;
                return @intFromFloat(v);
            },
            else => error.InvalidBaseFeeType,
        };
    }

    /// Cancel order on CLOB API before mutating local state.
    fn cancelOnCLOB(self: *OrderManager, order_id: []const u8) bool {
        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        const creds = self.config.api_creds orelse {
            log.err("order_mgr", "no API credentials — cannot cancel order", .{});
            return false;
        };

        const url = CLOB_API_BASE ++ "/order";

        var payload_buf: [256]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "{{\"orderID\":\"{s}\"}}", .{order_id}) catch {
            log.err("order_mgr", "failed to format cancel payload", .{});
            return false;
        };

        const auth_address = self.config.signer_address;
        const addr_hex = poly_auth.formatAddressEip55(auth_address);

        var delay_ms: u64 = 1000;
        const max_delay_ms: u64 = 60_000;

        var attempt: u32 = 0;
        while (attempt < self.config.max_retry_attempts) : (attempt += 1) {
            // Build L2 HMAC signature and timestamp per attempt
            var ts_buf: [32]u8 = undefined;
            const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch {
                log.err("order_mgr", "failed to format cancel timestamp", .{});
                return false;
            };

            const hmac_result = poly_auth.buildHmacSignature(
                creds.secret[0..creds.secret_len],
                ts,
                "DELETE",
                "/order",
                payload,
            ) catch |e| {
                log.err("order_mgr", "failed to compute cancel HMAC: {s}", .{@errorName(e)});
                return false;
            };

            var response = client.deleteJsonWithHeaders(url, payload, &.{
                .{ .name = "POLY_ADDRESS", .value = &addr_hex },
                .{ .name = "POLY_SIGNATURE", .value = hmac_result.slice() },
                .{ .name = "POLY_TIMESTAMP", .value = ts },
                .{ .name = "POLY_API_KEY", .value = creds.api_key[0..creds.api_key_len] },
                .{ .name = "POLY_PASSPHRASE", .value = creds.passphrase[0..creds.passphrase_len] },
            }) catch |e| {
                if (e == error.ClientError) {
                    log.warn("order_mgr", "CLOB cancel 429/client error, backoff {d}ms (attempt {d}/{d})", .{
                        delay_ms, attempt + 1, self.config.max_retry_attempts,
                    });
                    std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                    delay_ms = @min(delay_ms * 2, max_delay_ms);
                    continue;
                }
                log.err("order_mgr", "CLOB cancel request failed: {s}", .{@errorName(e)});
                return false;
            };
            defer response.deinit();

            if (response.status == .too_many_requests) {
                log.warn("order_mgr", "CLOB cancel 429, backoff {d}ms (attempt {d}/{d})", .{
                    delay_ms, attempt + 1, self.config.max_retry_attempts,
                });
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                delay_ms = @min(delay_ms * 2, max_delay_ms);
                continue;
            }

            if (response.status.class() != .success) {
                log.err("order_mgr", "CLOB cancel unexpected status: {d}", .{@intFromEnum(response.status)});
                return false;
            }

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{}) catch {
                log.err("order_mgr", "failed to parse CLOB cancel response", .{});
                return false;
            };
            defer parsed.deinit();

            if (parsed.value == .object) {
                if (parsed.value.object.get("success")) |v| {
                    if (v == .bool and !v.bool) {
                        log.err("order_mgr", "CLOB cancel rejected order={s}", .{order_id});
                        return false;
                    }
                }
                if (parsed.value.object.get("error")) |v| {
                    if (v == .string and v.string.len > 0) {
                        log.err("order_mgr", "CLOB cancel returned error for order={s}: {s}", .{ order_id, v.string });
                        return false;
                    }
                }
            }

            log.info("order_mgr", "CLOB order cancelled: {s}", .{order_id});
            return true;
        }

        log.err("order_mgr", "CLOB cancel failed after {d} retries", .{self.config.max_retry_attempts});
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

fn bytesToHex(bytes: []const u8, buf: []u8) []const u8 {
    std.debug.assert(bytes.len <= buf.len / 2);
    const charset = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        buf[i * 2] = charset[b >> 4];
        buf[i * 2 + 1] = charset[b & 0x0f];
    }
    return buf[0 .. bytes.len * 2];
}

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
