//! SQLite WAL database wrapper (C interop via sqlite3.h).
const std = @import("std");
const log = @import("logger.zig");

// NOTE: Keep embedded MIGRATION_00N SQL in sync with db/migrations/00N_*.sql.
// Shell tooling applies file-based migrations, while the engine applies embedded migrations.

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

/// Embedded Phase-3 migration (strategy engine tables).
const MIGRATION_003 =
    \\CREATE TABLE IF NOT EXISTS strategy_stats(id INTEGER PRIMARY KEY AUTOINCREMENT,strategy TEXT NOT NULL,signals_emitted INTEGER NOT NULL DEFAULT 0,orders_accepted INTEGER NOT NULL DEFAULT 0,orders_rejected INTEGER NOT NULL DEFAULT 0,cancels INTEGER NOT NULL DEFAULT 0,realized_pnl_estimate REAL NOT NULL DEFAULT 0.0,snapshot_at INTEGER NOT NULL DEFAULT(unixepoch()));
    \\CREATE INDEX IF NOT EXISTS idx_strategy_stats_at ON strategy_stats(snapshot_at DESC);
    \\INSERT OR IGNORE INTO schema_migrations(version)VALUES(3);
;

/// Embedded Phase-5 migration (runtime config table).
const MIGRATION_004 =
    \\CREATE TABLE IF NOT EXISTS runtime_config(key TEXT PRIMARY KEY,value TEXT NOT NULL,updated_at INTEGER NOT NULL DEFAULT(unixepoch()));
    \\CREATE INDEX IF NOT EXISTS idx_runtime_config_key ON runtime_config(key);
    \\INSERT OR IGNORE INTO schema_migrations(version)VALUES(4);
;

/// Embedded migration: market trading metadata for Polymarket CLOB order construction.
const MIGRATION_005 =
    \\ALTER TABLE markets ADD COLUMN condition_id TEXT DEFAULT '';
    \\ALTER TABLE markets ADD COLUMN clob_token_ids TEXT DEFAULT '[]';
    \\ALTER TABLE markets ADD COLUMN outcomes TEXT DEFAULT '[]';
    \\ALTER TABLE markets ADD COLUMN neg_risk INTEGER DEFAULT 0;
    \\ALTER TABLE markets ADD COLUMN min_tick_size TEXT DEFAULT '0.01';
    \\INSERT OR IGNORE INTO schema_migrations(version)VALUES(5);
;

/// Embedded migration: remove UNIQUE from markets.symbol (slug collision fix).
const MIGRATION_006 =
    \\BEGIN TRANSACTION;
    \\CREATE TABLE IF NOT EXISTS markets_new(id TEXT PRIMARY KEY,symbol TEXT NOT NULL,base TEXT NOT NULL,quote TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'active',created_at INTEGER NOT NULL DEFAULT(unixepoch()),condition_id TEXT DEFAULT '',clob_token_ids TEXT DEFAULT '[]',outcomes TEXT DEFAULT '[]',neg_risk INTEGER DEFAULT 0,min_tick_size TEXT DEFAULT '0.01');
    \\INSERT OR IGNORE INTO markets_new SELECT id,symbol,base,quote,status,created_at,condition_id,clob_token_ids,outcomes,neg_risk,min_tick_size FROM markets;
    \\DROP TABLE IF EXISTS markets;
    \\ALTER TABLE markets_new RENAME TO markets;
    \\COMMIT;
;

/// Embedded migration: fill tracking columns on orders table.
const MIGRATION_007 =
    \\INSERT OR IGNORE INTO schema_migrations(version)VALUES(7);
;

/// Embedded migration: LP inventory management and paired-leg cancel-on-fill.
const MIGRATION_008 =
    \\INSERT OR IGNORE INTO schema_migrations(version)VALUES(8);
;

/// Embedded migration: dry-run signal tracking table.
const MIGRATION_009 =
    \\CREATE TABLE IF NOT EXISTS dry_run_signals(id INTEGER PRIMARY KEY AUTOINCREMENT,market_id TEXT NOT NULL,strategy TEXT NOT NULL,direction TEXT NOT NULL,price REAL NOT NULL,size REAL NOT NULL,delta REAL NOT NULL,confidence REAL NOT NULL,signal_ts INTEGER NOT NULL,best_bid REAL,best_ask REAL,created_at INTEGER NOT NULL DEFAULT(unixepoch()));
    \\CREATE INDEX IF NOT EXISTS idx_dry_run_signals_ts ON dry_run_signals(signal_ts);
    \\CREATE INDEX IF NOT EXISTS idx_dry_run_signals_market ON dry_run_signals(market_id);
    \\INSERT OR IGNORE INTO schema_migrations(version)VALUES(9);
;

pub const DB = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) !DB {
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path.ptr, &handle, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null);
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
        try self.execZ("PRAGMA foreign_keys=OFF;");
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

        // Check if migration 003 has been applied.
        if (!self.migrationApplied(3)) {
            log.info("db", "applying migration 003", .{});
            // Ignore only the duplicate-column case; surface all other ALTER failures.
            self.execZ("ALTER TABLE orders ADD COLUMN strategy_origin TEXT DEFAULT NULL;" ++ &[_:0]u8{}) catch |err| {
                const sqlite_err = std.mem.span(c.sqlite3_errmsg(self.handle));
                const duplicate_col = std.mem.indexOf(u8, sqlite_err, "duplicate column name: strategy_origin") != null;

                if (err == error.DBExecFailed and duplicate_col) {
                    log.info("db", "orders.strategy_origin already exists; skipping ALTER TABLE", .{});
                } else {
                    log.err("db", "migration 003 ALTER TABLE failed: zig_err={s} sqlite_err={s}", .{ @errorName(err), sqlite_err });
                    return err;
                }
            };
            try self.execZ(MIGRATION_003 ++ &[_:0]u8{});
        }
        // Check if migration 004 has been applied.
        if (!self.migrationApplied(4)) {
            log.info("db", "applying migration 004", .{});
            try self.execZ(MIGRATION_004 ++ &[_:0]u8{});
        }
        // Check if migration 005 has been applied.
        if (!self.migrationApplied(5)) {
            log.info("db", "applying migration 005", .{});
            // List of ALTER TABLE statements for migration 005
            const alters = [_][:0]const u8{
                "ALTER TABLE markets ADD COLUMN condition_id TEXT DEFAULT '';",
                "ALTER TABLE markets ADD COLUMN clob_token_ids TEXT DEFAULT '[]';",
                "ALTER TABLE markets ADD COLUMN outcomes TEXT DEFAULT '[]';",
                "ALTER TABLE markets ADD COLUMN neg_risk INTEGER DEFAULT 0;",
                "ALTER TABLE markets ADD COLUMN min_tick_size TEXT DEFAULT '0.01';",
            };
            for (alters) |sql| {
                self.execZ(sql) catch |err| {
                    const sqlite_err = std.mem.span(c.sqlite3_errmsg(self.handle));
                    const duplicate_col = std.mem.indexOf(u8, sqlite_err, "duplicate column name") != null;
                    if (err == error.DBExecFailed and duplicate_col) {
                        log.info("db", "migration 005: column already exists; skipping ALTER TABLE: {s}", .{sql});
                        continue;
                    } else {
                        log.err("db", "migration 005 ALTER TABLE failed: zig_err={s} sqlite_err={s} sql={s}", .{ @errorName(err), sqlite_err, sql });
                        return err;
                    }
                };
            }
            // Only after all alters succeed/are skipped, mark migration 5 as applied
            try self.execZ("INSERT OR IGNORE INTO schema_migrations(version)VALUES(5);");
        }
        // Check if migration 006 has been applied.
        if (!self.migrationApplied(6)) {
            log.info("db", "applying migration 006", .{});
            self.execZ(MIGRATION_006 ++ &[_:0]u8{}) catch |err| {
                const sqlite_err = std.mem.span(c.sqlite3_errmsg(self.handle));
                log.err("db", "migration 006 table recreation failed: zig_err={s} sqlite_err={s}", .{ @errorName(err), sqlite_err });
                return err;
            };
            // Add gamma_id column and condition_id index to orderbooks (table may not exist yet)
            const ob_alters = [_][:0]const u8{
                "CREATE INDEX IF NOT EXISTS idx_orderbooks_market ON orderbooks(market);",
                "ALTER TABLE orderbooks ADD COLUMN gamma_id TEXT DEFAULT NULL;",
                "CREATE INDEX IF NOT EXISTS idx_orderbooks_gamma_id ON orderbooks(gamma_id);",
            };

            for (ob_alters) |sql| {
                self.execZ(sql) catch |err| {
                    const sqlite_err = std.mem.span(c.sqlite3_errmsg(self.handle));
                    const duplicate_col = std.mem.indexOf(u8, sqlite_err, "duplicate column name") != null;
                    const no_table = std.mem.indexOf(u8, sqlite_err, "no such table") != null;
                    if (err == error.DBExecFailed and (duplicate_col or no_table)) {
                        log.info("db", "migration 006: skipping orderbooks alter (table missing or column exists): {s}", .{sql});
                    } else {
                        log.err("db", "migration 006 orderbooks alter failed: zig_err={s} sqlite_err={s}", .{ @errorName(err), sqlite_err });
                        return err;
                    }
                };
            }
            try self.execZ("INSERT OR IGNORE INTO schema_migrations(version)VALUES(6);");
        }
        // Check if migration 007 has been applied.
        if (!self.migrationApplied(7)) {
            log.info("db", "applying migration 007", .{});
            const fill_alters = [_][:0]const u8{
                "ALTER TABLE orders ADD COLUMN filled_size TEXT DEFAULT '0';",
                "ALTER TABLE orders ADD COLUMN average_fill_price TEXT DEFAULT NULL;",
                "ALTER TABLE orders ADD COLUMN last_checked_at INTEGER DEFAULT 0;",
                "ALTER TABLE fills ADD COLUMN detected_at INTEGER DEFAULT 0;",
            };
            for (fill_alters) |sql| {
                self.execZ(sql) catch |err| {
                    const sqlite_err = std.mem.span(c.sqlite3_errmsg(self.handle));
                    const duplicate_col = std.mem.indexOf(u8, sqlite_err, "duplicate column name") != null;
                    if (err == error.DBExecFailed and duplicate_col) {
                        log.info("db", "migration 007: column already exists; skipping ALTER TABLE: {s}", .{sql});
                        continue;
                    } else {
                        log.err("db", "migration 007 ALTER TABLE failed: zig_err={s} sqlite_err={s} sql={s}", .{ @errorName(err), sqlite_err, sql });
                        return err;
                    }
                };
            }
            try self.execZ("INSERT OR IGNORE INTO schema_migrations(version)VALUES(7);");
        }
        // Check if migration 008 has been applied.
        if (!self.migrationApplied(8)) {
            log.info("db", "applying migration 008", .{});
            const m008_alters = [_][:0]const u8{
                "ALTER TABLE positions ADD COLUMN net_position_usd REAL DEFAULT 0.0;",
                "ALTER TABLE orders ADD COLUMN lp_pair_order_id TEXT DEFAULT NULL;",
            };
            for (m008_alters) |sql| {
                self.execZ(sql) catch |err| {
                    const sqlite_err = std.mem.span(c.sqlite3_errmsg(self.handle));
                    const duplicate_col = std.mem.indexOf(u8, sqlite_err, "duplicate column name") != null;
                    if (err == error.DBExecFailed and duplicate_col) {
                        log.info("db", "migration 008: column already exists; skipping ALTER TABLE: {s}", .{sql});
                        continue;
                    } else {
                        log.err("db", "migration 008 ALTER TABLE failed: zig_err={s} sqlite_err={s} sql={s}", .{ @errorName(err), sqlite_err, sql });
                        return err;
                    }
                };
            }
            // Seed default max_net_position_usd into runtime_config
            self.execZ("INSERT OR IGNORE INTO runtime_config(key,value) VALUES('lp_max_position_usd','50.0');" ++ &[_:0]u8{}) catch |err| {
                log.info("db", "migration 008: runtime_config seed skipped or failed: {s}", .{@errorName(err)});
            };
            try self.execZ("INSERT OR IGNORE INTO schema_migrations(version)VALUES(8);");
        }
        if (!self.migrationApplied(9)) {
            log.info("db", "applying migration 009", .{});
            try self.execZ(MIGRATION_009 ++ &[_:0]u8{});
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

    pub fn insertOrder(self: DB, id: []const u8, market_id: []const u8, client_order_id: []const u8, order_type: []const u8, side: []const u8, size: []const u8, price: []const u8, strategy_origin: ?[]const u8) !void {
        const sql = "INSERT INTO orders(id,market_id,client_order_id,type,side,size,price,strategy_origin) VALUES(?,?,?,?,?,?,?,?);" ++ &[_:0]u8{};
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

        if (strategy_origin) |so| {
            if (c.sqlite3_bind_text(stmt, 8, so.ptr, @intCast(so.len), null) != c.SQLITE_OK) {
                log.err("db", "failed to bind insertOrder strategy_origin", .{});
                return error.DBExecFailed;
            }
        } else {
            if (c.sqlite3_bind_null(stmt, 8) != c.SQLITE_OK) {
                log.err("db", "failed to bind insertOrder strategy_origin null", .{});
                return error.DBExecFailed;
            }
        }

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_DONE) {
            const sqlite_err = std.mem.span(c.sqlite3_errmsg(self.handle));
            log.err("db", "failed to execute insertOrder: rc={d} err={s}", .{ step_rc, sqlite_err });
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
        const sql = "INSERT INTO fills(id,order_id,size,price,fee,detected_at) VALUES(?,?,?,?,?,unixepoch());" ++ &[_:0]u8{};
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

    pub fn insertStrategySignal(self: DB, market_id: []const u8, signal_type: []const u8, strength: f64, metadata: []const u8) !void {
        const sql = "INSERT INTO strategy_signals(id,market_id,signal_type,strength,metadata) VALUES(hex(randomblob(16)),?,?,?,?);" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare insertStrategySignal", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, market_id.ptr, @intCast(market_id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, signal_type.ptr, @intCast(signal_type.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 3, strength) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 4, metadata.ptr, @intCast(metadata.len), null) != c.SQLITE_OK)
        {
            log.err("db", "failed to bind insertStrategySignal parameters", .{});
            return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            log.err("db", "failed to execute insertStrategySignal", .{});
            return error.DBExecFailed;
        }
    }

    pub const StrategyStatsRow = struct {
        signals_emitted: i64,
        orders_accepted: i64,
        orders_rejected: i64,
        cancels: i64,
        realized_pnl_estimate: f64,
        snapshot_at: i64,
    };

    pub fn queryStrategyStats(self: DB, strategy_name: []const u8) !?StrategyStatsRow {
        const sql = "SELECT signals_emitted,orders_accepted,orders_rejected,cancels,realized_pnl_estimate,snapshot_at FROM strategy_stats WHERE strategy=? ORDER BY snapshot_at DESC LIMIT 1;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare queryStrategyStats", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, strategy_name.ptr, @intCast(strategy_name.len), null) != c.SQLITE_OK) {
            log.err("db", "failed to bind queryStrategyStats parameters", .{});
            return error.DBExecFailed;
        }

        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) {
            const err_code = c.sqlite3_errcode(self.handle);
            const err_msg = c.sqlite3_errmsg(self.handle);
            log.err("db", "queryStrategyStats step failed: rc={d} err_code={d} err={s}", .{ rc, err_code, err_msg });
            return error.DBExecFailed;
        }

        return StrategyStatsRow{
            .signals_emitted = c.sqlite3_column_int64(stmt, 0),
            .orders_accepted = c.sqlite3_column_int64(stmt, 1),
            .orders_rejected = c.sqlite3_column_int64(stmt, 2),
            .cancels = c.sqlite3_column_int64(stmt, 3),
            .realized_pnl_estimate = c.sqlite3_column_double(stmt, 4),
            .snapshot_at = c.sqlite3_column_int64(stmt, 5),
        };
    }

    pub const SignalRow = struct {
        id_buf: [64]u8,
        id_len: usize,
        market_id_buf: [64]u8,
        market_id_len: usize,
        strength: f64,
        created_at: i64,
    };

    pub fn queryRecentSignalsByStrategy(self: DB, strategy_name: []const u8, limit: u32, out: []SignalRow) !usize {
        const sql = "SELECT id,market_id,strength,created_at FROM strategy_signals WHERE signal_type=? ORDER BY created_at DESC LIMIT ?;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare queryRecentSignalsByStrategy", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, strategy_name.ptr, @intCast(strategy_name.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_int(stmt, 2, @intCast(limit)) != c.SQLITE_OK)
        {
            log.err("db", "failed to bind queryRecentSignalsByStrategy parameters", .{});
            return error.DBExecFailed;
        }

        var count: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (count >= out.len) break;
            var row: SignalRow = .{
                .id_buf = undefined,
                .id_len = 0,
                .market_id_buf = undefined,
                .market_id_len = 0,
                .strength = c.sqlite3_column_double(stmt, 2),
                .created_at = c.sqlite3_column_int64(stmt, 3),
            };

            const id_ptr = c.sqlite3_column_text(stmt, 0);
            const id_span = if (id_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
            const id_len = @min(id_span.len, 64);
            @memcpy(row.id_buf[0..id_len], id_span[0..id_len]);
            row.id_len = id_len;

            const mid_ptr = c.sqlite3_column_text(stmt, 1);
            const mid_span = if (mid_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
            const mid_len = @min(mid_span.len, 64);
            @memcpy(row.market_id_buf[0..mid_len], mid_span[0..mid_len]);
            row.market_id_len = mid_len;

            out[count] = row;
            count += 1;
        }
        return count;
    }

    pub fn insertStrategyStats(self: DB, strategy: []const u8, signals: u64, accepted: u64, rejected: u64, cancels: u64, pnl: f64) !void {
        const sql = "INSERT INTO strategy_stats(strategy,signals_emitted,orders_accepted,orders_rejected,cancels,realized_pnl_estimate) VALUES(?,?,?,?,?,?);" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare insertStrategyStats", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, strategy.ptr, @intCast(strategy.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_int64(stmt, 2, @intCast(signals)) != c.SQLITE_OK or
            c.sqlite3_bind_int64(stmt, 3, @intCast(accepted)) != c.SQLITE_OK or
            c.sqlite3_bind_int64(stmt, 4, @intCast(rejected)) != c.SQLITE_OK or
            c.sqlite3_bind_int64(stmt, 5, @intCast(cancels)) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 6, pnl) != c.SQLITE_OK)
        {
            log.err("db", "failed to bind insertStrategyStats parameters", .{});
            return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            log.err("db", "failed to execute insertStrategyStats", .{});
            return error.DBExecFailed;
        }
    }

    pub fn getConfig(self: DB, key: []const u8, buf: []u8) ?[]u8 {
        const sql = "SELECT value FROM runtime_config WHERE key=?;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), null) != c.SQLITE_OK) return null;
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const val_ptr = c.sqlite3_column_text(stmt, 0);
        const val = if (val_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else return null;
        if (val.len > buf.len) return null;
        @memcpy(buf[0..val.len], val[0..val.len]);
        return buf[0..val.len];
    }

    pub fn getAllConfig(self: DB, alloc: std.mem.Allocator) ![]u8 {
        const sql = "SELECT key,value FROM runtime_config ORDER BY key;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare getAllConfig", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.append(alloc, '{');
        var first = true;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const key_ptr = c.sqlite3_column_text(stmt, 0);
            const key = if (key_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;
            const val_ptr = c.sqlite3_column_text(stmt, 1);
            const val = if (val_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;
            if (!first) try out.append(alloc, ',');
            first = false;
            try out.append(alloc, '"');
            try out.appendSlice(alloc, key);
            try out.appendSlice(alloc, "\":\"");
            try out.appendSlice(alloc, val);
            try out.append(alloc, '"');
        }
        try out.append(alloc, '}');
        return out.toOwnedSlice(alloc);
    }

    pub fn setConfig(self: DB, key: []const u8, value: []const u8, old_buf: []u8) !?[]u8 {
        try self.execZ("BEGIN IMMEDIATE;" ++ &[_:0]u8{});
        errdefer {
            self.execZ("ROLLBACK;" ++ &[_:0]u8{}) catch |e| {
                log.err("db", "failed to rollback setConfig transaction: {s}", .{@errorName(e)});
            };
        }

        // Read previous value inside the same transaction to avoid stale audit data.
        const old_value = self.getConfig(key, old_buf);

        // Upsert the config value
        const upsert_sql = "INSERT INTO runtime_config(key,value,updated_at) VALUES(?,?,unixepoch()) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, upsert_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare setConfig", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, value.ptr, @intCast(value.len), null) != c.SQLITE_OK)
        {
            log.err("db", "failed to bind setConfig parameters", .{});
            return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            log.err("db", "failed to execute setConfig", .{});
            return error.DBExecFailed;
        }

        // Write audit entry in the same transaction as the upsert.
        try self.insertConfigChange(key, old_value, value);
        try self.execZ("COMMIT;" ++ &[_:0]u8{});

        return old_value;
    }

    fn insertConfigChange(self: DB, key: []const u8, old_value: ?[]const u8, new_value: []const u8) !void {
        const sql = "INSERT INTO config_changes(id,key,old_value,new_value,changed_by) VALUES(hex(randomblob(16)),?,?,?,'telegram');" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare insertConfigChange", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), null) != c.SQLITE_OK) return error.DBExecFailed;
        if (old_value) |ov| {
            if (c.sqlite3_bind_text(stmt, 2, ov.ptr, @intCast(ov.len), null) != c.SQLITE_OK) return error.DBExecFailed;
        } else {
            if (c.sqlite3_bind_null(stmt, 2) != c.SQLITE_OK) return error.DBExecFailed;
        }
        if (c.sqlite3_bind_text(stmt, 3, new_value.ptr, @intCast(new_value.len), null) != c.SQLITE_OK) return error.DBExecFailed;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            log.err("db", "failed to execute insertConfigChange", .{});
            return error.DBExecFailed;
        }
    }

    pub const PnlResult = struct {
        realized_pnl: f64,
        win_count: i64,
        loss_count: i64,
        avg_win: f64,
        avg_loss: f64,
    };

    pub fn queryPnl(self: DB, window: []const u8) !PnlResult {
        // Determine the time filter based on window
        const time_filter: []const u8 = if (std.mem.eql(u8, window, "today"))
            " AND p.updated_at >= unixepoch('now','start of day')"
        else if (std.mem.eql(u8, window, "7d"))
            " AND p.updated_at >= unixepoch('now','-7 days')"
        else if (std.mem.eql(u8, window, "30d"))
            " AND p.updated_at >= unixepoch('now','-30 days')"
        else
            ""; // "all" — no filter

        // Build SQL for realized P&L from closed positions
        var sql_buf: [512]u8 = undefined;
        const sql = std.fmt.bufPrint(
            &sql_buf,
            "SELECT COALESCE(SUM(CAST(pnl AS REAL)),0.0)," ++
                "COALESCE(SUM(CASE WHEN CAST(pnl AS REAL)>0 THEN 1 ELSE 0 END),0)," ++
                "COALESCE(SUM(CASE WHEN CAST(pnl AS REAL)<0 THEN 1 ELSE 0 END),0)," ++
                "COALESCE(AVG(CASE WHEN CAST(pnl AS REAL)>0 THEN CAST(pnl AS REAL) END),0.0)," ++
                "COALESCE(AVG(CASE WHEN CAST(pnl AS REAL)<0 THEN CAST(pnl AS REAL) END),0.0)" ++
                " FROM positions p WHERE p.status='closed'{s};" ++
                &[_:0]u8{},
            .{time_filter},
        ) catch return error.DBExecFailed;

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare queryPnl", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
            return PnlResult{ .realized_pnl = 0, .win_count = 0, .loss_count = 0, .avg_win = 0, .avg_loss = 0 };
        }

        return PnlResult{
            .realized_pnl = c.sqlite3_column_double(stmt, 0),
            .win_count = c.sqlite3_column_int64(stmt, 1),
            .loss_count = c.sqlite3_column_int64(stmt, 2),
            .avg_win = c.sqlite3_column_double(stmt, 3),
            .avg_loss = c.sqlite3_column_double(stmt, 4),
        };
    }

    pub fn updateOrderFillStatus(self: DB, order_id: []const u8, status: []const u8, filled_size: []const u8, avg_fill_price: ?[]const u8) !void {
        const sql = "UPDATE orders SET status=?, filled_size=?, average_fill_price=?, last_checked_at=unixepoch(), updated_at=unixepoch() WHERE id=?;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare updateOrderFillStatus", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, status.ptr, @intCast(status.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, filled_size.ptr, @intCast(filled_size.len), null) != c.SQLITE_OK)
        {
            return error.DBExecFailed;
        }
        if (avg_fill_price) |afp| {
            if (c.sqlite3_bind_text(stmt, 3, afp.ptr, @intCast(afp.len), null) != c.SQLITE_OK) return error.DBExecFailed;
        } else {
            if (c.sqlite3_bind_null(stmt, 3) != c.SQLITE_OK) return error.DBExecFailed;
        }
        if (c.sqlite3_bind_text(stmt, 4, order_id.ptr, @intCast(order_id.len), null) != c.SQLITE_OK) return error.DBExecFailed;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            log.err("db", "failed to execute updateOrderFillStatus", .{});
            return error.DBExecFailed;
        }
    }

    pub fn updateOrderLastChecked(self: DB, order_id: []const u8) !void {
        const sql = "UPDATE orders SET last_checked_at=unixepoch() WHERE id=?;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare updateOrderLastChecked", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, order_id.ptr, @intCast(order_id.len), null) != c.SQLITE_OK) return error.DBExecFailed;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            log.err("db", "failed to execute updateOrderLastChecked", .{});
            return error.DBExecFailed;
        }
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

    /// Insert a dry-run signal record for later analysis.
    pub fn insertDryRunSignal(
        self: DB,
        market_id: []const u8,
        strategy_name: []const u8,
        direction: []const u8,
        price: f64,
        size: f64,
        delta: f64,
        confidence: f64,
        signal_ts: i64,
        best_bid: ?f64,
        best_ask: ?f64,
    ) !void {
        const sql = "INSERT INTO dry_run_signals(market_id,strategy,direction,price,size,delta,confidence,signal_ts,best_bid,best_ask) VALUES(?,?,?,?,?,?,?,?,?,?);" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare insertDryRunSignal", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, market_id.ptr, @intCast(market_id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, strategy_name.ptr, @intCast(strategy_name.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 3, direction.ptr, @intCast(direction.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 4, price) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 5, size) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 6, delta) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 7, confidence) != c.SQLITE_OK or
            c.sqlite3_bind_int64(stmt, 8, signal_ts) != c.SQLITE_OK)
        {
            log.err("db", "failed to bind insertDryRunSignal parameters", .{});
            return error.DBExecFailed;
        }
        if (best_bid) |bb| {
            _ = c.sqlite3_bind_double(stmt, 9, bb);
        } else {
            _ = c.sqlite3_bind_null(stmt, 9);
        }
        if (best_ask) |ba| {
            _ = c.sqlite3_bind_double(stmt, 10, ba);
        } else {
            _ = c.sqlite3_bind_null(stmt, 10);
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            log.err("db", "failed to execute insertDryRunSignal", .{});
            return error.DBExecFailed;
        }
    }

    /// Analyze dry-run signals: persistence rate and hypothetical P&L.
    /// Writes a JSON report to the provided buffer.
    /// Persistence check: a signal is "persistent" if another signal for the same
    /// market+direction exists >= 15 seconds after it.
    pub fn analyzeDryRunSignals(self: DB, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        // Total signals
        var total: i64 = 0;
        {
            const sql = "SELECT COUNT(*) FROM dry_run_signals;" ++ &[_:0]u8{};
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                total = c.sqlite3_column_int64(stmt, 0);
            }
        }

        // Persistent signals (>15s): a signal is persistent if there exists another
        // signal for the same market+strategy+direction at least 15 seconds later.
        var persistent: i64 = 0;
        {
            const sql = "SELECT COUNT(*) FROM dry_run_signals s WHERE EXISTS (SELECT 1 FROM dry_run_signals s2 WHERE s2.market_id=s.market_id AND s2.strategy=s.strategy AND s2.direction=s.direction AND s2.signal_ts >= s.signal_ts + 15 LIMIT 1);" ++ &[_:0]u8{};
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                persistent = c.sqlite3_column_int64(stmt, 0);
            }
        }

        // Hypothetical P&L: for each signal, optimistic fill = at signal price,
        // pessimistic fill = at signal price +/- half spread (worse by half spread).
        // For buy: profit if market moved up from entry; for sell: profit if market moved down.
        // We approximate final price as the latest signal price for that market.
        var optimistic_pnl: f64 = 0.0;
        var pessimistic_pnl: f64 = 0.0;
        {
            const sql =
                \\SELECT s.direction, s.price, s.size, s.best_bid, s.best_ask,
                \\  (SELECT s2.price FROM dry_run_signals s2 WHERE s2.market_id=s.market_id ORDER BY s2.signal_ts DESC LIMIT 1) AS latest_price
                \\FROM dry_run_signals s;
            ++ &[_:0]u8{};
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
            defer _ = c.sqlite3_finalize(stmt);

            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const dir_raw = c.sqlite3_column_text(stmt, 0);
                const dir = if (dir_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;
                const entry_price = c.sqlite3_column_double(stmt, 1);
                const size = c.sqlite3_column_double(stmt, 2);
                const has_bid = c.sqlite3_column_type(stmt, 3) != c.SQLITE_NULL;
                const has_ask = c.sqlite3_column_type(stmt, 4) != c.SQLITE_NULL;
                const latest_price = c.sqlite3_column_double(stmt, 5);

                const half_spread = if (has_bid and has_ask)
                    (c.sqlite3_column_double(stmt, 4) - c.sqlite3_column_double(stmt, 3)) / 2.0
                else
                    0.01; // default spread assumption

                const is_buy = std.mem.eql(u8, dir, "buy");
                if (is_buy) {
                    optimistic_pnl += (latest_price - entry_price) * size;
                    pessimistic_pnl += (latest_price - (entry_price + half_spread)) * size;
                } else {
                    optimistic_pnl += (entry_price - latest_price) * size;
                    pessimistic_pnl += ((entry_price - half_spread) - latest_price) * size;
                }
            }
        }

        const persistence_pct: f64 = if (total > 0) @as(f64, @floatFromInt(persistent)) / @as(f64, @floatFromInt(total)) * 100.0 else 0.0;

        try writer.print(
            "{{\"total_signals\":{d},\"persistent_signals\":{d},\"persistence_pct\":{d:.1},\"optimistic_pnl\":{d:.4},\"pessimistic_pnl\":{d:.4},\"diagnosis\":\"{s}\"}}",
            .{
                total,
                persistent,
                persistence_pct,
                optimistic_pnl,
                pessimistic_pnl,
                if (optimistic_pnl < 0) "signal_broken" else if (pessimistic_pnl < 0) "fill_rate_problem" else "viable",
            },
        );
        return fbs.getWritten();
    }
};
