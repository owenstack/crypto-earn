-- Phase 0 initial schema (idempotent)

CREATE TABLE IF NOT EXISTS schema_migrations (
  version    INTEGER PRIMARY KEY,
  applied_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS markets (
  id         TEXT PRIMARY KEY,
  symbol     TEXT NOT NULL UNIQUE,
  base       TEXT NOT NULL,
  quote      TEXT NOT NULL,
  status     TEXT NOT NULL DEFAULT 'active',
  created_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS positions (
  id            TEXT PRIMARY KEY,
  market_id     TEXT NOT NULL REFERENCES markets(id),
  side          TEXT NOT NULL CHECK (side IN ('long','short')),
  size          TEXT NOT NULL,
  entry_price   TEXT NOT NULL,
  current_price TEXT,
  pnl           TEXT,
  status        TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed')),
  created_at    INTEGER NOT NULL DEFAULT (unixepoch()),
  updated_at    INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS orders (
  id              TEXT PRIMARY KEY,
  market_id       TEXT NOT NULL REFERENCES markets(id),
  client_order_id TEXT UNIQUE,
  type            TEXT NOT NULL CHECK (type IN ('market','limit','stop_limit')),
  side            TEXT NOT NULL CHECK (side IN ('buy','sell')),
  size            TEXT NOT NULL,
  price           TEXT,
  status          TEXT NOT NULL DEFAULT 'pending',
  created_at      INTEGER NOT NULL DEFAULT (unixepoch()),
  updated_at      INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS fills (
  id        TEXT PRIMARY KEY,
  order_id  TEXT NOT NULL REFERENCES orders(id),
  size      TEXT NOT NULL,
  price     TEXT NOT NULL,
  fee       TEXT,
  filled_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS strategy_signals (
  id          TEXT PRIMARY KEY,
  market_id   TEXT REFERENCES markets(id),
  signal_type TEXT NOT NULL,
  strength    REAL,
  metadata    TEXT,
  created_at  INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS config_changes (
  id         TEXT PRIMARY KEY,
  key        TEXT NOT NULL,
  old_value  TEXT,
  new_value  TEXT,
  changed_by TEXT DEFAULT 'system',
  changed_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS logs (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  level      TEXT NOT NULL,
  component  TEXT NOT NULL,
  message    TEXT NOT NULL,
  metadata   TEXT,
  created_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE INDEX IF NOT EXISTS idx_positions_status ON positions(status);
CREATE INDEX IF NOT EXISTS idx_orders_status    ON orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_market    ON orders(market_id);
CREATE INDEX IF NOT EXISTS idx_fills_order      ON fills(order_id);
CREATE INDEX IF NOT EXISTS idx_logs_created     ON logs(created_at DESC);

INSERT OR IGNORE INTO schema_migrations (version) VALUES (1);
