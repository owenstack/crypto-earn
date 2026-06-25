#!/usr/bin/env bash
# Pre-live checklist for $10 deployment.
#
# Verifies that the dry-run produced enough data to be statistically
# meaningful before flipping the engine into live mode. Reports pass/fail
# per gate and exits non-zero if any required gate fails.
set -euo pipefail

DB="${1:-data/cex.db}"
PASS=0
FAIL=0

if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

check() {
    local label="$1"
    local condition="$2"
    local note="$3"
    if eval "$condition"; then
        echo "✅  $label"
        ((PASS++)) || true
    else
        echo "❌  $label — $note"
        ((FAIL++)) || true
    fi
}

echo ""
echo "══════════════════════════════════════"
echo "  cex-zig \$10 Pre-Live Preflight"
echo "══════════════════════════════════════"
echo ""

# Dry-run signal volume
SIG_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM dry_run_signals;" 2>/dev/null || echo 0)
check "Dry-run signals > 500" \
    "[ '$SIG_COUNT' -gt 500 ]" \
    "Have $SIG_COUNT signals. Need at least 500 (run for ~7 days)."

# Dry-run filled paper orders
ORDER_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM dry_run_orders WHERE status='filled';" 2>/dev/null || echo 0)
check "Dry-run filled orders > 10" \
    "[ '$ORDER_COUNT' -gt 10 ]" \
    "Have $ORDER_COUNT filled paper orders. Strategy may not be signalling correctly."

# Hyperliquid asset metadata discovered
ASSET_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM markets WHERE COALESCE(asset_index, -1) >= 0;" 2>/dev/null || echo 0)
check "Hyperliquid assets discovered > 0" \
    "[ '$ASSET_COUNT' -gt 0 ]" \
    "No HL asset metadata found. Start the engine with market data enabled before going live."

# Private key is set
check "HL_NETWORK is set" \
    "[ \"\${HL_NETWORK:-}\" = 'testnet' ] || [ \"\${HL_NETWORK:-}\" = 'mainnet' ]" \
    "Set HL_NETWORK to testnet or mainnet in .env"

check "HL_API_PRIVATE_KEY is set" \
    "[ -n \"\${HL_API_PRIVATE_KEY:-}\" ]" \
    "Set HL_API_PRIVATE_KEY in .env"

# DRY_RUN is unset or 0
check "DRY_RUN is disabled (unset or 0)" \
    "[ -z \"\${DRY_RUN:-}\" ] || [ \"\${DRY_RUN:-}\" = '0' ]" \
    "Remove DRY_RUN from .env before going live."

echo ""
echo "══════════════════════════════════════"
echo "  Manual checks (verify these too):"
echo "══════════════════════════════════════"
echo "  [ ] Hyperliquid account has enough USDC margin for the configured risk caps"
echo "  [ ] /config validate on Telegram shows all green"
echo "  [ ] /portfolio shows current HL equity, margin, and funding"
echo "  [ ] /drystatus diagnosis is paper_viable"
echo "  [ ] /strategy list shows strategies enabled"
echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "⛔  Not ready for live deployment."
    exit 1
else
    echo "🟢  Preflight passed. You may go live."
    exit 0
fi
