## Plan: Phase 6 Read-Only Dashboard

Implement only Phase 6 by extending the existing TS dashboard from a Phase 0 stub into a secure, read-only monitoring UI that satisfies FR-63/64/65/66/67 using authenticated GET APIs plus polling. Reuse current Bun routes, DB read queries, and IPC contracts; avoid adding any control surfaces or Telegram-side behavior changes.

**Steps**
1. Phase A: Lock Phase 6 boundaries and contracts
1. Confirm this phase includes FR-63/64/65/66/67 only, with minor UI polish allowed and no bot control actions exposed in web UI.
1. Confirm read-only contract: all dashboard routes remain GET-only and all state-changing operations remain Telegram-only. *blocks all later steps*
1. Confirm data shape sources for KPI cards:
1. Use IPC `status` and/or `portfolio` payload fields for USDC balance, exposure, unrealized and realized daily P&L.
1. If any KPI field is absent from current route responses, add route-level aggregation from existing IPC/DB read paths without introducing writes.

2. Phase B: Backend API completion for dashboard read models
1. Extend dashboard API routes in `/home/owenstack/repos/personal/cex-zig/ts/src/dashboard/server.ts` with a new authenticated GET endpoint for markets (`/api/markets`) that proxies IPC `market.list`. *depends on Phase A*
1. Keep existing endpoints (`/api/status`, `/api/portfolio`, `/api/orders`, `/api/logs`, `/api/heartbeat`, `/api/config`) read-only and authenticated; normalize fallback payloads for disconnected IPC to keep UI stable.
1. Ensure `/api/status` (or `/api/portfolio` if preferred) returns all FR-64 KPIs required by UI cards (USDC balance, total exposure, daily P&L).
1. Maintain strict no-store caching and 401 behavior for missing/invalid Bearer token.

3. Phase C: Dashboard UI completion (read-only)
1. Replace raw JSON-focused dashboard layout in `/home/owenstack/repos/personal/cex-zig/ts/src/components/Dashboard.tsx` with structured read-only panels. *depends on Phase B*
1. Add KPI cards for FR-64: USDC balance, total exposure, daily P&L, plus current engine/connection state.
1. Replace raw positions/orders JSON dumps with readable tabular lists while preserving “No open positions/orders” empty states.
1. Add System Log panel for FR-65 using polling from `/api/logs` and level-aware visual differentiation.
1. Add Market Tracker panel for FR-66 using polling from `/api/markets`, showing tracked markets with live mid-price and spread.
1. Keep zero control surfaces: no buttons/forms/actions that modify engine state (FR-67).
1. Minor polish allowed in this phase: responsive layout cleanup and safer display formatting (numbers/timestamps), but no auth UI/login page changes.

4. Phase D: Types and client helpers alignment
1. Update/verify IPC typing in `/home/owenstack/repos/personal/cex-zig/ts/src/ipc/types.ts` for market and KPI payload fields consumed by Phase 6 UI. *parallel with Phase C once Phase B payload design is fixed*
1. Optionally add small IPC helper method(s) in `/home/owenstack/repos/personal/cex-zig/ts/src/ipc/client.ts` only if route handlers need clearer typed wrappers; avoid broad refactors.
1. Keep TypeScript contracts consistent with existing Zig IPC semantics; if a field mismatch is discovered, prefer adapting TS route mapping over protocol redesign in this phase.

5. Phase E: Test coverage and regression checks
1. Extend route tests in `/home/owenstack/repos/personal/cex-zig/ts/test/dashboard.test.ts` to cover `/api/markets` auth/read behavior and disconnected fallback behavior. *depends on Phase B*
1. Add/adjust assertions that all dashboard routes are GET-only and reject unauthenticated requests (FR-63/67 guardrails).
1. Validate dashboard still renders read-only empty states and does not expose control actions.
1. Run targeted test suite for dashboard and related TS modules to catch regressions.

6. Phase F: Verification and acceptance mapping
1. Verify FR-63: dashboard access requires Bearer token and unauthorized requests receive 401.
1. Verify FR-64: UI displays balance, exposure, daily P&L, open orders, and open positions with live polling refresh.
1. Verify FR-65: system log panel updates via polling and displays recent structured logs.
1. Verify FR-66: market list shows currently tracked markets with mid-price and spread.
1. Verify FR-67: no web controls exist for halt/pause/config/trade; all modifications remain Telegram-only.

**Relevant files**
- `/home/owenstack/repos/personal/cex-zig/ts/src/dashboard/server.ts` — add `/api/markets`, ensure authenticated read-only route behavior and KPI-ready responses.
- `/home/owenstack/repos/personal/cex-zig/ts/src/components/Dashboard.tsx` — implement Phase 6 read-only dashboard UI panels and polling views.
- `/home/owenstack/repos/personal/cex-zig/ts/src/ipc/types.ts` — confirm/adjust payload contracts used by markets and KPI rendering.
- `/home/owenstack/repos/personal/cex-zig/ts/src/ipc/client.ts` — optional typed helper additions for market/P&L reads if needed by route layer.
- `/home/owenstack/repos/personal/cex-zig/ts/src/db/client.ts` — reuse existing read-only queries for orders/positions/logs.
- `/home/owenstack/repos/personal/cex-zig/ts/test/dashboard.test.ts` — add Phase 6 route/auth/read-only and fallback coverage.
- `/home/owenstack/repos/personal/cex-zig/ts/src/index.ts` — verify route wiring remains unchanged except expanded API route map.

**Verification**
1. Run dashboard route tests to validate auth, route existence, GET-only enforcement, and `/api/markets` behavior.
2. Run TS test subset covering IPC client + dashboard behavior.
3. Launch TS app and manually verify dashboard panels populate under valid Bearer token and fail closed (401) without token.
4. Simulate IPC disconnected state and confirm graceful fallback rendering (no crashes, clear offline status).
5. Confirm UI contains no actionable control endpoints or controls (halt/pause/config/trade absent).

**Decisions**
- Include scope: Phase 6 FR-63/64/65/66/67 only, with minor UI polish permitted.
- Auth approach: keep existing Bearer token model; no dedicated login/token prompt UI in this phase.
- Realtime approach: polling-based updates for dashboard panels; no event-stream/WebSocket expansion in this phase.
- Excluded from scope: Telegram command changes, Zig engine trading logic changes, non-Phase-6 strategy/risk/order features, and broader auth redesign.

**Further Considerations**
1. KPI source of truth: prefer IPC snapshot fields when available; only derive from DB when IPC data is unavailable.
2. Poll intervals: use faster cadence for status/markets and slightly slower cadence for logs to balance freshness vs load.
3. UI data formatting: standardize currency/percentage formatting to avoid ambiguity in P&L and exposure displays.