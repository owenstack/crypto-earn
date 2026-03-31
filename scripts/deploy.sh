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
  set -a; source "$DIR/.env"; set +a
fi
bash "$DIR/scripts/migrate.sh"

# --- Step 4: Sync to /opt/cex-zig ---
echo "==> Step 4: Syncing files to /opt/cex-zig"
# Stop services before sync if they are active
for unit in cex-engine cex-control; do
  if systemctl is-active --quiet "$unit.service"; then
    echo "    STOP $unit"
    sudo systemctl stop "$unit.service"
  fi
done

sudo mkdir -p /opt/cex-zig /opt/cex-zig/db
sudo rsync -av --exclude='.git' --exclude='node_modules' "$DIR/" /opt/cex-zig/

# Ensure .env exists in /opt/cex-zig
if [[ ! -f /opt/cex-zig/.env ]]; then
  echo "    COPY .env.example -> /opt/cex-zig/.env"
  sudo cp /opt/cex-zig/.env.example /opt/cex-zig/.env
  # Update DB_PATH in .env to an absolute path in /opt/cex-zig/db
  sudo sed -i "s|DB_PATH=.*|DB_PATH=/opt/cex-zig/db/cex.sqlite3|" /opt/cex-zig/.env
fi

# Fix ownership
sudo chown -R cex-engine:cex-engine /opt/cex-zig

# --- Step 5: Service install ---
echo "==> Step 5: Service install"
if [[ "$RESTART_SERVICES" == true ]]; then
  bash "$DIR/scripts/install-services.sh" --restart
else
  bash "$DIR/scripts/install-services.sh"
fi

# --- Step 6: Smoke checks ---
echo "==> Step 6: Post-start smoke checks"
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
