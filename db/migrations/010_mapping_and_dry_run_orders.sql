-- Historical market mapping table plus dry-run order lifecycle tracking.

CREATE TABLE IF NOT EXISTS kalshi_market_map(
  ticker TEXT PRIMARY KEY,
  gamma_id TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 0.0,
  match_method TEXT NOT NULL DEFAULT 'auto',
  created_at INTEGER NOT NULL DEFAULT(unixepoch()),
  updated_at INTEGER NOT NULL DEFAULT(unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_kalshi_map_gamma ON kalshi_market_map(gamma_id);

CREATE TABLE IF NOT EXISTS dry_run_orders(
  id TEXT PRIMARY KEY,
  market_id TEXT NOT NULL,
  strategy TEXT NOT NULL,
  direction TEXT NOT NULL,
  signal_price REAL NOT NULL,
  size REAL NOT NULL,
  status TEXT NOT NULL DEFAULT 'open',
  fill_price REAL,
  fill_ts INTEGER,
  pnl REAL,
  fees REAL,
  created_at INTEGER NOT NULL DEFAULT(unixepoch()),
  updated_at INTEGER NOT NULL DEFAULT(unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_dry_run_orders_status ON dry_run_orders(status);
CREATE INDEX IF NOT EXISTS idx_dry_run_orders_market ON dry_run_orders(market_id,status);
CREATE INDEX IF NOT EXISTS idx_dry_run_orders_created ON dry_run_orders(created_at DESC);

INSERT OR IGNORE INTO runtime_config(key,value) VALUES('lp_cooldown_seconds','15');
INSERT OR IGNORE INTO runtime_config(key,value) VALUES('lp_max_position_usd_pct','0.20');
INSERT OR IGNORE INTO schema_migrations(version) VALUES(10);
