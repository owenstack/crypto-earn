## Plan: Phase 2 Risk Gate and Orders

Deliver only PRD Phase 2 (Week 3): implement Zig-native risk gate + order management + staleness handling + persistence, with minimal TypeScript IPC wiring required to validate the flow end-to-end. Reuse the existing IPC server/client and scanner foundations, keep web control surfaces read-only, and defer strategy expansion and later phase features.

**Steps**
1. Phase A - Lock contracts and boundaries
1.1 Finalize Phase 2 message contract additions in Zig and TS before module implementation to avoid drift. Extend existing type registries in /home/owenstack/repos/personal/cex-zig/zig/src/ipc_types.zig (T constants + payload shape assumptions) and /home/owenstack/repos/personal/cex-zig/ts/src/ipc/types.ts (RequestMessageType/ResponseMessageType + payload types). Depends on none.
1.2 Add Phase 2 command/event set: order.place, order.cancel, order.cancel_all, halt, resume, risk.check.response, order.event, portfolio.snapshot.response, orders.open.response. Depends on 1.1.
1.3 Explicitly preserve security boundary: dashboard remains read-only and no state-changing HTTP routes added. Parallel with 1.2.

2. Phase B - Persistence and schema evolution
2.1 Add db migration file /home/owenstack/repos/personal/cex-zig/db/migrations/002_phase2_orders_risk.sql for risk_events, balance_snapshots, order_state timestamps needed for staleness and drawdown accounting. Depends on 1.1.
2.2 Replace hardcoded single migration string in /home/owenstack/repos/personal/cex-zig/zig/src/db.zig with an ordered migration runner that applies 001 + 002 idempotently. Depends on 2.1.
2.3 Add DB helper APIs in /home/owenstack/repos/personal/cex-zig/zig/src/db.zig for: insertOrder, updateOrderStatus, insertFill, recordRiskRejection, queryOpenOrderCount, queryOpenExposureUsd, queryPositionByMarketDirection, queryTodaysRealizedAndUnrealizedLoss. Depends on 2.2.

3. Phase C - Zig Risk Gate core
3.1 Create /home/owenstack/repos/personal/cex-zig/zig/src/risk_gate.zig with a single entrypoint validateOrder(request, snapshot, config) that returns pass or structured rejection reason/value context. Depends on 2.3.
3.2 Implement all five checks as isolated functions called from validateOrder in deterministic order: max position, max portfolio exposure, max daily drawdown, max open orders, duplicate position guard. Depends on 3.1.
3.3 Ensure non-bypassability: all order submission paths (strategy-originated and manual trade IPC route) call risk_gate.validateOrder before network dispatch. Depends on 3.2.
3.4 On rejection, persist risk_events row and emit IPC event payload suitable for Telegram alerting. Depends on 3.2.

4. Phase D - Zig Order Manager and staleness handling
4.1 Create /home/owenstack/repos/personal/cex-zig/zig/src/order_manager.zig with API: placeOrder, cancelOrder, cancelAll, reconcileOrderStatus, scanStaleOrders. Depends on 3.3.
4.2 Implement signed CLOB REST submission using existing /home/owenstack/repos/personal/cex-zig/zig/src/crypto.zig and /home/owenstack/repos/personal/cex-zig/zig/src/http_client.zig. Extend HttpClient where needed for headers/auth and status-aware retries. Depends on 4.1.
4.3 Add 429 exponential backoff policy for order submission path only: 1s, 2s, 4s, ... capped at 60s with max-attempt guard and structured logs. Depends on 4.2.
4.4 Implement order aging policy for GTC orders using max_order_age_hours and periodic scanStaleOrders ticker; stale orders must be canceled and recorded with reason stale_timeout. Depends on 4.1 and 2.3.

5. Phase E - Portfolio/fill tracking
5.1 Create /home/owenstack/repos/personal/cex-zig/zig/src/portfolio_tracker.zig that consumes order/fill events and maintains in-memory plus SQLite-synchronized state for open positions and PnL snapshots. Depends on 2.3.
5.2 Implement fee-aware PnL update on each fill using PRD formula and configurable maker/taker fees. Depends on 5.1.
5.3 Expose lightweight snapshot getters used by IPC status/portfolio/orders handlers (avoid SQL-heavy hot path per request). Depends on 5.1.

6. Phase F - IPC server integration in Zig
6.1 Extend dispatcher in /home/owenstack/repos/personal/cex-zig/zig/src/ipc.zig dispatch() to route new command types to order manager and control-plane actions. Depends on 1.2, 4.1, 5.3.
6.2 Replace Phase 0 stub payloads for portfolio/orders/config responses with live data from portfolio tracker and DB helpers. Depends on 6.1.
6.3 Integrate halt state in /home/owenstack/repos/personal/cex-zig/zig/src/main.zig so halt cancels all open orders and blocks further strategy-triggered order paths until resume. Depends on 4.1 and 6.1.

7. Phase G - Minimal TypeScript wiring for E2E validation
7.1 Extend /home/owenstack/repos/personal/cex-zig/ts/src/ipc/types.ts and keep envelope parity with Zig additions from Phase A. Depends on 1.2.
7.2 Add typed client helpers in /home/owenstack/repos/personal/cex-zig/ts/src/ipc/client.ts for place/cancel/halt flows (on top of existing request()). Depends on 7.1.
7.3 Extend /home/owenstack/repos/personal/cex-zig/ts/src/telegram/bot.ts command handlers minimally for /trade, /cancel, /halt, /resume and richer /status, reusing existing guard() and createBot() flow. Depends on 7.2 and 6.1.
7.4 Keep /home/owenstack/repos/personal/cex-zig/ts/src/dashboard/server.ts read-only; optionally surface richer status/portfolio/order fields only. Parallel with 7.3.

8. Phase H - Testing and sign-off
8.1 Zig unit tests: add risk gate threshold tests, duplicate guard tests, backoff schedule test, stale-order cancellation tests, halt-state enforcement tests in /home/owenstack/repos/personal/cex-zig/zig/src/tests.zig (and/or focused new test files). Depends on Phases C-F.
8.2 TS tests: update /home/owenstack/repos/personal/cex-zig/ts/test/ipc-client.test.ts and /home/owenstack/repos/personal/cex-zig/ts/test/dashboard.test.ts for new message types and read-only dashboard guarantee. Depends on Phase G.
8.3 E2E acceptance checks: manual IPC roundtrip for place->risk gate->persist->query status; simulate 429; verify stale cancel; verify /halt cancels and blocks new strategy-originated orders. Depends on all prior phases.

**Relevant files**
- /home/owenstack/repos/personal/cex-zig/plans/prd.md — source of truth for Phase 2 scope and FR-16/23/25-33.
- /home/owenstack/repos/personal/cex-zig/zig/src/ipc.zig — extend dispatch() routing and replace phase-0 stubs.
- /home/owenstack/repos/personal/cex-zig/zig/src/ipc_types.zig — add Phase 2 command/response/event type constants.
- /home/owenstack/repos/personal/cex-zig/zig/src/main.zig — wire order manager, risk gate, halt lifecycle.
- /home/owenstack/repos/personal/cex-zig/zig/src/db.zig — migration runner + Phase 2 query/mutation helpers.
- /home/owenstack/repos/personal/cex-zig/zig/src/http_client.zig — enhance POST behavior and 429-aware retry hooks for order path.
- /home/owenstack/repos/personal/cex-zig/zig/src/crypto.zig — reuse signing primitives for CLOB order payloads.
- /home/owenstack/repos/personal/cex-zig/zig/src/market_scanner.zig — preserve current scanner loop and avoid coupling Phase 2 logic into scanner core.
- /home/owenstack/repos/personal/cex-zig/zig/src/clob_orderbook.zig — reuse fetch/save patterns for fill/orderbook persistence style.
- /home/owenstack/repos/personal/cex-zig/zig/src/risk_gate.zig — new module for mandatory checks.
- /home/owenstack/repos/personal/cex-zig/zig/src/order_manager.zig — new module for lifecycle and staleness.
- /home/owenstack/repos/personal/cex-zig/zig/src/portfolio_tracker.zig — new module for exposure/PnL snapshots.
- /home/owenstack/repos/personal/cex-zig/db/migrations/002_phase2_orders_risk.sql — Phase 2 schema additions.
- /home/owenstack/repos/personal/cex-zig/ts/src/ipc/types.ts — mirror contract changes.
- /home/owenstack/repos/personal/cex-zig/ts/src/ipc/client.ts — typed Phase 2 request helpers.
- /home/owenstack/repos/personal/cex-zig/ts/src/telegram/bot.ts — minimal command wiring for E2E validation.
- /home/owenstack/repos/personal/cex-zig/ts/src/dashboard/server.ts — retain read-only boundary with richer visibility only.
- /home/owenstack/repos/personal/cex-zig/zig/src/tests.zig — Zig tests for risk/order behavior.
- /home/owenstack/repos/personal/cex-zig/ts/test/ipc-client.test.ts — IPC behavior validation.
- /home/owenstack/repos/personal/cex-zig/ts/test/dashboard.test.ts — auth and read-only route safety.

**Verification**
1. Build and tests: run zig build, zig build test, bun run typecheck, bun test.
2. Risk gate correctness: threshold boundary tests pass for all five checks with exact-equal and just-over values.
3. Non-bypassability: every IPC order command path proves a risk_gate.validateOrder call before placeOrder network execution.
4. 429 backoff: deterministic test confirms 1/2/4/.../60 sec sequence and termination behavior.
5. Staleness: seeded old GTC orders are canceled by scanStaleOrders and persisted with cancellation reason.
6. Halt behavior: halt triggers cancelAll and prevents further strategy-originated order placement until resume.
7. Data consistency: order/fill/position/risk_events rows appear as expected and dashboard remains read-only.
8. Latency spot-check: command response and dispatch path timings are captured in logs for Phase 2 acceptance tracking.

**Decisions**
- Use PRD Phase 2 definition as authoritative.
- Include minimal TS wiring only to validate Zig Phase 2 end-to-end.
- Keep dashboard strictly read-only; no web control operations.
- Keep Phase 2 bounded to risk/orders/persistence/control commands and exclude strategy expansion.

**Further Considerations**
1. Backoff ownership recommendation: keep retry policy inside order_manager.zig instead of generic http_client.zig to avoid unintended retries on non-order requests.
2. Risk snapshot source recommendation: compute exposure/open-order counts from a small in-memory mirror updated on order events, with DB fallback on startup/recovery.
3. Halt semantics recommendation: block strategy-originated placements while allowing explicit operator resume only; document this in Telegram help text.