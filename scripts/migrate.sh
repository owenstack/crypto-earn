#!/usr/bin/env bash
set -euo pipefail

# Migration runner for cex-zig
# Applies SQL migrations from db/migrations/ in deterministic numeric order.
# Idempotent: tracks applied versions in schema_migrations table.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
MIGRATIONS_DIR="$DIR/db/migrations"


# Set DB_PATH from argument, env, or default
DB_PATH="${1:-${DB_PATH:-}}"
if [[ -z "$DB_PATH" ]]; then
  DB_PATH="$DIR/db/cex.sqlite3"
  echo "DB_PATH not set, using default: $DB_PATH"
fi

if ! command -v sqlite3 &>/dev/null; then
  echo "ERROR: sqlite3 not found in PATH." >&2
  exit 1
fi

echo "==> Using database: $DB_PATH"
echo "==> Migrations dir: $MIGRATIONS_DIR"

# Ensure schema_migrations tracking table exists.
# Uses INTEGER version to match the existing migration SQL (INSERT OR IGNORE ... VALUES (1), etc.)
sqlite3 "$DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migrations (
  version    INTEGER PRIMARY KEY,
  applied_at INTEGER NOT NULL DEFAULT (unixepoch())
);
SQL

applied=0
skipped=0

for file in "$MIGRATIONS_DIR"/*.sql; do
  [[ -f "$file" ]] || continue

  basename="$(basename "$file")"
  # Extract numeric version: "001" -> 1, "004" -> 4
  version_str="${basename%%_*}"
  version=$((10#$version_str))

  # Check if already applied (migrations self-register via INSERT OR IGNORE).
  already=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM schema_migrations WHERE version=$version;")
  if [[ "$already" -gt 0 ]]; then
    echo "    SKIP $basename (already applied)"
    skipped=$((skipped + 1))
    continue
  fi

  echo "    APPLY $basename ..."
  if ! sqlite3 "$DB_PATH" < "$file"; then
    echo "ERROR: Migration $basename failed!" >&2
    exit 1
  fi
  applied=$((applied + 1))
  echo "    OK   $basename"
done

echo "==> Migration complete: $applied applied, $skipped skipped."
