-- Phase 7: Hyperliquid schema overhaul.
--
-- Recreates the `markets` table without the Polymarket-specific columns
-- (`condition_id`, `clob_token_ids`, `neg_risk`) and adds the HL-specific
-- columns (`asset_index INTEGER DEFAULT -1`, `base_asset TEXT DEFAULT ''`,
-- `max_leverage INTEGER DEFAULT 20`).
--
-- Positions / orders / dry_run_orders ALTERs and the funding_snapshots /
-- arb_events tables were already created by migration 013, so this file
-- only performs the markets overhaul (the only Phase 7 work not yet
-- covered by 012/013) and registers the migration version.
--
-- Idempotent: the markets recreate uses CREATE TABLE IF NOT EXISTS for the
-- shadow table and INSERT OR IGNORE INTO schema_migrations at the end so
-- re-running the script (`scripts/migrate.sh`) is a no-op once applied.

BEGIN TRANSACTION;

CREATE TABLE IF NOT EXISTS markets_p7_new(
  id            TEXT PRIMARY KEY,
  symbol        TEXT NOT NULL,
  base          TEXT NOT NULL,
  quote         TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'active',
  created_at    INTEGER NOT NULL DEFAULT(unixepoch()),
  outcomes      TEXT DEFAULT '[]',
  min_tick_size TEXT DEFAULT '0.01',
  asset_index   INTEGER DEFAULT -1,
  base_asset    TEXT DEFAULT '',
  max_leverage  INTEGER DEFAULT 20
);

INSERT OR IGNORE INTO markets_p7_new(
  id, symbol, base, quote, status, created_at,
  outcomes, min_tick_size, asset_index, base_asset, max_leverage
)
SELECT
  id,
  symbol,
  base,
  quote,
  status,
  created_at,
  COALESCE(outcomes, '[]'),
  COALESCE(min_tick_size, '0.01'),
  COALESCE(asset_index, -1),
  COALESCE(base, ''),
  20
FROM markets;

DROP TABLE markets;
ALTER TABLE markets_p7_new RENAME TO markets;

COMMIT;

INSERT OR IGNORE INTO schema_migrations(version) VALUES (14);
