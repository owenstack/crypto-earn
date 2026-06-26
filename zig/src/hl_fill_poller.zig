//! Phase 5 — Hyperliquid fill detection.
//!
//! Replaces the Polymarket REST polling stub with HL-native fill ingestion:
//!   - parses fill events from the HL user WebSocket channel
//!     (`{"channel":"user","data":{"fills":[...]}}`)
//!   - persists each fill into the `fills` table and updates the parent
//!     `orders` row (filled_size, average_fill_price, status)
//!   - emits `event.order.filled` / `event.order.partially_filled` IPC pushes
//!   - exposes a dry-run simulation entry point that crosses open
//!     `dry_run_orders` against the latest l2Book mid prices
//!
//! Network plumbing (the actual WS client + REST fallback) is wired into the
//! engine in main.zig; this module focuses on parsing + persistence so the
//! core logic is unit-testable without a live HL connection.

const std = @import("std");
const log = @import("logger.zig");
const db_mod = @import("db.zig");
const c = db_mod.c;
const ipc = @import("ipc.zig");
const ipc_types = @import("ipc_types.zig");

/// Single parsed HL fill event.
pub const HlFill = struct {
    /// HL `oid` (numeric order id, stringified for parity with our own
    /// client_order_id storage).
    oid: [40]u8,
    oid_len: usize,
    /// Filled size (base units).
    sz: f64,
    /// Fill price (quote per base).
    px: f64,
    /// "buy" | "sell".
    side: [4]u8,
    side_len: usize,
    /// HL fill timestamp (milliseconds since epoch).
    time_ms: i64,

    pub fn id(self: *const HlFill) []const u8 {
        return self.oid[0..self.oid_len];
    }

    pub fn sideStr(self: *const HlFill) []const u8 {
        return self.side[0..self.side_len];
    }
};

pub const ParsedFills = struct {
    fills: [32]HlFill,
    count: usize,
};

/// Parse an HL user-channel fill envelope, e.g.:
///   {"channel":"user","data":{"fills":[
///     {"oid":12345,"sz":"0.05","px":"45000.0","side":"B","time":1700000000000},
///     ...
///   ]}}
/// Also accepts the REST `/info {"type":"userFills"}` response shape, which
/// is a top-level fill array.
///
/// Tolerates the alternate `"side":"buy"|"sell"` form (some HL SDK builds
/// translate B/A → buy/sell before forwarding). Returns `null` if the
/// envelope is malformed or contains no fills.
pub fn parseUserChannelFills(body: []const u8) ?ParsedFills {
    var out = ParsedFills{ .fills = undefined, .count = 0 };

    // Locate the "fills":[ ... ] array. We do byte-level scanning so the
    // parser is allocation-free and safe to call from hot paths.
    const fills_key = "\"fills\"";
    var i: usize = if (std.mem.indexOf(u8, body, fills_key)) |fkidx| blk: {
        var arr_idx = fkidx + fills_key.len;
        while (arr_idx < body.len and body[arr_idx] != '[') : (arr_idx += 1) {}
        break :blk arr_idx;
    } else blk: {
        var arr_idx: usize = 0;
        while (arr_idx < body.len and (body[arr_idx] == ' ' or body[arr_idx] == '\n' or body[arr_idx] == '\r' or body[arr_idx] == '\t')) : (arr_idx += 1) {}
        break :blk arr_idx;
    };
    if (i >= body.len or body[i] != '[') return null;
    i += 1; // past '['

    while (i < body.len and out.count < out.fills.len) {
        // Skip whitespace + commas.
        while (i < body.len and (body[i] == ' ' or body[i] == ',' or body[i] == '\n' or body[i] == '\r' or body[i] == '\t')) : (i += 1) {}
        if (i >= body.len or body[i] == ']') break;
        if (body[i] != '{') {
            i += 1;
            continue;
        }

        // Find matching '}' (no nested objects in HL fill structs).
        const obj_start = i;
        var depth: i32 = 0;
        var obj_end: usize = obj_start;
        while (obj_end < body.len) : (obj_end += 1) {
            if (body[obj_end] == '{') depth += 1;
            if (body[obj_end] == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (obj_end >= body.len) break;
        const obj = body[obj_start .. obj_end + 1];

        var fill = HlFill{
            .oid = [_]u8{0} ** 40,
            .oid_len = 0,
            .sz = 0.0,
            .px = 0.0,
            .side = [_]u8{0} ** 4,
            .side_len = 0,
            .time_ms = 0,
        };

        if (extractScalar(obj, "oid")) |s| {
            const n = @min(s.len, fill.oid.len);
            @memcpy(fill.oid[0..n], s[0..n]);
            fill.oid_len = n;
        }
        if (extractScalar(obj, "sz")) |s| {
            fill.sz = std.fmt.parseFloat(f64, s) catch 0.0;
        }
        if (extractScalar(obj, "px")) |s| {
            fill.px = std.fmt.parseFloat(f64, s) catch 0.0;
        }
        if (extractScalar(obj, "side")) |s| {
            const norm = normalizeSide(s);
            const n = @min(norm.len, fill.side.len);
            @memcpy(fill.side[0..n], norm[0..n]);
            fill.side_len = n;
        }
        if (extractScalar(obj, "time")) |s| {
            fill.time_ms = std.fmt.parseInt(i64, s, 10) catch 0;
        }

        if (fill.oid_len > 0 and fill.sz > 0.0) {
            out.fills[out.count] = fill;
            out.count += 1;
        }

        i = obj_end + 1;
    }

    if (out.count == 0) return null;
    return out;
}

/// Normalize HL "B"/"A" side codes to "buy"/"sell"; pass through "buy"/"sell"
/// unchanged. Anything else is returned as-is so callers can detect oddities.
fn normalizeSide(raw: []const u8) []const u8 {
    if (raw.len == 1) {
        if (raw[0] == 'B' or raw[0] == 'b') return "buy";
        if (raw[0] == 'A' or raw[0] == 'a' or raw[0] == 'S' or raw[0] == 's') return "sell";
    }
    if (std.ascii.eqlIgnoreCase(raw, "buy")) return "buy";
    if (std.ascii.eqlIgnoreCase(raw, "sell")) return "sell";
    if (std.ascii.eqlIgnoreCase(raw, "bid")) return "buy";
    if (std.ascii.eqlIgnoreCase(raw, "ask")) return "sell";
    return raw;
}

/// Extract a scalar JSON value (string OR number) for `key` from a flat JSON
/// object. Strings are returned without their surrounding quotes; numbers as
/// the literal token.
fn extractScalar(obj: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + key.len + 3 < obj.len) : (i += 1) {
        if (obj[i] != '"') continue;
        if (i + 1 + key.len + 1 >= obj.len) continue;
        if (!std.mem.eql(u8, obj[i + 1 .. i + 1 + key.len], key)) continue;
        if (obj[i + 1 + key.len] != '"') continue;

        var j = i + 1 + key.len + 1;
        while (j < obj.len and (obj[j] == ':' or obj[j] == ' ')) : (j += 1) {}
        if (j >= obj.len) return null;

        if (obj[j] == '"') {
            const start = j + 1;
            var end = start;
            while (end < obj.len and obj[end] != '"') : (end += 1) {}
            return obj[start..end];
        }

        const start = j;
        var end = start;
        while (end < obj.len and obj[end] != ',' and obj[end] != '}' and obj[end] != ' ' and obj[end] != ']') : (end += 1) {}
        return obj[start..end];
    }
    return null;
}

/// Result of applying a single HL fill to local DB state.
pub const ApplyResult = struct {
    /// `filled_size_after / order_size`, clamped to [0, 1].
    fill_ratio: f64,
    /// "filled" if the order is now fully filled, otherwise
    /// "partially_filled".
    new_status: []const u8,
    /// True if the parent order row was found and updated.
    updated: bool,
};

/// Update the local `orders` and `fills` tables for an inbound HL fill.
/// Looks up the parent order by `id`, `client_order_id`, or
/// `exchange_order_id == fill.oid`,
/// increments `filled_size`, sets `average_fill_price` to a cumulative VWAP,
/// and toggles status to `filled` / `partially_filled`. Inserts a row in
/// `fills` keyed by the HL `oid` + ms timestamp so duplicate WS events are
/// idempotent.
pub fn applyFillToDb(database: *db_mod.DB, fill: HlFill) !ApplyResult {
    var result = ApplyResult{
        .fill_ratio = 0.0,
        .new_status = "partially_filled",
        .updated = false,
    };
    const oid = fill.id();
    if (oid.len == 0) return result;

    var fid_buf: [80]u8 = undefined;
    const fid = std.fmt.bufPrint(&fid_buf, "{s}-{d}", .{ oid, fill.time_ms }) catch oid;

    // Replay safety: both HL WS reconnects and REST fallback can deliver a
    // fill we've already processed. Check before mutating the parent order so
    // duplicate events cannot double-count filled_size.
    const dup_sql = "SELECT 1 FROM fills WHERE id=? LIMIT 1;" ++ &[_:0]u8{};
    var dup: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(database.handle, dup_sql.ptr, -1, &dup, null) != c.SQLITE_OK) {
        return error.DbPrepareFailed;
    }
    defer _ = c.sqlite3_finalize(dup);
    _ = c.sqlite3_bind_text(dup, 1, fid.ptr, @intCast(fid.len), null);
    if (c.sqlite3_step(dup) == c.SQLITE_ROW) {
        return result;
    }

    const select_sql =
        "SELECT id, size, COALESCE(filled_size, '0'), COALESCE(average_fill_price, '0') " ++
        "FROM orders WHERE id=? OR client_order_id=? OR exchange_order_id=? LIMIT 1;" ++ &[_:0]u8{};
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(database.handle, select_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        return error.DbPrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, oid.ptr, @intCast(oid.len), null);
    _ = c.sqlite3_bind_text(stmt, 2, oid.ptr, @intCast(oid.len), null);
    _ = c.sqlite3_bind_text(stmt, 3, oid.ptr, @intCast(oid.len), null);

    var order_id_buf: [128]u8 = undefined;
    var order_id_len: usize = 0;
    var order_size: f64 = 0.0;
    var filled_before: f64 = 0.0;
    var average_fill_price: f64 = 0.0;

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const id_raw = c.sqlite3_column_text(stmt, 0);
        if (id_raw) |p| {
            const span = std.mem.span(@as([*c]const u8, @ptrCast(p)));
            const n = @min(span.len, order_id_buf.len);
            @memcpy(order_id_buf[0..n], span[0..n]);
            order_id_len = n;
        }
        if (c.sqlite3_column_text(stmt, 1)) |p| {
            const span = std.mem.span(@as([*c]const u8, @ptrCast(p)));
            order_size = std.fmt.parseFloat(f64, span) catch 0.0;
        }
        if (c.sqlite3_column_text(stmt, 2)) |p| {
            const span = std.mem.span(@as([*c]const u8, @ptrCast(p)));
            filled_before = std.fmt.parseFloat(f64, span) catch 0.0;
        }
        if (c.sqlite3_column_text(stmt, 3)) |p| {
            const span = std.mem.span(@as([*c]const u8, @ptrCast(p)));
            average_fill_price = std.fmt.parseFloat(f64, span) catch 0.0;
        }
    } else {
        return result;
    }

    const order_id = order_id_buf[0..order_id_len];
    const filled_size = fill.sz;
    const filled_after = filled_before + filled_size;
    const fully_filled = order_size > 0 and filled_after >= order_size - 1e-9;
    result.new_status = if (fully_filled) "filled" else "partially_filled";
    result.fill_ratio = if (order_size > 0)
        std.math.clamp(filled_after / order_size, 0.0, 1.0)
    else
        0.0;
    result.updated = true;

    const new_cumulative_cost = (average_fill_price * filled_before) + (fill.px * filled_size);
    const new_avg = if (filled_after > 1e-18)
        new_cumulative_cost / filled_after
    else
        fill.px;

    var filled_str_buf: [32]u8 = undefined;
    const filled_str = std.fmt.bufPrint(&filled_str_buf, "{d:.10}", .{filled_after}) catch "0";
    var avg_str_buf: [32]u8 = undefined;
    const avg_str = std.fmt.bufPrint(&avg_str_buf, "{d:.10}", .{new_avg}) catch "0";

    const upd_sql = "UPDATE orders SET filled_size=?, average_fill_price=?, status=?, updated_at=unixepoch() WHERE id=?;" ++ &[_:0]u8{};
    var upd: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(database.handle, upd_sql.ptr, -1, &upd, null) != c.SQLITE_OK) {
        return error.DbPrepareFailed;
    }
    defer _ = c.sqlite3_finalize(upd);
    _ = c.sqlite3_bind_text(upd, 1, filled_str.ptr, @intCast(filled_str.len), null);
    _ = c.sqlite3_bind_text(upd, 2, avg_str.ptr, @intCast(avg_str.len), null);
    _ = c.sqlite3_bind_text(upd, 3, result.new_status.ptr, @intCast(result.new_status.len), null);
    _ = c.sqlite3_bind_text(upd, 4, order_id.ptr, @intCast(order_id.len), null);
    if (c.sqlite3_step(upd) != c.SQLITE_DONE) return error.DbExecFailed;

    // Insert the fill row. fill_id = "<oid>-<time_ms>" so duplicate events
    // (e.g. WS reconnect replays) collide on PRIMARY KEY and are ignored.
    var sz_str_buf: [32]u8 = undefined;
    const sz_str = std.fmt.bufPrint(&sz_str_buf, "{d:.10}", .{fill.sz}) catch "0";
    const ins_sql = "INSERT OR IGNORE INTO fills(id, order_id, size, price, fee, detected_at, filled_at) VALUES(?, ?, ?, ?, '0', ?, ?);" ++ &[_:0]u8{};
    var ins: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(database.handle, ins_sql.ptr, -1, &ins, null) != c.SQLITE_OK) {
        return error.DbPrepareFailed;
    }
    defer _ = c.sqlite3_finalize(ins);
    const fill_ts = @divTrunc(fill.time_ms, 1000);
    _ = c.sqlite3_bind_text(ins, 1, fid.ptr, @intCast(fid.len), null);
    _ = c.sqlite3_bind_text(ins, 2, order_id.ptr, @intCast(order_id.len), null);
    var px_str_buf: [32]u8 = undefined;
    const px_str = std.fmt.bufPrint(&px_str_buf, "{d:.10}", .{fill.px}) catch "0";
    _ = c.sqlite3_bind_text(ins, 3, sz_str.ptr, @intCast(sz_str.len), null);
    _ = c.sqlite3_bind_text(ins, 4, px_str.ptr, @intCast(px_str.len), null);
    _ = c.sqlite3_bind_int64(ins, 5, std.time.timestamp());
    _ = c.sqlite3_bind_int64(ins, 6, fill_ts);
    _ = c.sqlite3_step(ins);

    return result;
}

/// Emit an `event.order.filled` / `event.order.partially_filled` IPC push.
pub fn emitFillEvent(fill: HlFill, status: []const u8) void {
    var buf: [320]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &buf,
        "{{\"order_id\":\"{s}\",\"size\":{d:.10},\"price\":{d:.10},\"side\":\"{s}\",\"time_ms\":{d}}}",
        .{ fill.id(), fill.sz, fill.px, fill.sideStr(), fill.time_ms },
    ) catch "{}";

    const event_type = if (std.mem.eql(u8, status, "filled"))
        ipc_types.T.event_order_filled
    else
        ipc_types.T.event_order_partially_filled;

    ipc.publishEvent(event_type, payload);
}

/// Compute fill detection latency in milliseconds.
/// `submit_ns` and `fill_ns` use std.time.nanoTimestamp / nanoseconds() units.
pub fn fillLatencyMs(submit_ns: i128, fill_ns: i128) i64 {
    if (fill_ns <= submit_ns) return 0;
    const ms = @divTrunc(fill_ns - submit_ns, std.time.ns_per_ms);
    return @intCast(ms);
}

/// Simulated dry-run fill price + fee bookkeeping.
pub const SimResult = struct {
    /// Fill price that would have been crossed (best ask for buys, best bid for sells).
    fill_price: f64,
    /// Taker fee charged in quote units.
    fee: f64,
    /// True if the order would have crossed the book.
    would_fill: bool,
};

/// Phase 5 dry-run fill model: an order crosses the book when the resting
/// limit price is on the wrong side of the opposite top-of-book quote. Buys
/// fill at best_ask if signal_price >= best_ask; sells fill at best_bid if
/// signal_price <= best_bid. Taker fee is fixed at the default HL taker tier.
pub fn simulateDryRunFill(
    is_buy: bool,
    signal_price: f64,
    best_bid: f64,
    best_ask: f64,
    size: f64,
) SimResult {
    const taker_fee_bps: f64 = 4.5;
    const crosses = if (is_buy)
        (best_ask > 0 and signal_price >= best_ask)
    else
        (best_bid > 0 and signal_price <= best_bid);

    if (!crosses) {
        return .{ .fill_price = 0.0, .fee = 0.0, .would_fill = false };
    }

    const fill_price = if (is_buy) best_ask else best_bid;
    const notional = fill_price * size;
    const fee = notional * (taker_fee_bps / 10000.0);
    return .{ .fill_price = fill_price, .fee = fee, .would_fill = true };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "hl_fill_poller: parseUserChannelFills extracts a single fill" {
    const json =
        \\{"channel":"user","data":{"fills":[
        \\  {"oid":12345,"sz":"0.05","px":"45000.0","side":"B","time":1700000000000}
        \\]}}
    ;
    const parsed = parseUserChannelFills(json);
    try std.testing.expect(parsed != null);
    const p = parsed.?;
    try std.testing.expectEqual(@as(usize, 1), p.count);
    try std.testing.expectEqualStrings("12345", p.fills[0].id());
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), p.fills[0].sz, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 45000.0), p.fills[0].px, 1e-9);
    try std.testing.expectEqualStrings("buy", p.fills[0].sideStr());
    try std.testing.expectEqual(@as(i64, 1700000000000), p.fills[0].time_ms);
}

test "hl_fill_poller: parseUserChannelFills handles multiple + Ask side code" {
    const json =
        \\{"channel":"user","data":{"fills":[
        \\  {"oid":1,"sz":"0.02","px":"100.0","side":"B","time":1},
        \\  {"oid":2,"sz":"0.04","px":"101.0","side":"A","time":2}
        \\]}}
    ;
    const parsed = parseUserChannelFills(json) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(usize, 2), parsed.count);
    try std.testing.expectEqualStrings("buy", parsed.fills[0].sideStr());
    try std.testing.expectEqualStrings("sell", parsed.fills[1].sideStr());
}

test "hl_fill_poller: parseUserChannelFills returns null on empty array" {
    const json = "{\"channel\":\"user\",\"data\":{\"fills\":[]}}";
    try std.testing.expect(parseUserChannelFills(json) == null);
}

test "hl_fill_poller: parseUserChannelFills accepts REST userFills array" {
    const json = "[{\"oid\":67890,\"sz\":\"0.10\",\"px\":\"123.45\",\"side\":\"A\",\"time\":1700000000123}]";
    const parsed = parseUserChannelFills(json) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(usize, 1), parsed.count);
    try std.testing.expectEqualStrings("67890", parsed.fills[0].id());
    try std.testing.expectEqualStrings("sell", parsed.fills[0].sideStr());
}

test "hl_fill_poller: simulateDryRunFill — buy crosses ask" {
    const r = simulateDryRunFill(true, 0.55, 0.50, 0.52, 10.0);
    try std.testing.expect(r.would_fill);
    try std.testing.expectApproxEqAbs(@as(f64, 0.52), r.fill_price, 1e-9);
    // notional = 5.20, fee = 5.20 * 4.5 / 10000 = 0.00234
    try std.testing.expectApproxEqAbs(@as(f64, 0.00234), r.fee, 1e-6);
}

test "hl_fill_poller: simulateDryRunFill — sell crosses bid" {
    const r = simulateDryRunFill(false, 0.49, 0.50, 0.52, 10.0);
    try std.testing.expect(r.would_fill);
    try std.testing.expectApproxEqAbs(@as(f64, 0.50), r.fill_price, 1e-9);
}

test "hl_fill_poller: simulateDryRunFill — no cross" {
    const r = simulateDryRunFill(true, 0.49, 0.50, 0.52, 10.0);
    try std.testing.expect(!r.would_fill);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), r.fill_price, 1e-9);
}

test "hl_fill_poller: fillLatencyMs computes positive elapsed" {
    const submit: i128 = 1_000_000_000;
    const fill: i128 = 1_500_000_000;
    try std.testing.expectEqual(@as(i64, 500), fillLatencyMs(submit, fill));
}

test "hl_fill_poller: fillLatencyMs clamps non-positive to zero" {
    const t: i128 = 1_000_000_000;
    try std.testing.expectEqual(@as(i64, 0), fillLatencyMs(t, t - 1));
}

test "hl_fill_poller: applyFillToDb updates order + inserts fill" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    // Seed market + order.
    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('M-BTC','BTC','BTC','USDC');");
    try database.execZ(
        "INSERT INTO orders(id,market_id,client_order_id,type,side,size,price,status,filled_size) " ++
            "VALUES('order-1','M-BTC','12345','limit','buy','0.10','45000','placed','0');",
    );

    var fill = HlFill{
        .oid = [_]u8{0} ** 40,
        .oid_len = 0,
        .sz = 0.05,
        .px = 45100.0,
        .side = [_]u8{0} ** 4,
        .side_len = 3,
        .time_ms = 1_700_000_000_000,
    };
    @memcpy(fill.oid[0..5], "12345");
    fill.oid_len = 5;
    @memcpy(fill.side[0..3], "buy");

    const r = try applyFillToDb(&database, fill);
    try std.testing.expect(r.updated);
    try std.testing.expectEqualStrings("partially_filled", r.new_status);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), r.fill_ratio, 1e-9);

    // Apply the rest at a different price → fully filled; VWAP = (45100*0.05 + 46000*0.05) / 0.1
    fill.time_ms = 1_700_000_001_000;
    fill.px = 46000.0;
    const r2 = try applyFillToDb(&database, fill);
    try std.testing.expect(r2.updated);
    try std.testing.expectEqualStrings("filled", r2.new_status);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), r2.fill_ratio, 1e-9);

    var stmt2: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(
        database.handle,
        "SELECT average_fill_price FROM orders WHERE id='order-1';",
        -1,
        &stmt2,
        null,
    ));
    defer _ = c.sqlite3_finalize(stmt2);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt2));
    const avg_span = std.mem.span(c.sqlite3_column_text(stmt2, 0).?);
    const vwap = try std.fmt.parseFloat(f64, avg_span);
    try std.testing.expectApproxEqAbs(@as(f64, 45550.0), vwap, 1e-3);

    // Replaying the same fill id is ignored before mutating filled_size.
    const replay = try applyFillToDb(&database, fill);
    try std.testing.expect(!replay.updated);

    var replay_stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(
        database.handle,
        "SELECT filled_size FROM orders WHERE id='order-1';",
        -1,
        &replay_stmt,
        null,
    ));
    defer _ = c.sqlite3_finalize(replay_stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(replay_stmt));
    const filled_span = std.mem.span(c.sqlite3_column_text(replay_stmt, 0).?);
    const filled_after_replay = try std.fmt.parseFloat(f64, filled_span);
    try std.testing.expectApproxEqAbs(@as(f64, 0.10), filled_after_replay, 1e-9);

    // Verify two fill rows landed in the fills table.
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(
        database.handle,
        "SELECT COUNT(*) FROM fills WHERE order_id='order-1';",
        -1,
        &stmt,
        null,
    ));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 2), c.sqlite3_column_int64(stmt, 0));
}
