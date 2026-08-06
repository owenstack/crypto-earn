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
const hl_market_meta = @import("hl_market_meta.zig");
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

fn copySqlText(raw: ?[*c]const u8, out: []u8) []const u8 {
    const p = raw orelse return "";
    const span = std.mem.span(@as([*c]const u8, @ptrCast(p)));
    const n = @min(span.len, out.len);
    @memcpy(out[0..n], span[0..n]);
    return out[0..n];
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
    remote_id: []u8,
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

const SubmitResult = struct {
    ok: bool,
    oid_buf: [48]u8 = [_]u8{0} ** 48,
    oid_len: usize = 0,

    fn oid(self: *const SubmitResult) []const u8 {
        return self.oid_buf[0..self.oid_len];
    }
};

fn makeHlCloid(buf: *[34]u8) []const u8 {
    const ts: u64 = @intCast(@max(std.time.milliTimestamp(), 0));
    const ns: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    return std.fmt.bufPrint(buf, "0x{x:0>16}{x:0>16}", .{ ts, ns }) catch "0x00000000000000000000000000000000";
}

fn copyJsonScalarTo(value: std.json.Value, out: []u8) usize {
    var stream = std.io.fixedBufferStream(out);
    switch (value) {
        .string => |s| {
            const n = @min(s.len, out.len);
            @memcpy(out[0..n], s[0..n]);
            return n;
        },
        .integer => |i| {
            stream.writer().print("{d}", .{i}) catch return 0;
            return stream.pos;
        },
        .float => |f| {
            stream.writer().print("{d}", .{f}) catch return 0;
            return stream.pos;
        },
        else => return 0,
    }
}

fn parseHlOrderOid(body: []const u8, out: *[48]u8) usize {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return 0;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return 0,
    };
    const response = switch (root.get("response") orelse return 0) {
        .object => |o| o,
        else => return 0,
    };
    const data = switch (response.get("data") orelse return 0) {
        .object => |o| o,
        else => return 0,
    };
    const statuses = switch (data.get("statuses") orelse return 0) {
        .array => |a| a,
        else => return 0,
    };
    if (statuses.items.len == 0) return 0;
    const status_obj = switch (statuses.items[0]) {
        .object => |o| o,
        else => return 0,
    };
    if (status_obj.get("resting")) |resting| {
        if (resting == .object) {
            if (resting.object.get("oid")) |oid| return copyJsonScalarTo(oid, out);
        }
    }
    if (status_obj.get("filled")) |filled| {
        if (filled == .object) {
            if (filled.object.get("oid")) |oid| return copyJsonScalarTo(oid, out);
        }
    }
    return 0;
}

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

    /// Phase 4: Dry-run interception. When enabled, `placeOrder()` writes
    /// to `dry_run_orders` and skips the HL `/exchange` POST; `cancelOrder()`
    /// updates the dry-run row instead of cancelling on HL. Set by engine
    /// startup when loading the DRY_RUN env var.
    dry_run_enabled: bool = false,
    /// Initial simulated USDC balance (used by main.zig to seed
    /// balance_snapshots; recorded here for telemetry).
    dry_run_initial_balance: f64 = 10.0,
    /// Inclusive lower bound on the simulated submit→ack latency (ms).
    dry_run_latency_min_ms: u64 = 8,
    /// Inclusive upper bound on the simulated submit→ack latency (ms).
    dry_run_latency_max_ms: u64 = 25,
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
    /// Phase 3: shared asset metadata (symbol -> asset_index). May be null
    /// for tests / legacy paths where HL submission is disabled.
    asset_meta: ?*hl_market_meta.AssetMeta = null,

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
            .asset_meta = null,
        };
    }

    /// Phase 3: bind the shared HL asset metadata cache after construction.
    /// Lookups for `buildOrderAction` / `buildCancelAction` will use
    /// `asset_meta.lookup(market_id)` to resolve the asset index.
    pub fn setAssetMeta(self: *OrderManager, meta: *hl_market_meta.AssetMeta) void {
        self.asset_meta = meta;
    }

    /// Resolve the asset index for an HL order/cancel. A missing cache or
    /// symbol is a live-trading safety rejection, not an asset_index=0
    /// fallback.
    fn resolveAssetIndex(self: *OrderManager, market_id: []const u8) ?i64 {
        if (self.asset_meta) |meta| {
            if (meta.lookup(market_id)) |idx| return @intCast(idx);
            log.warn("order_mgr", "asset_meta lookup miss for symbol {s}", .{market_id});
            return null;
        }
        log.warn("order_mgr", "asset_meta unavailable while resolving symbol {s}", .{market_id});
        return null;
    }

    /// Resolve the asset index for a cancel by joining orders -> market_id ->
    /// hl_market_meta. Returns null if any link is missing.
    fn resolveCancelAssetIndex(self: *OrderManager, order_id: []const u8) ?i64 {
        const sql = "SELECT market_id FROM orders WHERE id=? OR client_order_id=? LIMIT 1;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, order_id.ptr, @intCast(order_id.len), null) != c.SQLITE_OK) return null;
        if (c.sqlite3_bind_text(stmt, 2, order_id.ptr, @intCast(order_id.len), null) != c.SQLITE_OK) return null;
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const raw = c.sqlite3_column_text(stmt, 0);
        const market_id = if (raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else return null;
        return self.resolveAssetIndex(market_id);
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

        // Generate local order ID and an HL-compatible client order ID
        // (`cloid`). HL expects a 16-byte hex string prefixed with 0x.
        var id_buf: [64]u8 = undefined;
        const order_id = std.fmt.bufPrint(&id_buf, "cex-{d}-{d}", .{
            std.time.milliTimestamp(),
            std.time.nanoTimestamp() & 0xFFFF,
        }) catch "cex-unknown";
        var cloid_buf: [34]u8 = undefined;
        const client_order_id = makeHlCloid(&cloid_buf);

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

        if (self.config.hl.enabled and !self.config.dry_run_enabled) {
            if (self.resolveAssetIndex(market_id) == null) {
                log.warn("order_mgr", "order rejected: unknown HL symbol {s}", .{market_id});
                return .{ .rejected = .{ .reason = "unknown_hl_symbol" } };
            }
        }

        // Phase 4: Dry-run interception. The risk gate has already passed
        // above, so dry-run and live paths share the same validation. Here
        // we intercept the side effects: write to `dry_run_orders`, sleep
        // for a uniform-random simulated latency, publish the same
        // `event.order.placed` event, and return a synthetic id (no HL POST).
        if (self.config.dry_run_enabled) {
            return self.placeDryRunOrder(market_id, side, size, price, order_type, strategy_origin);
        }

        // Persist order as pending
        self.database.insertOrder(
            order_id,
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
            order_id[0..@min(order_id.len, 32)],
        });

        // Submit to HL with 429 retry
        const submit_result = self.submitToHL(market_id, side, size, price, order_type, client_order_id);
        if (!submit_result.ok) {
            self.database.updateOrderStatus(order_id, "rejected") catch {};
            return .{ .failed = .{ .reason = "hl_submission_failed" } };
        }
        if (submit_result.oid_len > 0) {
            self.database.updateOrderExchangeOrderId(order_id, submit_result.oid()) catch |e| {
                log.warn("order_mgr", "failed to store HL oid for local_id={s}: {s}", .{ order_id, @errorName(e) });
            };
            log.info("order_mgr", "HL accepted order: local_id={s} cloid={s} oid={s}", .{ order_id, client_order_id, submit_result.oid() });
        }

        // Update status to placed
        self.database.updateOrderStatus(order_id, "placed") catch |e| {
            log.err("order_mgr", "failed to mark order as placed in DB: order_id={s} err={any}", .{ order_id, e });
            return .{ .failed = .{ .reason = "db_status_update_failed" } };
        };
        crash_trace.breadcrumb("order_mgr", "placed id={s}", .{
            order_id[0..@min(order_id.len, 32)],
        });
        log.info("order_mgr", "order placed: {s} {s} {s}@{s} on {s}", .{
            order_type, side, size, price, market_id,
        });
        // Publish order placed event
        const evt_payload = std.json.Stringify.valueAlloc(self.allocator, .{
            .order_id = client_order_id,
            .local_order_id = order_id,
            .market_id = market_id,
            .side = side,
            .size = size,
            .price = price,
            .order_type = order_type,
        }, .{}) catch |e| {
            log.err("order_mgr", "failed to serialize order placed event: {s}", .{@errorName(e)});
            const order_id_owned = self.allocator.dupe(u8, order_id) catch {
                log.err("order_mgr", "failed to allocate order_id result", .{});
                return .{ .failed = .{ .reason = "oom" } };
            };
            return .{ .success = .{ .order_id = order_id_owned } };
        };
        defer self.allocator.free(evt_payload);
        ipc.publishEvent(ipc_types.T.event_order_placed, evt_payload);

        const order_id_owned = self.allocator.dupe(u8, order_id) catch {
            log.err("order_mgr", "failed to allocate order_id result", .{});
            return .{ .failed = .{ .reason = "oom" } };
        };

        return .{ .success = .{ .order_id = order_id_owned } };
    }

    /// Cancel a specific order by ID.
    pub fn cancelOrder(self: *OrderManager, order_id: []const u8) bool {
        // Phase 4: Dry-run interception. The dry-run path keeps order state
        // in `dry_run_orders` (not `orders`), so cancellation flips the row
        // there and never touches the HL `/exchange` endpoint.
        if (self.config.dry_run_enabled) {
            return self.cancelDryRunOrder(order_id);
        }

        var should_cancel_remote = true;
        var remote_id_buf: [80]u8 = undefined;
        var remote_id: []const u8 = order_id;
        const status_sql = "SELECT status, COALESCE(client_order_id,''), COALESCE(exchange_order_id,'') FROM orders WHERE id=? LIMIT 1;" ++ &[_:0]u8{};
        var status_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, status_sql.ptr, -1, &status_stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(status_stmt);
            if (c.sqlite3_bind_text(status_stmt, 1, order_id.ptr, @intCast(order_id.len), null) == c.SQLITE_OK and
                c.sqlite3_step(status_stmt) == c.SQLITE_ROW)
            {
                const status_raw = c.sqlite3_column_text(status_stmt, 0);
                const status_str = if (status_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
                const client_id = copySqlText(c.sqlite3_column_text(status_stmt, 1), &remote_id_buf);
                if (client_id.len > 0) remote_id = client_id;
                const exchange_id = copySqlText(c.sqlite3_column_text(status_stmt, 2), &remote_id_buf);
                if (exchange_id.len > 0) remote_id = exchange_id;
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

        if (should_cancel_remote and !self.cancelOnHL(remote_id)) {
            log.err("order_mgr", "failed to cancel order on HL: local={s} remote={s}", .{ order_id, remote_id });
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

        const select_sql = "SELECT id, status, COALESCE(client_order_id,''), COALESCE(exchange_order_id,'') FROM orders WHERE status NOT IN ('filled','cancelled','rejected');" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, select_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("order_mgr", "cancelAll failed: unable to prepare open-order query", .{});
            return pre_open_count;
        }
        defer _ = c.sqlite3_finalize(stmt);

        var candidates: std.ArrayList(CancelCandidate) = .empty;
        defer {
            for (candidates.items) |candidate| {
                self.allocator.free(candidate.id);
                self.allocator.free(candidate.remote_id);
            }
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
            const client_id_raw = c.sqlite3_column_text(stmt, 2);
            const client_id = if (client_id_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
            const exchange_id_raw = c.sqlite3_column_text(stmt, 3);
            const exchange_id = if (exchange_id_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
            const remote_id = if (exchange_id.len > 0) exchange_id else if (client_id.len > 0) client_id else order_id;
            const owned_remote_id = self.allocator.dupe(u8, remote_id) catch {
                self.allocator.free(owned_id);
                log.err("order_mgr", "cancelAll failed to allocate remote order id copy", .{});
                continue;
            };
            candidates.append(self.allocator, .{
                .id = owned_id,
                .remote_id = owned_remote_id,
                .should_cancel_remote = should_cancel_remote,
            }) catch {
                self.allocator.free(owned_id);
                self.allocator.free(owned_remote_id);
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
            if (candidate.should_cancel_remote and !self.cancelOnHL(candidate.remote_id)) {
                log.err("order_mgr", "cancelAll failed HL cancel for order local={s} remote={s}", .{ candidate.id, candidate.remote_id });
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
        asset_index: i64,
        market_id: []const u8,
        side: []const u8,
        size: []const u8,
        price: []const u8,
        order_type: []const u8,
        client_order_id: []const u8,
    ) !std.json.Value {
        // Phase 3: asset_index is resolved by the caller via the shared
        // hl_market_meta cache. Strings are encoded as msgpack strings for
        // size/price so the operator can pass HL's expected decimal text.
        _ = market_id;
        var orders = std.json.Array.init(arena);
        var ord = std.json.ObjectMap.init(arena);
        try ord.put("a", .{ .integer = asset_index });
        try ord.put("b", .{ .bool = std.mem.eql(u8, side, "buy") });
        try ord.put("p", .{ .string = price });
        try ord.put("s", .{ .string = size });
        try ord.put("r", .{ .bool = false }); // reduce_only
        try ord.put("c", .{ .string = client_order_id });
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

    /// Build the cancel action JSON for a single order id or HL cloid.
    fn buildCancelAction(
        arena: std.mem.Allocator,
        asset_index: i64,
        order_id: []const u8,
    ) !std.json.Value {
        var cancels = std.json.Array.init(arena);
        var item = std.json.ObjectMap.init(arena);
        const is_cloid = std.mem.startsWith(u8, order_id, "0x") and order_id.len == 34;
        if (is_cloid) {
            try item.put("asset", .{ .integer = asset_index });
            try item.put("cloid", .{ .string = order_id });
        } else {
            try item.put("a", .{ .integer = asset_index });
            try item.put("o", .{ .string = order_id });
        }
        try cancels.append(.{ .object = item });

        var action = std.json.ObjectMap.init(arena);
        try action.put("type", .{ .string = if (is_cloid) "cancelByCloid" else "cancel" });
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

    /// Phase 4: simulate a uniform-random submit→ack latency in the
    /// configured `[min, max]` ms window (inclusive). Returns the chosen
    /// delay in ms (so callers can persist/log it).
    fn simulateDryRunLatency(self: *OrderManager) u64 {
        const lo = self.config.dry_run_latency_min_ms;
        const hi_raw = self.config.dry_run_latency_max_ms;
        const hi = if (hi_raw < lo) lo else hi_raw;
        const span = hi - lo + 1;
        const delay_ms = lo + std.crypto.random.uintLessThan(u64, span);
        std.Thread.sleep(delay_ms * std.time.ns_per_ms);
        return delay_ms;
    }

    /// Phase 4: dry-run placement. Generates a synthetic order id with a
    /// `dry-` prefix, sleeps for the simulated latency, persists the row to
    /// `dry_run_orders`, and publishes the standard `event.order.placed`
    /// event. Risk-gate validation has already run in `placeOrder()`.
    fn placeDryRunOrder(
        self: *OrderManager,
        market_id: []const u8,
        side: []const u8,
        size: []const u8,
        price: []const u8,
        order_type: []const u8,
        strategy_origin: ?[]const u8,
    ) OrderResult {
        const submit_ts_ms = std.time.milliTimestamp();
        const submit_ts_ns = std.time.nanoTimestamp();

        // Synthetic order id: `dry-<ms>-<rand>`. The `dry-` prefix is the
        // signal used by tests and downstream code to distinguish simulated
        // ids from live HL `cex-` ids.
        var id_buf: [64]u8 = undefined;
        const dry_id = std.fmt.bufPrint(&id_buf, "dry-{d}-{x}", .{
            std.time.milliTimestamp(),
            std.crypto.random.int(u32),
        }) catch "dry-unknown";

        // Simulate API latency before recording the placement so that the
        // ack timestamp / `simulated_latency_ms` reflect the real wait.
        const latency_ms = self.simulateDryRunLatency();
        const ack_ts_ns = std.time.nanoTimestamp();

        // Parse string price/size into the f64 columns the dry_run_orders
        // schema expects. Failures fall back to 0 — the row still records
        // intent so the operator can see what happened.
        const price_f64: f64 = std.fmt.parseFloat(f64, price) catch 0.0;
        const size_f64: f64 = std.fmt.parseFloat(f64, size) catch 0.0;

        const strategy_name: []const u8 = strategy_origin orelse "manual";

        self.database.insertDryRunOrderAt(
            dry_id,
            market_id,
            strategy_name,
            side,
            price_f64,
            size_f64,
            submit_ts_ms,
        ) catch |e| {
            log.err("order_mgr", "dry-run insert failed for {s}: {s}", .{ dry_id, @errorName(e) });
            return .{ .failed = .{ .reason = "db_error" } };
        };

        log.info("order_mgr", "dry-run order placed: {s} {s} {s} {s}@{s} latency={d}ms submit_ts_ns={d} ack_ts_ns={d}", .{
            dry_id, market_id, side, size, price, latency_ms, submit_ts_ns, ack_ts_ns,
        });

        // Mirror the live event so dashboards / IPC consumers see no
        // difference between dry-run and live placements.
        const evt_payload = blk: {
            const payload = std.json.Stringify.valueAlloc(self.allocator, .{
                .order_id = dry_id,
                .market_id = market_id,
                .side = side,
                .size = size,
                .price = price,
                .order_type = order_type,
                .dry_run = true,
                .simulated_latency_ms = latency_ms,
            }, .{}) catch |e| {
                log.err("order_mgr", "failed to stringify event_order_placed: {s}", .{@errorName(e)});
                break :blk null;
            };
            break :blk payload;
        };
        if (evt_payload) |payload| {
            defer self.allocator.free(payload);
            ipc.publishEvent(ipc_types.T.event_order_placed, payload);
        }

        const id_owned = self.allocator.dupe(u8, dry_id) catch {
            log.err("order_mgr", "failed to allocate dry-run order_id result", .{});
            return .{ .failed = .{ .reason = "oom" } };
        };
        return .{ .success = .{ .order_id = id_owned } };
    }

    /// Phase 4: dry-run cancellation. Looks up the row in `dry_run_orders`,
    /// updates `status='cancelled'` if it is still open, and publishes the
    /// usual `event.order.cancelled`. Idempotent for already-cancelled rows.
    fn cancelDryRunOrder(self: *OrderManager, order_id: []const u8) bool {
        // Read current status so we can short-circuit on filled/cancelled.
        var current_status_buf: [32]u8 = undefined;
        var current_status_len: usize = 0;
        {
            const sql = "SELECT status FROM dry_run_orders WHERE id=? LIMIT 1;" ++ &[_:0]u8{};
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
                log.err("order_mgr", "dry-run cancel: prepare status query failed for {s}", .{order_id});
                return false;
            }
            defer _ = c.sqlite3_finalize(stmt);

            if (c.sqlite3_bind_text(stmt, 1, order_id.ptr, @intCast(order_id.len), null) != c.SQLITE_OK) {
                log.err("order_mgr", "dry-run cancel: bind id failed for {s}", .{order_id});
                return false;
            }

            switch (c.sqlite3_step(stmt)) {
                c.SQLITE_ROW => {
                    if (c.sqlite3_column_text(stmt, 0)) |p| {
                        const s = std.mem.span(@as([*c]const u8, @ptrCast(p)));
                        const n = @min(s.len, current_status_buf.len);
                        @memcpy(current_status_buf[0..n], s[0..n]);
                        current_status_len = n;
                    }
                },
                else => {
                    log.warn("order_mgr", "dry-run cancel: order {s} not found", .{order_id});
                    return false;
                },
            }
        }

        const current_status = current_status_buf[0..current_status_len];

        // Already-filled rows mirror live HL behaviour: returning true
        // matches AC-009-2 ("If already filled, no error").
        if (std.mem.eql(u8, current_status, "filled")) {
            log.info("order_mgr", "dry-run cancel ignored, order already filled: {s}", .{order_id});
            return true;
        }
        // Idempotent: cancelling an already-cancelled row is a no-op.
        if (std.mem.eql(u8, current_status, "cancelled") or std.mem.eql(u8, current_status, "expired")) {
            log.info("order_mgr", "dry-run cancel ignored, order status={s}: {s}", .{ current_status, order_id });
            return false;
        }

        self.database.updateDryRunOrderStatus(order_id, "cancelled") catch |e| {
            log.err("order_mgr", "dry-run cancel: status update failed for {s}: {s}", .{ order_id, @errorName(e) });
            return false;
        };

        log.info("order_mgr", "dry-run order cancelled: {s}", .{order_id});

        var cancel_evt_buf: [256]u8 = undefined;
        const cancel_evt_payload = std.fmt.bufPrint(
            &cancel_evt_buf,
            "{{\"order_id\":\"{s}\",\"dry_run\":true}}",
            .{order_id},
        ) catch "{}";
        ipc.publishEvent(ipc_types.T.event_order_cancelled, cancel_evt_payload);
        return true;
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
        client_order_id: []const u8,
    ) SubmitResult {
        crash_trace.breadcrumb("order_mgr", "hl submit enter market={s} side={s} size={s} price={s}", .{
            market_id[0..@min(market_id.len, 24)],
            side,
            size,
            price,
        });

        if (!self.config.hl.enabled) {
            log.warn("order_mgr", "HL submission skipped: hl.enabled=false (Phase 2 stub)", .{});
            return .{ .ok = false };
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const asset_index = self.resolveAssetIndex(market_id) orelse {
            log.err("order_mgr", "refusing HL submit without asset metadata for {s}", .{market_id});
            return .{ .ok = false };
        };
        const action = buildOrderAction(arena.allocator(), asset_index, market_id, side, size, price, order_type, client_order_id) catch |e| {
            log.err("order_mgr", "failed to build HL order action: {s}", .{@errorName(e)});
            return .{ .ok = false };
        };

        const nonce: u64 = @intCast(@max(std.time.milliTimestamp(), 1));
        const envelope = self.buildHlEnvelope(action, nonce) catch |e| {
            log.err("order_mgr", "failed to build HL signed envelope: {s}", .{@errorName(e)});
            return .{ .ok = false };
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
            return .{ .ok = false };
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
                return .{ .ok = false };
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
                var result = SubmitResult{ .ok = true };
                result.oid_len = parseHlOrderOid(response.body, &result.oid_buf);
                return result;
            }

            log.err("order_mgr", "HL rejected: status={d} body={s}", .{
                @intFromEnum(response.status), response.body,
            });
            return .{ .ok = false };
        }

        log.err("order_mgr", "HL submission failed after {d} retries", .{self.config.max_retry_attempts});
        return .{ .ok = false };
    }

    /// Cancel an order on HL via the `/exchange` endpoint.
    fn cancelOnHL(self: *OrderManager, order_id: []const u8) bool {
        if (!self.config.hl.enabled) {
            log.warn("order_mgr", "HL cancel skipped: hl.enabled=false (Phase 2 stub)", .{});
            return false;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const asset_index = self.resolveCancelAssetIndex(order_id) orelse {
            log.err("order_mgr", "refusing HL cancel without asset metadata for order {s}", .{order_id});
            return false;
        };
        const action = buildCancelAction(arena.allocator(), asset_index, order_id) catch |e| {
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

test "order_manager: parseHlOrderOid extracts resting and filled oid" {
    var resting_buf: [48]u8 = undefined;
    const resting_len = parseHlOrderOid(
        \\{"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":12345}}]}}}
    , &resting_buf);
    try std.testing.expectEqualStrings("12345", resting_buf[0..resting_len]);

    var filled_buf: [48]u8 = undefined;
    const filled_len = parseHlOrderOid(
        \\{"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"oid":"67890","totalSz":"0.01"}}]}}}
    , &filled_buf);
    try std.testing.expectEqualStrings("67890", filled_buf[0..filled_len]);
}

test "order_manager: cloid cancel uses cancelByCloid action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const action = try OrderManager.buildCancelAction(
        arena.allocator(),
        1,
        "0x00000000000000010000000000000002",
    );
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, action, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"cancelByCloid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cloid\":\"0x00000000000000010000000000000002\"") != null);
}
