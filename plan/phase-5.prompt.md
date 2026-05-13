# Phase 5 Implementation Plan — Fill Detection & Portfolio Tracking

## TL;DR

Phase 5 implements real-time fill detection via Hyperliquid user WebSocket and portfolio equity tracking via the `clearinghouseState` API. Two new Zig modules (`hl_fill_poller.zig`, `hl_portfolio_tracker.zig`) replace the Polymarket-specific stubs, database schema is extended for HL margin semantics and arb telemetry, and IPC message types are updated to expose equity/margin/funding fields instead of USDC balance. Dry-run mode simulates fills every 30s against live l2Book snapshots.

## Phase 5 Scope

**What Phase 5 delivers:**
- HL user WebSocket fill detection (real-time + fallback REST polling)
- HL `clearinghouseState` API for equity/margin tracking
- Dry-run fill simulation layer
- Database schema updates for positions/orders/funding/arb telemetry
- IPC updates to expose HL margin semantics
- Unit tests for fill parsing and portfolio snapshots

**What Phase 5 does NOT include:**
- Arb strategy implementation (Phase 6)
- Risk gate margin rewrite (Phase 6)
- Telegram/dashboard UI updates (Phase 8)
- Live mainnet launch (Phase 7+)

## Dependencies

**Must be complete before Phase 5 starts:**
- Phase 2: `msgpack.zig`, `hl_auth.zig` ✅
- Phase 3: `hl_market_meta.zig`, `hl_orderbook.zig`, `binance_ws.zig` ✅
- Phase 4: `hl_order_manager.zig`, dry-run interception ✅

**Blocks the following:**
- Phase 6 (risk gate margin rewrite, arb strategy) — depends on accurate equity snapshots from Phase 5
- Phase 8 (dashboard) — depends on HL-aware IPC payloads
- Phase 9 (dry-run validation) — depends on functional fill detection

## Implementation Steps

### 1. Database Schema Updates (TASK-5.0)

**Create migration 013 — HL portfolio and fill fields.**

Migrations needed (order-dependent, run sequentially):

1. Add HL fields to `positions` table:
   - `mark_price REAL DEFAULT 0.0` — latest mark price from HL
   - `funding_accrued REAL DEFAULT 0.0` — cumulative funding charge
   - `leverage INTEGER DEFAULT 1` — position leverage setting
   - `funding_index REAL DEFAULT 0.0` — snapshot of cumulative funding index at entry

2. Add HL fields to `orders` table:
   - `asset_index INTEGER DEFAULT -1` — HL universe asset index
   - `reduce_only INTEGER DEFAULT 0` — flag for reduce-only orders

3. Create `funding_snapshots` table:
   ```sql
   CREATE TABLE funding_snapshots (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     asset TEXT NOT NULL,
     rate REAL NOT NULL,
     next_payment_ts INTEGER NOT NULL,
     recorded_at INTEGER NOT NULL DEFAULT (unixepoch())
   );
   CREATE INDEX idx_funding_snapshots_asset_ts ON funding_snapshots(asset, recorded_at DESC);
   ```

4. Create `arb_events` table (for Phase 6, but migrate in Phase 5 to avoid two migration runs):
   ```sql
   CREATE TABLE arb_events (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     asset TEXT NOT NULL,
     binance_mid REAL NOT NULL,
     hl_mid REAL NOT NULL,
     delta_bps REAL NOT NULL,
     order_id TEXT,
     realised_pnl REAL,
     submit_ns INTEGER,
     fill_ns INTEGER,
     created_at INTEGER NOT NULL DEFAULT (unixepoch())
   );
   CREATE INDEX idx_arb_events_asset_ts ON arb_events(asset, created_at DESC);
   ```

5. Add columns to `dry_run_orders` table:
   - `funding_charge REAL DEFAULT 0.0` — simulated funding charged
   - `simulated_slippage REAL DEFAULT 0.0` — fill price deviation from mid

**Acceptance:** `zig build test` passes all migration tests; schema introspection confirms all columns present.

---

### 2. HL Fill Poller (TASK-5.1)

**Create `zig/src/hl_fill_poller.zig`**

Responsibilities:
- HL user WebSocket subscription (real-time fills)
- REST polling fallback (query `/info` openOrders endpoint)
- Dry-run fill simulation (every 30s)
- Fill event parsing and database persistence

**Implementation details:**

1. **User WebSocket connection:**
   - Connect to `wss://api.hyperliquid[-testnet].xyz/ws`
   - Send subscription: `{"method":"subscribe","subscription":{"type":"user","user":"<API_WALLET>","signature":{"r":"...","s":"...","v":...}}}`
   - Parse incoming fill events: `{"channel":"user","data":{"fills":[...]}}`

2. **Fill event structure parsing:**
   - Extract from each fill: `oid` (order ID), `sz` (filled size), `px` (fill price), `side` (buy/sell), `time` (timestamp in ms)
   - Update `orders` table: set status to `filled` or `partially_filled`, increment `filled_size`
   - Insert row in `fills` table with fill price and size
   - Emit IPC event: `event.order.filled` with order ID and fill details
   - Emit Telegram push: `✅ Order Filled — <size> @ <price>`

3. **Latency tracking:**
   - Store `fill_ts = nanoseconds()` in `fills` table
   - Compute `latency_ms = fill_ts − order_submit_ts` per fill
   - Log p99 latency metric (output to logger, not a DB query yet)

4. **REST polling fallback (if WS down > 5s):**
   - Query `POST /info` with `{"type":"openOrders","user":"<WALLET>"}` every 5s
   - Compare returned order list with local open orders
   - Detect new fills by comparing `filled_size` in response vs. local DB
   - Apply same fill processing logic as WebSocket

5. **Dry-run fill simulation:**
   - Every 30s, scan `dry_run_orders` where `status='open'`
   - For each open dry-run order:
     - Check if current `l2Book` mid-price has crossed the order price (bid for buys, ask for sells)
     - Apply simulated latency (uniform 8ms–25ms)
     - If filled: mark as filled, deduct taker fee (3.5 bps), update simulated balance
   - Emit synthetic `event.order.filled` event (same as live)

6. **Public interface:**
   ```zig
   pub fn init(allocator, hl_auth, database) !*FillPoller
   pub fn deinit(self)
   pub fn startWsConnection() !void
   pub fn startPollingLoop() !void
   pub fn startDryRunSimulation() !void (if DRY_RUN enabled)
   pub fn waitForFill(order_id, timeout_ms) !FillResult
   ```

**Unit tests:**
- Parse fixture fill event JSON → verify DB insert
- Handle partial fill → verify status is `partially_filled`, filled_size increments
- Latency computation: fill_ts − submit_ts yields reasonable milliseconds
- Dry-run fill simulation: order crosses mid-price → marked filled with correct fee deduction
- Fallback polling: REST response parsed and fills detected

**Acceptance:** 
- Unit tests pass (100% path coverage for fill parsing, latency, and dry-run simulation)
- Manual integration test: place a testnet order, trigger fill on HL, confirm IPC event received within 500ms

---

### 3. HL Portfolio Tracker (TASK-5.2)

**Create `zig/src/hl_portfolio_tracker.zig`**

Responsibilities:
- Poll HL `clearinghouseState` API every 60s
- Parse equity, margin, open positions
- Maintain in-memory portfolio snapshot
- Provide IPC handlers with current state
- Emit portfolio change events

**Implementation details:**

1. **Equity polling:**
   - Query `POST /info {"type":"clearinghouseState","user":"<MAIN_WALLET>"}` every 60s (configurable via `PORTFOLIO_POLL_INTERVAL_SEC`)
   - Parse response: `clearinghouseState.marginSummary.accountValue` (total equity)
   - Parse response: `clearinghouseState.marginSummary.totalMarginUsed` (margin consumed)
   - Persist to `balance_snapshots` table with columns: `equity`, `margin_used`, `recorded_at`
   - If query fails: retry up to 3× with 2s backoff; if all fail, emit `event.portfolio.stale` and pause strategy

2. **Position parsing:**
   - From `clearinghouseState.assetPositions[]`, extract each position:
     - `coin` (asset), `szi` (signed size, negative=short), `entry_px` (entry price), `unrealPnl` (unrealised P&L)
   - Query HL for current `mark_price` of each asset (from latest l2Book or deduce from mid-price)
   - Update `positions` table:
     - `size = abs(szi)`, `side = szi > 0 ? 'long' : 'short'`
     - `entry_price = entry_px`
     - `current_price = mark_price` (from orderbook)
     - `unrealized_pnl = unrealPnl`
   - Detect new positions: compare asset set in response vs. local DB
   - Detect closed positions: local DB has position but response is absent → mark status='closed'

3. **Funding rate snapshot:**
   - Query HL `POST /info {"type":"fundingRate"}` every 5 min (separate thread)
   - For each asset, store: `{asset, rate, next_payment_ts}` in `funding_snapshots`
   - Expose `getFundingRate(asset) → f64` for strategy engine (LP and arb)

4. **In-memory cache:**
   - Hold latest snapshot in a struct (equity, margin_used, positions vec, timestamp)
   - Expose `getSnapshot() → Snapshot` for IPC handlers (no DB query on hot path)
   - Update-on-poll: atomic swap the snapshot reference

5. **IPC handlers (extensions to ipc.zig):**
   - `portfolio.response` now includes: `equity`, `margin_used_pct`, `funding_accrued` (instead of `usdc_balance`)
   - Position fields: `asset`, `side`, `size`, `entry_price`, `mark_price`, `unrealized_pnl`, `funding_accrued`
   - Fallback: if portfolio_tracker not initialized, return `phase-0-stub` response

6. **Public interface:**
   ```zig
   pub fn init(allocator, database, auth) !*PortfolioTracker
   pub fn deinit(self)
   pub fn startPollingLoop() !void
   pub fn getSnapshot() Snapshot
   pub fn writeSnapshotJson(writer) ![]u8 // for IPC portfolio.response
   pub fn queryPositionByAsset(asset) ?Position
   pub fn getAccountEquity() f64
   pub fn getMarginUsedPercent() f64
   pub fn getFundingRate(asset) f64
   ```

**Dry-run portfolio tracking:**
- Simulate starting equity from `DRY_RUN_INITIAL_BALANCE` env var (e.g., $10,000)
- For each simulated fill: update balance = balance − (size × price) − fees
- Accumulate unrealised PnL from open dry-run positions using current l2Book mid-price
- Emit `event.portfolio.updated` IPC event after each 30s fill simulation batch

**Unit tests:**
- Parse fixture `clearinghouseState` JSON → verify equity and positions extracted
- Position update: open new long position → verify side='long', size correct, unrealised_pnl computed
- Position close: asset absent from response → verify old position marked 'closed'
- Funding rate fetch: fixture response parsed, rate stored correctly
- Dry-run: initial balance set, fill deducts fee, balance decrements, unrealised PnL correct
- Margin percent: computed as `margin_used / equity × 100`

**Acceptance:**
- Unit tests pass (100% coverage for parsing, position lifecycle, funding rates, dry-run)
- Manual integration test: create testnet position, query clearinghouseState, confirm tracker snapshot matches
- Latency: portfolio poll completes within 2s even if API is slow

---

### 4. IPC Updates (TASK-5.3)

**Update `zig/src/ipc_types.zig`**

Add new message types for Phase 5 (funding and arb):

```zig
pub const T = struct {
    // ... existing ...
    
    // Phase 5: Funding rate and portfolio changes
    pub const funding_snapshot = "funding.snapshot";
    pub const funding_snapshot_response = "funding.snapshot.response";
    pub const event_portfolio_updated = "event.portfolio.updated";
    pub const event_portfolio_stale = "event.portfolio.stale";
    
    // Phase 5+: Arb events (placeholder for Phase 6)
    pub const arb_events = "arb.events";
    pub const arb_events_response = "arb.events.response";
    pub const event_arb_triggered = "event.arb.triggered";
};
```

**Update `zig/src/ipc.zig`**

1. Add dispatch handlers for new message types:
   ```zig
   .funding_snapshot => try handleFundingSnapshot(ctx, req_id, writer),
   .arb_events => try handleArbEvents(ctx, req_id, writer),
   ```

2. Implement `handleFundingSnapshot()`:
   - Query `funding_snapshots` table (last 24h)
   - Return JSON: `{ "funding": [ {"asset": "BTC", "rate": 0.0001, "next_payment_ts": ...}, ... ] }`

3. Implement `handleArbEvents()`:
   - Query `arb_events` table (last 100 events or 7 days)
   - Return JSON with arb event list (populated by Phase 6)

4. Update `handlePortfolio()`:
   - Call `portfolio_tracker.getSnapshot()`
   - Serialize to JSON with HL fields:
     ```json
     {
       "equity": 10500.50,
       "margin_used_pct": 45.2,
       "funding_accrued": -5.25,
       "positions": [
         {"asset": "BTC", "side": "long", "size": 0.05, "entry_price": 45000, "mark_price": 45100, "unrealized_pnl": 5, "funding_accrued": 0}
       ]
     }
     ```

5. Remove Polymarket-specific message handlers (if any):
   - Remove `kalshi_mappings`, `kalshi_mappings_response` dispatch (defer to Phase 8 cleanup)

**TypeScript IPC types (`ts/src/ipc/types.ts`)**

Mirror all Zig changes:
- Add `FundingSnapshotPayload`, `ArbEventPayload` interfaces
- Update `PortfolioPayload` interface: replace `usdc_balance` with `equity`, `margin_used_pct`, `funding_accrued`
- Update `Position` type: add `mark_price`, `funding_accrued` fields

**Unit tests:**
- IPC serialization: portfolio snapshot → JSON → verified structure
- Field presence: equity, margin_used_pct, positions array

**Acceptance:**
- TypeScript and Zig IPC types match
- JSON serialization produces valid JSON parseable by TS client

---

### 5. Update Existing Modules (TASK-5.4)

**Update `zig/src/portfolio_tracker.zig` (stub replacement)**

Replace the existing Polymarket-specific stub with a wrapper that delegates to `hl_portfolio_tracker.zig`:

```zig
pub const PortfolioTracker = struct {
    allocator: std.mem.Allocator,
    hl_tracker: *HlPortfolioTracker, // Delegate
    
    pub fn getSnapshot() PortfolioSnapshot {
        return hl_tracker.getSnapshot();
    }
    
    pub fn writeSnapshotJson(writer) ![]u8 {
        // Convert HlPortfolioTracker snapshot to legacy PortfolioSnapshot format
        // for backward compat with IPC handlers
    }
};
```

Or: replace entirely with new implementation (simpler approach).

**Update `zig/src/fill_poller.zig` (stub replacement)**

Replace with actual `hl_fill_poller.zig` implementation:
- Remove phase-0 stub comments
- Integrate with hl_auth, database, IPC

**Update `zig/src/main.zig`**

- Initialize `hl_portfolio_tracker` on startup (after DB migrations, after hl_auth ready)
- Start polling loops as separate threads:
  ```zig
  var pt_thread = try std.Thread.spawn(.{}, hl_portfolio_tracker.startPollingLoop, .{});
  var fp_thread = try std.Thread.spawn(.{}, hl_fill_poller.startWsConnection, .{});
  ```
- If `DRY_RUN=1`: start dry-run fill simulation loop
- On shutdown: gracefully stop both threads

**Update `zig/build.zig`**

Add new modules to build:
```zig
b.builder.module("hl_fill_poller", .{
    .root_source_file = b.path("src/hl_fill_poller.zig"),
});
b.builder.module("hl_portfolio_tracker", .{
    .root_source_file = b.path("src/hl_portfolio_tracker.zig"),
});
```

---

### 6. Testing (TASK-5.5)

**Update `zig/src/tests.zig`**

Add new test blocks:

1. **Migration tests:**
   - Verify migration 013 creates all required columns/tables
   - Verify schema version increments

2. **Fill poller tests:**
   - Fixture: HL user WebSocket fill event JSON
   - Test: parse → verify order status updated, fill row inserted
   - Test: partial fill → status='partially_filled'
   - Test: latency tracking → elapsed_ms > 0
   - Test: dry-run fill simulation → order crosses mid → fill settles with fee

3. **Portfolio tracker tests:**
   - Fixture: HL clearinghouseState JSON
   - Test: parse equity and margin → snapshot reflects both
   - Test: position parsing → side, size, entry_price correct
   - Test: unrealised PnL → computed as (current_price − entry_price) × size
   - Test: position close → status='closed' when removed from response
   - Test: funding rate snapshot → stored and queryable

4. **IPC tests:**
   - Test: portfolio.response serializes equity, margin_used_pct, positions
   - Test: funding.response returns funding rate list

**TypeScript tests (`ts/test/*.test.ts`)**

- Parse IPC portfolio.response JSON → verify payload interface
- Verify no references to legacy `usdc_balance` field

**Manual integration tests (on testnet):**

Before closing Phase 5:

1. Deploy engine with Phase 5 code to testnet
2. Confirm portfolio tracker polls clearinghouseState every 60s
3. Place a testnet order → confirm fill detected within 500ms
4. Verify IPC `/portfolio` returns equity and positions (not USDC balance)
5. If `DRY_RUN=1`: verify dry-run fills simulate every 30s

---

## Critical Decisions

| Decision | Recommendation | Rationale |
|----------|---|---|
| **User WebSocket auth:** Use API Wallet or main wallet? | Use API Wallet (documented on HL SDK for user channel) | Follows Hyperliquid security model; main wallet not needed for read-only fills |
| **Portfolio poll interval:** 60s or higher? | 60s | Balances latency (portfolio updates within 1 min) and API rate limit (300 req/min available) |
| **Dry-run fill latency model:** Fixed or random? | Uniform random 8–25ms | Realistic latency variability; accounts for network jitter |
| **Funding rate update freq:** Poll every 5 min or per-portfolio poll? | Separate 5 min loop | Funding changes every 8 hours (HL); 5 min granularity is frequent enough, avoids cluttering portfolio polls |
| **Dry-run fill simulation:** Per-fill or batch every 30s? | Batch every 30s | Avoids excessive CPU; fills settle in realistic clusters |
| **Portfolio fallback on equity fetch failure:** Pause strategy or halt? | Pause (temporary) | Safer than halt; allows recovery without manual intervention; emits alert to operator |

---

## Verification Steps

**Phase 5 gate: Each condition must be met before proceeding to Phase 6.**

1. ✅ Unit tests: `zig build test` passes 100% for fill_poller, portfolio_tracker, migrations, IPC
2. ✅ Manual integration test: testnet deployment confirms:
   - Portfolio tracker polls clearinghouseState, snapshot reflects real equity/margin
   - Fill poller detects fills within 500ms of fill event
   - Dry-run fills simulate every 30s, balance decrements correctly
   - IPC `/portfolio` returns equity + positions (no USDC balance field)
3. ✅ Latency telemetry: log p99 fill detection latency < 500ms over 10 test fills
4. ✅ Code review: no Polymarket-specific references remain in hl_fill_poller, hl_portfolio_tracker
5. ✅ Database schema: migration 013 passes, all columns present, no schema conflicts

---

## Files Modified / Created

**New files:**
- `zig/src/hl_fill_poller.zig`
- `zig/src/hl_portfolio_tracker.zig`
- `db/migrations/013_phase5_hl_portfolio.sql`

**Modified files:**
- `zig/src/fill_poller.zig` (replace with hl_fill_poller wrapper or delete)
- `zig/src/portfolio_tracker.zig` (rewrite for HL or replace with wrapper)
- `zig/src/ipc_types.zig` (add funding/arb message types)
- `zig/src/ipc.zig` (add funding/arb handlers, update portfolio handler)
- `zig/src/main.zig` (initialize portfolio/fill trackers, start polling threads)
- `zig/build.zig` (add new module declarations)
- `zig/src/tests.zig` (add Phase 5 test blocks)
- `ts/src/ipc/types.ts` (mirror Zig IPC updates)

**Optional:**
- `ts/src/telegram/bot.ts` (defer to Phase 8, but prepare for Phase 6 `/funding` command)

---

## Effort Estimate

- **HL Fill Poller:** 8–12 hours (WebSocket, REST fallback, dry-run simulation, test vectors)
- **HL Portfolio Tracker:** 6–10 hours (equity polling, position lifecycle, funding rates, snapshot serialization)
- **Database migrations:** 2–3 hours (schema design, migration SQL, test)
- **IPC updates:** 3–4 hours (new message types, handlers, serialization)
- **Existing module updates:** 3–4 hours (main.zig threading, build.zig, tests.zig)
- **Manual integration testing:** 4–6 hours (testnet deployment, fill triggering, latency measurement)

**Total:** ~26–39 hours (~4–5 days solo, 1 week with review cycles)

---

## Open Questions for Phase 5

- **Q1:** What is the exact format of HL user WebSocket subscription message? Must be confirmed from HL docs before TASK-5.1.1.
- **Q2:** Does HL return mark prices in every fill event, or must we deduce them from l2Book? (Affects position P&L accuracy in dry-run.)
- **Q3:** Should the dry-run fill simulator use bid/ask from l2Book snapshot or interpolated mid? (Current plan: best bid/ask; alternative: mid-price only.)
- **Q4:** If portfolio_tracker.equity fetch fails 3×, we emit a Telegram alert immediately

---