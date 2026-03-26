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
