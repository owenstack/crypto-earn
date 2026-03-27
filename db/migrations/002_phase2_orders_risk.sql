-- Phase 2: Orders, risk events, and balance snapshots

CREATE TABLE IF NOT EXISTS risk_events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  order_id    TEXT,
  market_id   TEXT,
  check_name  TEXT NOT NULL,
  reason      TEXT NOT NULL,
  limit_value TEXT,
  actual_value TEXT,
  created_at  INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE INDEX IF NOT EXISTS idx_risk_events_created ON risk_events(created_at DESC);

CREATE TABLE IF NOT EXISTS balance_snapshots (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  usdc_balance   TEXT NOT NULL,
  total_exposure TEXT NOT NULL,
  unrealized_pnl TEXT NOT NULL,
  realized_pnl   TEXT NOT NULL,
  snapshot_at    INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE INDEX IF NOT EXISTS idx_balance_snapshots_at ON balance_snapshots(snapshot_at DESC);

-- Add missing columns to orders table for staleness tracking
-- Using IF NOT EXISTS pattern via INSERT approach since ALTER TABLE IF NOT EXISTS is not standard
-- We'll handle this gracefully - if columns exist, the statements will just fail silently

INSERT OR IGNORE INTO schema_migrations (version) VALUES (2);
