-- Phase 5: Runtime config persistence
CREATE TABLE IF NOT EXISTS runtime_config(
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL DEFAULT(unixepoch())
);

INSERT OR IGNORE INTO schema_migrations(version) VALUES(4);
