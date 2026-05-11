-- Phase 3: Hyperliquid market metadata + Binance feed persistence.
-- Adds the minimum schema needed for Phase 3 deliverables only:
--   - orderbooks (created here if legacy runtime never ran)
--   - markets.asset_index (HL universe index)
--   - orderbooks.asset_index (HL feed asset index for time-series queries)
--   - binance_prices (latest mid/bid/ask per Binance symbol)
-- Phase 7 will perform the broader HL schema overhaul.

CREATE TABLE IF NOT EXISTS orderbooks (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  market          TEXT NOT NULL,
  asset_id        TEXT NOT NULL,
  best_bid        TEXT,
  best_ask        TEXT,
  mid_price       REAL,
  bids_json       TEXT,
  asks_json       TEXT,
  last_trade_price TEXT,
  tick_size       TEXT,
  timestamp       TEXT,
  created_at      INTEGER NOT NULL DEFAULT (unixepoch()),
  gamma_id        TEXT DEFAULT NULL,
  UNIQUE(market, asset_id, timestamp)
);

ALTER TABLE markets ADD COLUMN IF NOT EXISTS asset_index INTEGER DEFAULT NULL;
ALTER TABLE orderbooks ADD COLUMN IF NOT EXISTS asset_index INTEGER DEFAULT NULL;
CREATE TABLE IF NOT EXISTS binance_prices (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  symbol      TEXT NOT NULL,
  bid         REAL NOT NULL,
  ask         REAL NOT NULL,
  mid         REAL NOT NULL,
  ts_ns       INTEGER NOT NULL,
  recorded_at INTEGER NOT NULL DEFAULT (unixepoch()),
  UNIQUE(symbol, ts_ns)
);
);

CREATE INDEX IF NOT EXISTS idx_binance_prices_symbol_ts ON binance_prices(symbol, ts_ns DESC);
CREATE INDEX IF NOT EXISTS idx_binance_prices_recorded ON binance_prices(recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_orderbooks_asset_index ON orderbooks(asset_index);

INSERT OR IGNORE INTO schema_migrations (version) VALUES (12);
