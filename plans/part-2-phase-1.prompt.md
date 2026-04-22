## Plan: Implement Phase 1 — Critical Correctness Fixes

This plan covers only Phase 1 of the PRD, focusing on three critical fixes: (1) correct CLOB order cancellation, (2) market registry slug-collision data loss, and (3) standardizing market identifier usage. Each task is broken down into actionable steps, with explicit file references and verification methods.

---

**Steps**

### Phase 1A: Fix CLOB Order Cancellation HTTP Method

1. Update `cancelOnCLOB()` in `zig/src/order_manager.zig`:
   - Change HTTP method from `.POST` to `.DELETE`
   - Change endpoint from `/order/cancel` to `/order`
   - Ensure request body uses `{"orderID": "<id>"}` (verify against current Polymarket API docs)
2. Update payload key casing to match Polymarket spec (`orderID` vs `order_id`)
3. Add/modify integration test to assert:
   - 2xx response is accepted
   - Non-2xx triggers retry path
4. Update `cancelAll()` to log each individual CLOB cancel result for observability

### Phase 1B: Fix Market Registry Slug-Collision Data Loss

1. Add `MIGRATION_006` in `zig/src/db.zig`:
   - Remove `UNIQUE` constraint from `markets.symbol` (requires table recreation)
2. Update `persistMarket()` in `zig/src/market_scanner.zig`:
   - Change `INSERT OR REPLACE` to `INSERT OR IGNORE`
   - Add separate `UPDATE` for mutable fields (`best_bid`, `best_ask`, `status`, `clob_token_ids`, `outcomes`, `accepting_orders`)
3. Add tests:
   - Insert two markets with same slug, different IDs; assert both rows survive
   - Re-insert existing market ID; assert mutable fields update, no duplicate row

### Phase 1C: Standardize Market Identifier Usage

1. In `MIGRATION_006`, add `condition_id` index to `orderbooks` table
2. Update `wsPriceCallback()` in `zig/src/main.zig`:
   - Store `update.market` (condition_id) in `orderbooks.market`
   - Resolve and store corresponding Gamma `id` in new `orderbooks.gamma_id` column (nullable)
3. Update `evaluateNewsSignals()`:
   - Pass resolved Gamma `market_id` to both `queryLastMid()` and signal's `market_id` field
4. Remove `OR id=?` fallback in `resolveTokenId()` in `order_manager.zig`; replace with assertion log if lookup fails
5. Update `evaluateLpSignals()` to retrieve `gamma_id` from `orderbooks` for `placeOrder()`
6. Add test: `resolveTokenId()` returns correct token for known `market_id` with no fallback

---

**Relevant files**

- `zig/src/order_manager.zig` — Update `cancelOnCLOB()`, `resolveTokenId()`, and related logic
- `zig/src/market_scanner.zig` — Update `persistMarket()`
- `zig/src/db.zig` — Add `MIGRATION_006` for schema changes
- `zig/src/main.zig` — Update `wsPriceCallback()`, `evaluateNewsSignals()`, `evaluateLpSignals()`
- `zig/src/tests.zig` — Add/modify tests for all above changes

---

**Verification**

1. Run/extend integration and unit tests:
   - Order cancellation: 2xx/4xx/5xx handling, retry logic, log output
   - Market registry: slug collision, update vs. insert, no data loss
   - Identifier: correct storage and resolution, no fallback, assertion logs
2. Manual test: Issue halt/cancel, verify orders are cancelled on CLOB and in DB
3. Migration: Apply `MIGRATION_006` on a test DB, verify schema and data integrity
4. Code review: Confirm all identifier usage is consistent and fallback logic is removed

---

**Decisions & Scope**

- Only Phase 1 tasks are included; no changes to fill detection, reconciliation, or strategy logic
- All DB changes use the existing migration pattern
- No new external dependencies or libraries

---

**Further Considerations**

1. Confirm Polymarket API spec for order cancellation before merging (see PRD Q-003)
2. Migration must be tested on a copy of production data to ensure no data loss
3. If identifier ambiguity is found in other pipeline stages, document for future phases

---

Please review this plan for Phase 1 implementation. If any adjustments or clarifications are needed, let me know before proceeding.
