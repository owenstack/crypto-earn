-- Dry-run signal tracking table.

CREATE TABLE IF NOT EXISTS dry_run_signals(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  market_id TEXT NOT NULL,
  strategy TEXT NOT NULL,
  direction TEXT NOT NULL,
  price REAL NOT NULL,
  size REAL NOT NULL,
  delta REAL NOT NULL,
  confidence REAL NOT NULL,
  signal_ts INTEGER NOT NULL,
  best_bid REAL,
  best_ask REAL,
  created_at INTEGER NOT NULL DEFAULT(unixepoch())
);

CREATE INDEX IF NOT EXISTS idx_dry_run_signals_ts ON dry_run_signals(signal_ts);
CREATE INDEX IF NOT EXISTS idx_dry_run_signals_market ON dry_run_signals(market_id);
CREATE INDEX IF NOT EXISTS idx_dry_run_signals_market_ts ON dry_run_signals(market_id,signal_ts);
CREATE INDEX IF NOT EXISTS idx_dry_run_signals_group_ts ON dry_run_signals(market_id,strategy,direction,signal_ts);

INSERT OR IGNORE INTO schema_migrations(version) VALUES(9);
