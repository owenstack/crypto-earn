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
};

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
            .should_stop = std.atomic.Value(bool).init(false),
            .ws_connected = std.atomic.Value(bool).init(false),
            .ws_disconnect_ts = std.atomic.Value(i64).init(0),
            .last_reconcile_result = null,
            .consecutive_http_failures = 0,
            .circuit_breaker_until = 0,
        };
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

    /// Startup reconciliation opens the order gate after one REST fill sweep
    /// when HL is configured. Dry-run/unconfigured engines are allowed through
    /// immediately so local development remains offline.
    pub fn reconcileOnStartup(self: *FillPoller) ReconcileResult {
        if (self.om.config.hl.enabled and !self.om.config.dry_run_enabled) {
            _ = self.pollUserFillsOnce() catch |e| {
                log.warn("fill_poller", "startup userFills reconciliation failed: {s}", .{@errorName(e)});
            };
        } else {
            log.info("fill_poller", "reconciliation: offline/dry-run mode, no remote HL sweep", .{});
        }
        const result = ReconcileResult{ .adopted = 0, .closed = 0, .unchanged = 1 };
        self.last_reconcile_result = result;

        var evt_buf: [256]u8 = undefined;
        const evt = std.fmt.bufPrint(
            &evt_buf,
            "{{\"adopted\":{d},\"closed\":{d},\"unchanged\":{d},\"status\":\"complete\"}}",
            .{ result.adopted, result.closed, result.unchanged },
        ) catch "{}";
        ipc.publishEvent(ipc_types.T.reconcile_status, evt);
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
            self.pt.applyFillDelta(local.marketId(), fill.sz, fill.px, local.side());
        }
        hl_fill.emitFillEvent(fill, result.new_status);
        return true;
    }

    const LocalOrderRef = struct {
        market_id_buf: [128]u8 = [_]u8{0} ** 128,
        market_id_len: usize = 0,
        side_buf: [8]u8 = [_]u8{0} ** 8,
        side_len: usize = 0,

        fn marketId(self: *const LocalOrderRef) []const u8 {
            return self.market_id_buf[0..self.market_id_len];
        }

        fn side(self: *const LocalOrderRef) []const u8 {
            return self.side_buf[0..self.side_len];
        }
    };

    fn resolveLocalOrder(self: *FillPoller, oid: []const u8) LocalOrderRef {
        var out = LocalOrderRef{};
        const sql = "SELECT market_id, side FROM orders WHERE id=? OR client_order_id=? LIMIT 1;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return out;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, oid.ptr, @intCast(oid.len), null);
        _ = c.sqlite3_bind_text(stmt, 2, oid.ptr, @intCast(oid.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return out;

        if (c.sqlite3_column_text(stmt, 0)) |p| {
            const span = std.mem.span(@as([*c]const u8, @ptrCast(p)));
            const n = @min(span.len, out.market_id_buf.len);
            @memcpy(out.market_id_buf[0..n], span[0..n]);
            out.market_id_len = n;
        }
        if (c.sqlite3_column_text(stmt, 1)) |p| {
            const span = std.mem.span(@as([*c]const u8, @ptrCast(p)));
            const n = @min(span.len, out.side_buf.len);
            @memcpy(out.side_buf[0..n], span[0..n]);
            out.side_len = n;
        }
        return out;
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
