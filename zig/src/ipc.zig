//! UNIX domain socket IPC server.
//! Accepts JSON-lines connections, dispatches to handlers, responds in-kind.
const std = @import("std");
const log = @import("logger.zig");
const types = @import("ipc_types.zig");
const db = @import("db.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    database: *db.DB,
};

/// Start listening; blocks until an unrecoverable error.
pub fn serve(allocator: std.mem.Allocator, socket_path: []const u8, database: *db.DB) !void {
    // Remove stale socket file from a prior run.
    std.fs.cwd().deleteFile(socket_path) catch {};

    const addr = try std.net.Address.initUnix(socket_path);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer {
        listener.deinit();
        std.fs.cwd().deleteFile(socket_path) catch {};
    }

    log.info("ipc", "listening on {s}", .{socket_path});

    var ctx = Context{ .allocator = allocator, .database = database };

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
        try types.writeResponse(writer, req_id, types.T.portfolio_response, "{\"positions\":[],\"note\":\"phase-0-stub\"}");
    } else if (std.mem.eql(u8, msg_type, types.T.orders)) {
        try types.writeResponse(writer, req_id, types.T.orders_response, "{\"orders\":[],\"note\":\"phase-0-stub\"}");
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
    } else {
        try types.writeError(writer, req_id, "unknown message type");
    }
}
