#!/bin/bash
# Dry-run profitability analysis
# Run after the engine has collected signals in DRY_RUN mode

DB="${1:-/home/owenstack/repos/personal/cex-zig/zig/data/cex.db}"
REPORT="/tmp/cex-dry-run-analysis.txt"

echo "═══════════════════════════════════════════════════════════════" > "$REPORT"
echo "  CEX-ZIG DRY RUN ANALYSIS — $(date)" >> "$REPORT"
echo "═══════════════════════════════════════════════════════════════" >> "$REPORT"
echo "" >> "$REPORT"

echo "── 1. SIGNAL SUMMARY ─────────────────────────────────────────" >> "$REPORT"
sqlite3 "$DB" <<'SQL' >> "$REPORT"
.mode column
.headers on
SELECT
  strategy,
  direction,
  COUNT(*) as signal_count,
  ROUND(AVG(price), 4) as avg_price,
  ROUND(AVG(size), 2) as avg_size,
  ROUND(AVG(delta), 4) as avg_delta,
  ROUND(AVG(confidence), 4) as avg_confidence,
  ROUND(MIN(price), 4) as min_price,
  ROUND(MAX(price), 4) as max_price
FROM dry_run_signals
GROUP BY strategy, direction
ORDER BY strategy, direction;
SQL
echo "" >> "$REPORT"

echo "── 2. TIME RANGE ─────────────────────────────────────────────" >> "$REPORT"
sqlite3 "$DB" <<'SQL' >> "$REPORT"
.mode column
.headers on
SELECT
  datetime(MIN(signal_ts), 'unixepoch', 'localtime') as first_signal,
  datetime(MAX(signal_ts), 'unixepoch', 'localtime') as last_signal,
  ROUND((MAX(signal_ts) - MIN(signal_ts)) / 3600.0, 2) as duration_hours,
  COUNT(*) as total_signals
FROM dry_run_signals;
SQL
echo "" >> "$REPORT"

echo "── 3. SIGNAL FREQUENCY (per 5 min) ──────────────────────────" >> "$REPORT"
sqlite3 "$DB" <<'SQL' >> "$REPORT"
.mode column
.headers on
SELECT
  strategy,
  ROUND(COUNT(*) * 300.0 / NULLIF(MAX(signal_ts) - MIN(signal_ts), 0), 2) as signals_per_5min
FROM dry_run_signals
GROUP BY strategy;
SQL
echo "" >> "$REPORT"

echo "── 4. LP SPREAD ANALYSIS ─────────────────────────────────────" >> "$REPORT"
sqlite3 "$DB" <<'SQL' >> "$REPORT"
.mode column
.headers on
SELECT
  ROUND(AVG(best_ask - best_bid), 4) as avg_spread,
  ROUND(MIN(best_ask - best_bid), 4) as min_spread,
  ROUND(MAX(best_ask - best_bid), 4) as max_spread,
  ROUND(AVG((best_ask - best_bid) / NULLIF((best_bid + best_ask) / 2.0, 0) * 100), 2) as avg_spread_pct,
  COUNT(*) as samples
FROM dry_run_signals
WHERE strategy = 'liquidity_provision'
  AND direction = 'buy'
  AND best_bid > 0 AND best_ask > 0;
SQL
echo "" >> "$REPORT"

echo "── 5. LP PROFITABILITY ESTIMATE ──────────────────────────────" >> "$REPORT"
echo "(Assumes each LP pair captures 50% of quoted spread)" >> "$REPORT"
sqlite3 "$DB" <<'SQL' >> "$REPORT"
.mode column
.headers on
WITH lp_pairs AS (
  SELECT
    market_id,
    signal_ts,
    best_bid,
    best_ask,
    size,
    (best_ask - best_bid) as spread,
    price,
    direction
  FROM dry_run_signals
  WHERE strategy = 'liquidity_provision'
    AND direction = 'buy'
    AND best_bid > 0 AND best_ask > 0
)
SELECT
  COUNT(*) as pair_count,
  ROUND(SUM(spread * size * 0.5), 2) as gross_profit_est,
  ROUND(SUM(spread * size * 0.5) - COUNT(*) * 2 * 5.0 * 0.001, 2) as net_after_fees,
  ROUND(AVG(spread * size * 0.5), 4) as avg_profit_per_pair,
  ROUND(SUM(size) * 2, 2) as total_volume_usd
FROM lp_pairs;
SQL
echo "" >> "$REPORT"

echo "── 6. NEWS REPRICING SIGNALS ─────────────────────────────────" >> "$REPORT"
sqlite3 "$DB" <<'SQL' >> "$REPORT"
.mode column
.headers on
SELECT
  market_id,
  direction,
  ROUND(price, 4) as signal_price,
  ROUND(delta, 4) as delta,
  ROUND(confidence, 4) as confidence,
  ROUND(best_bid, 4) as bid,
  ROUND(best_ask, 4) as ask,
  datetime(signal_ts, 'unixepoch', 'localtime') as time
FROM dry_run_signals
WHERE strategy = 'news_repricing'
ORDER BY signal_ts DESC
LIMIT 20;
SQL
echo "" >> "$REPORT"

echo "── 7. TOP MARKETS BY SIGNAL COUNT ────────────────────────────" >> "$REPORT"
sqlite3 "$DB" <<'SQL' >> "$REPORT"
.mode column
.headers on
SELECT
  market_id,
  strategy,
  COUNT(*) as signals,
  ROUND(AVG(delta), 4) as avg_delta,
  ROUND(AVG(best_ask - best_bid), 4) as avg_spread
FROM dry_run_signals
WHERE best_bid > 0 AND best_ask > 0
GROUP BY market_id, strategy
ORDER BY signals DESC
LIMIT 15;
SQL
echo "" >> "$REPORT"

echo "── 8. HOURLY BREAKDOWN ───────────────────────────────────────" >> "$REPORT"
sqlite3 "$DB" <<'SQL' >> "$REPORT"
.mode column
.headers on
SELECT
  strftime('%Y-%m-%d %H:00', signal_ts, 'unixepoch', 'localtime') as hour,
  strategy,
  COUNT(*) as signals,
  ROUND(AVG(delta), 4) as avg_delta
FROM dry_run_signals
GROUP BY hour, strategy
ORDER BY hour;
SQL
echo "" >> "$REPORT"

echo "── 9. STRATEGY STATS (from engine) ───────────────────────────" >> "$REPORT"
sqlite3 "$DB" <<'SQL' >> "$REPORT"
.mode column
.headers on
SELECT
  strategy,
  signals_emitted,
  orders_accepted,
  orders_rejected,
  cancels,
  ROUND(realized_pnl_estimate, 4) as realized_pnl,
  datetime(snapshot_at, 'unixepoch', 'localtime') as recorded_at
FROM strategy_stats
ORDER BY snapshot_at DESC
LIMIT 10;
SQL
echo "" >> "$REPORT"

echo "── 10. VERDICT ───────────────────────────────────────────────" >> "$REPORT"
sqlite3 "$DB" <<'SQL' >> "$REPORT"
.mode list
WITH stats AS (
  SELECT
    COUNT(*) as total,
    SUM(CASE WHEN strategy='liquidity_provision' THEN 1 ELSE 0 END) as lp_total,
    SUM(CASE WHEN strategy='news_repricing' THEN 1 ELSE 0 END) as nr_total,
    AVG(CASE WHEN strategy='liquidity_provision' AND direction='buy' AND best_bid > 0 AND best_ask > 0 
         THEN (best_ask - best_bid) * size * 0.5 END) as avg_lp_profit_per_pair,
    ROUND((MAX(signal_ts) - MIN(signal_ts)) / 3600.0, 2) as hours
  FROM dry_run_signals
)
SELECT
  'Total signals: ' || total,
  'LP signals: ' || lp_total || ' (' || ROUND(lp_total * 1.0 / NULLIF(total, 0) * 100, 1) || '%)',
  'News signals: ' || nr_total || ' (' || ROUND(nr_total * 1.0 / NULLIF(total, 0) * 100, 1) || '%)',
  'Duration: ' || hours || ' hours',
  'Avg LP profit/pair: $' || ROUND(COALESCE(avg_lp_profit_per_pair, 0), 4),
  'Est. daily LP gross (24h extrapolation): $' || 
    ROUND(COALESCE(avg_lp_profit_per_pair * lp_total / 2.0 / NULLIF(hours, 0) * 24, 0), 2)
FROM stats;
SQL
echo "" >> "$REPORT"

echo "═══════════════════════════════════════════════════════════════" >> "$REPORT"
echo "  Analysis complete." >> "$REPORT"
echo "═══════════════════════════════════════════════════════════════" >> "$REPORT"

cat "$REPORT"
