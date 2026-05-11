## Plan: Phase 3 Market Data Foundation

Deliver only Phase 3 by adding Hyperliquid asset metadata loading, Hyperliquid l2Book orderbook ingestion, and Binance bookTicker feed support, including only the minimum schema changes required to persist these feeds for strategy consumption. Keep all work scoped to wiring and validating market-data foundations without implementing later strategy/risk/order execution phases.

**Steps**
1. Phase A - Baseline and contracts: Freeze current integration points and define data contracts reused by runtime code. Confirm current dependencies in main startup flow, websocket callback path, orderbook reads in strategy loop, and asset-index stub in order manager. This establishes exact interfaces for Phase 3 modules. *blocks all later steps*
2. Phase B - Asset metadata module (TASK-3.1): Add new module for HL meta fetch, parse universe into symbol->asset_index map, and expose thread-safe lookup API. Include startup fetch with 3 retries + 2s backoff and 24h refresh timer. Persist refreshed asset metadata into markets with asset_index where present. *depends on 1*
3. Phase C - HL orderbook module (TASK-3.2 core): Add new module for HL websocket l2Book subscription per configured asset, snapshot ingestion, delta apply (insert/update/delete, zero-size removal), and best bid/ask/mid getters. Include reconnect with exponential backoff (1s-30s) and full resubscribe/reload on reconnect. *depends on 1; parallel with 2 after shared config types are stable*
4. Phase D - Binance feed module (TASK-3.3): Add new module for Binance Futures bookTicker subscriptions for multi-asset list, parse bid/ask to mid + nanosecond timestamp, expose thread-safe getters, reconnect with 2s delay, and emit feed-down signal if outage >30s. *depends on 1; parallel with 2 and 3*
5. Phase E - Startup/runtime wiring: Replace existing polymarket websocket boot path with HL orderbook startup path and add Binance feed thread bootstrap. Insert metadata preload before strategy/fill threads, and pass shared feed handles into runtime context. *depends on 2, 3, 4*
6. Phase F - Schema and DB hooks (Phase-3-only minimum): Add a migration for Phase 3 persistence only: markets.asset_index (if missing), orderbooks.asset_index (if missing), and binance_prices table. Update db migration runner and DB helper methods used by new modules for insert/select paths. Do not include Phase 7 HL-wide schema overhaul. *depends on 1; parallel with 2/3/4, must finish before 5 integration tests*
7. Phase G - Replace asset-index stub in order manager: Remove hardcoded asset index 0 path and bind order payload asset index lookup to metadata module API. This change is limited to data dependency correctness and does not expand into Phase 4 order execution logic. *depends on 2 and 5*
8. Phase H - Tests and verification: Add unit tests for meta response parsing/lookup, orderbook snapshot+delta mutations, and Binance bookTicker parse/mid calculation. Add integration-level assertions for startup preload and reconnect behavior. Run Zig tests and targeted smoke checks for persistence writes and latest-price reads consumed by strategy queries. *depends on 2-7*

**Parallelization map**
1. Parallel track 1: Steps 2 + 6 can proceed together after Step 1.
2. Parallel track 2: Steps 3 + 4 can proceed together after Step 1.
3. Step 5 waits for Steps 2, 3, 4, and DB write paths from 6.
4. Step 8 starts after Steps 5, 6, and 7 complete.

**Relevant files**
- /home/owenstack/repos/personal/crypto-earn/zig/src/main.zig - startup sequencing, thread spawns, callback wiring currently tied to existing websocket client.
- /home/owenstack/repos/personal/crypto-earn/zig/src/websocket.zig - current polymarket-oriented feed client to be replaced or isolated from Phase 3 paths.
- /home/owenstack/repos/personal/crypto-earn/zig/src/order_manager.zig - asset index stub currently hardcoded to 0; wire lookup integration.
- /home/owenstack/repos/personal/crypto-earn/zig/src/db.zig - migration runner and DB helpers used by feed persistence.
- /home/owenstack/repos/personal/crypto-earn/db/migrations/001_initial.sql - baseline schema context for new Phase-3 persistence migration.
- /home/owenstack/repos/personal/crypto-earn/db/migrations/002_phase2_orders_risk.sql - migration numbering baseline.
- /home/owenstack/repos/personal/crypto-earn/db/migrations/003_phase3_strategy_stats.sql - existing phase numbering anchor; new migration should continue sequence.
- /home/owenstack/repos/personal/crypto-earn/zig/src/tests.zig - add Phase 3 parser/orderbook/binance test cases.
- /home/owenstack/repos/personal/crypto-earn/zig/src - create new modules for hl_market_meta, hl_orderbook, and binance_ws.

**Verification**
1. Unit tests: parse HL meta fixture and assert symbol->asset_index map values and missing-symbol behavior.
2. Unit tests: apply orderbook snapshot + sequence of deltas and assert sorted levels, removals, and mid-price after each mutation.
3. Unit tests: parse Binance bookTicker fixture and assert bid/ask/mid/timestamp extraction.
4. Runtime smoke: startup logs show asset-index preload success and loaded count before strategy loop starts.
5. Runtime smoke: simulated disconnects trigger expected reconnect policy for HL and Binance feeds.
6. DB checks: confirm markets.asset_index and orderbooks.asset_index are populated; confirm binance_prices receives rows for all configured symbols.
7. Regression check: existing strategy query paths reading latest orderbook rows still return valid best bid/ask/mid after wiring change.

**Decisions**
- Include only schema changes strictly needed by Phase 3 feed and metadata persistence; defer broader HL schema redesign to later phase.
- Multi-asset feed support is included in Phase 3 scope for both HL subscriptions and Binance symbols.
- Keep phase boundary strict: no Phase 4 order placement logic, no Phase 5 fill/portfolio rewrites, no Phase 6 arb signal implementation.

**Scope boundaries**
- Included: metadata fetch/refresh, orderbook ingestion+deltas, binance feed ingest, startup wiring, minimal DB persistence, tests.
- Excluded: live order routing/cancel improvements, risk gate margin rewrite, strategy behavior changes, telegram/dashboard feature updates.

**Further considerations**
1. Fully bypass polymarket websocket client in startup to reduce migration risk during Phase 3 testing.
2. Confirm canonical symbol normalization rules between HL coin names and Binance symbols (for example BTC vs BTCUSDT) before wiring multi-asset persistence keys.
3. Add lightweight instrumentation counters for snapshot count, delta count, and reconnect count now to simplify Phase 5/6 observability later.