-- Phase 3: Strategy stats and strategy order attribution
CREATE TABLE IF NOT EXISTS strategy_stats(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  strategy TEXT NOT NULL,
  signals_emitted INTEGER NOT NULL DEFAULT 0,
  orders_accepted INTEGER NOT NULL DEFAULT 0,
  orders_rejected INTEGER NOT NULL DEFAULT 0,
  cancels INTEGER NOT NULL DEFAULT 0,
  realized_pnl_estimate REAL NOT NULL DEFAULT 0.0,
  snapshot_at INTEGER NOT NULL DEFAULT(unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_strategy_stats_at ON strategy_stats(snapshot_at DESC);
ALTER TABLE orders ADD COLUMN strategy_origin TEXT DEFAULT NULL;
INSERT OR IGNORE INTO schema_migrations(version) VALUES(3);
