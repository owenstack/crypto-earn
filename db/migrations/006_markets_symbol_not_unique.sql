-- Remove UNIQUE from markets.symbol and add legacy orderbook indexes when present.

BEGIN TRANSACTION;

CREATE TABLE IF NOT EXISTS markets_new(
  id TEXT PRIMARY KEY,
  symbol TEXT NOT NULL,
  base TEXT NOT NULL,
  quote TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  created_at INTEGER NOT NULL DEFAULT(unixepoch()),
  condition_id TEXT DEFAULT '',
  clob_token_ids TEXT DEFAULT '[]',
  outcomes TEXT DEFAULT '[]',
  neg_risk INTEGER DEFAULT 0,
  min_tick_size TEXT DEFAULT '0.01'
);

INSERT OR IGNORE INTO markets_new
SELECT id,symbol,base,quote,status,created_at,condition_id,clob_token_ids,outcomes,neg_risk,min_tick_size
FROM markets;

DROP TABLE markets;
ALTER TABLE markets_new RENAME TO markets;

COMMIT;

INSERT OR IGNORE INTO schema_migrations(version) VALUES(6);
