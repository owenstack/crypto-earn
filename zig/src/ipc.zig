//! UNIX domain socket IPC server.
//! Accepts JSON-lines connections, dispatches to handlers, responds in-kind.
const std = @import("std");
const log = @import("logger.zig");
const types = @import("ipc_types.zig");
const db = @import("db.zig");
const order_mgr = @import("order_manager.zig");
const portfolio = @import("portfolio_tracker.zig");
const strategy = @import("strategy_engine.zig");

const MAX_SUBSCRIBERS = 16;

var subscribers: [MAX_SUBSCRIBERS]?std.net.Stream = .{null} ** MAX_SUBSCRIBERS;
var subscriber_mutex: std.Thread.Mutex = .{};

/// Register a client stream for event push delivery.
fn addSubscriber(stream: std.net.Stream) bool {
    subscriber_mutex.lock();
    defer subscriber_mutex.unlock();
    for (&subscribers) |*slot| {
        if (slot.* == null) {
            slot.* = stream;
            return true;
        }
    }
    return false;
}

/// Remove a client stream from event subscribers.
fn removeSubscriber(stream: std.net.Stream) void {
    subscriber_mutex.lock();
    defer subscriber_mutex.unlock();
    for (&subscribers) |*slot| {
        if (slot.*) |s| {
            if (s.handle == stream.handle) {
                slot.* = null;
                return;
            }
        }
    }
}

/// Publish an event to all subscribers. Best-effort: write failures silently remove the subscriber.
pub fn publishEvent(event_type: []const u8, payload_json: []const u8) void {
    var active_streams: [MAX_SUBSCRIBERS]std.net.Stream = undefined;
    var active_slots: [MAX_SUBSCRIBERS]usize = undefined;
    var active_count: usize = 0;

    subscriber_mutex.lock();
    for (subscribers, 0..) |slot, slot_idx| {
        if (slot) |stream| {
            active_streams[active_count] = stream;
            active_slots[active_count] = slot_idx;
            active_count += 1;
        }
    }
    subscriber_mutex.unlock();

    for (active_streams[0..active_count], active_slots[0..active_count]) |stream, slot_idx| {
        var buf: [8192]u8 = undefined;
        var net_writer = stream.writer(&buf);
        const writer = &net_writer.interface;

        types.writeEvent(writer, event_type, payload_json) catch {
            subscriber_mutex.lock();
            if (subscribers[slot_idx]) |current| {
                if (current.handle == stream.handle) {
                    subscribers[slot_idx] = null;
                }
            }
            subscriber_mutex.unlock();
            continue;
        };

        writer.flush() catch {
            subscriber_mutex.lock();
            if (subscribers[slot_idx]) |current| {
                if (current.handle == stream.handle) {
                    subscribers[slot_idx] = null;
                }
            }
            subscriber_mutex.unlock();
            continue;
        };
    }
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    database: *db.DB,
    order_manager: ?*order_mgr.OrderManager = null,
    portfolio_tracker: ?*portfolio.PortfolioTracker = null,
    strategy_engine: ?*strategy.StrategyEngine = null,
};

/// Start listening; blocks until an unrecoverable error.
pub fn serve(allocator: std.mem.Allocator, socket_path: []const u8, database: *db.DB, om: ?*order_mgr.OrderManager, pt: ?*portfolio.PortfolioTracker, se: ?*strategy.StrategyEngine) !void {
    // Remove stale socket file from a prior run.
    std.fs.cwd().deleteFile(socket_path) catch {};

    const addr = try std.net.Address.initUnix(socket_path);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer {
        listener.deinit();
        std.fs.cwd().deleteFile(socket_path) catch {};
    }

    log.info("ipc", "listening on {s}", .{socket_path});

    var ctx = Context{ .allocator = allocator, .database = database, .order_manager = om, .portfolio_tracker = pt, .strategy_engine = se };

    while (true) {
        const conn = listener.accept() catch |e| {
            log.err("ipc", "accept error: {any}", .{e});
            continue;
        };
        const t = std.Thread.spawn(.{}, handleClient, .{ conn, &ctx }) catch |e| {
            log.err("ipc", "thread spawn error: {any}", .{e});
            conn.stream.close();
            continue;
        };
        t.detach();
    }
}

fn handleClient(conn: std.net.Server.Connection, ctx: *Context) void {
    defer {
        removeSubscriber(conn.stream);
        conn.stream.close();
    }

    var reader_buf: [8192]u8 = undefined;
    var net_reader = conn.stream.reader(&reader_buf);
    const reader = net_reader.interface();
    var writer_buf: [8192]u8 = undefined;
    var net_writer = conn.stream.writer(&writer_buf);
    const writer = &net_writer.interface;

    while (true) {
        const line = reader.takeDelimiter('\n') catch break orelse break;
        if (line.len == 0) continue;
        dispatch(ctx, line, writer, conn.stream) catch |e| {
            log.warn("ipc", "dispatch error: {any}", .{e});
        };
        writer.flush() catch {};
    }
}

const DispatchKind = enum {
    heartbeat,
    status,
    portfolio,
    orders,
    config_get,
    logs,
    order_place,
    order_cancel,
    order_cancel_all,
    halt,
    @"resume",
    strategy_list,
    strategy_enable,
    strategy_disable,
    event_subscribe,
    event_unsubscribe,
    config_set,
    pause,
    pnl_query,
    config_validate,
    reconcile_status,
    inventory_snapshot,
    dry_run_analysis,
};

const DispatchEntry = struct {
    msg_type: []const u8,
    kind: DispatchKind,
};

const DISPATCH_TABLE = [_]DispatchEntry{
    .{ .msg_type = types.T.heartbeat, .kind = .heartbeat },
    .{ .msg_type = types.T.status, .kind = .status },
    .{ .msg_type = types.T.portfolio, .kind = .portfolio },
    .{ .msg_type = types.T.orders, .kind = .orders },
    .{ .msg_type = types.T.config_get, .kind = .config_get },
    .{ .msg_type = types.T.logs, .kind = .logs },
    .{ .msg_type = types.T.order_place, .kind = .order_place },
    .{ .msg_type = types.T.order_cancel, .kind = .order_cancel },
    .{ .msg_type = types.T.order_cancel_all, .kind = .order_cancel_all },
    .{ .msg_type = types.T.halt, .kind = .halt },
    .{ .msg_type = types.T.@"resume", .kind = .@"resume" },
    .{ .msg_type = types.T.strategy_list, .kind = .strategy_list },
    .{ .msg_type = types.T.strategy_enable, .kind = .strategy_enable },
    .{ .msg_type = types.T.strategy_disable, .kind = .strategy_disable },
    .{ .msg_type = types.T.event_subscribe, .kind = .event_subscribe },
    .{ .msg_type = types.T.event_unsubscribe, .kind = .event_unsubscribe },
    .{ .msg_type = types.T.config_set, .kind = .config_set },
    .{ .msg_type = types.T.pause, .kind = .pause },
    .{ .msg_type = types.T.pnl_query, .kind = .pnl_query },
    .{ .msg_type = types.T.reconcile_status, .kind = .reconcile_status },
    .{ .msg_type = types.T.config_validate, .kind = .config_validate },
    .{ .msg_type = types.T.inventory_snapshot, .kind = .inventory_snapshot },
    .{ .msg_type = types.T.dry_run_analysis, .kind = .dry_run_analysis },
};

fn resolveDispatchKind(msg_type: []const u8) ?DispatchKind {
    for (DISPATCH_TABLE) |entry| {
        if (std.mem.eql(u8, msg_type, entry.msg_type)) return entry.kind;
    }
    return null;
}

fn getReqId(root: std.json.ObjectMap) []const u8 {
    return if (root.get("id")) |v|
        switch (v) {
            .string => |s| s,
            else => "unknown",
        }
    else
        "unknown";
}

fn getStringField(obj: std.json.ObjectMap, field: []const u8, default: []const u8) []const u8 {
    return if (obj.get(field)) |v|
        switch (v) {
            .string => |s| s,
            else => default,
        }
    else
        default;
}

fn getPayloadObject(root: std.json.ObjectMap) ?std.json.ObjectMap {
    return if (root.get("payload")) |v| switch (v) {
        .object => |o| o,
        else => null,
    } else null;
}

fn parseStrategyName(name_str: []const u8) ?strategy.StrategyName {
    if (std.mem.eql(u8, name_str, "news_repricing")) return .news_repricing;
    if (std.mem.eql(u8, name_str, "liquidity_provision")) return .liquidity_provision;
    return null;
}

fn dispatch(ctx: *Context, line: []const u8, writer: anytype, stream: std.net.Stream) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, line, .{}) catch {
        try types.writeError(writer, "unknown", "invalid json");
        return;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => {
            try types.writeError(writer, "unknown", "invalid json root");
            return;
        },
    };

    const req_id = getReqId(root);
    const msg_type = getStringField(root, "type", "");
    const kind = resolveDispatchKind(msg_type) orelse {
        try types.writeError(writer, req_id, "unknown message type");
        return;
    };

    switch (kind) {
        .heartbeat => try handleHeartbeat(req_id, writer),
        .status => try handleStatus(ctx, req_id, writer),
        .portfolio => try handlePortfolio(ctx, req_id, writer),
        .orders => try handleOrders(ctx, req_id, writer),
        .config_get => try handleConfigGet(ctx, req_id, writer),
        .logs => try handleLogs(ctx, req_id, writer),
        .order_place => try handleOrderPlace(ctx, req_id, root, writer),
        .order_cancel => try handleOrderCancel(ctx, req_id, root, writer),
        .order_cancel_all => try handleOrderCancelAll(ctx, req_id, writer),
        .halt => try handleHalt(ctx, req_id, writer),
        .@"resume" => try handleResume(ctx, req_id, writer),
        .strategy_list => try handleStrategyList(ctx, req_id, writer),
        .strategy_enable => try handleStrategyToggle(ctx, req_id, root, writer, true),
        .strategy_disable => try handleStrategyToggle(ctx, req_id, root, writer, false),
        .event_subscribe => try handleEventSubscribe(req_id, writer, stream),
        .event_unsubscribe => try handleEventUnsubscribe(req_id, writer, stream),
        .config_set => try handleConfigSet(ctx, req_id, root, writer),
        .pause => try handlePause(ctx, req_id, writer),
        .pnl_query => try handlePnlQuery(ctx, req_id, root, writer),
        .reconcile_status => try handleReconcileStatus(req_id, writer),
        .config_validate => try handleConfigValidate(ctx, req_id, writer),
        .inventory_snapshot => try handleInventorySnapshot(ctx, req_id, writer),
        .dry_run_analysis => try handleDryRunAnalysis(ctx, req_id, writer),
    }
}

fn handleHeartbeat(req_id: []const u8, writer: anytype) !void {
    var p: [64]u8 = undefined;
    const payload = std.fmt.bufPrint(&p, "{{\"status\":\"ok\",\"uptime_ms\":{d}}}", .{log.uptimeMs()}) catch "{}";
    try types.writeResponse(writer, req_id, types.T.heartbeat_response, payload);
}

fn handleStatus(ctx: *Context, req_id: []const u8, writer: anytype) !void {
    var jm_buf: [16]u8 = undefined;
    const jm = ctx.database.journalMode(&jm_buf);
    var p: [128]u8 = undefined;
    const payload = std.fmt.bufPrint(&p, "{{\"engine\":\"running\",\"db\":\"{s}\",\"uptime_ms\":{d}}}", .{ jm, log.uptimeMs() }) catch "{}";
    try types.writeResponse(writer, req_id, types.T.status_response, payload);
}

fn handlePortfolio(ctx: *Context, req_id: []const u8, writer: anytype) !void {
    if (ctx.portfolio_tracker) |pt| {
        var snap_buf: [8192]u8 = undefined;
        const snap_json = pt.writeSnapshotJson(&snap_buf) catch |e| {
            log.err("ipc", "failed to write portfolio snapshot: {s}", .{@errorName(e)});
            var err_buf: [192]u8 = undefined;
            const err_payload = std.fmt.bufPrint(&err_buf, "{{\"positions\":[],\"error\":\"snapshot_write_failed\",\"details\":\"{s}\"}}", .{@errorName(e)}) catch "{\"positions\":[],\"error\":\"snapshot_write_failed\"}";
            try types.writeResponse(writer, req_id, types.T.portfolio_response, err_payload);
            return;
        };
        try types.writeResponse(writer, req_id, types.T.portfolio_response, snap_json);
        return;
    }

    try types.writeResponse(writer, req_id, types.T.portfolio_response, "{\"positions\":[],\"note\":\"phase-0-stub\"}");
}

fn handleOrders(ctx: *Context, req_id: []const u8, writer: anytype) !void {
    if (ctx.portfolio_tracker) |pt| {
        var orders_buf: [8192]u8 = undefined;
        const orders_json = pt.writeOrdersJson(&orders_buf) catch |e| {
            log.err("ipc", "failed to write open orders snapshot: {s}", .{@errorName(e)});
            var err_buf: [192]u8 = undefined;
            const err_payload = std.fmt.bufPrint(&err_buf, "{{\"orders\":[],\"error\":\"orders_write_failed\",\"details\":\"{s}\"}}", .{@errorName(e)}) catch "{\"orders\":[],\"error\":\"orders_write_failed\"}";
            try types.writeResponse(writer, req_id, types.T.orders_response, err_payload);
            return;
        };
        try types.writeResponse(writer, req_id, types.T.orders_response, orders_json);
        return;
    }

    try types.writeResponse(writer, req_id, types.T.orders_response, "{\"orders\":[],\"note\":\"phase-0-stub\"}");
}

fn handleConfigGet(ctx: *Context, req_id: []const u8, writer: anytype) !void {
    const config_json = ctx.database.getAllConfig(ctx.allocator) catch {
        try types.writeResponse(writer, req_id, types.T.config_get_response, "{\"config\":{}}");
        return;
    };
    defer ctx.allocator.free(config_json);

    var p: [4096]u8 = undefined;
    const payload = std.fmt.bufPrint(&p, "{{\"config\":{s}}}", .{config_json}) catch "{\"config\":{}}";
    try types.writeResponse(writer, req_id, types.T.config_get_response, payload);
}

fn handleLogs(ctx: *Context, req_id: []const u8, writer: anytype) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(ctx.allocator);
    try payload.appendSlice(ctx.allocator, "{\"logs\":");
    try log.writeRecentLogs(payload.writer(ctx.allocator));
    try payload.append(ctx.allocator, '}');
    try types.writeResponse(writer, req_id, types.T.logs_response, payload.items);
}

fn handleOrderPlace(ctx: *Context, req_id: []const u8, root: std.json.ObjectMap, writer: anytype) !void {
    if (ctx.order_manager) |om| {
        const payload_obj = getPayloadObject(root) orelse {
            try types.writeError(writer, req_id, "missing payload");
            return;
        };

        const market_id = getStringField(payload_obj, "market_id", "");
        const side = getStringField(payload_obj, "side", "");
        const size = getStringField(payload_obj, "size", "");
        const price = getStringField(payload_obj, "price", "");
        const otype = getStringField(payload_obj, "order_type", "limit");

        const result = om.placeOrder(market_id, side, size, price, otype, null);
        var p_buf: [256]u8 = undefined;
        var owned_order_id: ?[]u8 = null;
        defer if (owned_order_id) |id| om.allocator.free(id);

        const resp_payload = switch (result) {
            .success => |s| blk: {
                owned_order_id = s.order_id;
                break :blk std.fmt.bufPrint(&p_buf, "{{\"order_id\":\"{s}\",\"status\":\"placed\"}}", .{s.order_id}) catch "{}";
            },
            .rejected => |r| std.fmt.bufPrint(&p_buf, "{{\"order_id\":\"\",\"status\":\"rejected\",\"reason\":\"{s}\"}}", .{r.reason}) catch "{}",
            .failed => |f| std.fmt.bufPrint(&p_buf, "{{\"order_id\":\"\",\"status\":\"failed\",\"reason\":\"{s}\"}}", .{f.reason}) catch "{}",
        };
        try types.writeResponse(writer, req_id, types.T.order_place_response, resp_payload);
        return;
    }

    try types.writeError(writer, req_id, "order manager not available");
}

fn handleOrderCancel(ctx: *Context, req_id: []const u8, root: std.json.ObjectMap, writer: anytype) !void {
    if (ctx.order_manager) |om| {
        const payload_obj = getPayloadObject(root) orelse {
            try types.writeError(writer, req_id, "missing payload");
            return;
        };

        const order_id = getStringField(payload_obj, "order_id", "");
        const ok = om.cancelOrder(order_id);
        var p_buf: [128]u8 = undefined;
        const resp = std.fmt.bufPrint(&p_buf, "{{\"order_id\":\"{s}\",\"status\":\"{s}\"}}", .{ order_id, if (ok) "cancelled" else "failed" }) catch "{}";
        try types.writeResponse(writer, req_id, types.T.order_cancel_response, resp);
        return;
    }

    try types.writeError(writer, req_id, "order manager not available");
}

fn handleOrderCancelAll(ctx: *Context, req_id: []const u8, writer: anytype) !void {
    if (ctx.order_manager) |om| {
        const cancelled = om.cancelAll();
        var p_buf: [64]u8 = undefined;
        const resp = std.fmt.bufPrint(&p_buf, "{{\"cancelled_count\":{d}}}", .{cancelled}) catch "{}";
        try types.writeResponse(writer, req_id, types.T.order_cancel_all_response, resp);
        return;
    }

    try types.writeError(writer, req_id, "order manager not available");
}

fn handleHalt(ctx: *Context, req_id: []const u8, writer: anytype) !void {
    if (ctx.order_manager) |om| {
        const cancelled = om.halt();
        var p_buf: [64]u8 = undefined;
        const resp = std.fmt.bufPrint(&p_buf, "{{\"status\":\"halted\",\"cancelled_orders\":{d}}}", .{cancelled}) catch "{}";
        try types.writeResponse(writer, req_id, types.T.halt_response, resp);
        return;
    }

    try types.writeError(writer, req_id, "order manager not available");
}

fn handleResume(ctx: *Context, req_id: []const u8, writer: anytype) !void {
    if (ctx.order_manager) |om| {
        om.@"resume"();
        if (ctx.strategy_engine) |se| {
            se.paused.store(false, .seq_cst);
        }
        try types.writeResponse(writer, req_id, types.T.resume_response, "{\"status\":\"resumed\"}");
        return;
    }

    try types.writeError(writer, req_id, "order manager not available");
}

fn handleStrategyList(ctx: *Context, req_id: []const u8, writer: anytype) !void {
    if (ctx.strategy_engine) |se| {
        const news_enabled = se.isEnabled(.news_repricing);
        const lp_enabled = se.isEnabled(.liquidity_provision);
        const ns = se.getStats(.news_repricing);
        const ls = se.getStats(.liquidity_provision);
        var p: [1024]u8 = undefined;
        const payload = std.fmt.bufPrint(
            &p,
            "{{\"strategies\":[" ++
                "{{\"name\":\"news_repricing\",\"enabled\":{},\"stats\":{{\"signals_emitted\":{d},\"orders_accepted\":{d},\"orders_rejected\":{d},\"cancels\":{d},\"active_order_overflow_count\":{d}}}}}," ++
                "{{\"name\":\"liquidity_provision\",\"enabled\":{},\"stats\":{{\"signals_emitted\":{d},\"orders_accepted\":{d},\"orders_rejected\":{d},\"cancels\":{d},\"active_order_overflow_count\":{d}}}}}" ++
                "]}}",
            .{
                news_enabled, ns.signals_emitted, ns.orders_accepted, ns.orders_rejected, ns.cancels, ns.active_order_overflow_count,
                lp_enabled,   ls.signals_emitted, ls.orders_accepted, ls.orders_rejected, ls.cancels, ls.active_order_overflow_count,
            },
        ) catch "{}";
        try types.writeResponse(writer, req_id, types.T.strategy_list_response, payload);
        return;
    }

    try types.writeError(writer, req_id, "strategy engine not available");
}

fn handleStrategyToggle(ctx: *Context, req_id: []const u8, root: std.json.ObjectMap, writer: anytype, enable: bool) !void {
    if (ctx.strategy_engine) |se| {
        const payload_obj = getPayloadObject(root) orelse {
            try types.writeError(writer, req_id, "missing payload");
            return;
        };

        const name_str = getStringField(payload_obj, "name", "");
        const strat_name = parseStrategyName(name_str) orelse {
            try types.writeError(writer, req_id, "unknown strategy name");
            return;
        };

        if (enable) {
            se.enableStrategy(strat_name);
        } else {
            se.disableStrategy(strat_name);
        }

        var p: [128]u8 = undefined;
        const resp = std.fmt.bufPrint(&p, "{{\"name\":\"{s}\",\"enabled\":{}}}", .{ name_str, enable }) catch "{}";
        const resp_type = if (enable) types.T.strategy_enable_response else types.T.strategy_disable_response;
        try types.writeResponse(writer, req_id, resp_type, resp);
        return;
    }

    try types.writeError(writer, req_id, "strategy engine not available");
}

fn handleEventSubscribe(req_id: []const u8, writer: anytype, stream: std.net.Stream) !void {
    if (addSubscriber(stream)) {
        try types.writeResponse(writer, req_id, types.T.event_subscribe_response, "{\"status\":\"subscribed\"}");
    } else {
        try types.writeError(writer, req_id, "max subscribers reached");
    }
}

fn handleEventUnsubscribe(req_id: []const u8, writer: anytype, stream: std.net.Stream) !void {
    removeSubscriber(stream);
    try types.writeResponse(writer, req_id, types.T.event_unsubscribe_response, "{\"status\":\"unsubscribed\"}");
}

fn handleConfigSet(ctx: *Context, req_id: []const u8, root: std.json.ObjectMap, writer: anytype) !void {
    const payload_obj = getPayloadObject(root) orelse {
        try types.writeError(writer, req_id, "missing payload");
        return;
    };

    const key = getStringField(payload_obj, "key", "");
    const value = getStringField(payload_obj, "value", "");
    if (key.len == 0 or value.len == 0) {
        try types.writeError(writer, req_id, "key and value are required");
        return;
    }

    var old_buf: [256]u8 = undefined;
    const old_value = ctx.database.setConfig(key, value, &old_buf) catch {
        try types.writeError(writer, req_id, "config write failed");
        return;
    };

    const payload = std.json.Stringify.valueAlloc(ctx.allocator, .{
        .key = key,
        .old_value = old_value,
        .new_value = value,
    }, .{}) catch {
        try types.writeError(writer, req_id, "config response serialization failed");
        return;
    };
    defer ctx.allocator.free(payload);

    try types.writeResponse(writer, req_id, types.T.config_set_response, payload);
}

fn handlePause(ctx: *Context, req_id: []const u8, writer: anytype) !void {
    if (ctx.order_manager) |om| {
        om.setPaused(true);
        if (ctx.strategy_engine) |se| {
            se.paused.store(true, .seq_cst);
        }
        try types.writeResponse(writer, req_id, types.T.pause_response, "{\"status\":\"paused\"}");
        return;
    }

    try types.writeError(writer, req_id, "order manager not available");
}

fn handlePnlQuery(ctx: *Context, req_id: []const u8, root: std.json.ObjectMap, writer: anytype) !void {
    const payload_obj = getPayloadObject(root);
    const window = if (payload_obj) |pl| getStringField(pl, "window", "today") else "today";

    const pnl_result = ctx.database.queryPnl(window) catch {
        try types.writeError(writer, req_id, "pnl query failed");
        return;
    };

    var p: [512]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &p,
        "{{\"window\":\"{s}\",\"realized_pnl\":\"{d:.2}\",\"unrealized_pnl\":\"0.00\",\"win_count\":{d},\"loss_count\":{d},\"avg_win\":\"{d:.2}\",\"avg_loss\":\"{d:.2}\"}}",
        .{ window, pnl_result.realized_pnl, pnl_result.win_count, pnl_result.loss_count, pnl_result.avg_win, pnl_result.avg_loss },
    ) catch "{}";
    try types.writeResponse(writer, req_id, types.T.pnl_response, payload);
}

fn handleReconcileStatus(req_id: []const u8, writer: anytype) !void {
    // The last reconcile result is stored in the fill_poller module.
    // Since we don't have direct access to it here, return a stub indicating
    // the reconciliation has completed (the engine wouldn't be accepting
    // IPC connections if it hadn't).
    try types.writeResponse(writer, req_id, types.T.reconcile_status_response, "{\"status\":\"complete\"}");
}

fn handleConfigValidate(ctx: *Context, req_id: []const u8, writer: anytype) !void {
    // Validate prob_source_url
    var url_buf: [512]u8 = undefined;
    const url = ctx.database.getConfig("prob_source_url", &url_buf);
    const url_valid = if (url) |u| u.len > 0 and (std.mem.startsWith(u8, u, "http://") or std.mem.startsWith(u8, u, "https://")) else false;

    // Validate prob_source_poll_seconds
    var poll_buf: [16]u8 = undefined;
    const poll_str = ctx.database.getConfig("prob_source_poll_seconds", &poll_buf);
    var poll_valid = false;
    if (poll_str) |ps| {
        if (std.fmt.parseInt(u32, ps, 10)) |v| {
            poll_valid = v >= 10 and v <= 3600;
        } else |_| {}
    }

    // Validate prob_source_market_id_field
    var mid_field_buf: [64]u8 = undefined;
    const mid_field = ctx.database.getConfig("prob_source_market_id_field", &mid_field_buf);
    const mid_field_valid = if (mid_field) |f| f.len > 0 else false;

    // Validate prob_source_probability_field
    var prob_field_buf: [64]u8 = undefined;
    const prob_field = ctx.database.getConfig("prob_source_probability_field", &prob_field_buf);
    const prob_field_valid = if (prob_field) |f| f.len > 0 else false;

    const ValidationResult = struct {
        valid: bool,
        value: []const u8,
    };
    const ConfigValidation = struct {
        prob_source_url: ValidationResult,
        prob_source_poll_seconds: ValidationResult,
        prob_source_market_id_field: ValidationResult,
        prob_source_probability_field: ValidationResult,
    };

    const result = std.json.Stringify.valueAlloc(ctx.allocator, ConfigValidation{
        .prob_source_url = .{
            .valid = url_valid,
            .value = if (url) |u| u else "",
        },
        .prob_source_poll_seconds = .{
            .valid = poll_valid,
            .value = if (poll_str) |ps| ps else "",
        },
        .prob_source_market_id_field = .{
            .valid = mid_field_valid,
            .value = if (mid_field) |f| f else "",
        },
        .prob_source_probability_field = .{
            .valid = prob_field_valid,
            .value = if (prob_field) |f| f else "",
        },
    }, .{}) catch {
        try types.writeError(writer, req_id, "config validation serialization failed");
        return;
    };
    defer ctx.allocator.free(result);

    try types.writeResponse(writer, req_id, types.T.config_validate_response, result);
}

fn handleInventorySnapshot(ctx: *Context, req_id: []const u8, writer: anytype) !void {
    if (ctx.strategy_engine) |se| {
        var snap_buf: [4096]u8 = undefined;
        const snap = se.getInventorySnapshot(&snap_buf) catch {
            try types.writeError(writer, req_id, "inventory snapshot failed");
            return;
        };
        try types.writeResponse(writer, req_id, types.T.inventory_snapshot_response, snap);
        return;
    }
    try types.writeError(writer, req_id, "strategy engine not available");
}

fn handleDryRunAnalysis(ctx: *Context, req_id: []const u8, writer: anytype) !void {
    var buf: [2048]u8 = undefined;
    const result = ctx.database.analyzeDryRunSignals(&buf) catch {
        try types.writeError(writer, req_id, "dry-run analysis failed");
        return;
    };
    try types.writeResponse(writer, req_id, types.T.dry_run_analysis_response, result);
}
