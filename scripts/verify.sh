#!/usr/bin/env bash
set -euo pipefail

# Phase 7 verification — single entry point for all checks.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

STEPS=0
PASSED=0

step() {
  STEPS=$((STEPS + 1))
  echo ""
  echo "==> Step $STEPS: $1"
}

step_ok() {
  PASSED=$((PASSED + 1))
  echo "    OK   $1"
}

# ── 1. Zig release build ─────────────────────────────────────────────────────
step "Zig release build"
(cd "$DIR/zig" && zig build -Doptimize=ReleaseFast)
step_ok "zig build -Doptimize=ReleaseFast succeeded"

# ── 1b. Zig unit tests ───────────────────────────────────────────────────────
step "Zig unit tests"
(cd "$DIR/zig" && zig build test)
step_ok "zig build test succeeded"

# ── 2. TS typecheck ──────────────────────────────────────────────────────────
step "TS typecheck"
(cd "$DIR/ts" && bun run typecheck)
step_ok "bun run typecheck succeeded"

# ── 2b. TS unit tests ────────────────────────────────────────────────────────
step "TS unit tests"
(cd "$DIR/ts" && bun test)
step_ok "bun test succeeded"

# ── 3. Migration idempotency ─────────────────────────────────────────────────
step "Migration idempotency"

# Source env for DB_PATH
if [[ -f /opt/cex-zig/.env ]]; then
  set -a; source /opt/cex-zig/.env; set +a
elif [[ -f "$DIR/.env" ]]; then
  set -a; source "$DIR/.env"; set +a
fi

DB_PATH="${DB_PATH:-./data/cex.db}"

echo "    Run 1 ..."
bash "$DIR/scripts/migrate.sh" "$DB_PATH"
echo "    Run 2 ..."
bash "$DIR/scripts/migrate.sh" "$DB_PATH"
step_ok "migrate.sh is idempotent (two successive runs succeeded)"

# ── 3b. Migration source parity ─────────────────────────────────────────────
step "Migration source parity"
embedded_count=$(rg -n "^const MIGRATION_00[0-9]" "$DIR/zig/src/db.zig" | wc -l | tr -d ' ')
file_count=$(find "$DIR/db/migrations" -maxdepth 1 -type f -name '*.sql' | wc -l | tr -d ' ')
if [[ "$embedded_count" != "$file_count" ]]; then
  echo "ERROR: migration source mismatch (embedded=$embedded_count files=$file_count)" >&2
  exit 1
fi
step_ok "embedded and file-based migration counts match"

# ── 4. E2E tests ─────────────────────────────────────────────────────────────
step "E2E integration tests"
bash "$DIR/scripts/e2e-test.sh"
step_ok "e2e-test.sh passed"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  Verification: $PASSED/$STEPS steps passed"
echo "========================================"

if [[ "$PASSED" -lt "$STEPS" ]]; then
  exit 1
fi
