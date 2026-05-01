CREATE INDEX IF NOT EXISTS idx_dry_run_signals_market_ts
  ON dry_run_signals(market_id, signal_ts);

CREATE INDEX IF NOT EXISTS idx_dry_run_signals_group_ts
  ON dry_run_signals(market_id, strategy, direction, signal_ts);

INSERT OR IGNORE INTO schema_migrations (version) VALUES (11);
