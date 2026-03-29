//! UNIX domain socket IPC server.
//! Accepts JSON-lines connections, dispatches to handlers, responds in-kind.
const std = @import("std");
const log = @import("logger.zig");
const types = @import("ipc_types.zig");
const db = @import("db.zig");
const order_mgr = @import("order_manager.zig");
const portfolio = @import("portfolio_tracker.zig");
const strategy = @import("strategy_engine.zig");

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
    defer conn.stream.close();

    var reader_buf: [8192]u8 = undefined;
    var net_reader = conn.stream.reader(&reader_buf);
    const reader = net_reader.interface();
    var writer_buf: [8192]u8 = undefined;
    var net_writer = conn.stream.writer(&writer_buf);
    const writer = &net_writer.interface;

    while (true) {
        const line = reader.takeDelimiter('\n') catch break orelse break;
        if (line.len == 0) continue;
        dispatch(ctx, line, writer) catch |e| {
            log.warn("ipc", "dispatch error: {any}", .{e});
        };
        writer.flush() catch {};
    }
}

fn dispatch(ctx: *Context, line: []const u8, writer: anytype) !void {
    const alloc = ctx.allocator;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch {
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

    const req_id = if (root.get("id")) |v|
        switch (v) {
            .string => |s| s,
            else => "unknown",
        }
    else
        "unknown";

    const msg_type = if (root.get("type")) |v|
        switch (v) {
            .string => |s| s,
            else => "",
        }
    else
        "";

    if (std.mem.eql(u8, msg_type, types.T.heartbeat)) {
        var p: [64]u8 = undefined;
        const payload = std.fmt.bufPrint(
            &p,
            "{{\"status\":\"ok\",\"uptime_ms\":{d}}}",
            .{log.uptimeMs()},
        ) catch "{}";
        try types.writeResponse(writer, req_id, types.T.heartbeat_response, payload);
    } else if (std.mem.eql(u8, msg_type, types.T.status)) {
        var jm_buf: [16]u8 = undefined;
        const jm = ctx.database.journalMode(&jm_buf);
        var p: [128]u8 = undefined;
        const payload = std.fmt.bufPrint(
            &p,
            "{{\"engine\":\"running\",\"db\":\"{s}\",\"uptime_ms\":{d}}}",
            .{ jm, log.uptimeMs() },
        ) catch "{}";
        try types.writeResponse(writer, req_id, types.T.status_response, payload);
    } else if (std.mem.eql(u8, msg_type, types.T.portfolio)) {
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
        } else {
            try types.writeResponse(writer, req_id, types.T.portfolio_response, "{\"positions\":[],\"note\":\"phase-0-stub\"}");
        }
    } else if (std.mem.eql(u8, msg_type, types.T.orders)) {
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
        } else {
            try types.writeResponse(writer, req_id, types.T.orders_response, "{\"orders\":[],\"note\":\"phase-0-stub\"}");
        }
    } else if (std.mem.eql(u8, msg_type, types.T.config_get)) {
        try types.writeResponse(writer, req_id, types.T.config_get_response, "{\"config\":{},\"note\":\"phase-0-stub\"}");
    } else if (std.mem.eql(u8, msg_type, types.T.logs)) {
        // Build payload: {"logs": [...]}
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(alloc);
        try payload.appendSlice(alloc, "{\"logs\":");
        try log.writeRecentLogs(payload.writer(alloc));
        try payload.append(alloc, '}');
        try types.writeResponse(writer, req_id, types.T.logs_response, payload.items);
    } else if (std.mem.eql(u8, msg_type, types.T.order_place)) {
        if (ctx.order_manager) |om| {
            const payload_obj = if (root.get("payload")) |v| switch (v) {
                .object => |o| o,
                else => null,
            } else null;
            if (payload_obj) |pl| {
                const market_id = if (pl.get("market_id")) |v| switch (v) {
                    .string => |s| s,
                    else => "",
                } else "";
                const side = if (pl.get("side")) |v| switch (v) {
                    .string => |s| s,
                    else => "",
                } else "";
                const size = if (pl.get("size")) |v| switch (v) {
                    .string => |s| s,
                    else => "",
                } else "";
                const price = if (pl.get("price")) |v| switch (v) {
                    .string => |s| s,
                    else => "",
                } else "";
                const otype = if (pl.get("order_type")) |v| switch (v) {
                    .string => |s| s,
                    else => "limit",
                } else "limit";

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
            } else {
                try types.writeError(writer, req_id, "missing payload");
            }
        } else {
            try types.writeError(writer, req_id, "order manager not available");
        }
    } else if (std.mem.eql(u8, msg_type, types.T.order_cancel)) {
        if (ctx.order_manager) |om| {
            const payload_obj = if (root.get("payload")) |v| switch (v) {
                .object => |o| o,
                else => null,
            } else null;
            if (payload_obj) |pl| {
                const order_id = if (pl.get("order_id")) |v| switch (v) {
                    .string => |s| s,
                    else => "",
                } else "";
                const ok = om.cancelOrder(order_id);
                var p_buf: [128]u8 = undefined;
                const resp = std.fmt.bufPrint(&p_buf, "{{\"order_id\":\"{s}\",\"status\":\"{s}\"}}", .{ order_id, if (ok) "cancelled" else "failed" }) catch "{}";
                try types.writeResponse(writer, req_id, types.T.order_cancel_response, resp);
            } else {
                try types.writeError(writer, req_id, "missing payload");
            }
        } else {
            try types.writeError(writer, req_id, "order manager not available");
        }
    } else if (std.mem.eql(u8, msg_type, types.T.order_cancel_all)) {
        if (ctx.order_manager) |om| {
            const cancelled = om.cancelAll();
            var p_buf: [64]u8 = undefined;
            const resp = std.fmt.bufPrint(&p_buf, "{{\"cancelled_count\":{d}}}", .{cancelled}) catch "{}";
            try types.writeResponse(writer, req_id, types.T.order_cancel_all_response, resp);
        } else {
            try types.writeError(writer, req_id, "order manager not available");
        }
    } else if (std.mem.eql(u8, msg_type, types.T.halt)) {
        if (ctx.order_manager) |om| {
            const cancelled = om.halt();
            var p_buf: [64]u8 = undefined;
            const resp = std.fmt.bufPrint(&p_buf, "{{\"status\":\"halted\",\"cancelled_orders\":{d}}}", .{cancelled}) catch "{}";
            try types.writeResponse(writer, req_id, types.T.halt_response, resp);
        } else {
            try types.writeError(writer, req_id, "order manager not available");
        }
    } else if (std.mem.eql(u8, msg_type, types.T.@"resume")) {
        if (ctx.order_manager) |om| {
            om.@"resume"();
            try types.writeResponse(writer, req_id, types.T.resume_response, "{\"status\":\"resumed\"}");
        } else {
            try types.writeError(writer, req_id, "order manager not available");
        }
    } else if (std.mem.eql(u8, msg_type, types.T.strategy_list)) {
        if (ctx.strategy_engine) |se| {
            const news_enabled = se.isEnabled(.news_repricing);
            const lp_enabled = se.isEnabled(.liquidity_provision);
            const ns = se.getStats(.news_repricing);
            const ls = se.getStats(.liquidity_provision);
            var p: [1024]u8 = undefined;
            const payload = std.fmt.bufPrint(&p,
                "{{\"strategies\":[" ++
                "{{\"name\":\"news_repricing\",\"enabled\":{},\"stats\":{{\"signals_emitted\":{d},\"orders_accepted\":{d},\"orders_rejected\":{d},\"cancels\":{d}}}}}," ++
                "{{\"name\":\"liquidity_provision\",\"enabled\":{},\"stats\":{{\"signals_emitted\":{d},\"orders_accepted\":{d},\"orders_rejected\":{d},\"cancels\":{d}}}}}" ++
                "]}}",
                .{
                    news_enabled, ns.signals_emitted, ns.orders_accepted, ns.orders_rejected, ns.cancels,
                    lp_enabled, ls.signals_emitted, ls.orders_accepted, ls.orders_rejected, ls.cancels,
                },
            ) catch "{}";
            try types.writeResponse(writer, req_id, types.T.strategy_list_response, payload);
        } else {
            try types.writeError(writer, req_id, "strategy engine not available");
        }
    } else if (std.mem.eql(u8, msg_type, types.T.strategy_enable)) {
        if (ctx.strategy_engine) |se| {
            const payload_obj = if (root.get("payload")) |v| switch (v) {
                .object => |o| o,
                else => null,
            } else null;
            if (payload_obj) |pl| {
                const name_str = if (pl.get("name")) |v| switch (v) {
                    .string => |s| s,
                    else => "",
                } else "";
                const strat_name: ?strategy.StrategyName = if (std.mem.eql(u8, name_str, "news_repricing"))
                    .news_repricing
                else if (std.mem.eql(u8, name_str, "liquidity_provision"))
                    .liquidity_provision
                else
                    null;
                if (strat_name) |sn| {
                    se.enableStrategy(sn);
                    var p: [128]u8 = undefined;
                    const resp = std.fmt.bufPrint(&p, "{{\"name\":\"{s}\",\"enabled\":true}}", .{name_str}) catch "{}";
                    try types.writeResponse(writer, req_id, types.T.strategy_enable_response, resp);
                } else {
                    try types.writeError(writer, req_id, "unknown strategy name");
                }
            } else {
                try types.writeError(writer, req_id, "missing payload");
            }
        } else {
            try types.writeError(writer, req_id, "strategy engine not available");
        }
    } else if (std.mem.eql(u8, msg_type, types.T.strategy_disable)) {
        if (ctx.strategy_engine) |se| {
            const payload_obj = if (root.get("payload")) |v| switch (v) {
                .object => |o| o,
                else => null,
            } else null;
            if (payload_obj) |pl| {
                const name_str = if (pl.get("name")) |v| switch (v) {
                    .string => |s| s,
                    else => "",
                } else "";
                const strat_name: ?strategy.StrategyName = if (std.mem.eql(u8, name_str, "news_repricing"))
                    .news_repricing
                else if (std.mem.eql(u8, name_str, "liquidity_provision"))
                    .liquidity_provision
                else
                    null;
                if (strat_name) |sn| {
                    se.disableStrategy(sn);
                    var p: [128]u8 = undefined;
                    const resp = std.fmt.bufPrint(&p, "{{\"name\":\"{s}\",\"enabled\":false}}", .{name_str}) catch "{}";
                    try types.writeResponse(writer, req_id, types.T.strategy_disable_response, resp);
                } else {
                    try types.writeError(writer, req_id, "unknown strategy name");
                }
            } else {
                try types.writeError(writer, req_id, "missing payload");
            }
        } else {
            try types.writeError(writer, req_id, "strategy engine not available");
        }
    } else {
        try types.writeError(writer, req_id, "unknown message type");
    }
}
