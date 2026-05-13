-- Phase 5: Hyperliquid portfolio + fill detection schema additions.
--
-- Adds HL margin/funding semantics to positions and orders, the
-- funding_snapshots and arb_events tables, and dry-run telemetry columns.
-- IF NOT EXISTS applies only to CREATE TABLE / CREATE INDEX below. The
-- ALTER TABLE ... ADD COLUMN statements are plain DDL; the Zig migrator
-- (runMigrations, migration 013 ALTER loop in zig/src/db.zig) tolerates
-- duplicate-column and missing-table errors when applying them.

-- 1. Positions table — HL margin & funding.
ALTER TABLE positions ADD COLUMN mark_price REAL DEFAULT 0.0;
ALTER TABLE positions ADD COLUMN funding_accrued REAL DEFAULT 0.0;
ALTER TABLE positions ADD COLUMN leverage INTEGER DEFAULT 1;
ALTER TABLE positions ADD COLUMN funding_index REAL DEFAULT 0.0;

-- 2. Orders table — HL asset_index + reduce_only.
ALTER TABLE orders ADD COLUMN asset_index INTEGER DEFAULT -1;
ALTER TABLE orders ADD COLUMN reduce_only INTEGER DEFAULT 0;

-- 3. Funding rate snapshots.
CREATE TABLE IF NOT EXISTS funding_snapshots (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  asset TEXT NOT NULL,
  rate REAL NOT NULL,
  next_payment_ts INTEGER NOT NULL,
  recorded_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_funding_snapshots_asset_ts
  ON funding_snapshots(asset, recorded_at DESC);

-- 4. Arb events (Phase 6 populates; schema lives here to avoid extra migration).
CREATE TABLE IF NOT EXISTS arb_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  asset TEXT NOT NULL,
  binance_mid REAL NOT NULL,
  hl_mid REAL NOT NULL,
  delta_bps REAL NOT NULL,
  order_id TEXT,
  realised_pnl REAL,
  submit_ns INTEGER,
  fill_ns INTEGER,
  created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_arb_events_asset_ts
  ON arb_events(asset, created_at DESC);

-- 5. Dry-run order telemetry.
ALTER TABLE dry_run_orders ADD COLUMN funding_charge REAL DEFAULT 0.0;
ALTER TABLE dry_run_orders ADD COLUMN simulated_slippage REAL DEFAULT 0.0;

INSERT OR IGNORE INTO schema_migrations(version) VALUES (13);
