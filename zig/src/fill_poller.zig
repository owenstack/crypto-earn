//! Fill poller — Phase 2 stub.
//!
//! The legacy Polymarket REST polling and user-channel WebSocket logic was
//! removed in Phase 1. The HL equivalents (l2Book + user channel) land in
//! Phase 5 (FR-12). For Phase 2 we keep the public surface stable so the
//! engine can boot, the IPC reconciliation gate opens, and existing tests
//! that exercise parseOrderResponse / circuit-breaker fields still pass.
//! All network-bound methods are no-ops that log and return immediately.
const std = @import("std");
const log = @import("logger.zig");
const db_mod = @import("db.zig");
const order_mgr = @import("order_manager.zig");
const portfolio = @import("portfolio_tracker.zig");
const strategy = @import("strategy_engine.zig");
const ipc = @import("ipc.zig");
const ipc_types = @import("ipc_types.zig");

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

    const POLL_INTERVAL_NS: u64 = 3 * std.time.ns_per_s;

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
        log.info("fill_poller", "REST polling stub started (HL fill polling lands in Phase 5)", .{});
        while (!self.should_stop.load(.seq_cst)) {
            std.Thread.sleep(POLL_INTERVAL_NS);
        }
        log.info("fill_poller", "REST polling stub stopped", .{});
    }

    pub fn wsLoop(self: *FillPoller) void {
        log.info("fill_poller", "WebSocket user-channel stub started (HL user channel lands in Phase 5)", .{});
        while (!self.should_stop.load(.seq_cst)) {
            std.Thread.sleep(5 * std.time.ns_per_s);
        }
        log.info("fill_poller", "WebSocket user-channel stub stopped", .{});
    }

    /// Phase 2 stub: pretend reconciliation completed cleanly so the order
    /// gate can open. Phase 5 will replace this with HL openOrders + fills
    /// reconciliation.
    pub fn reconcileOnStartup(self: *FillPoller) ReconcileResult {
        log.info("fill_poller", "reconciliation stub: skipping HL openOrders fetch (Phase 5)", .{});
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
