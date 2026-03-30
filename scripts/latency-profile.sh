#!/usr/bin/env bash
set -euo pipefail

# ── CEX Latency Profiler ─────────────────────────────────────────────────────
# Measures dashboard API latency for key paths against PRD targets.
# Pure bash + curl + awk — no Node.js/Bun dependencies.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
ITERATIONS=100
API_THRESHOLD_MS=100
IPC_THRESHOLD_MS=50
OUTPUT_FILE=""

# ── Parse flags ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations)       ITERATIONS="$2"; shift 2 ;;
    --threshold-ms)     API_THRESHOLD_MS="$2"; IPC_THRESHOLD_MS="$2"; shift 2 ;;
    --api-threshold-ms) API_THRESHOLD_MS="$2"; shift 2 ;;
    --ipc-threshold-ms) IPC_THRESHOLD_MS="$2"; shift 2 ;;
    --output)           OUTPUT_FILE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--iterations N] [--threshold-ms MS] [--output FILE]"
      echo ""
      echo "Options:"
      echo "  --iterations N        Number of requests per endpoint (default: 100)"
      echo "  --threshold-ms MS     Set both API and IPC thresholds (default: API=100, IPC=50)"
      echo "  --api-threshold-ms MS API endpoint threshold in ms (default: 100)"
      echo "  --ipc-threshold-ms MS IPC-proxied endpoint threshold in ms (default: 50)"
      echo "  --output FILE         Write report to FILE in addition to stdout"
      exit 0
      ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# ── Load environment ──────────────────────────────────────────────────────────
if [[ -f /opt/cex-zig/.env ]]; then
  set -a; source /opt/cex-zig/.env; set +a
elif [[ -f "$DIR/.env" ]]; then
  set -a; source "$DIR/.env"; set +a
else
  echo "WARN: No .env found at /opt/cex-zig/.env or $DIR/.env — using env vars" >&2
fi

DASHBOARD_PORT="${DASHBOARD_PORT:-3000}"
DASHBOARD_SECRET="${DASHBOARD_SECRET:-}"
BASE_URL="http://127.0.0.1:${DASHBOARD_PORT}"

if [[ -z "$DASHBOARD_SECRET" ]]; then
  echo "ERROR: DASHBOARD_SECRET is not set" >&2
  exit 1
fi

# ── Preflight check ──────────────────────────────────────────────────────────
if ! curl -sf -o /dev/null -w '' "${BASE_URL}/api/heartbeat" \
    -H "Authorization: Bearer ${DASHBOARD_SECRET}" --max-time 5 2>/dev/null; then
  echo "ERROR: Dashboard not reachable at ${BASE_URL}" >&2
  echo "       Make sure the dashboard is running before profiling." >&2
  exit 1
fi

# ── Endpoint definitions ─────────────────────────────────────────────────────
# Format: path|threshold_ms|category
# category: "ipc" for IPC-proxied endpoints, "api" for direct DB/API
ENDPOINTS=(
  "/api/status|${IPC_THRESHOLD_MS}|ipc"
  "/api/heartbeat|${IPC_THRESHOLD_MS}|ipc"
  "/api/portfolio|${API_THRESHOLD_MS}|api"
  "/api/orders|${API_THRESHOLD_MS}|api"
)

# ── Collect latencies ────────────────────────────────────────────────────────
declare -A LATENCIES

echo "Profiling ${#ENDPOINTS[@]} endpoints × ${ITERATIONS} iterations..."
echo ""

for entry in "${ENDPOINTS[@]}"; do
  IFS='|' read -r path threshold category <<< "$entry"
  times_file=$(mktemp)
  TEMP_FILES+=("$times_file")

  for ((i = 1; i <= ITERATIONS; i++)); do
    curl -sf -o /dev/null \
      -w '%{time_total}\n' \
      -H "Authorization: Bearer ${DASHBOARD_SECRET}" \
      --max-time 10 \
      "${BASE_URL}${path}" >> "$times_file"
  done

  LATENCIES["${path}"]="$times_file"
  echo "  ✓ ${path} (${ITERATIONS} samples collected)"
done

echo ""

# ── Percentile calculation ────────────────────────────────────────────────────
# Reads a file of seconds (float), converts to ms, returns: p50 p95 p99 max
calc_percentiles() {
  local file="$1"
  awk '
  {
    ms = $1 * 1000
    vals[NR] = ms
  }
  END {
    n = NR
    # sort
    for (i = 1; i <= n; i++)
      for (j = i + 1; j <= n; j++)
        if (vals[i] > vals[j]) {
          tmp = vals[i]; vals[i] = vals[j]; vals[j] = tmp
        }
    p50_idx = int(n * 0.50 + 0.5); if (p50_idx < 1) p50_idx = 1
    p95_idx = int(n * 0.95 + 0.5); if (p95_idx < 1) p95_idx = 1
    p99_idx = int(n * 0.99 + 0.5); if (p99_idx < 1) p99_idx = 1
    printf "%.1f %.1f %.1f %.1f\n", vals[p50_idx], vals[p95_idx], vals[p99_idx], vals[n]
  }
  ' "$file"
}

# ── Generate report ──────────────────────────────────────────────────────────
generate_report() {
  echo "=== CEX Latency Profile Report ==="
  echo "Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Target: ${BASE_URL}"
  echo "Iterations: ${ITERATIONS}"
  echo ""
  printf "%-24s %8s %8s %8s %8s %12s %8s\n" \
    "Path" "p50" "p95" "p99" "max" "threshold" "result"
  printf "%-24s %8s %8s %8s %8s %12s %8s\n" \
    "------------------------" "--------" "--------" "--------" "--------" "------------" "--------"

  overall_pass=true

  for entry in "${ENDPOINTS[@]}"; do
    IFS='|' read -r path threshold category <<< "$entry"
    file="${LATENCIES[$path]}"

    read -r p50 p95 p99 max_val <<< "$(calc_percentiles "$file")"

    # Compare p99 against threshold
    result=$(awk -v p99="$p99" -v thr="$threshold" 'BEGIN { print (p99 <= thr) ? "PASS" : "FAIL" }')
    if [[ "$result" == "FAIL" ]]; then
      overall_pass=false
    fi

    printf "%-24s %6sms %6sms %6sms %6sms %10sms %8s\n" \
      "$path" "$p50" "$p95" "$p99" "$max_val" "$threshold" "$result"
  done

  echo ""
  if [[ "$overall_pass" == true ]]; then
    echo "Overall: PASS (all paths within threshold)"
  else
    echo "Overall: FAIL (one or more paths exceeded threshold)"
  fi
}

# Print to stdout
report=$(generate_report)
echo "$report"

# Optionally write to file
if [[ -n "$OUTPUT_FILE" ]]; then
  echo "$report" > "$OUTPUT_FILE"
  echo ""
  echo "Report written to: ${OUTPUT_FILE}"
fi

# ── Cleanup ──────────────────────────────────────────────────────────────────
for entry in "${ENDPOINTS[@]}"; do
  IFS='|' read -r path _ _ <<< "$entry"
  rm -f "${LATENCIES[$path]}"
done

# Exit with failure if any path exceeded threshold
if echo "$report" | grep -q "^Overall: FAIL"; then
  exit 1
fi
