# Phase 4 Implementation Plan: Order Placement & Cancellation

## Discovery Summary

### Already Implemented (Phases 1-3 Dependencies)
- ✅ `msgpack.zig` — MsgPack encoder for HL order signing
- ✅ `hl_auth.zig` — HL EIP-712 signing, domain separator, address derivation
- ✅ `hl_market_meta.zig` — Asset index fetch and in-memory lookup
- ✅ `hl_orderbook.zig` — l2Book WebSocket handler
- ✅ `binance_ws.zig` — Binance Futures BBO feed

### Current State of `order_manager.zig`

**Live/test mode functions (mostly complete):**
- `placeOrder()` — Places orders, passes risk gate, persists to DB
- `cancelOrder()` — Cancels individual orders by ID
- `cancelAll()` — Cancels all open orders
- `halt()` — Halts engine and cancels all
- `resume()` — Resumes from halt
- `buildOrderAction()` — Builds HL order JSON structure
- `buildCancelAction()` — Builds HL cancel JSON structure
- `submitToHL()` — Posts to `/exchange` with 7-retry exponential backoff (1s base, 60s cap)
- `cancelOnHL()` — Posts cancel action with retry logic
- `buildHlEnvelope()` — Wraps action in signed envelope {action, nonce, signature}

**Missing: Dry-run layer**
- No `DRY_RUN` flag check at top of `placeOrder()` or `cancelOrder()`
- No interception logic that writes to `dry_run_orders` when in dry-run mode
- No simulated latency injection
- No synthetic order ID generation for dry-run orders

### Database State
- ✅ `dry_run_orders` table exists in migrations
- ✅ Schema includes columns for dry-run tracking
- Missing: Columns `funding_charge REAL`, `simulated_slippage REAL` (needed for Phase 8 completion)

### IPC/Environment
- ✅ `.env.example` has `DRY_RUN=1`, `DRY_RUN_INITIAL_BALANCE=10.0`
- ❓ Unclear: How `DRY_RUN` flag is loaded into the `OrderManager` config
- ❓ Unclear: Whether dry-run mode affects cancel path as well

---

## Phase 4 Scope & Acceptance Criteria

**Phase 4 Requirements (from migrate.md):**
- **TASK-4.1**: Implement HL order manager (signing, placement, cancellation, retry)
  - Order placement → POST `/exchange` with msgpack + EIP-712
  - Order cancellation → POST `/exchange` with cancel action
  - Retry logic: 7 attempts, 1s base, 60s cap, backoff on 429/5xx
  - Persist order ID and track `order_submit_ts`

- **TASK-4.2**: Dry-run interception layer
  - Check `DRY_RUN` flag at top of `placeOrder()` and `cancelOrder()`
  - If dry-run: write to `dry_run_orders`, skip API call, return synthetic order ID
  - Simulate latency: uniform random 8–25 ms
  - Share risk gate with live path (no separate validation)

**User Stories:**
- **US-008**: Limit order placement on HL (AC-008-1 to AC-008-5)
  - Payload includes asset_index, is_buy, limit_px, sz, reduce_only, order_type.limit.tif
  - Order ID persisted with status "placed"
  - Retries on 429
  - Latency logged per order
  
- **US-009**: Order cancellation (AC-009-1 to AC-009-4)
  - Cancel action via `/exchange`, marked in local DB as "cancelled"
  - If already filled, update local DB to "filled" without error
  - Cancel-all within 5 seconds

---

## Implementation Plan

### Phase 4.1: DRY-RUN CONFIGURATION & LOADING

**Objective:** Make `DRY_RUN` flag accessible to `OrderManager` at runtime.

**Steps:**

1. **Update `OrderManagerConfig`** (zig/src/order_manager.zig)
   - Add field: `dry_run_enabled: bool = false`
   - Add field: `dry_run_initial_balance: f64 = 10.0` (for simulation)
   - Add field: `dry_run_latency_min_ms: u64 = 8`
   - Add field: `dry_run_latency_max_ms: u64 = 25`
   - Document: "Set by engine startup when loading DRY_RUN env var"

2. **Update `main.zig`** to load and pass `DRY_RUN` flag
   - Read `DRY_RUN` env var (0 or 1, default: 1 for testnet safety)
   - Read `DRY_RUN_INITIAL_BALANCE` env var (float, default: 10.0)
   - Pass both to `OrderManagerConfig` during initialization
   - Log: `"DRY_RUN mode: {s}, initial balance: {d}"` on startup

3. **Verify integration** (ts/src/index.ts or relevant startup)
   - Confirm env vars flow through to Zig config
   - Test: set `DRY_RUN=0` and confirm orders attempt HL submission

---

### Phase 4.2: DRY-RUN ORDER INTERCEPTION

**Objective:** Intercept order placements in dry-run mode and write to `dry_run_orders`.

**Steps:**

1. **Implement dry-run placement in `placeOrder()`**
   - **Location:** After risk gate validation, before `database.insertOrder()`
   - **Logic:**
     ```zig
     if (self.config.dry_run_enabled) {
       // Generate synthetic order ID (e.g., "dry-<nonce>-<random>")
       // Inject simulated latency: uniform(dry_run_latency_min_ms, dry_run_latency_max_ms)
       // Write to dry_run_orders table with status='open'
       // Return success with synthetic order ID
       // Do NOT call submitToHL()
       // Log: "dry-run order placed: {market_id} {side} {size}@{price}"
     } else {
       // Existing live path
     }
     ```

   - **DB Write:** `DB.insertDryRunOrder(market_id, side, size, price, order_type, strategy_origin)`
     - Returns synthetic `order_id` for consistency with live path
     - Columns: `id`, `market_id`, `side`, `size`, `price`, `order_type`, `strategy_origin`, `status='open'`, `created_at`, `simulated_latency_ms`

   - **Acceptance Criteria:**
     - AC-016-1: When `DRY_RUN=1`, no POST requests to `/exchange`
     - AC-016-2: Simulated orders written to `dry_run_orders` with `status='open'`
     - AC-016-4: Simulated latency of `uniform(8ms, 25ms)` applied before checking fill eligibility
     - **Verification:** Set `DRY_RUN=1`; place order; confirm no HTTP calls; check `dry_run_orders` table has new row

2. **Implement dry-run cancellation in `cancelOrder()`**
   - **Location:** At the start of `cancelOrder()`, check dry-run mode
   - **Logic:**
     ```zig
     if (self.config.dry_run_enabled) {
       // Query dry_run_orders for order_id
       // If status='open', update to 'cancelled'
       // Publish event.order.cancelled IPC event
       // Return true
       // Do NOT call cancelOnHL()
     } else {
       // Existing live path
     }
     ```

   - **Acceptance Criteria:**
     - AC-016-3: Dry-run cancel updates `dry_run_orders.status = 'cancelled'` only; no API call
     - **Verification:** Place dry-run order; cancel it; confirm status='cancelled' in DB

3. **Ensure shared risk gate**
   - **Verify:** Risk gate validation in `placeOrder()` runs **before** dry-run branch
   - Risk gate rejects orders based on notional exposure, margin limits, inventory skew
   - Same validation applies to both dry-run and live orders
   - **Acceptance Criteria:**
     - AC-016-4: Ensure dry-run and live code paths share the same risk gate and signal pipeline
     - **Verification:** Place dry-run order that violates risk gate; confirm rejection with same reason as live

---

### Phase 4.3: LATENCY INSTRUMENTATION

**Objective:** Log `order_submit_ts` for every order to enable p99 latency tracking.

**Steps:**

1. **Add timestamp tracking to `placeOrder()`**
   - Record `submit_ts_ns: i128 = std.time.nanoTimestamp()` at the start of order placement
   - For live orders: capture `ack_ts_ns` when HL API responds (in `submitToHL()`)
   - For dry-run orders: `ack_ts_ns ≈ submit_ts_ns + simulated_latency_ms`
   - Persist both to `orders` table via new column `order_submit_ts_ns`

2. **Store in DB**
   - Add column to `orders` table: `order_submit_ts_ns INTEGER DEFAULT 0`
   - Add column: `order_ack_ts_ns INTEGER DEFAULT 0`
   - Migration required (Phase 7)

3. **Expose for IPC telemetry**
   - IPC handler `/orders` includes `submit_latency_ms` per order
   - Calculated as: `(ack_ts_ns − submit_ts_ns) / 1_000_000`

   - **Acceptance Criteria:**
     - AC-008-5: Order submission latency (signal-to-API-ack) is logged per order for p99 tracking
     - **Verification:** Place order; check logs and IPC response for `submit_latency_ms` field

---

### Phase 4.4: DRY-RUN BALANCE MANAGEMENT

**Objective:** Track simulated USDC balance across dry-run orders.

**Steps:**

1. **Initialize dry-run balance**
   - On engine startup (in `main.zig`):
     - If `DRY_RUN=1`, insert into `balance_snapshots` a row with `balance = DRY_RUN_INITIAL_BALANCE`
     - Query this balance when evaluating new orders

2. **Update balance on simulated fills** (Phase 5, but note dependency here)
   - When `fill_poller.zig` (Phase 5) settles a dry-run fill:
     - Deduct taker fee (3.5 bps) from notional
     - Update `balance_snapshots` with new balance
   - Dry-run orders **do not settle immediately**; they're settled every 30 seconds by the fill poller

3. **Dry-run risk gate integration**
   - Risk gate checks `balance_snapshots.balance` for available notional
   - Dry-run orders must not exceed `balance × max_leverage_pct`

   - **Acceptance Criteria:**
     - AC-016-7: The simulated USDC balance starts at `DRY_RUN_INITIAL_BALANCE` and is updated after each settled fill

---

### Phase 4.5: TESTING & VALIDATION

**Objective:** Ensure Phase 4 functions work correctly before Phase 5.

**Steps:**

1. **Unit tests in `zig/src/tests.zig`**
   - Test dry-run placement: confirm order written to `dry_run_orders`, not called submitToHL
   - Test dry-run cancellation: confirm status updated, not called cancelOnHL
   - Test latency injection: confirm `simulated_latency_ms` is in range [8, 25]
   - Test shared risk gate: same rejection reason for dry-run and live paths
   - Test order ID generation: synthetic IDs differ from live IDs (e.g., "dry-" prefix)

2. **Integration test (local testnet)**
   - Set `DRY_RUN=1`, `HL_NETWORK=testnet`
   - Place a test order; verify:
     - No HTTP call to HL API (use network sniffer or mock)
     - Row in `dry_run_orders` table
     - Event `event.order.placed` published via IPC
   - Place another order; cancel the first; verify:
     - First order status → 'cancelled'
     - Event `event.order.cancelled` published

3. **Latency benchmarking**
   - Measure time to insert 100 dry-run orders
   - Confirm DB insert < 1 ms per order (latency simulation is application-level, not DB)

   - **Acceptance Criteria (from migrate.md)**
     - AC-003-4 (msgpack encode): < 5 µs (already tested in Phase 2)
     - AC-016-1 to AC-016-7: All dry-run ACs pass
     - **Verification:** Run `zig build test` to 100% pass; manual EC2 integration test

---

## Relevant Files to Modify

| File | Changes |
|------|---------|
| [zig/src/order_manager.zig](zig/src/order_manager.zig) | Add `dry_run_enabled`, `dry_run_initial_balance`, latency config fields; implement dry-run branches in `placeOrder()` and `cancelOrder()` |
| [zig/src/db.zig](zig/src/db.zig) | Add `insertDryRunOrder()`, `updateDryRunOrderStatus()` helper methods |
| [zig/src/main.zig](zig/src/main.zig) | Load `DRY_RUN` and `DRY_RUN_INITIAL_BALANCE` env vars; pass to `OrderManagerConfig` |
| [zig/src/tests.zig](zig/src/tests.zig) | Add dry-run unit tests (latency injection, DB writes, risk gate shared path) |
| (Phase 7) `db/migrations/015_phase4_dryrun.sql` | Add `order_submit_ts_ns`, `order_ack_ts_ns` columns to `orders`; add `simulated_latency_ms` to `dry_run_orders` |

---

## Verification Checklist

- [ ] Unit tests pass: `zig build test` (100% dry-run tests)
- [ ] DRY_RUN env var loads correctly on startup
- [ ] Dry-run order placed: no HL API call, row in `dry_run_orders` table
- [ ] Dry-run order cancelled: status updated to 'cancelled'
- [ ] Risk gate shared: same rejection reasons for dry-run and live paths
- [ ] Latency logged: `order_submit_ts_ns`, `order_ack_ts_ns` persisted in DB
- [ ] Local integration test: set `DRY_RUN=1` on testnet; place 10 orders; confirm all in `dry_run_orders` with no HTTP calls

---

## Dependencies & Blockers

- ✅ Phase 1, 2, 3 (signing, market data) already implemented
- ⏳ Phase 5 (fill_poller) depends on dry-run balance updates, but dry-run **placement** is independent
- ⏳ Phase 7 (migrations) needed for `order_submit_ts_ns` column (nice-to-have; IPC telemetry works with log-only until then)
- ⏳ Phase 9 (testing) will validate dry-run in context of full strategy engine

---

## Estimated Effort

- **Dry-run config & loading:** 30 min (add fields, load env vars)
- **Dry-run interception:** 1 h (implement branches, test logic)
- **DB helpers:** 30 min (`insertDryRunOrder`, update methods)
- **Unit tests:** 1 h (5–6 test cases, fixtures)
- **Integration test & debugging:** 1 h
- **Total:** 4–4.5 hours solo

---

## Success Metrics (Phase 4 Gates)

1. **Dry-run orders placed successfully** with no HL API calls
2. **Shared risk gate** rejects same orders for both dry-run and live paths
3. **Latency telemetry** logged and persisted per order
4. **Unit test pass rate:** 100% (all 5–6 dry-run tests pass)
5. **Integration test on testnet:** 10 dry-run orders placed; 5 cancelled; all statuses correct in DB
