-- Remote Hyperliquid order id correlation for fills and cancels.

ALTER TABLE orders ADD COLUMN exchange_order_id TEXT DEFAULT NULL;
CREATE INDEX IF NOT EXISTS idx_orders_exchange_order_id ON orders(exchange_order_id);

INSERT OR IGNORE INTO schema_migrations(version) VALUES(15);
