#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
INCIDENT_EXIT_STATUS=75
HEARTBEAT="${CEX_MONITOR_HEARTBEAT:-/tmp/cex-dry-run-monitor.heartbeat}"
LOG_FILE="${CEX_MONITOR_LOG:-/tmp/cex-dry-run-monitor.log}"
INTERVAL_SECONDS="${CEX_MONITOR_INTERVAL_SECONDS:-600}"

mkdir -p "$(dirname "$HEARTBEAT")" "$(dirname "$LOG_FILE")"

# Compose may still be bringing the control API up when systemd starts this
# monitor. Allow a bounded readiness window; after readiness, check failures
# are treated as incidents and stop the stack for human review.
for _ in $(seq 1 45); do
  date -u +%FT%TZ > "$HEARTBEAT"
  health=$(docker inspect -f '{{.State.Health.Status}}' crypto-earn-engine-1 2>/dev/null || true)
  control_running=$(docker inspect -f '{{.State.Running}}' crypto-earn-control-1 2>/dev/null || true)
  if [[ "$health" == "healthy" && "$control_running" == "true" ]]; then
    break
  fi
  sleep 2
done

health=$(docker inspect -f '{{.State.Health.Status}}' crypto-earn-engine-1 2>/dev/null || true)
control_running=$(docker inspect -f '{{.State.Running}}' crypto-earn-control-1 2>/dev/null || true)
if [[ "$health" != "healthy" || "$control_running" != "true" ]]; then
  echo "===== monitor readiness failed: engine=$health control_running=$control_running $(date -u +%FT%TZ) =====" >> "$LOG_FILE"
  docker compose -f "$REPO_ROOT/docker-compose.yml" down >> "$LOG_FILE" 2>&1 || true
  exit "$INCIDENT_EXIT_STATUS"
fi

while :; do
  date -u +%FT%TZ > "$HEARTBEAT"
  {
    echo "===== monitor cycle $(date -u +%FT%TZ) ====="
    bash -e "$REPO_ROOT/scripts/check-dry-run.sh"
  } >> "$LOG_FILE" 2>&1 || {
    echo "===== monitor cycle failed; stopping stack for review $(date -u +%FT%TZ) =====" >> "$LOG_FILE"
    docker compose -f "$REPO_ROOT/docker-compose.yml" down >> "$LOG_FILE" 2>&1 || true
    exit "$INCIDENT_EXIT_STATUS"
  }
  sleep "$INTERVAL_SECONDS"
done
