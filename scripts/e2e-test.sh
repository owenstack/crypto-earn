#!/usr/bin/env bash
set -euo pipefail

# E2E integration test harness for cex-zig
# Validates the full deployed system: services, IPC, dashboard API, DB.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

# ── Source environment ────────────────────────────────────────────────────────
if [[ -f /opt/cex-zig/.env ]]; then
  set -a; source /opt/cex-zig/.env; set +a
elif [[ -f "$DIR/.env" ]]; then
  set -a; source "$DIR/.env"; set +a
fi

DASHBOARD_SECRET="${DASHBOARD_SECRET:-}"
DB_PATH="${DB_PATH:-./data/cex.db}"
IPC_SOCKET="${IPC_SOCKET:-/tmp/cex-engine.sock}"
DASHBOARD_PORT="${DASHBOARD_PORT:-3000}"
BASE_URL="http://127.0.0.1:${DASHBOARD_PORT}"

TEST_FAILURES=false
for arg in "$@"; do
  case "$arg" in
    --test-failures) TEST_FAILURES=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# ── Test counters ─────────────────────────────────────────────────────────────
PASS=0
FAIL=0

pass() {
  echo "    PASS $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "    FAIL $1" >&2
  FAIL=$((FAIL + 1))
}

check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label"
  fi
}

# ── 1. Service startup checks ────────────────────────────────────────────────
echo "==> Service startup checks"

check "cex-engine.service is active" \
  systemctl is-active --quiet cex-engine.service

check "cex-control.service is active" \
  systemctl is-active --quiet cex-control.service

# Verify engine starts after network.target
after_deps=$(systemctl show -p After --value cex-engine.service 2>/dev/null || true)
if echo "$after_deps" | grep -q "network.target"; then
  pass "cex-engine starts after network.target"
else
  fail "cex-engine starts after network.target"
fi

# ── 2. IPC socket checks ─────────────────────────────────────────────────────
echo "==> IPC socket checks"

if [[ -e "$IPC_SOCKET" ]]; then
  pass "IPC socket file exists ($IPC_SOCKET)"
else
  fail "IPC socket file exists ($IPC_SOCKET)"
fi

if [[ -S "$IPC_SOCKET" ]]; then
  pass "IPC socket is a socket file"
else
  fail "IPC socket is a socket file"
fi

# ── 3. Dashboard auth checks ─────────────────────────────────────────────────
echo "==> Dashboard auth checks"

# GET /api/status without auth → 401
status_code=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api/status" 2>/dev/null || echo "000")
if [[ "$status_code" == "401" ]]; then
  pass "GET /api/status without auth → 401"
else
  fail "GET /api/status without auth → 401 (got $status_code)"
fi

# GET /api/status with wrong token → 401
status_code=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer wrong-token" \
  "${BASE_URL}/api/status" 2>/dev/null || echo "000")
if [[ "$status_code" == "401" ]]; then
  pass "GET /api/status with wrong token → 401"
else
  fail "GET /api/status with wrong token → 401 (got $status_code)"
fi

# GET /api/status with correct auth → 200
if [[ -n "$DASHBOARD_SECRET" ]]; then
  status_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${DASHBOARD_SECRET}" \
    "${BASE_URL}/api/status" 2>/dev/null || echo "000")
  if [[ "$status_code" == "200" ]]; then
    pass "GET /api/status with correct auth → 200"
  else
    fail "GET /api/status with correct auth → 200 (got $status_code)"
  fi

  # GET /api/portfolio with correct auth → 200
  status_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${DASHBOARD_SECRET}" \
    "${BASE_URL}/api/portfolio" 2>/dev/null || echo "000")
  if [[ "$status_code" == "200" ]]; then
    pass "GET /api/portfolio with correct auth → 200"
  else
    fail "GET /api/portfolio with correct auth → 200 (got $status_code)"
  fi

  # GET /api/heartbeat with correct auth → 200
  status_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${DASHBOARD_SECRET}" \
    "${BASE_URL}/api/heartbeat" 2>/dev/null || echo "000")
  if [[ "$status_code" == "200" ]]; then
    pass "GET /api/heartbeat with correct auth → 200"
  else
    fail "GET /api/heartbeat with correct auth → 200 (got $status_code)"
  fi
else
  fail "DASHBOARD_SECRET not set — skipping authenticated endpoint tests"
fi

# ── 4. DB accessibility ──────────────────────────────────────────────────────
echo "==> DB accessibility checks"

if command -v sqlite3 &>/dev/null && [[ -f "$DB_PATH" ]]; then
  # Basic query against schema_migrations
  if sqlite3 "$DB_PATH" "SELECT version FROM schema_migrations LIMIT 1;" >/dev/null 2>&1; then
    pass "schema_migrations table is queryable"
  else
    fail "schema_migrations table is queryable"
  fi

  # Verify migration versions 1, 2, 4 are present
  for v in 1 2 4; do
    count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM schema_migrations WHERE version=$v;" 2>/dev/null || echo "0")
    if [[ "$count" -gt 0 ]]; then
      pass "migration version $v is present"
    else
      fail "migration version $v is present"
    fi
  done
else
  fail "DB not accessible (sqlite3 missing or $DB_PATH not found)"
fi

# ── 5. Failure path tests (optional) ─────────────────────────────────────────
if [[ "$TEST_FAILURES" == true ]]; then
  echo "==> Failure path tests"

  echo "    Stopping cex-engine.service ..."
  sudo systemctl stop cex-engine.service
  sleep 2

  if [[ -n "$DASHBOARD_SECRET" ]]; then
    body=$(curl -s \
      -H "Authorization: Bearer ${DASHBOARD_SECRET}" \
      "${BASE_URL}/api/status" 2>/dev/null || echo "")
    if echo "$body" | grep -qi "offline"; then
      pass "/api/status reports offline when engine stopped"
    else
      fail "/api/status reports offline when engine stopped"
    fi
  else
    fail "DASHBOARD_SECRET not set — cannot test failure path"
  fi

  echo "    Restarting cex-engine.service ..."
  sudo systemctl start cex-engine.service
  sleep 3
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==> E2E Test Summary: $PASS passed, $FAIL failed"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
