#!/bin/bash
# Improved dry-run health check.
# - Keeps a JSONL history so a single noisy snapshot can't fool you.
# - Normalizes PnL to bps of equity so it's comparable across balance changes.
# - Gates the diagnosis behind a sample-size confidence label.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT" || exit 1
set -a; . "$REPO_ROOT/.env"; set +a

cycle_status=0

HISTORY_FILE="${CEX_HEALTH_HISTORY:-$HOME/.cex-earn-health.jsonl}"
DASH="http://localhost:${DASHBOARD_PORT:-3000}"
AUTH=(-H "Authorization: Bearer $DASHBOARD_SECRET")

# ── 1. Container + API reachability ─────────────────────────────────
health=$(docker inspect -f '{{.State.Health.Status}}' crypto-earn-engine-1 2>/dev/null || echo missing)

analysis_http=$(curl -sS --max-time 5 -o /tmp/cex-analysis-now -w '%{http_code}' \
  "${AUTH[@]}" "$DASH/api/dry-run-analysis")
portfolio_http=$(curl -sS --max-time 5 -o /tmp/cex-portfolio-now -w '%{http_code}' \
  "${AUTH[@]}" "$DASH/api/portfolio")

printf 'health=%s DRY_RUN=%s ARB=%s SUBMIT=%s analysis_http=%s portfolio_http=%s\n' \
  "$health" "$DRY_RUN" "${ENABLE_CEX_DEX_ARB:-0}" "${ARB_SUBMIT_ORDERS:-0}" \
  "$analysis_http" "$portfolio_http"

[[ "$health" == "healthy" ]] || cycle_status=1
[[ "$analysis_http" == "200" ]] || cycle_status=1
[[ "$portfolio_http" == "200" ]] || cycle_status=1

if [[ "$analysis_http" != "200" ]]; then
  echo "⚠️  dry-run-analysis endpoint not healthy, skipping metric analysis"
else

  # ── 2. Pull current equity for normalization ──────────────────────
  equity=$(jq -r '[.equity, .usdc_balance, .committed_capital_usd]
    | map(select(type == "number" and . > 0)) | first // empty' \
    /tmp/cex-portfolio-now 2>/dev/null)
  [[ -z "$equity" || "$equity" == "null" ]] && equity="$DRY_RUN_INITIAL_BALANCE"
  [[ -z "$equity" ]] && equity=10

  # ── 3. Extract current metrics ─────────────────────────────────────
  read -r total persistent filled fill_rate net_pnl pf diagnosis <<<"$(jq -r '
    [.total_signals, .persistent_signals, .paper_filled_trades,
     .paper_fill_rate_pct, .paper_net_pnl, .paper_profit_factor, .diagnosis]
    | @tsv' /tmp/cex-analysis-now)"

  # PnL normalized to bps of current equity — comparable even after you
  # change DRY_RUN_INITIAL_BALANCE, unlike the raw dollar figure.
  pnl_bps=$(awk -v pnl="$net_pnl" -v eq="$equity" 'BEGIN {
    if (eq > 0) printf "%.2f", (pnl/eq)*10000; else print "NA" }')

  # ── 4. Sample-size confidence gate ─────────────────────────────────
  # Don't trust profit_factor/diagnosis as a verdict below ~30 fills;
  # treat it as a status update, not a signal, until then.
  if   (( filled < 15 ));  then confidence="LOW (n=$filled, noise-dominated)"
  elif (( filled < 30 ));  then confidence="LOW-MED (n=$filled)"
  elif (( filled < 100 )); then confidence="MEDIUM (n=$filled)"
  else                          confidence="HIGH (n=$filled)"
  fi

  # ── 5. Delta since last check ──────────────────────────────────────
  if [[ -f "$HISTORY_FILE" ]]; then
    prev=$(tail -n1 "$HISTORY_FILE")
    prev_filled=$(jq -r '.paper_filled_trades // 0' <<<"$prev")
    prev_pnl=$(jq -r '.paper_net_pnl // 0' <<<"$prev")
    new_fills=$(( filled - prev_filled ))
    pnl_delta=$(awk -v a="$net_pnl" -v b="$prev_pnl" 'BEGIN{printf "%.4f", a-b}')
  else
    new_fills="n/a (first run)"
    pnl_delta="n/a"
  fi

  echo "── Dry-run snapshot ──────────────────────────────────────────"
  jq -n --arg total "$total" --arg persistent "$persistent" --arg filled "$filled" \
    --arg fill_rate "$fill_rate" --arg net_pnl "$net_pnl" --arg pf "$pf" \
    --arg diagnosis "$diagnosis" --arg pnl_bps "$pnl_bps" --arg equity "$equity" \
    --arg confidence "$confidence" \
    '{total_signals:$total, persistent_signals:$persistent, paper_filled_trades:$filled,
      paper_fill_rate_pct:$fill_rate, paper_net_pnl:$net_pnl, paper_profit_factor:$pf,
      pnl_bps_of_equity:$pnl_bps, equity_used:$equity, diagnosis:$diagnosis,
      confidence:$confidence}'
  echo "since last check: new_fills=$new_fills pnl_delta=\$${pnl_delta}"

  # ── 6. Append to history for trend tracking ────────────────────────
  jq -cn --arg ts "$(date -u +%FT%TZ)" --arg total "$total" --arg persistent "$persistent" \
    --arg filled "$filled" --arg fill_rate "$fill_rate" --arg net_pnl "$net_pnl" \
    --arg pf "$pf" --arg diagnosis "$diagnosis" --arg pnl_bps "$pnl_bps" --arg equity "$equity" \
    --arg confidence "$confidence" \
    '{ts:$ts, total_signals:$total, persistent_signals:$persistent, paper_filled_trades:$filled,
      paper_fill_rate_pct:$fill_rate, paper_net_pnl:$net_pnl, paper_profit_factor:$pf,
      pnl_bps_of_equity:$pnl_bps, equity_used:$equity, diagnosis:$diagnosis,
      confidence:$confidence}' \
    >> "$HISTORY_FILE"
fi

# ── 7. Resource + error log checks (unchanged from your original) ────
docker stats --no-stream --format '{{.MemUsage}}' crypto-earn-engine-1

error_lines=$(docker compose logs --tail=200 engine 2>&1 |
  grep -E '"level":"ERROR"|panic|segfault|oom|out of memory|fatal|corrupt' |
  tail -10 || true)
if [[ -n "$error_lines" ]]; then
  printf '%s\n' "$error_lines"
  cycle_status=1
fi

# ── 8. Monitoring-loop / watchdog check ───────────────────────────────
# Status only: the separately-owned loop must never be started, restarted, or
# reconfigured here. Its owner can provide the exact unit via .env.
if [[ -n "${MONITORING_LOOP_SYSTEMD_UNIT:-}" ]]; then
  monitoring_status=$(systemctl is-active "$MONITORING_LOOP_SYSTEMD_UNIT" 2>/dev/null || true)
  printf 'monitoring_loop_unit=%s monitoring_loop_status=%s\n' \
    "$MONITORING_LOOP_SYSTEMD_UNIT" "${monitoring_status:-unknown}"
else
  echo "monitoring_loop_status=unknown (MONITORING_LOOP_SYSTEMD_UNIT not configured)"
fi

exit "$cycle_status"
