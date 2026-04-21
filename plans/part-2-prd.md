# CEX Engine — Correctness & Strategy Integrity PRD

**Document ID**: PRD-CEX-002  
**Version**: 1.0  
**Status**: Draft  
**Date**: 2026-04-20  
**Scope**: Excludes dashboard authentication (covered separately in PRD-CEX-003)

---

## Context

### Project description

`cex-engine` is a two-process automated trading system for the Polymarket prediction market CLOB. A Zig engine handles market scanning, order lifecycle, risk gating, and strategy evaluation. A TypeScript/Bun control plane surfaces a React dashboard and Telegram command interface. They communicate over a UNIX domain socket with a JSON-lines envelope protocol and share a SQLite WAL database.

A prior analysis identified seven production-blocking defects and one architectural weakness that, left unresolved, would cause the system to place orders it cannot track, fail to cancel orders on the exchange, trade on a signal that carries no real edge, and silently corrupt its own market registry after a restart. None of these defects are visible in normal operation until money is lost.

### Business objectives

- Achieve a state where the engine can be funded and operated with real capital without silent data loss, uncancellable open orders, or phantom positions
- Ensure the news-repricing strategy operates on a genuine independent probability signal rather than lagged data from the same venue
- Ensure the liquidity-provision strategy does not bleed inventory against informed traders without any protective mechanism
- Establish a reliable ground-truth synchronisation point between SQLite and Polymarket's own ledger on every startup and after every reconnect

### Target users and key personas

**Persona A — Operator (primary)**: The engineer who deploys and monitors the bot. Needs confidence that halts, cancels, and reconciliation work correctly under all failure modes. Interacts via Telegram bot and dashboard.

**Persona B — Strategy Developer (secondary)**: Adds or tunes strategies. Needs a clean signal interface, accurate fill data, and trustworthy position state to evaluate performance.

### Technical constraints

- Zig 0.15.x for the engine; Bun 1.x / TypeScript for the control plane
- SQLite WAL, no external database
- Polymarket CLOB REST API v1 and WebSocket subscription API
- All network calls from the Zig engine; no browser-side API calls to Polymarket
- No new third-party Zig libraries may be added without updating `zig.zon`; new TypeScript packages must be compatible with Bun

---

## Non-goals

- Dashboard authentication fixes (separate PRD-CEX-003)
- UI redesign or new dashboard panels
- Support for venues other than Polymarket
- Multi-account or multi-key operation
- Automated backtesting infrastructure

---

## Functional requirements

| ID | Requirement | Priority |
|---|---|---|
| FR-01 | Engine detects order fills from Polymarket and updates local state | P0 |
| FR-02 | Engine cancels orders on the CLOB exchange using the correct API method | P0 |
| FR-03 | Engine reconciles open orders and positions against the CLOB on startup | P0 |
| FR-04 | News-repricing strategy derives `external_prob` from an independent probability source, not Polymarket's own `outcome_prices` field | P0 |
| FR-05 | Market scanner prevents data loss caused by slug collisions in the `markets` table | P0 |
| FR-06 | Engine uses a single canonical market identifier consistently across scanner, strategy evaluation, order placement, and the WebSocket feed | P1 |
| FR-07 | Liquidity-provision strategy enforces per-market inventory limits and cancels the unpaired leg when one side fills | P1 |
| FR-08 | Fill events are published over IPC so the control plane and Telegram bot receive real-time fill notifications | P1 |

### Non-functional requirements

| ID | Requirement | Priority |
|---|---|---|
| NFR-01 | Startup reconciliation completes within 30 seconds for an account with ≤ 500 open orders | P0 |
| NFR-02 | Fill detection latency ≤ 5 seconds from CLOB acknowledgement to local DB update under normal network conditions | P0 |
| NFR-03 | A failed cancel attempt on the CLOB is retried with the same backoff schedule already used for order placement | P1 |
| NFR-04 | The independent probability source is configurable via `runtime_config` without a binary recompile | P1 |
| NFR-05 | All new DB schema changes are applied via the existing numbered migration pattern in `db.zig` | P0 |
| NFR-06 | New functionality is covered by tests in `tests.zig` following the existing test naming convention | P1 |

---

## User experience narrative

The operator starts the engine after depositing USDC. On boot the engine queries Polymarket for every open order and open position associated with the signing address. Any discrepancies between that ledger and the local SQLite state are resolved before any new strategy signals are evaluated. The operator receives a Telegram message confirming the reconciled state: "Reconciliation complete — 3 open orders adopted, 1 stale DB order closed."

During trading, when a limit order fills, the engine receives confirmation within seconds, updates the position table, calculates realised PnL, and publishes a Telegram notification: "✅ Order filled — market: X, side: buy, size: 10, price: 0.47." The LP strategy immediately cancels the mirrored unfilled leg. The dashboard's Positions panel now reflects the correct position.

When the operator issues `/halt` via Telegram, the engine marks itself halted, then iterates every open order and calls `DELETE /order` on the CLOB for each one, correctly cancelling them at the exchange. The Telegram response confirms the count of orders cancelled at both the exchange and in the database.

When the news-repricing strategy fires, it is because a configured independent source (Metaculus, Manifold, or a locally hosted probability API endpoint) reports a probability materially different from the live CLOB mid. The operator can change the source URL and confidence threshold live via `/config set` without restarting the engine.

---

## Milestones and sequencing

### Phase 1 — Critical correctness fixes (P0 blockers, ~2 weeks solo)

Fixes FR-02, FR-05, and the identifier consistency issue (FR-06 partially). No new external dependencies. Safe to deploy immediately after.

### Phase 2 — Fill detection and reconciliation (~2 weeks solo)

Implements FR-01, FR-03, FR-08. Requires CLOB REST polling and a new DB migration. Unblocks accurate position tracking, realised PnL, and the Telegram fill notification.

### Phase 3 — Strategy integrity (~2 weeks solo)

Implements FR-04 and FR-07. Requires a configurable external probability source and LP inventory management. Strategy can be paper-traded after Phase 2 is complete.

### Phase 4 — Hardening and test coverage (~1 week solo)

NFR-01 through NFR-06. Integration tests, load testing reconciliation, documentation update.

---

## Development task plan

### Phase 1 — Critical correctness fixes

- [ ] **TASK-1.1** Fix CLOB order cancellation HTTP method
  - **File**: `zig/src/order_manager.zig`, `cancelOnCLOB()`
  - **Change**: Replace `POST` to `/order/cancel` with `DELETE` to `/order`. Polymarket CLOB API spec requires `DELETE /order` with body `{"orderID": "<id>"}` (note the `orderID` casing in the official spec — verify against current API docs before merging)
  - **Subtasks**:
    - [ ] TASK-1.1.1 Update `cancelOnCLOB()` method string from `.POST` to `.DELETE` and URL from `/order/cancel` to `/order`
    - [ ] TASK-1.1.2 Verify payload key casing matches current Polymarket spec (`orderID` vs `order_id`)
    - [ ] TASK-1.1.3 Add integration test that asserts a 2xx response code is accepted and non-2xx triggers the existing retry path
    - [ ] TASK-1.1.4 Update `cancelAll()` to log each individual CLOB cancel result so failures are observable per-order

- [ ] **TASK-1.2** Fix market registry slug-collision data loss
  - **File**: `zig/src/market_scanner.zig`, `persistMarket()`; `zig/src/db.zig`, `MIGRATION_001`
  - **Background**: `symbol` column maps to `m.slug` and has a `UNIQUE` constraint. Two distinct Polymarket markets (different `id` values) can share the same slug during their lifetime, causing `INSERT OR REPLACE` to silently delete the conflicting row's foreign-key-linked orders and positions
  - **Subtasks**:
    - [ ] TASK-1.2.1 Add `MIGRATION_006` in `db.zig` that drops the `UNIQUE` constraint on `markets.symbol` (requires recreating the table in SQLite, which does not support `DROP CONSTRAINT` — use the `CREATE TABLE ... INSERT ... DROP ... RENAME` pattern)
    - [ ] TASK-1.2.2 Change `INSERT OR REPLACE` in `persistMarket()` to `INSERT OR IGNORE` combined with a separate `UPDATE` for mutable fields (`best_bid`, `best_ask`, `status`, `clob_token_ids`, `outcomes`, `accepting_orders`)
    - [ ] TASK-1.2.3 Add a test that inserts two markets with the same slug but different IDs and asserts both rows survive
    - [ ] TASK-1.2.4 Add a test that re-inserting an existing market ID updates its mutable fields without creating a duplicate row

- [ ] **TASK-1.3** Standardise market identifier usage across the pipeline
  - **Background**: The WebSocket `market` field carries the `condition_id`. `evaluateNewsSignals()` passes `condition_id` to `queryLastMid()` and then passes `market_id` (Gamma `id`) to `placeOrder()`. `resolveTokenId()` queries `WHERE condition_id=? OR id=?`, which is a silent fallback, not a deliberate design. This ambiguity must become explicit
  - **Subtasks**:
    - [ ] TASK-1.3.1 Add a `condition_id` index to the `orderbooks` table in `MIGRATION_006` (alongside TASK-1.2.1)
    - [ ] TASK-1.3.2 Update `wsPriceCallback()` in `main.zig` to store `update.market` (which is condition_id) in `orderbooks.market` **and** resolve the corresponding `markets.id` via a single `SELECT id FROM markets WHERE condition_id=?` lookup, storing the resolved Gamma `id` in a new `orderbooks.gamma_id` TEXT column (nullable, for cases where the market has not yet been scanned)
    - [ ] TASK-1.3.3 Update `evaluateNewsSignals()` to pass the resolved Gamma `market_id` (not `condition_id`) to both `queryLastMid()` and the signal's `market_id` field, so the downstream `placeOrder()` always receives a Gamma `id`
    - [ ] TASK-1.3.4 Remove the `OR id=?` fallback in `resolveTokenId()` once the above is confirmed correct, replacing it with an assertion log if lookup returns null
    - [ ] TASK-1.3.5 Update `evaluateLpSignals()` to retrieve `gamma_id` from `orderbooks` rather than using `market` (condition_id) as the identifier passed to `placeOrder()`
    - [ ] TASK-1.3.6 Add a test that verifies `resolveTokenId()` returns the correct token for a known market_id with no OR fallback

---

### Phase 2 — Fill detection and startup reconciliation

- [ ] **TASK-2.1** Implement CLOB order-status polling for fill detection
  - **Background**: `processFill()` in `portfolio_tracker.zig` is fully implemented but never called. Polymarket CLOB provides `GET /orders/{order_id}` which returns current status (`matched`, `delayed`, `live`, `open`, `canceled`) and a `fills` array
  - **Subtasks**:
    - [ ] TASK-2.1.1 Add a new `MIGRATION_007` that adds `filled_size TEXT DEFAULT '0'`, `average_fill_price TEXT DEFAULT NULL`, and `last_checked_at INTEGER DEFAULT 0` columns to the `orders` table
    - [ ] TASK-2.1.2 Implement `checkOrderFills(order_id: []const u8, allocator: std.mem.Allocator) !FillCheckResult` in a new file `zig/src/fill_poller.zig`. The function calls `GET /clob.polymarket.com/orders/{order_id}` with L2 HMAC auth headers, parses the response, and returns a struct containing current status and any new fills since `last_checked_at`
    - [ ] TASK-2.1.3 Implement `FillPoller` struct in `fill_poller.zig` with a `runFillCheck(database: *db.DB, om: *OrderManager, pt: *PortfolioTracker) void` method that: (a) queries all orders in `placed` or `partially_filled` state from DB; (b) calls `checkOrderFills()` for each; (c) for each new fill, calls `pt.processFill()` and `database.updateOrderStatus()`; (d) updates `last_checked_at` on the order row; (e) publishes `event.order.filled` or `event.order.partially_filled` IPC events
    - [ ] TASK-2.1.4 Poll interval: check any order not checked within the last 3 seconds, with a maximum of 20 concurrent in-flight HTTP calls. Use a fixed 3-second ticker thread spawned in `main.zig` alongside the existing `staleOrderTicker`
    - [ ] TASK-2.1.5 When `checkOrderFills()` returns status `canceled` or `matched` (fully filled) and the local DB still shows `placed`, reconcile the DB status to match the CLOB
    - [ ] TASK-2.1.6 Wire `processFill()` calls through the fill poller so portfolio tracker in-memory state and DB are both updated atomically within the same scope
    - [ ] TASK-2.1.7 Add unit tests for `checkOrderFills()` using mock HTTP responses for each possible CLOB order status
    - [ ] TASK-2.1.8 Add an integration test that inserts a `placed` order, simulates a fill response, and verifies `positions` table is updated and `event.order.filled` is published

- [ ] **TASK-2.2** Implement startup account reconciliation
  - **Background**: After a crash or restart, SQLite may contain orders the CLOB has already filled or cancelled, and vice versa. The engine must not place new orders until it has a clean picture of existing state
  - **Subtasks**:
    - [ ] TASK-2.2.1 Add `reconcileOnStartup(allocator: std.mem.Allocator, database: *db.DB, om: *OrderManager, pt: *PortfolioTracker) !ReconcileResult` in `fill_poller.zig`. The function calls `GET /clob.polymarket.com/orders?maker_address=<signer>&status=open` (paginated) to fetch all open orders from the exchange
    - [ ] TASK-2.2.2 For each order returned by the CLOB that is absent from the local DB, insert it with status `placed` and `strategy_origin = 'reconciled'`
    - [ ] TASK-2.2.3 For each order in local DB with status `placed` or `partially_filled` that is absent from the CLOB open-orders response, call `checkOrderFills()` to determine final state (filled, cancelled, or expired) and update DB accordingly
    - [ ] TASK-2.2.4 Call `pt.syncFromDB()` after reconciliation completes so in-memory position state reflects the resolved picture
    - [ ] TASK-2.2.5 Introduce a `ReconcileGate` — an `std.atomic.Value(bool)` flag in the `OrderManager` named `reconciliation_complete` initialised to `false`. `placeOrder()` returns `.rejected = .{ .reason = "reconciliation_pending" }` until the flag is set to `true`. The flag is set by `reconcileOnStartup()` on success
    - [ ] TASK-2.2.6 Call `reconcileOnStartup()` in `main.zig` immediately after `portfolio.PortfolioTracker.init()` and before starting the strategy worker thread. The call is blocking; if it fails after 3 retries, log an error and set `reconciliation_complete = true` anyway (allow manual override to prevent a permanent lockout)
    - [ ] TASK-2.2.7 Emit a `log.info` summary: `"reconciliation complete: adopted={d} closed={d} unchanged={d}"` and publish a structured IPC log event for the Telegram bot to forward
    - [ ] TASK-2.2.8 Add a new IPC message type `reconcile.status` → `reconcile.status.response` that returns the last reconciliation result so the Telegram bot can query it via `/status`
    - [ ] TASK-2.2.9 Add tests for the three reconciliation cases: order absent from DB (adopt), order absent from CLOB (close), order present in both (no change)

- [ ] **TASK-2.3** Wire fill events through IPC to Telegram bot
  - **Subtasks**:
    - [ ] TASK-2.3.1 Ensure `fill_poller.zig` publishes `event.order.filled` and `event.order.partially_filled` via `ipc.publishEvent()` using the existing `ipc_types.T.event_order_filled` constant, with payload fields: `order_id`, `market_id`, `side`, `fill_size`, `fill_price`, `realized_pnl` (formatted to 2 dp)
    - [ ] TASK-2.3.2 Add a case for `event.order.partially_filled` in `formatEvent()` in `ts/src/telegram/bot.ts` that produces: `"⏳ Order Partially Filled\n• ID: <code>{id}</code>\n• Filled: {fill_size} @ {fill_price}\n• Remaining: {remaining_size}"`
    - [ ] TASK-2.3.3 Update the existing `event.order.filled` formatter in `formatEvent()` to include `realized_pnl` in the message body
    - [ ] TASK-2.3.4 Add TypeScript types for `event.order.partially_filled` payload to `ts/src/ipc/types.ts`

---

### Phase 3 — Strategy integrity

- [ ] **TASK-3.1** Replace Gamma `outcome_prices` with an independent probability source in the news-repricing strategy
  - **Background**: `updateFromGammaMarkets()` sets `probability` from Polymarket's own `outcome_prices` field, which is the CLOB's last-trade price, polled on a 10-minute lag. Comparing this stale price against the live CLOB mid produces noise, not signal. An independent source must be used
  - **Design decision required (Q-001)**: Which external probability source to integrate first? Options are listed in the open questions section. The tasks below assume a generic configurable HTTP polling source; the adapter pattern allows swapping providers
  - **Subtasks**:
    - [ ] TASK-3.1.1 Define a `ProbabilityProvider` interface in a new file `zig/src/probability_provider.zig`:

      ```zig
      pub const ExternalEstimate = struct {
          market_id: [64]u8,       // Gamma market id
          market_id_len: usize,
          condition_id: [128]u8,
          condition_id_len: usize,
          probability: f64,
          confidence: f64,
          source: []const u8,      // e.g. "metaculus", "manifold", "custom"
          fetched_at: i64,
      };

      pub const ProviderConfig = struct {
          endpoint_url: [512]u8,
          endpoint_url_len: usize,
          api_key: [128]u8,
          api_key_len: usize,
          poll_interval_seconds: u32,
          market_id_field: [64]u8,     // JSON field name containing market identifier
          probability_field: [64]u8,   // JSON field name containing probability
      };
      ```

    - [ ] TASK-3.1.2 Implement `ProbabilityPoller` struct in `probability_provider.zig` that: (a) reads `ProviderConfig` from `runtime_config` table keys `prob_source_url`, `prob_source_api_key`, `prob_source_poll_seconds`, `prob_source_market_id_field`, `prob_source_probability_field`; (b) calls the configured URL with optional Bearer token auth; (c) parses the response as a JSON array; (d) maps each element to an `ExternalEstimate` using the configured field names; (e) writes estimates into a ring buffer of `[256]?ExternalEstimate` behind a mutex
    - [ ] TASK-3.1.3 Remove `updateFromGammaMarkets()` call from `market_scanner.zig`; scanner no longer feeds the news client
    - [ ] TASK-3.1.4 Remove `NewsClient.updateFromGammaMarkets()` from `news_sources.zig`; retain `NewsClient` as a cache wrapper that is now fed by `ProbabilityPoller` instead
    - [ ] TASK-3.1.5 Spawn `ProbabilityPoller` as a new thread in `main.zig` between the scanner thread and the strategy worker thread. If `prob_source_url` is empty in `runtime_config`, log a warning and disable `news_repricing` strategy automatically, logging the reason
    - [ ] TASK-3.1.6 Update `evaluateNewsSignals()` in `main.zig` to read estimates from `ProbabilityPoller`'s ring buffer rather than `NewsClient.cached_estimates`
    - [ ] TASK-3.1.7 Add `ProviderConfig` loading and validation unit tests
    - [ ] TASK-3.1.8 Add an integration test that points `prob_source_url` at a local mock HTTP server serving a minimal JSON array and asserts that `ProbabilityPoller` populates estimates correctly
    - [ ] TASK-3.1.9 Document the expected JSON response schema in a new `docs/probability-source.md` file, including a worked example for Metaculus and Manifold Markets

- [ ] **TASK-3.2** Add LP inventory management and paired-leg cancel-on-fill
  - **Background**: The LP strategy posts paired bid/ask orders. When one side fills, the other must be cancelled immediately to avoid carrying unhedged inventory. Without this, a sequence of fills on one side accumulates a directional position that resolves to $0 or $1 at market expiry
  - **Subtasks**:
    - [ ] TASK-3.2.1 Add `MIGRATION_008` adding column `max_net_position_usd REAL DEFAULT 50.0` to `runtime_config` defaults and column `net_position_usd REAL DEFAULT 0.0` to the `positions` table
    - [ ] TASK-3.2.2 Add a per-market inventory tracker in `strategy_engine.zig`: a fixed-size map `market_net_position: [64]MarketInventory` where `MarketInventory = struct { market_id: [64]u8, net_shares: f64, cost_basis: f64 }`. Protected by `state_mu`
    - [ ] TASK-3.2.3 Before emitting any LP signal, `evaluateLiquidityProvision()` checks: if `abs(market_net_position.net_shares) * mid_price >= config.lp_max_position_usd` (read from `runtime_config`), return `LpResult{ .count = 0 }` and log the reason
    - [ ] TASK-3.2.4 After `trackOrder()` records a new LP order, call `linkPair()` immediately with the indices of the bid and ask orders placed in the same `evaluateLiquidityProvision()` call. Currently `linkPair()` exists but is never called from `dispatchSignal()`
    - [ ] TASK-3.2.5 In `strategyWorker()` in `main.zig`, after each successful fill event is received (via the fill poller IPC event or by querying `pt.getLastFill()`), call `se.findPairedOrder(filled_order_id)`. If a paired order is found, call `om.cancelOrder(paired_id)` and `se.untrackOrder(paired_id)`
    - [ ] TASK-3.2.6 When a fill is detected, update `market_net_position` in the strategy engine: for a buy fill, increment `net_shares`; for a sell fill, decrement. Call a new method `se.updateInventory(market_id, direction, fill_size)` from the strategy worker after receiving a fill event
    - [ ] TASK-3.2.7 Add a new IPC message type `inventory.snapshot` → `inventory.snapshot.response` that serialises the `market_net_position` array for the Telegram `/portfolio` command to display
    - [ ] TASK-3.2.8 Add unit tests: (a) inventory limit blocks LP signal; (b) fill on bid triggers cancel of linked ask; (c) `net_shares` correctly increments/decrements
    - [ ] TASK-3.2.9 Add a `MIGRATION_008` column `lp_pair_order_id TEXT DEFAULT NULL` on the `orders` table so paired order links survive an engine restart (currently they live only in `strategy_engine.zig` in-memory)

---

### Phase 4 — Hardening and test coverage

- [ ] **TASK-4.1** Reconciliation performance and timeout enforcement
  - **Subtasks**:
    - [ ] TASK-4.1.1 Confirm `GET /orders` supports pagination and implement a paginated fetch loop with a max of 25 pages (5,000 orders at 200 per page) with a hard timeout of 30 seconds total (NFR-01)
    - [ ] TASK-4.1.2 Add a benchmark test that runs reconciliation against a mock CLOB returning 500 orders and asserts completion within 30 seconds

- [ ] **TASK-4.2** Fill poller latency measurement
  - **Subtasks**:
    - [ ] TASK-4.2.1 Record `detected_at INTEGER` in `fills` table (add to `MIGRATION_007`) populated by `insertFill()` with `std.time.timestamp()`
    - [ ] TASK-4.2.2 Log `fill_latency_ms = detected_at * 1000 - filled_at_ms` per fill using `log.info` so operators can audit detection speed against NFR-02

- [ ] **TASK-4.3** Retry hardening for fill poller HTTP calls
  - **Subtasks**:
    - [ ] TASK-4.3.1 Reuse `backoffDelayMs()` from `order_manager.zig` in `fill_poller.zig` for all retry paths (NFR-03)
    - [ ] TASK-4.3.2 Add a circuit-breaker in `FillPoller` that pauses polling for 60 seconds if 5 consecutive HTTP calls to the fill-check endpoint fail

- [ ] **TASK-4.4** Runtime config validation for probability source
  - **Subtasks**:
    - [ ] TASK-4.4.1 Add a `/config validate` Telegram subcommand that calls a new IPC `config.validate` message and returns a per-key validation result (valid URL format, poll interval within 10–3600 seconds, field name non-empty)
    - [ ] TASK-4.4.2 Add `config.validate` and `config.validate.response` to `ipc_types.zig` type constants

- [ ] **TASK-4.5** Test coverage enforcement
  - **Subtasks**:
    - [ ] TASK-4.5.1 Add tests in `tests.zig` for every new function in `fill_poller.zig`, `probability_provider.zig` (see TASK-3.1.7, TASK-3.1.8, TASK-2.1.7, TASK-2.1.8)
    - [ ] TASK-4.5.2 Add tests for each new migration (TASK-1.2.3, TASK-1.2.4, TASK-2.1.1, TASK-3.2.9)
    - [ ] TASK-4.5.3 Run `zig build test` in CI and fail the build on any test failure

---

## User stories

- [ ] **PP-ITEM-1.1**
  - **ID**: US-001
  - **Title**: Order cancellation reaches the exchange
  - **Description**: As an operator, when I issue a halt or cancel command, I want all targeted orders to be cancelled on the Polymarket CLOB, so that open risk is actually removed from the market
  - **Acceptance criteria**:
    - AC-001.1: `cancelOnCLOB()` issues an HTTP `DELETE` request to `/order` (not `POST` to `/order/cancel`)
    - AC-001.2: The request body contains the order identifier under the field name required by the current Polymarket API spec
    - AC-001.3: A 200-series response from the CLOB is required before the DB is updated to `cancelled`
    - AC-001.4: A 4xx or 5xx response triggers the existing retry loop with exponential backoff
    - AC-001.5: After a successful `halt`, every order that was `placed` in the DB is also `cancelled` in the CLOB (verified by a subsequent `GET /orders?status=open` returning zero results for that signing address)
  - **Maps to**: FR-02, NFR-03

- [ ] **PP-ITEM-1.2**
  - **ID**: US-002
  - **Title**: Market registry survives slug collisions
  - **Description**: As a strategy developer, when the market scanner refreshes and finds two Polymarket markets with the same slug, I want both markets to be persisted with their distinct IDs, so that no orders or positions are silently deleted due to a unique-constraint conflict
  - **Acceptance criteria**:
    - AC-002.1: The `markets.symbol` column does not have a `UNIQUE` constraint after migration
    - AC-002.2: Inserting two markets with the same slug but different IDs results in two rows in the `markets` table
    - AC-002.3: Re-inserting a market with an existing ID updates `best_bid`, `best_ask`, `status`, and `clob_token_ids` without creating a duplicate row
    - AC-002.4: No existing `orders` or `positions` rows are deleted as a side effect of a market scanner refresh
  - **Maps to**: FR-05

- [ ] **PP-ITEM-1.3**
  - **ID**: US-003
  - **Title**: Market identifier is consistent across all pipeline stages
  - **Description**: As a strategy developer, I want every component (scanner, WebSocket callback, strategy evaluator, order manager) to use the same market identifier (Gamma `id`) when referring to a market, so that token ID resolution, position tracking, and order placement always target the correct CLOB market
  - **Acceptance criteria**:
    - AC-003.1: `orderbooks` rows store both `market` (condition_id, as received from WS) and a resolved `gamma_id` (Gamma market `id`)
    - AC-003.2: `evaluateNewsSignals()` passes the resolved Gamma `id` (not condition_id) to both `queryLastMid()` and to the signal's `market_id` field
    - AC-003.3: `evaluateLpSignals()` passes the resolved Gamma `id` to `placeOrder()`
    - AC-003.4: `resolveTokenId()` in `order_manager.zig` succeeds on the first query branch (`condition_id = ?`) without falling back to the `OR id = ?` clause for any market that has been scanned
    - AC-003.5: If `gamma_id` cannot be resolved for a new WS event, the callback logs a `WARN` and does not insert an `orderbooks` row with a null gamma_id being used as a market identifier downstream
  - **Maps to**: FR-06

- [ ] **PP-ITEM-2.1**
  - **ID**: US-004
  - **Title**: Engine detects fills and updates positions in real time
  - **Description**: As an operator, I want the engine to detect when my orders have been filled on Polymarket, so that the position table, realised PnL, and dashboard reflect the actual account state within 5 seconds of a fill occurring
  - **Acceptance criteria**:
    - AC-004.1: A polling loop checks fill status for all `placed` and `partially_filled` orders at most every 3 seconds
    - AC-004.2: When a fill is detected, `processFill()` is called with correct `order_id`, `fill_size`, `fill_price`, and `is_maker` values
    - AC-004.3: The `positions` table is updated within 5 seconds of the fill being confirmed by the CLOB REST API
    - AC-004.4: `realized_pnl_today` in the portfolio tracker reflects the fill's P&L after `processFill()` completes
    - AC-004.5: An `event.order.filled` or `event.order.partially_filled` IPC event is published for each detected fill
    - AC-004.6: The Telegram bot receives and formats a fill notification message within 10 seconds of the fill
  - **Maps to**: FR-01, FR-08, NFR-02

- [ ] **PP-ITEM-2.2**
  - **ID**: US-005
  - **Title**: Engine reconciles state with the CLOB on startup
  - **Description**: As an operator, I want the engine to sync its local order and position state with Polymarket's ledger before placing any new orders after a restart, so that stale or phantom state from a previous session does not cause duplicate positions or missed fills
  - **Acceptance criteria**:
    - AC-005.1: `placeOrder()` returns `rejected` with reason `"reconciliation_pending"` until reconciliation completes
    - AC-005.2: Orders present on the CLOB but absent from the local DB are inserted with status `placed` and `strategy_origin = 'reconciled'`
    - AC-005.3: Orders present in local DB as `placed` or `partially_filled` but absent from the CLOB's open-orders response are resolved to their final status (`filled` or `cancelled`) via a targeted `GET /orders/{id}` call
    - AC-005.4: `pt.syncFromDB()` is called after all reconciliation writes complete
    - AC-005.5: Reconciliation completes within 30 seconds for an account with ≤ 500 open orders
    - AC-005.6: If reconciliation fails after 3 retries, `reconciliation_complete` is set to `true` with a `WARN` log, allowing the engine to proceed rather than being permanently locked
    - AC-005.7: A Telegram notification is sent on reconciliation completion summarising adopted, closed, and unchanged order counts
  - **Maps to**: FR-03, NFR-01

- [ ] **PP-ITEM-3.1**
  - **ID**: US-006
  - **Title**: News-repricing strategy uses an independent probability source
  - **Description**: As a strategy developer, I want the news-repricing strategy to compare CLOB prices against probabilities from a source independent of Polymarket, so that signals reflect genuine information asymmetry rather than polling-lag artefacts
  - **Acceptance criteria**:
    - AC-006.1: `ProbabilityPoller` fetches estimates from a URL stored in `runtime_config` under key `prob_source_url`
    - AC-006.2: `evaluateNewsSignals()` uses `ExternalEstimate.probability` from `ProbabilityPoller`, not from `gamma_market.outcome_prices`
    - AC-006.3: When `prob_source_url` is empty, the `news_repricing` strategy is automatically disabled and a `WARN` log explains why
    - AC-006.4: The source URL, API key, poll interval, and JSON field mappings are all changeable at runtime via `/config set` without restarting the engine
    - AC-006.5: A new poll is triggered at most every `prob_source_poll_seconds` seconds (minimum 10, maximum 3600), enforced with validation
    - AC-006.6: `ProbabilityPoller` does not call `updateFromGammaMarkets()` and does not depend on the market scanner cycle
  - **Maps to**: FR-04, NFR-04

- [ ] **PP-ITEM-3.2**
  - **ID**: US-007
  - **Title**: LP strategy cancels the unpaired leg when one side fills
  - **Description**: As an operator, I want the liquidity-provision strategy to cancel the open leg of a pair immediately when the other leg is filled, so that the engine does not accumulate unhedged directional inventory in a binary market
  - **Acceptance criteria**:
    - AC-007.1: Every LP signal pair is linked via `linkPair()` immediately after both orders are tracked
    - AC-007.2: When a fill event is detected for an LP order, `findPairedOrder()` is called and the result, if non-null, is passed to `om.cancelOrder()`
    - AC-007.3: The cancel is attempted on the CLOB via `DELETE /order` before the paired order is untracked
    - AC-007.4: If the cancel fails, the failure is logged and retried on the next fill-poller tick rather than being silently ignored
    - AC-007.5: The engine refuses to emit a new LP signal for a market where `abs(net_shares) * mid_price >= lp_max_position_usd` (configurable via `runtime_config`)
    - AC-007.6: Paired order links survive an engine restart via the `lp_pair_order_id` column on the `orders` table
  - **Maps to**: FR-07

- [ ] **PP-ITEM-3.3**
  - **ID**: US-008
  - **Title**: Operator receives real-time fill notifications via Telegram
  - **Description**: As an operator, I want to receive a Telegram message within 10 seconds of any order filling, so that I can monitor strategy activity and take manual action if needed without watching the dashboard
  - **Acceptance criteria**:
    - AC-008.1: Full fills produce a message containing order ID, market (truncated to 40 chars), side, fill size, fill price, and realised PnL
    - AC-008.2: Partial fills produce a distinct message format that includes remaining size
    - AC-008.3: Fill messages are deduplicated using the existing `dedup()` mechanism in `bot.ts` so reconnects do not cause duplicate notifications
    - AC-008.4: The Telegram message is sent to all `TELEGRAM_ALLOWED_CHAT_IDS` within 10 seconds of the fill being detected by the fill poller
  - **Maps to**: FR-08

---

## Traceability matrix

| Functional Req | User Story | Key Acceptance Criteria |
|---|---|---|
| FR-01 Fill detection | US-004 | AC-004.1 – AC-004.6 |
| FR-02 Cancel HTTP method | US-001 | AC-001.1 – AC-001.5 |
| FR-03 Startup reconciliation | US-005 | AC-005.1 – AC-005.7 |
| FR-04 Independent probability source | US-006 | AC-006.1 – AC-006.6 |
| FR-05 Slug collision fix | US-002 | AC-002.1 – AC-002.4 |
| FR-06 Identifier consistency | US-003 | AC-003.1 – AC-003.5 |
| FR-07 LP inventory management | US-007 | AC-007.1 – AC-007.6 |
| FR-08 Fill IPC events + Telegram | US-008 | AC-008.1 – AC-008.4 |
| NFR-01 Reconciliation ≤ 30s | US-005 | AC-005.5 |
| NFR-02 Fill latency ≤ 5s | US-004 | AC-004.3 |
| NFR-03 Cancel retry with backoff | US-001 | AC-001.4 |
| NFR-04 Configurable prob source | US-006 | AC-006.4 |
| NFR-05 Migration pattern | All DB tasks | TASK-1.2.1, TASK-2.1.1, TASK-3.2.1 |
| NFR-06 Test coverage | All tasks | TASK-4.5.1 – TASK-4.5.3 |

---

## Open questions

- [x] **Q-001**: Which external probability source should be integrated first for the news-repricing strategy?
  - **Options**: Kalshi Websocket API — regulated US market, directly comparable binary contracts, requires account [https://docs.kalshi.com/getting_started/quick_start_websockets]
  - **Decision needed**: Must be made before TASK-3.1.2 can be fully specified
  - **Owner**: Operator / strategy developer
  - **Default if no decision**: Implement Option C (generic configurable HTTP endpoint) so any source can be plugged in via config without a code change, as described in TASK-3.1.1

- [x] **Q-002**: Should the fill poller use WebSocket user-stream events (if Polymarket exposes them) instead of REST polling?
  - **Context**: REST polling at 3-second intervals produces ~20 HTTP calls/minute per open order. Polymarket's WebSocket API documentation should be checked for a user-stream channel that pushes fill events
  - **Decision needed**: Before TASK-2.1.4 is implemented; Prioritize websocket user-stream if a user-stream is available, TASK-2.1 changes significantly
  - **Owner**: Developer

- [x] **Q-003**: What is the correct current Polymarket CLOB cancel API method and payload format?
  - **Context**: The analysis assumed `DELETE /order` with body `{"orderID": "<id>"}`. The official docs should be verified at the time of implementation as Polymarket has changed their API spec previously
  - **Decision needed**: Before TASK-1.1 is merged. From the docs:
  Cancel a single order

  ```curl
  curl -X DELETE "https://clob.polymarket.com/order" \
  -H "Content-Type: application/json" \
  -H "POLY_ADDRESS: ..." \
  -H "POLY_SIGNATURE: ..." \
  -H "POLY_TIMESTAMP: ..." \
  -H "POLY_API_KEY: ..." \
  -H "POLY_PASSPHRASE: ..." \
  -d '{"orderID": "0xb816482a..."}'
  ```

  cancel multiple orders
  
  ```curl
  curl -X DELETE "https://clob.polymarket.com/orders" \
  -H "Content-Type: application/json" \
  -H "POLY_ADDRESS: ..." \
  -H "POLY_SIGNATURE: ..." \
  -H "POLY_TIMESTAMP: ..." \
  -H "POLY_API_KEY: ..." \
  -H "POLY_PASSPHRASE: ..." \
  -d '["0xb816482a...", "0xc927593b..."]'
  ```

  - **Owner**: Developer (verify against <https://docs.polymarket.com>)

- [x] **Q-004**: Should the `lp_max_position_usd` limit be per-market or global across all LP markets?
  - **Context**: A global limit is simpler to implement and prevents total LP exposure from growing unbounded. A per-market limit is more granular
  - **Decision needed**: Before TASK-3.2.3
  - **Owner**: Strategy developer
  - **Default**: Per-market, implemented as `abs(net_shares * mid_price) >= lp_max_position_usd` checked inside `evaluateLiquidityProvision()`
