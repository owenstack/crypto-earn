-- Inventory and paired-leg tracking for market making.

ALTER TABLE positions ADD COLUMN net_position_usd REAL DEFAULT 0.0;
ALTER TABLE orders ADD COLUMN lp_pair_order_id TEXT DEFAULT NULL;

INSERT OR IGNORE INTO runtime_config(key,value) VALUES('lp_max_position_usd','50.0');
INSERT OR IGNORE INTO schema_migrations(version) VALUES(8);
