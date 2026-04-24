//! JSON-lines IPC envelope types (Phase 0, v=1).
//! Both Zig and TS must agree on this schema.
const std = @import("std");

pub const VERSION: u8 = 1;

/// All message type strings used by both sides.
pub const T = struct {
    pub const heartbeat = "heartbeat";
    pub const heartbeat_response = "heartbeat.response";
    pub const status = "status";
    pub const status_response = "status.response";
    pub const portfolio = "portfolio";
    pub const portfolio_response = "portfolio.response";
    pub const orders = "orders";
    pub const orders_response = "orders.response";
    pub const config_get = "config.get";
    pub const config_get_response = "config.get.response";
    pub const logs = "logs";
    pub const logs_response = "logs.response";
    pub const err_response = "error.response";

    // Phase 1: Market data messages
    pub const market_list = "market.list";
    pub const market_list_response = "market.list.response";
    pub const orderbook_snapshot = "orderbook.snapshot";
    pub const orderbook_snapshot_response = "orderbook.snapshot.response";
    pub const price_update = "price.update";

    // Phase 2: Order/Risk/Control messages
    pub const order_place = "order.place";
    pub const order_cancel = "order.cancel";
    pub const order_cancel_all = "order.cancel_all";
    pub const halt = "halt";
    pub const @"resume" = "resume";
    pub const risk_check_response = "risk.check.response";
    pub const order_event = "order.event";
    pub const portfolio_snapshot_response = "portfolio.snapshot.response";
    pub const orders_open_response = "orders.open.response";
    pub const order_place_response = "order.place.response";
    pub const order_cancel_response = "order.cancel.response";
    pub const order_cancel_all_response = "order.cancel_all.response";
    pub const halt_response = "halt.response";
    pub const resume_response = "resume.response";

    // Phase 3: Strategy messages
    pub const strategy_enable = "strategy.enable";
    pub const strategy_disable = "strategy.disable";
    pub const strategy_list = "strategy.list";
    pub const strategy_list_response = "strategy.list.response";
    pub const strategy_enable_response = "strategy.enable.response";
    pub const strategy_disable_response = "strategy.disable.response";
    pub const strategy_signal_event = "strategy.signal.event";

    // Phase 4: Event subscription messages
    pub const event_subscribe = "event.subscribe";
    pub const event_subscribe_response = "event.subscribe.response";
    pub const event_unsubscribe = "event.unsubscribe";
    pub const event_unsubscribe_response = "event.unsubscribe.response";

    // Phase 4: Push event types (server→client, no request id correlation)
    pub const event_order_placed = "event.order.placed";
    pub const event_order_filled = "event.order.filled";
    pub const event_order_cancelled = "event.order.cancelled";
    pub const event_order_rejected = "event.order.rejected";
    pub const event_risk_rejection = "event.risk.rejection";
    pub const event_engine_halted = "event.engine.halted";
    pub const event_engine_resumed = "event.engine.resumed";

    // Phase 2: Fill detection events
    pub const event_order_partially_filled = "event.order.partially_filled";
    pub const reconcile_status = "reconcile.status";
    pub const reconcile_status_response = "reconcile.status.response";

    // Phase 3: Inventory snapshot
    pub const inventory_snapshot = "inventory.snapshot";
    pub const inventory_snapshot_response = "inventory.snapshot.response";

    // Phase 5: Config/Pause/P&L messages
    pub const config_set = "config.set";
    pub const config_set_response = "config.set.response";
    // pause is a temporary trading suspend: strategy/order placement is paused,
    // open orders are preserved, and resume is the corresponding unpause command.
    // Use pause for short-lived intervention; use halt for emergency stop/cancel-all.
    pub const pause = "pause";
    pub const pause_response = "pause.response";
    pub const pnl_query = "pnl.query";
    pub const pnl_response = "pnl.response";
    pub const config_validate = "config.validate";
    pub const config_validate_response = "config.validate.response";

    // Dry-run analysis
    pub const dry_run_analysis = "dry_run.analysis";
    pub const dry_run_analysis_response = "dry_run.analysis.response";
};

/// Write a complete JSON-lines response envelope to `writer`.
/// `payload_json` must be a valid JSON object string (e.g. `{}`).
pub fn writeResponse(
    writer: anytype,
    req_id: []const u8,
    msg_type: []const u8,
    payload_json: []const u8,
) !void {
    const ts = std.time.milliTimestamp();
    try writer.print(
        "{{\"v\":{d},\"id\":\"{s}\",\"ts\":{d},\"type\":\"{s}\",\"payload\":{s}}}\n",
        .{ VERSION, req_id, ts, msg_type, payload_json },
    );
}

/// Write an error response.
pub fn writeError(writer: anytype, req_id: []const u8, message: []const u8) !void {
    var payload_buf: [256]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &payload_buf,
        "{{\"error\":\"{s}\"}}",
        .{message},
    ) catch "{}";
    try writeResponse(writer, req_id, T.err_response, payload);
}

/// Write an event envelope (push, no request correlation).
/// Uses a monotonic counter for event IDs.
var event_counter = std.atomic.Value(u64).init(0);

pub fn writeEvent(
    writer: anytype,
    event_type: []const u8,
    payload_json: []const u8,
) !void {
    const event_seq = event_counter.fetchAdd(1, .monotonic) + 1;
    var id_buf: [32]u8 = undefined;
    const event_id = std.fmt.bufPrint(&id_buf, "evt-{d}", .{event_seq}) catch "evt-0";
    const ts = std.time.milliTimestamp();
    try writer.print(
        "{{\"v\":{d},\"id\":\"{s}\",\"ts\":{d},\"type\":\"{s}\",\"payload\":{s}}}\n",
        .{ VERSION, event_id, ts, event_type, payload_json },
    );
}
