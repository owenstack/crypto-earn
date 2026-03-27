//! SQLite WAL database wrapper (C interop via sqlite3.h).
const std = @import("std");
const log = @import("logger.zig");

pub const c = @cImport(@cInclude("sqlite3.h"));

/// Embedded Phase-0 migration (idempotent via CREATE IF NOT EXISTS).
const MIGRATION_001 =
    \\CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY,applied_at INTEGER NOT NULL DEFAULT(unixepoch()));
    \\CREATE TABLE IF NOT EXISTS markets(id TEXT PRIMARY KEY,symbol TEXT NOT NULL UNIQUE,base TEXT NOT NULL,quote TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'active',created_at INTEGER NOT NULL DEFAULT(unixepoch()));
    \\CREATE TABLE IF NOT EXISTS positions(id TEXT PRIMARY KEY,market_id TEXT NOT NULL REFERENCES markets(id),side TEXT NOT NULL CHECK(side IN('long','short')),size TEXT NOT NULL,entry_price TEXT NOT NULL,current_price TEXT,pnl TEXT,status TEXT NOT NULL DEFAULT 'open',created_at INTEGER NOT NULL DEFAULT(unixepoch()),updated_at INTEGER NOT NULL DEFAULT(unixepoch()));
    \\CREATE TABLE IF NOT EXISTS orders(id TEXT PRIMARY KEY,market_id TEXT NOT NULL REFERENCES markets(id),client_order_id TEXT UNIQUE,type TEXT NOT NULL,side TEXT NOT NULL CHECK(side IN('buy','sell')),size TEXT NOT NULL,price TEXT,status TEXT NOT NULL DEFAULT 'pending',created_at INTEGER NOT NULL DEFAULT(unixepoch()),updated_at INTEGER NOT NULL DEFAULT(unixepoch()));
    \\CREATE TABLE IF NOT EXISTS fills(id TEXT PRIMARY KEY,order_id TEXT NOT NULL REFERENCES orders(id),size TEXT NOT NULL,price TEXT NOT NULL,fee TEXT,filled_at INTEGER NOT NULL DEFAULT(unixepoch()));
    \\CREATE TABLE IF NOT EXISTS strategy_signals(id TEXT PRIMARY KEY,market_id TEXT REFERENCES markets(id),signal_type TEXT NOT NULL,strength REAL,metadata TEXT,created_at INTEGER NOT NULL DEFAULT(unixepoch()));
    \\CREATE TABLE IF NOT EXISTS config_changes(id TEXT PRIMARY KEY,key TEXT NOT NULL,old_value TEXT,new_value TEXT,changed_by TEXT DEFAULT 'system',changed_at INTEGER NOT NULL DEFAULT(unixepoch()));
    \\CREATE TABLE IF NOT EXISTS logs(id INTEGER PRIMARY KEY AUTOINCREMENT,level TEXT NOT NULL,component TEXT NOT NULL,message TEXT NOT NULL,metadata TEXT,created_at INTEGER NOT NULL DEFAULT(unixepoch()));
    \\CREATE INDEX IF NOT EXISTS idx_positions_status ON positions(status);
    \\CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);
    \\CREATE INDEX IF NOT EXISTS idx_orders_market ON orders(market_id);
    \\CREATE INDEX IF NOT EXISTS idx_fills_order ON fills(order_id);
    \\CREATE INDEX IF NOT EXISTS idx_logs_created ON logs(created_at DESC);
    \\INSERT OR IGNORE INTO schema_migrations(version)VALUES(1);
;

/// Embedded Phase-2 migration.
const MIGRATION_002 =
    \\CREATE TABLE IF NOT EXISTS risk_events(id INTEGER PRIMARY KEY AUTOINCREMENT,order_id TEXT,market_id TEXT,check_name TEXT NOT NULL,reason TEXT NOT NULL,limit_value TEXT,actual_value TEXT,created_at INTEGER NOT NULL DEFAULT(unixepoch()));
    \\CREATE INDEX IF NOT EXISTS idx_risk_events_created ON risk_events(created_at DESC);
    \\CREATE TABLE IF NOT EXISTS balance_snapshots(id INTEGER PRIMARY KEY AUTOINCREMENT,usdc_balance TEXT NOT NULL,total_exposure TEXT NOT NULL,unrealized_pnl TEXT NOT NULL,realized_pnl TEXT NOT NULL,snapshot_at INTEGER NOT NULL DEFAULT(unixepoch()));
    \\CREATE INDEX IF NOT EXISTS idx_balance_snapshots_at ON balance_snapshots(snapshot_at DESC);
    \\INSERT OR IGNORE INTO schema_migrations(version)VALUES(2);
;

pub const DB = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) !DB {
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path.ptr, &handle);
        if (rc != c.SQLITE_OK) {
            log.err("db", "sqlite3_open failed: rc={d}", .{rc});
            return error.DBOpenFailed;
        }
        const db = DB{ .handle = handle.? };
        try db.configure();
        return db;
    }

    pub fn close(self: *DB) void {
        _ = c.sqlite3_close(self.handle);
    }

    fn configure(self: DB) !void {
        try self.execZ("PRAGMA journal_mode=WAL;");
        try self.execZ("PRAGMA synchronous=NORMAL;");
        try self.execZ("PRAGMA busy_timeout=5000;");
        try self.execZ("PRAGMA foreign_keys=ON;");
        try self.execZ("PRAGMA cache_size=-8000;");
    }

    pub fn execZ(self: DB, sql: [:0]const u8) !void {
        var errmsg: ?[*:0]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql.ptr, null, null, @ptrCast(&errmsg));
        if (rc != c.SQLITE_OK) {
            if (errmsg) |m| {
                log.err("db", "exec error: {s}", .{m});
                c.sqlite3_free(m);
            }
            return error.DBExecFailed;
        }
    }

    pub fn runMigrations(self: DB) !void {
        log.info("db", "running migrations", .{});
        // Always apply migration 001 first (creates schema_migrations table).
        try self.execZ(MIGRATION_001 ++ &[_:0]u8{});

        // Check if migration 002 has been applied.
        if (!self.migrationApplied(2)) {
            log.info("db", "applying migration 002", .{});
            try self.execZ(MIGRATION_002 ++ &[_:0]u8{});
        }
        log.info("db", "migrations complete", .{});
    }

    fn migrationApplied(self: DB, version: i32) bool {
        const sql = "SELECT 1 FROM schema_migrations WHERE version=?;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        const prepare_rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null);
        if (prepare_rc != c.SQLITE_OK) {
            const err = c.sqlite3_errmsg(self.handle);
            log.err("db", "migrationApplied prepare failed: rc={d} err={s}", .{ prepare_rc, err });
            return false;
        }

        const bind_rc = c.sqlite3_bind_int(stmt, 1, version);
        if (bind_rc != c.SQLITE_OK) {
            const err = c.sqlite3_errmsg(self.handle);
            log.err("db", "migrationApplied bind failed: rc={d} version={d} err={s}", .{ bind_rc, version, err });
            _ = c.sqlite3_finalize(stmt);
            return false;
        }

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_ROW and step_rc != c.SQLITE_DONE) {
            const err = c.sqlite3_errmsg(self.handle);
            log.err("db", "migrationApplied step failed: rc={d} err={s}", .{ step_rc, err });
        }
        _ = c.sqlite3_finalize(stmt);
        return step_rc == c.SQLITE_ROW;
    }

    pub fn insertOrder(self: DB, id: []const u8, market_id: []const u8, client_order_id: []const u8, order_type: []const u8, side: []const u8, size: []const u8, price: []const u8) !void {
        const sql = "INSERT INTO orders(id,market_id,client_order_id,type,side,size,price) VALUES(?,?,?,?,?,?,?);" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare insertOrder", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, market_id.ptr, @intCast(market_id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 3, client_order_id.ptr, @intCast(client_order_id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 4, order_type.ptr, @intCast(order_type.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 5, side.ptr, @intCast(side.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 6, size.ptr, @intCast(size.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 7, price.ptr, @intCast(price.len), null) != c.SQLITE_OK)
        {
            log.err("db", "failed to bind insertOrder parameters", .{});
            return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            log.err("db", "failed to execute insertOrder", .{});
            return error.DBExecFailed;
        }
    }

    pub fn updateOrderStatus(self: DB, order_id: []const u8, status: []const u8) !void {
        const sql = "UPDATE orders SET status=?,updated_at=unixepoch() WHERE id=?;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare updateOrderStatus", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, status.ptr, @intCast(status.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, order_id.ptr, @intCast(order_id.len), null) != c.SQLITE_OK)
        {
            log.err("db", "failed to bind updateOrderStatus parameters", .{});
            return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            log.err("db", "failed to execute updateOrderStatus", .{});
            return error.DBExecFailed;
        }
    }

    pub fn insertFill(self: DB, id: []const u8, order_id: []const u8, size: []const u8, price: []const u8, fee: []const u8) !void {
        const sql = "INSERT INTO fills(id,order_id,size,price,fee) VALUES(?,?,?,?,?);" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare insertFill", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, order_id.ptr, @intCast(order_id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 3, size.ptr, @intCast(size.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 4, price.ptr, @intCast(price.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 5, fee.ptr, @intCast(fee.len), null) != c.SQLITE_OK)
        {
            log.err("db", "failed to bind insertFill parameters", .{});
            return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            log.err("db", "failed to execute insertFill", .{});
            return error.DBExecFailed;
        }
    }

    pub fn recordRiskRejection(self: DB, order_id: []const u8, market_id: []const u8, check_name: []const u8, reason: []const u8, limit_value: []const u8, actual_value: []const u8) !void {
        const sql = "INSERT INTO risk_events(order_id,market_id,check_name,reason,limit_value,actual_value) VALUES(?,?,?,?,?,?);" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare recordRiskRejection", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, order_id.ptr, @intCast(order_id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, market_id.ptr, @intCast(market_id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 3, check_name.ptr, @intCast(check_name.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 4, reason.ptr, @intCast(reason.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 5, limit_value.ptr, @intCast(limit_value.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 6, actual_value.ptr, @intCast(actual_value.len), null) != c.SQLITE_OK)
        {
            log.err("db", "failed to bind recordRiskRejection parameters", .{});
            return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            log.err("db", "failed to execute recordRiskRejection", .{});
            return error.DBExecFailed;
        }
    }

    pub fn queryOpenOrderCount(self: DB) !u32 {
        const sql = "SELECT count(*) FROM orders WHERE status NOT IN ('filled','cancelled','rejected');" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare queryOpenOrderCount", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
            log.err("db", "failed to execute queryOpenOrderCount", .{});
            return error.DBExecFailed;
        }
        return @intCast(c.sqlite3_column_int(stmt, 0));
    }

    pub fn queryOpenExposureUsd(self: DB) !f64 {
        const sql = "SELECT COALESCE(SUM(CAST(size AS REAL) * CAST(price AS REAL)), 0.0) FROM orders WHERE status NOT IN ('filled','cancelled','rejected');" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare queryOpenExposureUsd", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
            log.err("db", "failed to execute queryOpenExposureUsd", .{});
            return error.DBExecFailed;
        }
        return c.sqlite3_column_double(stmt, 0);
    }

    pub fn queryPositionByMarketDirection(self: DB, market_id: []const u8, side: []const u8) !bool {
        const sql = "SELECT count(*) FROM positions WHERE market_id=? AND side=? AND status='open';" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare queryPositionByMarketDirection", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, market_id.ptr, @intCast(market_id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, side.ptr, @intCast(side.len), null) != c.SQLITE_OK)
        {
            log.err("db", "failed to bind queryPositionByMarketDirection parameters", .{});
            return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
            log.err("db", "failed to execute queryPositionByMarketDirection", .{});
            return error.DBExecFailed;
        }
        return c.sqlite3_column_int(stmt, 0) > 0;
    }

    pub fn queryTodaysRealizedAndUnrealizedLoss(self: DB) !f64 {
        const sql = "SELECT COALESCE(SUM(CAST(pnl AS REAL)), 0.0) FROM positions WHERE updated_at >= unixepoch('now','start of day');" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare queryTodaysRealizedAndUnrealizedLoss", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
            log.err("db", "failed to execute queryTodaysRealizedAndUnrealizedLoss", .{});
            return error.DBExecFailed;
        }
        return c.sqlite3_column_double(stmt, 0);
    }

    /// Return journal_mode as a stack-allocated slice (for health check).
    pub fn journalMode(self: DB, buf: []u8) []const u8 {
        var stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(self.handle, "PRAGMA journal_mode;", -1, &stmt, null);
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const val: [*c]const u8 = @ptrCast(c.sqlite3_column_text(stmt, 0));
            const s = std.mem.span(val);
            const n = @min(s.len, buf.len);
            @memcpy(buf[0..n], s[0..n]);
            return buf[0..n];
        }
        return "unknown";
    }
};
