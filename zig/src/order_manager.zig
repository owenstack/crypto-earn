//! Order manager — lifecycle management, signed CLOB submission, staleness handling.
//! Retry policy (429 backoff) is kept here, not in http_client.zig.
const std = @import("std");
const log = @import("logger.zig");
const db_mod = @import("db.zig");
const http = @import("http_client.zig");
const crypto = @import("crypto.zig");
const risk = @import("risk_gate.zig");
const ipc = @import("ipc.zig");
const ipc_types = @import("ipc_types.zig");
const c = db_mod.c;

const CLOB_API_BASE = "https://clob.polymarket.com";

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
};

pub const OrderManager = struct {
    allocator: std.mem.Allocator,
    database: *db_mod.DB,
    risk_config: risk.RiskConfig,
    config: OrderManagerConfig,
    halted: std.atomic.Value(bool),
    paused: std.atomic.Value(bool),
    should_stop: std.atomic.Value(bool),

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
        // Block if halted
        if (self.halted.load(.seq_cst)) {
            log.warn("order_mgr", "order rejected: engine is halted", .{});
            return .{ .rejected = .{ .reason = "engine_halted" } };
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

        // MANDATORY risk gate check
        const validation = risk.validateOrder(order_request, self.database, self.risk_config);
        switch (validation) {
            .reject => |rejection| {
                const reason_name = risk.rejectionReasonName(rejection.reason);
                log.warn("order_mgr", "risk gate rejected: {s}", .{reason_name});
                // Publish risk rejection event
                const rej_evt_payload = std.json.Stringify.valueAlloc(self.allocator, .{
                    .order_id = client_order_id,
                    .market_id = market_id,
                    .side = side,
                    .check_name = rejection.check_name,
                    .reason = reason_name,
                }, .{}) catch |e| {
                    log.err("order_mgr", "failed to serialize risk rejection event: {s}", .{@errorName(e)});
                    return .{ .rejected = .{ .reason = reason_name } };
                };
                defer self.allocator.free(rej_evt_payload);
                ipc.publishEvent(ipc_types.T.event_risk_rejection, rej_evt_payload);
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

        // Submit to CLOB with 429 retry
        const submit_result = self.submitToCLOB(market_id, side, size, price, order_type, client_order_id);
        if (!submit_result) {
            self.database.updateOrderStatus(client_order_id, "rejected") catch {};
            return .{ .failed = .{ .reason = "clob_submission_failed" } };
        }

        // Update status to placed
        self.database.updateOrderStatus(client_order_id, "placed") catch |e| {
            log.err("order_mgr", "failed to mark order as placed in DB: order_id={s} err={any}", .{ client_order_id, e });
            return .{ .failed = .{ .reason = "db_status_update_failed" } };
        };
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
        if (!self.cancelOnCLOB(order_id)) {
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

        const select_sql = "SELECT id FROM orders WHERE status NOT IN ('filled','cancelled','rejected');" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, select_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("order_mgr", "cancelAll failed: unable to prepare open-order query", .{});
            return pre_open_count;
        }
        defer _ = c.sqlite3_finalize(stmt);

        var order_ids: std.ArrayList([]u8) = .empty;
        defer {
            for (order_ids.items) |id| self.allocator.free(id);
            order_ids.deinit(self.allocator);
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const order_id_raw = c.sqlite3_column_text(stmt, 0);
            const order_id_ptr: [*c]const u8 = @ptrCast(order_id_raw orelse @as([*c]const u8, ""));
            const order_id = std.mem.span(order_id_ptr);
            if (order_id.len == 0) continue;

            const owned_id = self.allocator.dupe(u8, order_id) catch {
                log.err("order_mgr", "cancelAll failed to allocate order id copy", .{});
                continue;
            };
            order_ids.append(self.allocator, owned_id) catch {
                self.allocator.free(owned_id);
                log.err("order_mgr", "cancelAll failed to append order id", .{});
                continue;
            };
        }

        var cancelled_count: u32 = 0;
        for (order_ids.items) |order_id| {
            if (!self.cancelOnCLOB(order_id)) {
                log.err("order_mgr", "cancelAll failed CLOB cancel for order {s}", .{order_id});
                continue;
            }

            const escaped_order_id = escapeSqlLiteral(self.allocator, order_id) catch {
                log.err("order_mgr", "cancelAll failed to escape order id {s}", .{order_id});
                continue;
            };

            const update_sql = std.fmt.allocPrintSentinel(
                self.allocator,
                "UPDATE orders SET status='cancelled', updated_at=unixepoch() WHERE id='{s}';",
                .{escaped_order_id},
                0,
            ) catch {
                self.allocator.free(escaped_order_id);
                log.err("order_mgr", "cancelAll failed to build UPDATE for order {s}", .{order_id});
                continue;
            };

            self.database.execZ(update_sql) catch |e| {
                self.allocator.free(update_sql);
                self.allocator.free(escaped_order_id);
                log.err("order_mgr", "cancelAll DB update failed for order {s}: {any}", .{ order_id, e });
                continue;
            };

            self.allocator.free(update_sql);
            self.allocator.free(escaped_order_id);

            cancelled_count += 1;
        }

        log.info("order_mgr", "cancelAll complete: open_before={d} cancelled={d}", .{ pre_open_count, cancelled_count });
        return cancelled_count;
    }

    /// Scan for stale GTC orders older than max_order_age_hours and cancel them.
    pub fn scanStaleOrders(self: *OrderManager) void {
        const max_age_seconds: i64 = @as(i64, @intCast(self.config.max_order_age_hours)) * 3600;
        const cutoff = std.time.timestamp() - max_age_seconds;

        const sql = "SELECT id FROM orders WHERE status='placed' AND created_at < ?;" ++ &[_:0]u8{};
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

        var cancelled_count: u32 = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const order_id_raw = c.sqlite3_column_text(stmt, 0);
            const order_id_ptr: [*c]const u8 = @ptrCast(order_id_raw orelse @as([*c]const u8, ""));
            const order_id = std.mem.span(order_id_ptr);
            if (order_id.len == 0) continue;

            if (!self.cancelOnCLOB(order_id)) {
                log.err("order_mgr", "failed stale-order cancel on CLOB: {s}", .{order_id});
                continue;
            }

            const escaped_order_id = escapeSqlLiteral(self.allocator, order_id) catch {
                log.err("order_mgr", "failed to escape stale-order id for DB update: {s}", .{order_id});
                continue;
            };
            defer self.allocator.free(escaped_order_id);

            const update_sql = std.fmt.allocPrintSentinel(
                self.allocator,
                "UPDATE orders SET status='cancelled', updated_at=unixepoch() WHERE id='{s}';",
                .{escaped_order_id},
                0,
            ) catch {
                log.err("order_mgr", "failed to build stale-order update SQL: {s}", .{order_id});
                continue;
            };
            defer self.allocator.free(update_sql);

            self.database.execZ(update_sql) catch |e| {
                log.err("order_mgr", "failed DB update after stale-order cancel {s}: {any}", .{ order_id, e });
                continue;
            };

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

    /// Submit order to CLOB REST API with 429 exponential backoff.
    /// Backoff schedule: 1s, 2s, 4s, 8s, 16s, 32s, 60s (capped).
    /// Returns true on success, false on failure after exhausting retries.
    fn submitToCLOB(
        self: *OrderManager,
        market_id: []const u8,
        side: []const u8,
        size: []const u8,
        price: []const u8,
        order_type: []const u8,
        client_order_id: []const u8,
    ) bool {
        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        // Build order JSON payload with proper escaping.
        const order_payload = struct {
            market: []const u8,
            side: []const u8,
            size: []const u8,
            price: []const u8,
            type: []const u8,
            client_order_id: []const u8,
        }{
            .market = market_id,
            .side = side,
            .size = size,
            .price = price,
            .type = order_type,
            .client_order_id = client_order_id,
        };

        const json_body = std.json.Stringify.valueAlloc(self.allocator, order_payload, .{}) catch |e| {
            log.err("order_mgr", "failed to stringify order JSON: {s}", .{@errorName(e)});
            return false;
        };
        defer self.allocator.free(json_body);

        const url = CLOB_API_BASE ++ "/order";

        var delay_ms: u64 = 1000; // Start at 1 second
        const max_delay_ms: u64 = 60_000; // Cap at 60 seconds

        var attempt: u32 = 0;
        while (attempt < self.config.max_retry_attempts) : (attempt += 1) {
            var response = client.postJson(url, json_body) catch |e| {
                if (e == error.ClientError) {
                    // Could be a 429 - apply backoff
                    log.warn("order_mgr", "CLOB 429/client error, backoff {d}ms (attempt {d}/{d})", .{
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
                log.info("order_mgr", "CLOB order submitted successfully", .{});
                return true;
            }

            log.err("order_mgr", "CLOB unexpected status: {d}", .{@intFromEnum(response.status)});
            return false;
        }

        log.err("order_mgr", "CLOB submission failed after {d} retries", .{self.config.max_retry_attempts});
        return false;
    }

    /// Cancel order on CLOB API before mutating local state.
    fn cancelOnCLOB(self: *OrderManager, order_id: []const u8) bool {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const url = CLOB_API_BASE ++ "/order/cancel";

        var ts_buf: [32]u8 = undefined;
        const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch {
            log.err("order_mgr", "failed to format cancel timestamp", .{});
            return false;
        };

        var payload_buf: [256]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "{{\"order_id\":\"{s}\",\"timestamp\":\"{s}\"}}", .{ order_id, ts }) catch {
            log.err("order_mgr", "failed to format cancel payload", .{});
            return false;
        };

        const digest = crypto.Keccak256.hash(payload);
        const sig = crypto.signEip712(digest, self.config.private_key) catch |e| {
            log.err("order_mgr", "failed to sign cancel payload: {s}", .{@errorName(e)});
            return false;
        };

        var sig_bytes: [65]u8 = undefined;
        @memcpy(sig_bytes[0..32], sig.r[0..32]);
        @memcpy(sig_bytes[32..64], sig.s[0..32]);
        sig_bytes[64] = sig.v;

        var sig_hex_body: [130]u8 = undefined;
        _ = bytesToHex(sig_bytes[0..], sig_hex_body[0..]);
        var sig_hdr_buf: [132]u8 = undefined;
        sig_hdr_buf[0] = '0';
        sig_hdr_buf[1] = 'x';
        @memcpy(sig_hdr_buf[2..], sig_hex_body[0..]);

        const uri = std.Uri.parse(url) catch {
            log.err("order_mgr", "invalid cancel URL: {s}", .{url});
            return false;
        };

        var delay_ms: u64 = 1000;
        const max_delay_ms: u64 = 60_000;

        var attempt: u32 = 0;
        while (attempt < self.config.max_retry_attempts) : (attempt += 1) {
            var body_writer = std.Io.Writer.Allocating.init(self.allocator);
            defer body_writer.deinit();

            const result = client.fetch(.{
                .location = .{ .uri = uri },
                .method = .POST,
                .payload = payload,
                .response_writer = &body_writer.writer,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/json" },
                    .{ .name = "POLY_TIMESTAMP", .value = ts },
                    .{ .name = "POLY_SIGNATURE", .value = sig_hdr_buf[0..] },
                },
            }) catch |e| {
                log.err("order_mgr", "CLOB cancel request failed: {s}", .{@errorName(e)});
                return false;
            };

            if (result.status == .too_many_requests) {
                log.warn("order_mgr", "CLOB cancel 429, backoff {d}ms (attempt {d}/{d})", .{
                    delay_ms, attempt + 1, self.config.max_retry_attempts,
                });
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                delay_ms = @min(delay_ms * 2, max_delay_ms);
                continue;
            }

            if (result.status.class() != .success) {
                log.err("order_mgr", "CLOB cancel unexpected status: {d}", .{@intFromEnum(result.status)});
                return false;
            }

            const body = body_writer.toOwnedSlice() catch {
                log.err("order_mgr", "failed to read CLOB cancel response body", .{});
                return false;
            };
            defer self.allocator.free(body);

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
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

fn escapeSqlLiteral(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (input) |ch| {
        if (ch == '\'') {
            try out.append(allocator, '\'');
            try out.append(allocator, '\'');
        } else {
            try out.append(allocator, ch);
        }
    }

    return out.toOwnedSlice(allocator);
}
