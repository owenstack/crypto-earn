#!/bin/bash
# Dry-run profitability analysis
# Run after the engine has collected signals in DRY_RUN mode

DB="${1:-./data/cex.db}"
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
WHERE strategy IN ('market_making','liquidity_provision')
  AND direction = 'buy'
  AND best_bid > 0 AND best_ask > 0;
SQL
echo "" >> "$REPORT"

echo "── 5. LP PROFITABILITY ESTIMATE ──────────────────────────────" >> "$REPORT"
echo "(Per distinct market, with fill-rate sensitivity)" >> "$REPORT"
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
    direction,
    ROW_NUMBER() OVER (PARTITION BY market_id ORDER BY signal_ts) as rn
  FROM dry_run_signals
  WHERE strategy IN ('market_making','liquidity_provision')
    AND direction = 'buy'
    AND best_bid > 0 AND best_ask > 0
),
distinct_markets AS (
  SELECT
    market_id,
    COUNT(*) as signal_repeats,
    AVG(spread) as avg_spread,
    AVG(size) as avg_size,
    AVG(spread * size * 0.5) as avg_profit_per_fill
  FROM lp_pairs
  GROUP BY market_id
),
summary AS (
  SELECT
    COUNT(*) as distinct_market_count,
    (SELECT COUNT(*) FROM lp_pairs) as raw_pair_count,
    ROUND(AVG(avg_spread), 4) as avg_spread,
    ROUND(AVG(signal_repeats), 1) as avg_repeats_per_market,
    ROUND(SUM(avg_profit_per_fill), 2) as profit_if_all_fill_once,
    ROUND(SUM(avg_profit_per_fill) * 0.05, 2) as profit_at_5pct_fill,
    ROUND(SUM(avg_profit_per_fill) * 0.10, 2) as profit_at_10pct_fill,
    ROUND(SUM(avg_profit_per_fill) * 0.25, 2) as profit_at_25pct_fill,
    ROUND(SUM(avg_size) * 2, 2) as total_notional_if_all_fill
  FROM distinct_markets
)
SELECT * FROM summary;
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
    COUNT(DISTINCT CASE WHEN strategy IN ('market_making','liquidity_provision') THEN market_id END) as lp_distinct_markets,
    SUM(CASE WHEN strategy IN ('market_making','liquidity_provision') THEN 1 ELSE 0 END) as lp_raw_signals,
    SUM(CASE WHEN strategy='news_repricing' THEN 1 ELSE 0 END) as nr_total,
    AVG(CASE WHEN strategy IN ('market_making','liquidity_provision') AND direction='buy' AND best_bid > 0 AND best_ask > 0
         THEN (best_ask - best_bid) * size * 0.5 END) as avg_lp_profit_per_pair,
    ROUND((MAX(signal_ts) - MIN(signal_ts)) / 3600.0, 2) as hours
  FROM dry_run_signals
)
SELECT
  'Total raw signals: ' || total,
  'LP distinct markets: ' || lp_distinct_markets || ' (raw signals: ' || lp_raw_signals || ', ' || COALESCE(ROUND(lp_raw_signals * 1.0 / NULLIF(lp_distinct_markets, 0), 0), 0) || 'x oversample)',
  'News signals: ' || nr_total,
  'Duration: ' || hours || ' hours',
  'Avg LP profit/pair (if filled): $' || ROUND(COALESCE(avg_lp_profit_per_pair, 0), 4),
  'Per-market profit @ 10% fill: $' || (
    SELECT ROUND(COALESCE(SUM(avg_profit_per_fill) * 0.10, 0), 2)
    FROM (
      SELECT AVG((best_ask - best_bid) * size * 0.5) as avg_profit_per_fill
      FROM dry_run_signals
      WHERE strategy IN ('market_making','liquidity_provision')
        AND direction = 'buy'
        AND best_bid > 0 AND best_ask > 0
      GROUP BY market_id
    )
  ),
  'WARNING: Fill rate is unknown — these are theoretical maximums'
FROM stats;
SQL
echo "" >> "$REPORT"

echo "═══════════════════════════════════════════════════════════════" >> "$REPORT"
echo "  Analysis complete." >> "$REPORT"
echo "═══════════════════════════════════════════════════════════════" >> "$REPORT"

cat "$REPORT"
