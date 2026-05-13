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
    \\CREATE INDEX IF NOT EXISTS idx_dry_run_signals_market_ts ON dry_run_signals(market_id,signal_ts);
    \\CREATE INDEX IF NOT EXISTS idx_dry_run_signals_group_ts ON dry_run_signals(market_id,strategy,direction,signal_ts);
    \\INSERT OR IGNORE INTO schema_migrations(version)VALUES(9);
;

/// Embedded migration: Kalshi auto-mapping persistence + dry-run order
/// lifecycle tracking + LP cooldown / position pct defaults.
const MIGRATION_010 =
    \\CREATE TABLE IF NOT EXISTS kalshi_market_map(
    \\  ticker TEXT PRIMARY KEY,
    \\  gamma_id TEXT NOT NULL,
    \\  confidence REAL NOT NULL DEFAULT 0.0,
    \\  match_method TEXT NOT NULL DEFAULT 'auto',
    \\  created_at INTEGER NOT NULL DEFAULT(unixepoch()),
    \\  updated_at INTEGER NOT NULL DEFAULT(unixepoch())
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_kalshi_map_gamma ON kalshi_market_map(gamma_id);
    \\CREATE TABLE IF NOT EXISTS dry_run_orders(
    \\  id TEXT PRIMARY KEY,
    \\  market_id TEXT NOT NULL,
    \\  strategy TEXT NOT NULL,
    \\  direction TEXT NOT NULL,
    \\  signal_price REAL NOT NULL,
    \\  size REAL NOT NULL,
    \\  status TEXT NOT NULL DEFAULT 'open',
    \\  fill_price REAL,
    \\  fill_ts INTEGER,
    \\  pnl REAL,
    \\  fees REAL,
    \\  created_at INTEGER NOT NULL DEFAULT(unixepoch()),
    \\  updated_at INTEGER NOT NULL DEFAULT(unixepoch())
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_dry_run_orders_status  ON dry_run_orders(status);
    \\CREATE INDEX IF NOT EXISTS idx_dry_run_orders_market  ON dry_run_orders(market_id, status);
    \\CREATE INDEX IF NOT EXISTS idx_dry_run_orders_created ON dry_run_orders(created_at DESC);
    \\INSERT OR IGNORE INTO runtime_config(key,value) VALUES('lp_cooldown_seconds','15');
    \\INSERT OR IGNORE INTO runtime_config(key,value) VALUES('lp_max_position_usd_pct','0.20');
    \\INSERT OR IGNORE INTO schema_migrations(version)VALUES(10);
;

/// Embedded migration: dry-run analysis indexes for fast per-market scans.
const MIGRATION_011 =
    \\CREATE INDEX IF NOT EXISTS idx_dry_run_signals_market_ts ON dry_run_signals(market_id,signal_ts);
    \\CREATE INDEX IF NOT EXISTS idx_dry_run_signals_group_ts ON dry_run_signals(market_id,strategy,direction,signal_ts);
    \\INSERT OR IGNORE INTO schema_migrations(version)VALUES(11);
;

/// Embedded Phase-5 migration: HL portfolio + fill detection schema.
/// Adds HL margin/funding columns to positions, asset_index/reduce_only to
/// orders, dry-run telemetry columns, and creates funding_snapshots and
/// arb_events tables. ALTER TABLE statements are run separately in
/// runMigrations so duplicate-column errors are tolerated.
const MIGRATION_013 =
    \\CREATE TABLE IF NOT EXISTS funding_snapshots(
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  asset TEXT NOT NULL,
    \\  rate REAL NOT NULL,
    \\  next_payment_ts INTEGER NOT NULL,
    \\  recorded_at INTEGER NOT NULL DEFAULT(unixepoch())
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_funding_snapshots_asset_ts ON funding_snapshots(asset, recorded_at DESC);
    \\CREATE TABLE IF NOT EXISTS arb_events(
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  asset TEXT NOT NULL,
    \\  binance_mid REAL NOT NULL,
    \\  hl_mid REAL NOT NULL,
    \\  delta_bps REAL NOT NULL,
    \\  order_id TEXT,
    \\  realised_pnl REAL,
    \\  submit_ns INTEGER,
    \\  fill_ns INTEGER,
    \\  created_at INTEGER NOT NULL DEFAULT(unixepoch())
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_arb_events_asset_ts ON arb_events(asset, created_at DESC);
;

/// Embedded Phase-3 migration: HL market metadata + Binance feed persistence.
/// ALTER TABLE on markets/orderbooks runs separately (column-exists checks).
/// orderbooks is created here when missing (legacy code constructed it at
/// runtime); Phase 3 owns the canonical schema for this table going forward.
const MIGRATION_012 =
    \\CREATE TABLE IF NOT EXISTS orderbooks(
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  market TEXT NOT NULL,
    \\  asset_id TEXT NOT NULL,
    \\  best_bid TEXT,
    \\  best_ask TEXT,
    \\  mid_price REAL,
    \\  bids_json TEXT,
    \\  asks_json TEXT,
    \\  last_trade_price TEXT,
    \\  tick_size TEXT,
    \\  timestamp TEXT,
    \\  created_at INTEGER NOT NULL DEFAULT(unixepoch()),
    \\  gamma_id TEXT DEFAULT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS binance_prices(
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  symbol TEXT NOT NULL,
    \\  bid REAL NOT NULL,
    \\  ask REAL NOT NULL,
    \\  mid REAL NOT NULL,
    \\  ts_ns INTEGER NOT NULL,
    \\  recorded_at INTEGER NOT NULL DEFAULT(unixepoch())
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_binance_prices_symbol_ts ON binance_prices(symbol, ts_ns DESC);
    \\CREATE INDEX IF NOT EXISTS idx_binance_prices_recorded ON binance_prices(recorded_at DESC);
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
        // auto_vacuum=INCREMENTAL allows reclaiming space from deleted rows
        // when `PRAGMA incremental_vacuum;` is called periodically. This is a
        // no-op if the database already exists with a different auto_vacuum
        // mode, but new databases benefit immediately.
        try self.execZ("PRAGMA auto_vacuum=INCREMENTAL;");
        // Cap WAL growth so it doesn't balloon between checkpoints.
        try self.execZ("PRAGMA wal_autocheckpoint=1000;");
        try self.execZ("PRAGMA journal_size_limit=67108864;"); // 64 MiB
    }

    /// Retention table descriptor.
    const RetentionRule = struct {
        sql: [:0]const u8,
        label: []const u8,
    };

    /// Periodic retention task. Deletes rows older than the per-table cutoff
    /// from high-churn tables, then runs an incremental vacuum + WAL
    /// checkpoint to reclaim disk space. Safe to run concurrently with normal
    /// operation thanks to WAL mode.
    pub fn runRetention(self: DB) void {
        const rules = [_]RetentionRule{
            // Orderbook snapshots: only the latest row per asset is ever
            // queried. Keep last 10 minutes so the table never accumulates
            // more than a few thousand rows even at high tick rates.
            .{ .sql = "DELETE FROM orderbooks WHERE created_at < unixepoch() - 600;", .label = "orderbooks" },
            // Per-asset dedup: keep only the most recent row per asset_id.
            // This bounds the steady-state row count to N (number of subscribed
            // assets), regardless of WS update frequency.
            .{ .sql = "DELETE FROM orderbooks WHERE id NOT IN (SELECT MAX(id) FROM orderbooks GROUP BY asset_id);", .label = "orderbooks_dedup" },
            // Binance price feed: keep last 10 minutes; only recent ticks are
            // used. Time-based cleanup prevents unbounded growth at high tick rates.
            .{ .sql = "DELETE FROM binance_prices WHERE recorded_at < unixepoch() - 600;", .label = "binance_prices" },
            // Per-symbol Binance dedup: keep only the most recent row per symbol.
            // This bounds steady-state row count to N (number of tracked symbols).
            .{ .sql = "DELETE FROM binance_prices WHERE id NOT IN (SELECT MAX(id) FROM binance_prices GROUP BY symbol);", .label = "binance_prices_dedup" },
            // Risk events: keep 2 days for audit/debugging.
            .{ .sql = "DELETE FROM risk_events WHERE created_at < unixepoch() - 2*86400;", .label = "risk_events" },
            // Balance snapshots: keep 2 days. Worker writes ~1/5min so this
            // is ~576 rows total.
            .{ .sql = "DELETE FROM balance_snapshots WHERE snapshot_at < unixepoch() - 2*86400;", .label = "balance_snapshots" },
            // Strategy stats: keep 2 days.
            .{ .sql = "DELETE FROM strategy_stats WHERE snapshot_at < unixepoch() - 2*86400;", .label = "strategy_stats" },
            // Strategy signals: keep 2 days.
            .{ .sql = "DELETE FROM strategy_signals WHERE created_at < unixepoch() - 2*86400;", .label = "strategy_signals" },
            // Engine logs: keep 1 day (most logs go to stdout / docker logs;
            // this table is currently unused but pruned defensively).
            .{ .sql = "DELETE FROM logs WHERE created_at < unixepoch() - 86400;", .label = "logs" },
            // Dry-run signals: keep 3 days.
            .{ .sql = "DELETE FROM dry_run_signals WHERE created_at < unixepoch() - 3*86400;", .label = "dry_run_signals" },
            // HL funding rate snapshots + arb telemetry: keep 7 days.
            .{ .sql = "DELETE FROM funding_snapshots WHERE recorded_at < unixepoch() - 7*86400;", .label = "funding_snapshots" },
            .{ .sql = "DELETE FROM arb_events WHERE created_at < unixepoch() - 7*86400;", .label = "arb_events" },
            // Closed orders > 30 days: archive by deletion. Open orders are
            // never deleted regardless of age.
            .{ .sql = "DELETE FROM orders WHERE status IN ('cancelled','rejected','filled') AND updated_at < unixepoch() - 30*86400;", .label = "orders_closed" },
            // Fills tied to deleted orders (cleanup orphans).
            .{ .sql = "DELETE FROM fills WHERE filled_at < unixepoch() - 30*86400 AND order_id NOT IN (SELECT id FROM orders);", .label = "fills_orphans" },
            // Config change audit log: keep 30 days.
            .{ .sql = "DELETE FROM config_changes WHERE changed_at < unixepoch() - 30*86400;", .label = "config_changes" },
        };

        for (rules) |rule| {
            self.execZ(rule.sql) catch |e| {
                log.warn("db", "retention DELETE failed for {s}: {s}", .{ rule.label, @errorName(e) });
                continue;
            };
            const changed = c.sqlite3_changes(self.handle);
            if (changed > 0) {
                log.info("db", "retention pruned {d} rows from {s}", .{ changed, rule.label });
            }
        }

        // Reclaim freed pages and truncate WAL.
        self.execZ("PRAGMA incremental_vacuum;") catch |e| {
            log.warn("db", "incremental_vacuum failed: {s}", .{@errorName(e)});
        };
        self.execZ("PRAGMA wal_checkpoint(TRUNCATE);") catch |e| {
            log.warn("db", "wal_checkpoint failed: {s}", .{@errorName(e)});
        };
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
        if (!self.migrationApplied(10)) {
            log.info("db", "applying migration 010", .{});
            try self.execZ(MIGRATION_010 ++ &[_:0]u8{});
        }
        if (!self.migrationApplied(11)) {
            log.info("db", "applying migration 011", .{});
            try self.execZ(MIGRATION_011 ++ &[_:0]u8{});
        }
        // Migration 012 — Phase 3 HL market metadata + Binance feed
        // persistence. ALTER TABLE adds asset_index columns to markets and
        // orderbooks (orderbooks may not exist yet on a fresh DB; skip
        // gracefully if so).
        if (!self.migrationApplied(12)) {
            log.info("db", "applying migration 012", .{});
            // Create base tables first (orderbooks if missing, binance_prices),
            // then apply ALTER TABLE for additive columns.
            try self.execZ(MIGRATION_012 ++ &[_:0]u8{});
            const m012_alters = [_][:0]const u8{
                "ALTER TABLE markets ADD COLUMN asset_index INTEGER DEFAULT NULL;",
                "ALTER TABLE orderbooks ADD COLUMN asset_index INTEGER DEFAULT NULL;",
                "CREATE INDEX IF NOT EXISTS idx_orderbooks_asset_index ON orderbooks(asset_index);",
            };
            for (m012_alters) |sql| {
                self.execZ(sql) catch |err| {
                    const sqlite_err = std.mem.span(c.sqlite3_errmsg(self.handle));
                    const duplicate_col = std.mem.indexOf(u8, sqlite_err, "duplicate column name") != null;
                    const no_table = std.mem.indexOf(u8, sqlite_err, "no such table") != null;
                    if (err == error.DBExecFailed and (duplicate_col or no_table)) {
                        log.info("db", "migration 012: skipping alter (column exists or table missing): {s}", .{sql});
                        continue;
                    } else {
                        log.err("db", "migration 012 ALTER TABLE failed: zig_err={s} sqlite_err={s} sql={s}", .{ @errorName(err), sqlite_err, sql });
                        return err;
                    }
                };
            }
            // Mark migration as applied only after all ALTERs succeed.
            try self.execZ("INSERT OR IGNORE INTO schema_migrations(version)VALUES(12);" ++ &[_:0]u8{});
        }
        // Migration 013 — Phase 5 HL portfolio + fill detection schema.
        // Creates funding_snapshots + arb_events; adds HL margin/funding
        // columns to positions, asset_index/reduce_only to orders, and
        // funding_charge/simulated_slippage to dry_run_orders.
        if (!self.migrationApplied(13)) {
            log.info("db", "applying migration 013", .{});
            try self.execZ(MIGRATION_013 ++ &[_:0]u8{});
            const m013_alters = [_][:0]const u8{
                "ALTER TABLE positions ADD COLUMN mark_price REAL DEFAULT 0.0;",
                "ALTER TABLE positions ADD COLUMN funding_accrued REAL DEFAULT 0.0;",
                "ALTER TABLE positions ADD COLUMN leverage INTEGER DEFAULT 1;",
                "ALTER TABLE positions ADD COLUMN funding_index REAL DEFAULT 0.0;",
                "ALTER TABLE orders ADD COLUMN asset_index INTEGER DEFAULT -1;",
                "ALTER TABLE orders ADD COLUMN reduce_only INTEGER DEFAULT 0;",
                "ALTER TABLE dry_run_orders ADD COLUMN funding_charge REAL DEFAULT 0.0;",
                "ALTER TABLE dry_run_orders ADD COLUMN simulated_slippage REAL DEFAULT 0.0;",
            };
            for (m013_alters) |sql| {
                self.execZ(sql) catch |err| {
                    const sqlite_err = std.mem.span(c.sqlite3_errmsg(self.handle));
                    const duplicate_col = std.mem.indexOf(u8, sqlite_err, "duplicate column name") != null;
                    const no_table = std.mem.indexOf(u8, sqlite_err, "no such table") != null;
                    if (err == error.DBExecFailed and (duplicate_col or no_table)) {
                        log.info("db", "migration 013: skipping alter (column exists or table missing): {s}", .{sql});
                        continue;
                    } else {
                        log.err("db", "migration 013 ALTER TABLE failed: zig_err={s} sqlite_err={s} sql={s}", .{ @errorName(err), sqlite_err, sql });
                        return err;
                    }
                };
            }
            try self.execZ("INSERT OR IGNORE INTO schema_migrations(version)VALUES(13);" ++ &[_:0]u8{});
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
        // Only exchange-acknowledged live orders should consume capacity.
        // A stranded local `pending` row after a restart must not keep the
        // engine permanently saturated.
        const sql = "SELECT count(*) FROM orders WHERE status IN ('placed','partially_filled');" ++ &[_:0]u8{};
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

    /// Count live (placed/partially_filled) AND locally pending orders for a
    /// specific market. Used by the risk gate to block stacking duplicate
    /// resting orders on the same market while the previous one waits to
    /// fill or be acknowledged.
    pub fn queryOpenOrderCountByMarket(self: DB, market_id: []const u8) !u32 {
        const sql = "SELECT count(*) FROM orders WHERE market_id=? AND status IN ('pending','placed','partially_filled');" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare queryOpenOrderCountByMarket", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, market_id.ptr, @intCast(market_id.len), null) != c.SQLITE_OK) {
            log.err("db", "failed to bind queryOpenOrderCountByMarket parameters", .{});
            return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
            log.err("db", "failed to execute queryOpenOrderCountByMarket", .{});
            return error.DBExecFailed;
        }
        return @intCast(c.sqlite3_column_int(stmt, 0));
    }

    pub fn queryOpenExposureUsd(self: DB) !f64 {
        // Match queryOpenOrderCount: only placed / partially_filled orders
        // represent real exchange exposure.
        const sql = "SELECT COALESCE(SUM(CAST(size AS REAL) * CAST(price AS REAL)), 0.0) FROM orders WHERE status IN ('placed','partially_filled');" ++ &[_:0]u8{};
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

    /// Query the latest usable USDC balance from balance_snapshots.
    /// Returns null if no recent positive snapshot exists.
    pub fn queryLatestUsdcBalance(self: DB, max_age_seconds: i64) !?f64 {
        const sql = "SELECT id, CAST(usdc_balance AS REAL), snapshot_at FROM balance_snapshots ORDER BY snapshot_at DESC, id DESC;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare queryLatestUsdcBalance", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const now = std.time.timestamp();
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_ROW) {
                const row_id = c.sqlite3_column_int64(stmt, 0);
                const balance = c.sqlite3_column_double(stmt, 1);
                const snapshot_at = c.sqlite3_column_int64(stmt, 2);
                const age = now - snapshot_at;

                if (age > max_age_seconds) {
                    log.warn("db", "balance snapshot stale: id={d} age={d}s max={d}s", .{ row_id, age, max_age_seconds });
                    return null;
                }
                if (balance <= 0 or !std.math.isFinite(balance)) {
                    log.warn("db", "ignoring invalid balance snapshot: id={d} balance={d:.6}", .{ row_id, balance });
                    continue;
                }
                return balance;
            } else if (rc == c.SQLITE_DONE) {
                return null;
            } else {
                const err_msg = c.sqlite3_errmsg(self.handle);
                log.err("db", "failed to execute queryLatestUsdcBalance: {s}", .{err_msg});
                return error.DBExecFailed;
            }
        }
    }

    /// Insert a USDC balance snapshot.
    pub fn insertBalanceSnapshot(self: DB, usdc_balance: f64, total_exposure: f64, unrealized_pnl: f64, realized_pnl: f64) !void {
        const sql = "INSERT INTO balance_snapshots(usdc_balance, total_exposure, unrealized_pnl, realized_pnl) VALUES(?,?,?,?);" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare insertBalanceSnapshot", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        var bal_buf: [32]u8 = undefined;
        const bal_str = std.fmt.bufPrint(&bal_buf, "{d:.6}", .{usdc_balance}) catch return error.FormatFailed;
        var exp_buf: [32]u8 = undefined;
        const exp_str = std.fmt.bufPrint(&exp_buf, "{d:.6}", .{total_exposure}) catch return error.FormatFailed;
        var upnl_buf: [32]u8 = undefined;
        const upnl_str = std.fmt.bufPrint(&upnl_buf, "{d:.6}", .{unrealized_pnl}) catch return error.FormatFailed;
        var rpnl_buf: [32]u8 = undefined;
        const rpnl_str = std.fmt.bufPrint(&rpnl_buf, "{d:.6}", .{realized_pnl}) catch return error.FormatFailed;

        if (c.sqlite3_bind_text(stmt, 1, bal_str.ptr, @intCast(bal_str.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, exp_str.ptr, @intCast(exp_str.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 3, upnl_str.ptr, @intCast(upnl_str.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 4, rpnl_str.ptr, @intCast(rpnl_str.len), null) != c.SQLITE_OK)
        {
            log.err("db", "failed to bind insertBalanceSnapshot parameters", .{});
            return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            log.err("db", "failed to execute insertBalanceSnapshot", .{});
            return error.DBExecFailed;
        }
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
    // -------------------------------------------------------------------
    // Phase 3 HL/Binance market data helpers (migration 012)
    // -------------------------------------------------------------------

    /// Insert a Binance bookTicker snapshot. ts_ns is the wall-clock
    /// nanosecond timestamp captured when the message arrived.
    pub fn insertBinancePrice(
        self: DB,
        symbol: []const u8,
        bid: f64,
        ask: f64,
        mid: f64,
        ts_ns: i64,
    ) !void {
        const sql = "INSERT INTO binance_prices(symbol,bid,ask,mid,ts_ns) VALUES(?,?,?,?,?);" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare insertBinancePrice", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, symbol.ptr, @intCast(symbol.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 2, bid) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 3, ask) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 4, mid) != c.SQLITE_OK or
            c.sqlite3_bind_int64(stmt, 5, ts_ns) != c.SQLITE_OK)
        {
            log.err("db", "failed to bind insertBinancePrice parameters", .{});
            return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            log.err("db", "failed to execute insertBinancePrice", .{});
            return error.DBExecFailed;
        }
    }

    pub const BinancePriceRow = struct {
        bid: f64,
        ask: f64,
        mid: f64,
        ts_ns: i64,
    };

    pub fn queryLatestBinancePrice(self: DB, symbol: []const u8) ?BinancePriceRow {
        const sql = "SELECT bid,ask,mid,ts_ns FROM binance_prices WHERE symbol=? ORDER BY ts_ns DESC LIMIT 1;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, symbol.ptr, @intCast(symbol.len), null) != c.SQLITE_OK) return null;
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return BinancePriceRow{
            .bid = c.sqlite3_column_double(stmt, 0),
            .ask = c.sqlite3_column_double(stmt, 1),
            .mid = c.sqlite3_column_double(stmt, 2),
            .ts_ns = c.sqlite3_column_int64(stmt, 3),
        };
    }

    /// Persist (or update) the asset_index for a market row keyed by symbol.
    /// Used during HL meta refresh to keep markets.asset_index aligned with
    /// the universe array. INSERT OR IGNORE creates a stub row when the
    /// market is not already known so feed persistence has somewhere to
    /// reference.
    pub fn upsertMarketAssetIndex(self: DB, symbol: []const u8, asset_index: i64) !void {
        // Stub-create the markets row if missing; symbol acts as the
        // identity key for HL coins (BTC, ETH, ...) until full market
        // registry overhaul lands in Phase 7.
        var id_buf: [96]u8 = undefined;
        const id_z = std.fmt.bufPrint(&id_buf, "hl-{s}", .{symbol}) catch return error.DBExecFailed;

        const ins_sql = "INSERT OR IGNORE INTO markets(id,symbol,base,quote,asset_index) VALUES(?,?,?,?,?);" ++ &[_:0]u8{};
        var ins_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, ins_sql.ptr, -1, &ins_stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
        defer _ = c.sqlite3_finalize(ins_stmt);
        if (c.sqlite3_bind_text(ins_stmt, 1, id_z.ptr, @intCast(id_z.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(ins_stmt, 2, symbol.ptr, @intCast(symbol.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(ins_stmt, 3, symbol.ptr, @intCast(symbol.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(ins_stmt, 4, "USD", 3, null) != c.SQLITE_OK or
            c.sqlite3_bind_int64(ins_stmt, 5, asset_index) != c.SQLITE_OK)
        {
            return error.DBExecFailed;
        }
        if (c.sqlite3_step(ins_stmt) != c.SQLITE_DONE) return error.DBExecFailed;

        const upd_sql = "UPDATE markets SET asset_index=? WHERE symbol=?;" ++ &[_:0]u8{};
        var upd_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, upd_sql.ptr, -1, &upd_stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
        defer _ = c.sqlite3_finalize(upd_stmt);
        if (c.sqlite3_bind_int64(upd_stmt, 1, asset_index) != c.SQLITE_OK or
            c.sqlite3_bind_text(upd_stmt, 2, symbol.ptr, @intCast(symbol.len), null) != c.SQLITE_OK)
        {
            return error.DBExecFailed;
        }
        if (c.sqlite3_step(upd_stmt) != c.SQLITE_DONE) return error.DBExecFailed;
    }

    /// Insert an HL orderbook snapshot row tagged with asset_index for
    /// strategy queries. `symbol` is the HL coin (BTC, ETH...).
    pub fn insertHlOrderbookSnapshot(
        self: DB,
        symbol: []const u8,
        asset_index: ?i64,
        best_bid: f64,
        best_ask: f64,
        mid: f64,
    ) !void {
        const sql = "INSERT INTO orderbooks(market,asset_id,best_bid,best_ask,mid_price,asset_index) VALUES(?,?,?,?,?,?);" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            log.err("db", "failed to prepare insertHlOrderbookSnapshot", .{});
            return error.DBExecFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        var bid_buf: [32]u8 = undefined;
        const bid_str = std.fmt.bufPrint(&bid_buf, "{d}", .{best_bid}) catch return error.DBExecFailed;
        var ask_buf: [32]u8 = undefined;
        const ask_str = std.fmt.bufPrint(&ask_buf, "{d}", .{best_ask}) catch return error.DBExecFailed;

        if (c.sqlite3_bind_text(stmt, 1, symbol.ptr, @intCast(symbol.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, symbol.ptr, @intCast(symbol.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 3, bid_str.ptr, @intCast(bid_str.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 4, ask_str.ptr, @intCast(ask_str.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 5, mid) != c.SQLITE_OK)
        {
            return error.DBExecFailed;
        }
        if (asset_index) |ai| {
            if (c.sqlite3_bind_int64(stmt, 6, ai) != c.SQLITE_OK) return error.DBExecFailed;
        } else {
            if (c.sqlite3_bind_null(stmt, 6) != c.SQLITE_OK) return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            log.err("db", "failed to execute insertHlOrderbookSnapshot", .{});
            return error.DBExecFailed;
        }
    }

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

    const DryRunFill = struct {
        filled_at: i64,
        fill_price: f64,
    };

    const DryRunExit = struct {
        exit_at: i64,
        mark_price: f64,
        used_fallback: bool,
    };

    const DryRunPaperMetrics = struct {
        considered_signals: i64 = 0,
        filled_trades: i64 = 0,
        unfilled_signals: i64 = 0,
        fallback_exit_marks: i64 = 0,
        winning_trades: i64 = 0,
        losing_trades: i64 = 0,
        net_pnl: f64 = 0.0,
        gross_profit: f64 = 0.0,
        gross_loss: f64 = 0.0,
        max_drawdown: f64 = 0.0,
        avg_hold_seconds: f64 = 0.0,
    };

    const DryRunSignalRow = struct {
        market_id: []const u8,
        strategy: []const u8,
        direction: []const u8,
        group_key: []const u8,
        price: f64,
        size: f64,
        signal_ts: i64,
        best_bid: ?f64,
        best_ask: ?f64,
    };

    const DryRunMarketSeries = struct {
        signal_indices: std.ArrayList(usize) = .empty,
        latest_price: f64 = 0.0,
    };

    const DRY_RUN_ENTRY_LOOKAHEAD_SECONDS: i64 = 15 * 60;
    const DRY_RUN_MAX_HOLD_SECONDS: i64 = 30 * 60;
    const DRY_RUN_FEE_BPS_PER_SIDE: f64 = 2.0;

    /// Analyze dry-run signals: persistence rate, coarse mark-to-market P&L,
    /// and a conservative paper-trading simulation.
    /// Writes a JSON report to the provided buffer.
    /// Persistence check: a signal is "persistent" if another signal for the same
    /// market+direction exists >= 15 seconds after it.
    pub fn analyzeDryRunSignals(self: DB, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var signals: std.ArrayList(DryRunSignalRow) = .empty;
        var markets: std.ArrayList(DryRunMarketSeries) = .empty;
        var market_to_index = std.StringHashMap(usize).init(alloc);
        var group_last_ts = std.StringHashMap(i64).init(alloc);

        {
            const sql =
                \\SELECT market_id, strategy, direction, price, size, signal_ts, best_bid, best_ask
                \\FROM dry_run_signals
                \\ORDER BY signal_ts ASC, id ASC;
            ++ &[_:0]u8{};
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
            defer _ = c.sqlite3_finalize(stmt);

            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const market_id_raw = c.sqlite3_column_text(stmt, 0);
                const strategy_raw = c.sqlite3_column_text(stmt, 1);
                const direction_raw = c.sqlite3_column_text(stmt, 2);
                if (market_id_raw == null or strategy_raw == null or direction_raw == null) continue;

                const market_id = try alloc.dupe(u8, std.mem.span(@as([*c]const u8, @ptrCast(market_id_raw.?))));
                const strategy = try alloc.dupe(u8, std.mem.span(@as([*c]const u8, @ptrCast(strategy_raw.?))));
                const direction = try alloc.dupe(u8, std.mem.span(@as([*c]const u8, @ptrCast(direction_raw.?))));
                const group_key = try std.fmt.allocPrint(alloc, "{s}\x1f{s}\x1f{s}", .{ market_id, strategy, direction });

                const signal = DryRunSignalRow{
                    .market_id = market_id,
                    .strategy = strategy,
                    .direction = direction,
                    .group_key = group_key,
                    .price = c.sqlite3_column_double(stmt, 3),
                    .size = c.sqlite3_column_double(stmt, 4),
                    .signal_ts = c.sqlite3_column_int64(stmt, 5),
                    .best_bid = if (c.sqlite3_column_type(stmt, 6) == c.SQLITE_NULL) null else c.sqlite3_column_double(stmt, 6),
                    .best_ask = if (c.sqlite3_column_type(stmt, 7) == c.SQLITE_NULL) null else c.sqlite3_column_double(stmt, 7),
                };

                const signal_idx = signals.items.len;
                try signals.append(alloc, signal);

                const market_entry = try market_to_index.getOrPut(market_id);
                if (!market_entry.found_existing) {
                    market_entry.key_ptr.* = market_id;
                    market_entry.value_ptr.* = markets.items.len;
                    try markets.append(alloc, .{});
                }
                const market_idx = market_entry.value_ptr.*;
                try markets.items[market_idx].signal_indices.append(alloc, signal_idx);
                markets.items[market_idx].latest_price = signal.price;

                try group_last_ts.put(group_key, signal.signal_ts);
            }
        }

        const total: i64 = @intCast(signals.items.len);
        var persistent: i64 = 0;
        var optimistic_pnl: f64 = 0.0;
        var pessimistic_pnl: f64 = 0.0;

        for (signals.items) |signal| {
            if (group_last_ts.get(signal.group_key)) |last_ts| {
                if (last_ts >= signal.signal_ts + 15) persistent += 1;
            }

            const market_idx = market_to_index.get(signal.market_id).?;
            const latest_price = markets.items[market_idx].latest_price;
            const half_spread = if (signal.best_bid != null and signal.best_ask != null)
                (signal.best_ask.? - signal.best_bid.?) / 2.0
            else
                0.01;

            if (std.mem.eql(u8, signal.direction, "buy")) {
                optimistic_pnl += (latest_price - signal.price) * signal.size;
                pessimistic_pnl += (latest_price - (signal.price + half_spread)) * signal.size;
            } else {
                optimistic_pnl += (signal.price - latest_price) * signal.size;
                pessimistic_pnl += ((signal.price - half_spread) - latest_price) * signal.size;
            }
        }

        const paper = try self.simulateDryRunPaperTrades(signals.items, markets.items, &market_to_index);

        const persistence_pct: f64 = if (total > 0) @as(f64, @floatFromInt(persistent)) / @as(f64, @floatFromInt(total)) * 100.0 else 0.0;
        const paper_fill_rate_pct: f64 = if (paper.considered_signals > 0)
            @as(f64, @floatFromInt(paper.filled_trades)) / @as(f64, @floatFromInt(paper.considered_signals)) * 100.0
        else
            0.0;
        const paper_win_rate_pct: f64 = if (paper.filled_trades > 0)
            @as(f64, @floatFromInt(paper.winning_trades)) / @as(f64, @floatFromInt(paper.filled_trades)) * 100.0
        else
            0.0;
        const paper_avg_pnl_per_trade: f64 = if (paper.filled_trades > 0)
            paper.net_pnl / @as(f64, @floatFromInt(paper.filled_trades))
        else
            0.0;
        const paper_expectancy_per_signal: f64 = if (paper.considered_signals > 0)
            paper.net_pnl / @as(f64, @floatFromInt(paper.considered_signals))
        else
            0.0;
        const paper_profit_factor: f64 = if (paper.gross_loss > 0.0)
            paper.gross_profit / paper.gross_loss
        else if (paper.gross_profit > 0.0)
            999999.0
        else
            0.0;
        const diagnosis =
            if (total == 0) "no_data" else if (paper.filled_trades == 0) "no_fills_detected" else if (paper.net_pnl <= 0.0) "paper_loss" else if (paper_fill_rate_pct < 10.0) "fill_rate_too_low" else "paper_viable";

        try writer.print(
            "{{\"total_signals\":{d},\"persistent_signals\":{d},\"persistence_pct\":{d:.1}," ++
                "\"optimistic_pnl\":{d:.4},\"pessimistic_pnl\":{d:.4}," ++
                "\"paper_entry_lookahead_seconds\":{d},\"paper_max_hold_seconds\":{d},\"paper_fee_bps_per_side\":{d:.2}," ++
                "\"paper_filled_trades\":{d},\"paper_unfilled_signals\":{d},\"paper_fill_rate_pct\":{d:.1}," ++
                "\"paper_winning_trades\":{d},\"paper_losing_trades\":{d},\"paper_win_rate_pct\":{d:.1}," ++
                "\"paper_net_pnl\":{d:.4},\"paper_avg_pnl_per_trade\":{d:.4},\"paper_expectancy_per_signal\":{d:.4}," ++
                "\"paper_profit_factor\":{d:.4},\"paper_max_drawdown\":{d:.4},\"paper_avg_hold_seconds\":{d:.1}," ++
                "\"paper_fallback_exit_marks\":{d},\"diagnosis\":\"{s}\"}}",
            .{
                total,
                persistent,
                persistence_pct,
                optimistic_pnl,
                pessimistic_pnl,
                DRY_RUN_ENTRY_LOOKAHEAD_SECONDS,
                DRY_RUN_MAX_HOLD_SECONDS,
                DRY_RUN_FEE_BPS_PER_SIDE,
                paper.filled_trades,
                paper.unfilled_signals,
                paper_fill_rate_pct,
                paper.winning_trades,
                paper.losing_trades,
                paper_win_rate_pct,
                paper.net_pnl,
                paper_avg_pnl_per_trade,
                paper_expectancy_per_signal,
                paper_profit_factor,
                paper.max_drawdown,
                paper.avg_hold_seconds,
                paper.fallback_exit_marks,
                diagnosis,
            },
        );
        return fbs.getWritten();
    }

    fn simulateDryRunPaperTrades(
        self: DB,
        signals: []const DryRunSignalRow,
        markets: []const DryRunMarketSeries,
        market_to_index: *const std.StringHashMap(usize),
    ) !DryRunPaperMetrics {
        _ = self;
        var metrics = DryRunPaperMetrics{};
        var equity: f64 = 0.0;
        var peak_equity: f64 = 0.0;
        var total_hold_seconds: f64 = 0.0;

        for (signals) |signal| {
            if (signal.size <= 0.0 or signal.price <= 0.0) continue;

            metrics.considered_signals += 1;

            const market_idx = market_to_index.get(signal.market_id).?;
            const series = markets[market_idx].signal_indices.items;
            const fill = queryDryRunFill(signals, series, signal.direction, signal.price, signal.signal_ts, DRY_RUN_ENTRY_LOOKAHEAD_SECONDS);
            if (fill == null) {
                metrics.unfilled_signals += 1;
                continue;
            }

            const f = fill.?;
            const exit = queryDryRunExitMark(signals, series, f.filled_at, DRY_RUN_MAX_HOLD_SECONDS, f.fill_price);
            const hold_seconds = @as(f64, @floatFromInt(exit.exit_at - f.filled_at));
            const exit_price = exit.mark_price;
            const gross_pnl = if (std.mem.eql(u8, signal.direction, "buy"))
                (exit_price - f.fill_price) * signal.size
            else
                (f.fill_price - exit_price) * signal.size;
            const fees = ((f.fill_price * signal.size) + (exit_price * signal.size)) * (DRY_RUN_FEE_BPS_PER_SIDE / 10000.0);
            const net_pnl = gross_pnl - fees;

            metrics.filled_trades += 1;
            if (exit.used_fallback) metrics.fallback_exit_marks += 1;
            total_hold_seconds += hold_seconds;
            metrics.net_pnl += net_pnl;

            if (net_pnl >= 0.0) {
                metrics.winning_trades += 1;
                metrics.gross_profit += net_pnl;
            } else {
                metrics.losing_trades += 1;
                metrics.gross_loss += @abs(net_pnl);
            }

            equity += net_pnl;
            if (equity > peak_equity) peak_equity = equity;
            const drawdown = peak_equity - equity;
            if (drawdown > metrics.max_drawdown) metrics.max_drawdown = drawdown;
        }

        if (metrics.filled_trades > 0) {
            metrics.avg_hold_seconds = total_hold_seconds / @as(f64, @floatFromInt(metrics.filled_trades));
        }

        return metrics;
    }

    fn lowerBoundSignalTs(
        signals: []const DryRunSignalRow,
        indices: []const usize,
        target_ts: i64,
    ) usize {
        var lo: usize = 0;
        var hi: usize = indices.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const ts = signals[indices[mid]].signal_ts;
            if (ts <= target_ts) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    fn queryDryRunFill(
        signals: []const DryRunSignalRow,
        indices: []const usize,
        direction: []const u8,
        signal_price: f64,
        signal_ts: i64,
        lookahead_seconds: i64,
    ) ?DryRunFill {
        const is_buy = std.mem.eql(u8, direction, "buy");
        const max_ts = signal_ts + lookahead_seconds;
        var idx = lowerBoundSignalTs(signals, indices, signal_ts);
        while (idx < indices.len) : (idx += 1) {
            const row = signals[indices[idx]];
            if (row.signal_ts > max_ts) break;

            const fill_price = if (is_buy) row.best_ask else row.best_bid;
            if (fill_price == null or fill_price.? <= 0.0) continue;

            if ((is_buy and fill_price.? <= signal_price) or (!is_buy and fill_price.? >= signal_price)) {
                return DryRunFill{
                    .filled_at = row.signal_ts,
                    .fill_price = fill_price.?,
                };
            }
        }

        return null;
    }

    fn queryDryRunExitMark(
        signals: []const DryRunSignalRow,
        indices: []const usize,
        filled_at: i64,
        max_hold_seconds: i64,
        fallback_fill_price: f64,
    ) DryRunExit {
        const end_ts = filled_at + max_hold_seconds;
        const start_idx = lowerBoundSignalTs(signals, indices, filled_at);
        const end_idx = lowerBoundSignalTs(signals, indices, end_ts);

        if (start_idx < end_idx) {
            const row = signals[indices[end_idx - 1]];
            const mark_price = if (row.best_bid != null and row.best_ask != null)
                (row.best_bid.? + row.best_ask.?) / 2.0
            else if (row.price > 0.0)
                row.price
            else
                fallback_fill_price;

            return DryRunExit{
                .exit_at = row.signal_ts,
                .mark_price = mark_price,
                .used_fallback = false,
            };
        }

        return .{
            .exit_at = filled_at + max_hold_seconds,
            .mark_price = fallback_fill_price,
            .used_fallback = true,
        };
    }

    // -------------------------------------------------------------------
    // Kalshi market map persistence (migration 010)
    // -------------------------------------------------------------------

    /// Insert or update a Kalshi ticker → Polymarket Gamma id mapping.
    pub fn upsertKalshiMapping(
        self: DB,
        ticker: []const u8,
        gamma_id: []const u8,
        confidence: f64,
        method: []const u8,
    ) !void {
        const sql =
            "INSERT INTO kalshi_market_map(ticker,gamma_id,confidence,match_method,updated_at) " ++
            "VALUES(?,?,?,?,unixepoch()) " ++
            "ON CONFLICT(ticker) DO UPDATE SET gamma_id=excluded.gamma_id," ++
            "confidence=excluded.confidence,match_method=excluded.match_method,updated_at=excluded.updated_at;" ++
            &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, ticker.ptr, @intCast(ticker.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, gamma_id.ptr, @intCast(gamma_id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 3, confidence) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 4, method.ptr, @intCast(method.len), null) != c.SQLITE_OK)
        {
            return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DBExecFailed;
    }

    /// Look up a Kalshi ticker → Gamma id mapping. Returns the slice into `buf`.
    pub fn lookupKalshiMapping(self: DB, ticker: []const u8, buf: []u8) ?[]const u8 {
        const sql = "SELECT gamma_id FROM kalshi_market_map WHERE ticker=? LIMIT 1;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_bind_text(stmt, 1, ticker.ptr, @intCast(ticker.len), null) != c.SQLITE_OK) return null;
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const raw_ptr = c.sqlite3_column_text(stmt, 0);
        const raw = if (raw_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else return null;
        if (raw.len > buf.len) return null;
        @memcpy(buf[0..raw.len], raw);
        return buf[0..raw.len];
    }

    pub const KalshiMapRow = struct {
        ticker_buf: [64]u8 = [_]u8{0} ** 64,
        ticker_len: usize = 0,
        gamma_id_buf: [64]u8 = [_]u8{0} ** 64,
        gamma_id_len: usize = 0,
        confidence: f64 = 0.0,
        match_method_buf: [32]u8 = [_]u8{0} ** 32,
        match_method_len: usize = 0,
        updated_at: i64 = 0,
    };

    /// Return all Kalshi mappings sorted by ticker. Caller owns the returned slice.
    pub fn getAllKalshiMappings(self: DB, alloc: std.mem.Allocator) ![]KalshiMapRow {
        const sql = "SELECT ticker,gamma_id,confidence,match_method,updated_at FROM kalshi_market_map ORDER BY ticker;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
        defer _ = c.sqlite3_finalize(stmt);

        var list: std.ArrayList(KalshiMapRow) = .empty;
        errdefer list.deinit(alloc);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            var row: KalshiMapRow = .{};

            if (c.sqlite3_column_text(stmt, 0)) |p| {
                const s = std.mem.span(@as([*c]const u8, @ptrCast(p)));
                const n = @min(s.len, row.ticker_buf.len);
                @memcpy(row.ticker_buf[0..n], s[0..n]);
                row.ticker_len = n;
            }
            if (c.sqlite3_column_text(stmt, 1)) |p| {
                const s = std.mem.span(@as([*c]const u8, @ptrCast(p)));
                const n = @min(s.len, row.gamma_id_buf.len);
                @memcpy(row.gamma_id_buf[0..n], s[0..n]);
                row.gamma_id_len = n;
            }
            row.confidence = c.sqlite3_column_double(stmt, 2);
            if (c.sqlite3_column_text(stmt, 3)) |p| {
                const s = std.mem.span(@as([*c]const u8, @ptrCast(p)));
                const n = @min(s.len, row.match_method_buf.len);
                @memcpy(row.match_method_buf[0..n], s[0..n]);
                row.match_method_len = n;
            }
            row.updated_at = c.sqlite3_column_int64(stmt, 4);

            try list.append(alloc, row);
        }

        return list.toOwnedSlice(alloc);
    }

    // -------------------------------------------------------------------
    // Dry-run order lifecycle (migration 010)
    // -------------------------------------------------------------------

    pub const DryRunOrderRow = struct {
        id_buf: [64]u8 = [_]u8{0} ** 64,
        id_len: usize = 0,
        market_id_buf: [128]u8 = [_]u8{0} ** 128,
        market_id_len: usize = 0,
        strategy_buf: [32]u8 = [_]u8{0} ** 32,
        strategy_len: usize = 0,
        direction_buf: [8]u8 = [_]u8{0} ** 8,
        direction_len: usize = 0,
        signal_price: f64 = 0.0,
        size: f64 = 0.0,
        created_at: i64 = 0,

        pub fn id(self: *const DryRunOrderRow) []const u8 {
            return self.id_buf[0..self.id_len];
        }
        pub fn marketId(self: *const DryRunOrderRow) []const u8 {
            return self.market_id_buf[0..self.market_id_len];
        }
        pub fn strategy(self: *const DryRunOrderRow) []const u8 {
            return self.strategy_buf[0..self.strategy_len];
        }
        pub fn direction(self: *const DryRunOrderRow) []const u8 {
            return self.direction_buf[0..self.direction_len];
        }
    };

    pub fn insertDryRunOrder(
        self: DB,
        id: []const u8,
        market_id: []const u8,
        strategy_name: []const u8,
        direction: []const u8,
        signal_price: f64,
        size: f64,
    ) !void {
        const sql =
            "INSERT INTO dry_run_orders(id,market_id,strategy,direction,signal_price,size) " ++
            "VALUES(?,?,?,?,?,?);" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, market_id.ptr, @intCast(market_id.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 3, strategy_name.ptr, @intCast(strategy_name.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 4, direction.ptr, @intCast(direction.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 5, signal_price) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 6, size) != c.SQLITE_OK)
        {
            return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DBExecFailed;
    }

    /// Phase 4: flip the status column of a dry_run_orders row. Used by
    /// `OrderManager.cancelDryRunOrder` to mark a paper order as
    /// 'cancelled' without touching `fill_price`/`pnl`/`fees`.
    pub fn updateDryRunOrderStatus(
        self: DB,
        id: []const u8,
        new_status: []const u8,
    ) !void {
        const sql = "UPDATE dry_run_orders SET status=?,updated_at=unixepoch() WHERE id=?;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, new_status.ptr, @intCast(new_status.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 2, id.ptr, @intCast(id.len), null) != c.SQLITE_OK)
        {
            return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DBExecFailed;
    }

    pub fn settleDryRunOrder(
        self: DB,
        id: []const u8,
        status: []const u8,
        fill_price: f64,
        pnl: f64,
        fees: f64,
    ) !void {
        const sql =
            "UPDATE dry_run_orders SET status=?,fill_price=?,fill_ts=unixepoch(),pnl=?,fees=?,updated_at=unixepoch() WHERE id=?;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, status.ptr, @intCast(status.len), null) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 2, fill_price) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 3, pnl) != c.SQLITE_OK or
            c.sqlite3_bind_double(stmt, 4, fees) != c.SQLITE_OK or
            c.sqlite3_bind_text(stmt, 5, id.ptr, @intCast(id.len), null) != c.SQLITE_OK)
        {
            return error.DBExecFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DBExecFailed;
    }

    /// Fill the provided buffer with up to out.len open dry_run_orders rows.
    pub fn getOpenDryRunOrders(self: DB, out: []DryRunOrderRow) !usize {
        const sql =
            "SELECT id,market_id,strategy,direction,signal_price,size,created_at FROM dry_run_orders WHERE status='open' ORDER BY created_at ASC LIMIT ?;" ++ &[_:0]u8{};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DBExecFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_int(stmt, 1, @intCast(out.len)) != c.SQLITE_OK) return error.DBExecFailed;

        var count: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW and count < out.len) {
            var row: DryRunOrderRow = .{};
            if (c.sqlite3_column_text(stmt, 0)) |p| {
                const s = std.mem.span(@as([*c]const u8, @ptrCast(p)));
                const n = @min(s.len, row.id_buf.len);
                @memcpy(row.id_buf[0..n], s[0..n]);
                row.id_len = n;
            }
            if (c.sqlite3_column_text(stmt, 1)) |p| {
                const s = std.mem.span(@as([*c]const u8, @ptrCast(p)));
                const n = @min(s.len, row.market_id_buf.len);
                @memcpy(row.market_id_buf[0..n], s[0..n]);
                row.market_id_len = n;
            }
            if (c.sqlite3_column_text(stmt, 2)) |p| {
                const s = std.mem.span(@as([*c]const u8, @ptrCast(p)));
                const n = @min(s.len, row.strategy_buf.len);
                @memcpy(row.strategy_buf[0..n], s[0..n]);
                row.strategy_len = n;
            }
            if (c.sqlite3_column_text(stmt, 3)) |p| {
                const s = std.mem.span(@as([*c]const u8, @ptrCast(p)));
                const n = @min(s.len, row.direction_buf.len);
                @memcpy(row.direction_buf[0..n], s[0..n]);
                row.direction_len = n;
            }
            row.signal_price = c.sqlite3_column_double(stmt, 4);
            row.size = c.sqlite3_column_double(stmt, 5);
            row.created_at = c.sqlite3_column_int64(stmt, 6);

            out[count] = row;
            count += 1;
        }
        return count;
    }
};
