//! SQLite WAL database wrapper (C interop via sqlite3.h).
const std = @import("std");
const log = @import("logger.zig");

const c = @cImport(@cInclude("sqlite3.h"));

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
        // execZ requires null-terminator; MIGRATION_001 is a comptime string literal
        try self.execZ(MIGRATION_001 ++ &[_:0]u8{});
        log.info("db", "migrations complete", .{});
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
