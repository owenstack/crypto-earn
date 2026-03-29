//! Portfolio tracker — maintains in-memory position state synchronized with SQLite.
//! Consumes order/fill events and provides lightweight snapshot getters
//! for IPC handlers (avoids SQL-heavy hot path per request).
const std = @import("std");
const log = @import("logger.zig");
const db_mod = @import("db.zig");
const c = db_mod.c;

pub const Position = struct {
    market_id: [64]u8,
    market_id_len: usize,
    side: [8]u8,
    side_len: usize,
    size: f64,
    entry_price: f64,
    current_price: f64,
    unrealized_pnl: f64,
};

pub const PortfolioSnapshot = struct {
    positions: []const Position,
    total_exposure_usd: f64,
    unrealized_pnl: f64,
    realized_pnl_today: f64,
    usdc_balance: f64,
};

pub const FeeConfig = struct {
    maker_fee_bps: f64 = 0.0, // maker fee in basis points (e.g., 0 bps)
    taker_fee_bps: f64 = 2.0, // taker fee in basis points (e.g., 2 bps)
};

pub const PortfolioTracker = struct {
    allocator: std.mem.Allocator,
    database: *db_mod.DB,
    fee_config: FeeConfig,

    // In-memory state (lightweight cache)
    positions: [MAX_POSITIONS]Position,
    position_count: usize,
    usdc_balance: f64,
    realized_pnl_today: f64,
    last_sync_ts: i64,

    const MAX_POSITIONS = 100;

    pub fn init(allocator: std.mem.Allocator, database: *db_mod.DB, fee_config: FeeConfig) PortfolioTracker {
        var tracker = PortfolioTracker{
            .allocator = allocator,
            .database = database,
            .fee_config = fee_config,
            .positions = undefined,
            .position_count = 0,
            .usdc_balance = 0.0,
            .realized_pnl_today = 0.0,
            .last_sync_ts = 0,
        };
        tracker.syncFromDB();
        return tracker;
    }

    /// Sync in-memory state from SQLite (called on startup and recovery).
    pub fn syncFromDB(self: *PortfolioTracker) void {
        self.position_count = 0;
        self.usdc_balance = 0.0;

        const sql = "SELECT market_id, side, size, entry_price, COALESCE(current_price, entry_price), COALESCE(pnl, '0') FROM positions WHERE status='open' LIMIT 100;" ++ &[_:0]u8{};

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            log.err("portfolio", "failed to prepare position query: rc={d}", .{rc});
            return;
        }
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW and self.position_count < MAX_POSITIONS) {
            var pos: Position = .{
                .market_id = [_]u8{0} ** 64,
                .market_id_len = 0,
                .side = [_]u8{0} ** 8,
                .side_len = 0,
                .size = 0,
                .entry_price = 0,
                .current_price = 0,
                .unrealized_pnl = 0,
            };

            // market_id
            const mid_raw = c.sqlite3_column_text(stmt, 0);
            if (mid_raw) |mid_ptr_raw| {
                const mid: [*c]const u8 = @ptrCast(mid_ptr_raw);
                const mid_s = std.mem.span(mid);
                const mid_n = @min(mid_s.len, 64);
                @memcpy(pos.market_id[0..mid_n], mid_s[0..mid_n]);
                pos.market_id_len = mid_n;
            } else {
                pos.market_id_len = 0;
            }

            // side
            const side_raw = c.sqlite3_column_text(stmt, 1);
            if (side_raw) |side_ptr_raw| {
                const side_ptr: [*c]const u8 = @ptrCast(side_ptr_raw);
                const side_s = std.mem.span(side_ptr);
                const side_n = @min(side_s.len, 8);
                @memcpy(pos.side[0..side_n], side_s[0..side_n]);
                pos.side_len = side_n;
            } else {
                pos.side_len = 0;
            }

            // size
            const size_raw = c.sqlite3_column_text(stmt, 2);
            if (size_raw) |size_ptr_raw| {
                const size_ptr: [*c]const u8 = @ptrCast(size_ptr_raw);
                pos.size = std.fmt.parseFloat(f64, std.mem.span(size_ptr)) catch 0;
            } else {
                pos.size = 0.0;
            }

            // entry_price
            const ep_raw = c.sqlite3_column_text(stmt, 3);
            if (ep_raw) |ep_ptr_raw| {
                const ep_ptr: [*c]const u8 = @ptrCast(ep_ptr_raw);
                pos.entry_price = std.fmt.parseFloat(f64, std.mem.span(ep_ptr)) catch 0;
            } else {
                pos.entry_price = 0.0;
            }

            // current_price
            const cp_raw = c.sqlite3_column_text(stmt, 4);
            if (cp_raw) |cp_ptr_raw| {
                const cp_ptr: [*c]const u8 = @ptrCast(cp_ptr_raw);
                pos.current_price = std.fmt.parseFloat(f64, std.mem.span(cp_ptr)) catch 0;
            } else {
                pos.current_price = 0.0;
            }

            // Calculate unrealized PnL
            pos.unrealized_pnl = calculateUnrealizedPnl(pos);

            self.positions[self.position_count] = pos;
            self.position_count += 1;
        }

        const bal_sql = "SELECT usdc_balance FROM balance_snapshots ORDER BY snapshot_at DESC, id DESC LIMIT 1;" ++ &[_:0]u8{};
        var bal_stmt: ?*c.sqlite3_stmt = null;
        const bal_rc = c.sqlite3_prepare_v2(self.database.handle, bal_sql.ptr, -1, &bal_stmt, null);
        if (bal_rc == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(bal_stmt);
            if (c.sqlite3_step(bal_stmt) == c.SQLITE_ROW) {
                const bal_raw = c.sqlite3_column_text(bal_stmt, 0);
                const bal_txt: [*c]const u8 = @ptrCast(bal_raw orelse @as([*c]const u8, "0"));
                self.usdc_balance = std.fmt.parseFloat(f64, std.mem.span(bal_txt)) catch 0.0;
            }
        } else {
            log.warn("portfolio", "failed to prepare balance snapshot query: rc={d}", .{bal_rc});
        }

        self.last_sync_ts = std.time.timestamp();
        log.info("portfolio", "synced {d} open positions from DB", .{self.position_count});
    }

    /// Process a fill event and update PnL.
    /// PRD formula: (fill_price - entry_price) × size − fees
    pub fn processFill(
        self: *PortfolioTracker,
        order_id: []const u8,
        fill_id: []const u8,
        fill_size: []const u8,
        fill_price: []const u8,
        is_maker: bool,
    ) void {
        const size_f = std.fmt.parseFloat(f64, fill_size) catch |e| {
            log.warn("portfolio", "invalid fill_size for order={s}: size={s} err={s}", .{
                order_id,
                fill_size,
                @errorName(e),
            });
            return;
        };
        const price_f = std.fmt.parseFloat(f64, fill_price) catch |e| {
            log.warn("portfolio", "invalid fill_price for order={s}: price={s} err={s}", .{
                order_id,
                fill_price,
                @errorName(e),
            });
            return;
        };
        const notional = size_f * price_f;

        // Calculate fee
        const fee_bps = if (is_maker) self.fee_config.maker_fee_bps else self.fee_config.taker_fee_bps;
        const fee = notional * fee_bps / 10000.0;

        if (self.computeRealizedPnlForFill(order_id, size_f, price_f, fee)) |realized| {
            self.realized_pnl_today += realized;
        }

        // Format fee as string
        var fee_buf: [32]u8 = undefined;
        const fee_str = std.fmt.bufPrint(&fee_buf, "{d:.6}", .{fee}) catch "0";

        // Persist fill
        self.database.insertFill(fill_id, order_id, fill_size, fill_price, fee_str) catch |e| {
            log.err("portfolio", "failed to persist fill: {any}", .{e});
        };

        log.info("portfolio", "fill processed: order={s} size={s} price={s} fee={s}", .{
            order_id, fill_size, fill_price, fee_str,
        });

        // Re-sync from DB to pick up latest state
        self.syncFromDB();
    }

    fn computeRealizedPnlForFill(
        self: *PortfolioTracker,
        order_id: []const u8,
        size_f: f64,
        price_f: f64,
        fee: f64,
    ) ?f64 {
        const sql =
            "SELECT o.side, p.entry_price " ++
            "FROM orders o " ++
            "JOIN positions p ON p.market_id = o.market_id " ++
            "WHERE o.id=? AND p.status='open' AND ((o.side='sell' AND p.side='long') OR (o.side='buy' AND p.side='short')) " ++
            "ORDER BY p.updated_at DESC LIMIT 1;" ++ &[_:0]u8{};

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            log.warn("portfolio", "failed to prepare realized PnL query: rc={d}", .{rc});
            return null;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, order_id.ptr, @intCast(order_id.len), null) != c.SQLITE_OK) {
            return null;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
            return null;
        }

        const side_raw = c.sqlite3_column_text(stmt, 0);
        const side_ptr: [*c]const u8 = @ptrCast(side_raw orelse @as([*c]const u8, ""));
        const side = std.mem.span(side_ptr);

        const entry_raw = c.sqlite3_column_text(stmt, 1);
        const entry_ptr: [*c]const u8 = @ptrCast(entry_raw orelse @as([*c]const u8, "0"));
        const entry_price: ?f64 = std.fmt.parseFloat(f64, std.mem.span(entry_ptr)) catch null;

        const ep = entry_price orelse return null;

        if (std.mem.eql(u8, side, "sell")) {
            return (price_f - ep) * size_f - fee;
        }
        if (std.mem.eql(u8, side, "buy")) {
            return (ep - price_f) * size_f - fee;
        }
        return null;
    }

    /// Get a lightweight snapshot suitable for IPC responses.
    pub fn getSnapshot(self: *PortfolioTracker) PortfolioSnapshot {
        var total_exposure: f64 = 0;
        var total_unrealized: f64 = 0;

        for (self.positions[0..self.position_count]) |pos| {
            total_exposure += pos.size * pos.current_price;
            total_unrealized += pos.unrealized_pnl;
        }

        return .{
            .positions = self.positions[0..self.position_count],
            .total_exposure_usd = total_exposure,
            .unrealized_pnl = total_unrealized,
            .realized_pnl_today = self.realized_pnl_today,
            .usdc_balance = self.usdc_balance,
        };
    }

    /// Write snapshot as JSON to a buffer for IPC responses.
    pub fn writeSnapshotJson(self: *PortfolioTracker, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();
        const snap = self.getSnapshot();

        try writer.writeAll("{\"positions\":[");
        for (snap.positions, 0..) |pos, i| {
            if (i > 0) try writer.writeAll(",");
            var num_buf: [128]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "\",\"size\":{d:.6},\"entry_price\":{d:.6},\"current_price\":{d:.6},\"unrealized_pnl\":{d:.6}}}", .{
                pos.size,
                pos.entry_price,
                pos.current_price,
                pos.unrealized_pnl,
            }) catch return error.Overflow;

            try writer.writeAll("{\"market_id\":\"");
            try writeJsonEscapedString(writer, pos.market_id[0..pos.market_id_len]);
            try writer.writeAll("\",\"side\":\"");
            try writeJsonEscapedString(writer, pos.side[0..pos.side_len]);
            try writer.writeAll(num_str);
        }
        var summary_buf: [256]u8 = undefined;
        const summary = std.fmt.bufPrint(&summary_buf, "],\"total_exposure_usd\":{d:.2},\"unrealized_pnl\":{d:.2},\"realized_pnl_today\":{d:.2},\"usdc_balance\":{d:.2}}}", .{
            snap.total_exposure_usd,
            snap.unrealized_pnl,
            snap.realized_pnl_today,
            snap.usdc_balance,
        }) catch return error.Overflow;
        try writer.writeAll(summary);

        return fbs.getWritten();
    }

    /// Write open orders as JSON to a buffer for IPC responses.
    pub fn writeOrdersJson(self: *PortfolioTracker, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        const sql = "SELECT id, market_id, side, size, price, type, status, created_at FROM orders WHERE status NOT IN ('filled','cancelled','rejected') ORDER BY created_at DESC LIMIT 50;" ++ &[_:0]u8{};

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            const err = c.sqlite3_errmsg(self.database.handle);
            log.err("portfolio", "failed to prepare open orders query: rc={d} err={s}", .{ rc, err });
            try writer.writeAll("{\"orders\":[]}");
            return fbs.getWritten();
        }
        defer _ = c.sqlite3_finalize(stmt);

        try writer.writeAll("{\"orders\":[");
        var i: usize = 0;
        var skipped_orders: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id_raw = c.sqlite3_column_text(stmt, 0);
            const id: [*c]const u8 = @ptrCast(id_raw orelse @as([*c]const u8, ""));
            const mid_raw = c.sqlite3_column_text(stmt, 1);
            const mid: [*c]const u8 = @ptrCast(mid_raw orelse @as([*c]const u8, ""));
            const side_raw = c.sqlite3_column_text(stmt, 2);
            const side: [*c]const u8 = @ptrCast(side_raw orelse @as([*c]const u8, ""));
            const size_raw = c.sqlite3_column_text(stmt, 3);
            const size: [*c]const u8 = @ptrCast(size_raw orelse @as([*c]const u8, "0"));
            const price_raw = c.sqlite3_column_text(stmt, 4);
            const price_col: [*c]const u8 = @ptrCast(price_raw orelse @as([*c]const u8, "0"));
            const otype_raw = c.sqlite3_column_text(stmt, 5);
            const otype: [*c]const u8 = @ptrCast(otype_raw orelse @as([*c]const u8, ""));
            const status_raw = c.sqlite3_column_text(stmt, 6);
            const status: [*c]const u8 = @ptrCast(status_raw orelse @as([*c]const u8, ""));
            const created = c.sqlite3_column_int64(stmt, 7);

            var order_buf: [1024]u8 = undefined;
            var order_fbs = std.io.fixedBufferStream(&order_buf);
            const order_writer = order_fbs.writer();

            writeOrderJsonObject(order_writer, std.mem.span(id), std.mem.span(mid), std.mem.span(side), std.mem.span(size), std.mem.span(price_col), std.mem.span(otype), std.mem.span(status), created) catch |e| {
                skipped_orders += 1;
                log.err("portfolio", "skipping order during JSON serialization: id={s} err={s}", .{ std.mem.span(id), @errorName(e) });
                continue;
            };

            if (i > 0) try writer.writeAll(",");
            try writer.writeAll(order_fbs.getWritten());
            i += 1;
        }
        if (skipped_orders > 0) {
            log.warn("portfolio", "writeOrdersJson skipped {d} orders due to serialization errors", .{skipped_orders});
        }
        try writer.writeAll("]}");
        return fbs.getWritten();
    }
};

/// Calculate unrealized PnL for a position.
/// For long: (current_price - entry_price) × size
/// For short: (entry_price - current_price) × size
fn calculateUnrealizedPnl(pos: Position) f64 {
    const side_str = pos.side[0..pos.side_len];
    if (std.mem.eql(u8, side_str, "long")) {
        return (pos.current_price - pos.entry_price) * pos.size;
    } else {
        return (pos.entry_price - pos.current_price) * pos.size;
    }
}

fn writeJsonEscapedString(writer: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u00{x:0>2}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
}

fn writeOrderJsonObject(
    writer: anytype,
    id: []const u8,
    market_id: []const u8,
    side: []const u8,
    size: []const u8,
    price: []const u8,
    order_type: []const u8,
    status: []const u8,
    created_at: i64,
) !void {
    try writer.writeAll("{\"id\":\"");
    try writeJsonEscapedString(writer, id);
    try writer.writeAll("\",\"market_id\":\"");
    try writeJsonEscapedString(writer, market_id);
    try writer.writeAll("\",\"side\":\"");
    try writeJsonEscapedString(writer, side);
    try writer.writeAll("\",\"size\":\"");
    try writeJsonEscapedString(writer, size);
    try writer.writeAll("\",\"price\":\"");
    try writeJsonEscapedString(writer, price);
    try writer.writeAll("\",\"order_type\":\"");
    try writeJsonEscapedString(writer, order_type);
    try writer.writeAll("\",\"status\":\"");
    try writeJsonEscapedString(writer, status);

    var ca_buf: [32]u8 = undefined;
    const ca_str = try std.fmt.bufPrint(&ca_buf, "\",\"created_at\":{d}}}", .{created_at});
    try writer.writeAll(ca_str);
}
