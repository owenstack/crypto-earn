-- Millisecond lifecycle timestamps for accurate dry-run fill latency.

ALTER TABLE dry_run_orders ADD COLUMN submitted_at_ms INTEGER DEFAULT NULL;
ALTER TABLE dry_run_orders ADD COLUMN fill_ts_ms INTEGER DEFAULT NULL;

INSERT OR IGNORE INTO schema_migrations(version) VALUES(16);
