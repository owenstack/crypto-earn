#!/usr/bin/env bash
set -euo pipefail

# Deployment orchestrator for cex-zig

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

SKIP_BUILD=false
RESTART_SERVICES=false

for arg in "$@"; do
  case "$arg" in
    --skip-build)        SKIP_BUILD=true ;;
    --restart-services)  RESTART_SERVICES=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# --- Step 1: Prerequisite checks ---
echo "==> Step 1: Prerequisite checks"
fail=0
for cmd in zig bun sqlite3; do
  if command -v "$cmd" &>/dev/null; then
    echo "    OK   $cmd ($(command -v "$cmd"))"
  else
    echo "    FAIL $cmd not found" >&2
    fail=1
  fi
done
if [[ "$fail" -ne 0 ]]; then
  echo "ERROR: Missing prerequisites. Run scripts/provision.sh first." >&2
  exit 1
fi

# --- Step 2: Build ---
if [[ "$SKIP_BUILD" == true ]]; then
  echo "==> Step 2: Build (skipped via --skip-build)"
else
  echo "==> Step 2: Build"
  bash "$DIR/scripts/build.sh"
fi

# --- Step 3: Migration ---
echo "==> Step 3: Database migration"
# Source environment for DB_PATH
if [[ -f /opt/cex-zig/.env ]]; then
  set -a; source /opt/cex-zig/.env; set +a
elif [[ -f "$DIR/.env" ]]; then
  set -a; source "$DIR/.env; set +a
fi
bash "$DIR/scripts/migrate.sh"

# --- Step 4: Service install ---
echo "==> Step 4: Service install"
if [[ "$RESTART_SERVICES" == true ]]; then
  bash "$DIR/scripts/install-services.sh" --restart
else
  bash "$DIR/scripts/install-services.sh"
fi

# --- Step 5: Smoke checks ---
echo "==> Step 5: Post-start smoke checks"
all_ok=true
for unit in cex-engine cex-control; do
  if systemctl is-active --quiet "$unit.service"; then
    echo "    OK   $unit is active"
  else
    echo "    FAIL $unit is NOT active" >&2
    all_ok=false
  fi
done

if [[ "$all_ok" == false ]]; then
  echo "ERROR: One or more services failed smoke check." >&2
  exit 1
fi

echo "==> Deployment complete."
