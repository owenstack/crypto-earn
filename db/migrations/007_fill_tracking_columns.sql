-- Fill tracking columns for live orders.

ALTER TABLE orders ADD COLUMN filled_size TEXT DEFAULT '0';
ALTER TABLE orders ADD COLUMN average_fill_price TEXT DEFAULT NULL;
ALTER TABLE orders ADD COLUMN last_checked_at INTEGER DEFAULT 0;
ALTER TABLE fills ADD COLUMN detected_at INTEGER DEFAULT 0;

INSERT OR IGNORE INTO schema_migrations(version) VALUES(7);
