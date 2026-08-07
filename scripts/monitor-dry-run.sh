#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
HEARTBEAT="${CEX_MONITOR_HEARTBEAT:-/tmp/cex-dry-run-monitor.heartbeat}"
LOG_FILE="${CEX_MONITOR_LOG:-/tmp/cex-dry-run-monitor.log}"
INTERVAL_SECONDS="${CEX_MONITOR_INTERVAL_SECONDS:-600}"

mkdir -p "$(dirname "$HEARTBEAT")" "$(dirname "$LOG_FILE")"

while :; do
  date -u +%FT%TZ > "$HEARTBEAT"
  {
    echo "===== monitor cycle $(date -u +%FT%TZ) ====="
    bash -e "$REPO_ROOT/scripts/check-dry-run.sh"
  } >> "$LOG_FILE" 2>&1 || {
    echo "===== monitor cycle failed; retrying in 10s $(date -u +%FT%TZ) =====" >> "$LOG_FILE"
    sleep 10
    continue
  }
  sleep "$INTERVAL_SECONDS"
done
