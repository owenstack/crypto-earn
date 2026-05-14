## Plan: Phase 6 Trading Logic

Phase 6 is the trading-core slice of the migration: rewrite the Zig risk gate for margin semantics, extend the strategy engine for Hyperliquid inventory skew, and add the Binance-DEX arb evaluator with latency-aware circuit breaking. Keep the scope inside the Zig engine and its unit tests; defer dashboard/Telegram wording changes and schema migrations to later phases unless a build break forces a minimal compatibility shim.

**Steps**
1. Rework the risk gate around account-equity and notional exposure, using the existing balance snapshot path as the source of truth and replacing the current Polymarket-style position/share checks with margin-aware validation. This should update `validateOrder` and `validatePairPreflight`, keep rejection persistence intact, and add the smallest DB helper needed to compute open notional from current open positions and latest prices. *Depends on the current DB snapshot/query helpers.*
2. Extend the strategy engine for Hyperliquid semantics by renaming LP to `market_making` internally, tightening the LP spread defaults, and introducing an inventory-skew state machine that suppresses bids and skews asks after a long fill until inventory falls back under the exit threshold. Keep the existing signal-tracking structure, but change the LP evaluation path so the skewed quote path is explicit and testable. *Depends on step 1 only for any risk-aware sizing checks; otherwise parallel with step 1.*
3. Add a new `cex_dex_arb` module that consumes Binance and Hyperliquid mids, computes signed delta in bps, confirms stability across the configured window, and emits taker signals through the existing order pipeline. Model the arb as allowed to open new directional positions when the signal fires, and add a loss-based circuit breaker that disables the strategy after five consecutive losing trades and re-enables it after the cooldown. Persist arb telemetry to the existing `arb_events` table. *Depends on the existing order manager and DB persistence surface.*
4. Refresh unit coverage in `zig/src/tests.zig` to lock the new semantics in place: margin-limit acceptance and rejection, LP quote suppression after a fill, LP resumption after inventory clears, arb delta math, arb confirm-window logic, and arb circuit-breaker state transitions. Update any old LP strategy assertions that still refer to `liquidity_provision` so they match the renamed `market_making` behavior. *Depends on steps 1-3.*

**Relevant files**
- `/home/owenstack/repos/personal/crypto-earn/zig/src/risk_gate.zig` — replace `max_position_pct`/duplicate-position behavior with margin-aware notional checks and keep structured rejection logging.
- `/home/owenstack/repos/personal/crypto-earn/zig/src/db.zig` — add or reuse helpers for open notional and arb telemetry persistence; the current embedded `arb_events` and `funding_snapshots` tables already exist.
- `/home/owenstack/repos/personal/crypto-earn/zig/src/strategy_engine.zig` — rename LP semantics, add inventory-skew state, tighten spread defaults, and keep signal statistics consistent.
- `/home/owenstack/repos/personal/crypto-earn/zig/src/cex_dex_arb.zig` — new pure strategy module for delta computation, confirm window, circuit breaker, and telemetry emission.
- `/home/owenstack/repos/personal/crypto-earn/zig/src/order_manager.zig` — reuse the existing order dispatch path for arb taker orders rather than introducing a second submission path.
- `/home/owenstack/repos/personal/crypto-earn/zig/src/tests.zig` — add the phase-6 regression tests and update existing strategy/risk expectations.
- `/home/owenstack/repos/personal/crypto-earn/zig/src/ipc_types.zig` — only touch if a Zig-side enum or event string must be aligned for compilation; otherwise leave phase 8 IPC work alone.
- `/home/owenstack/repos/personal/crypto-earn/ts/src/ipc/types.ts` — defer unless the workspace build proves it is a compile-time dependency for phase 6; keep the control-plane rename work out of this phase if possible.

**Verification**
1. Run `zig build test` after the edits and require a clean pass.
2. Add and run focused tests for the touched slice: risk gate margin rejection and acceptance, LP skew suppression/resume, arb delta and confirm-window logic, and arb circuit-breaker cooldown.
3. Run a narrow compile-only check if needed to isolate regressions in `zig/src/risk_gate.zig`, `zig/src/strategy_engine.zig`, and `zig/src/cex_dex_arb.zig` before widening to the full test suite.

**Decisions**
- Arb taker orders are allowed to open new directional positions; the phase-6 arb is not reduce-only by default.
- Phase 6 should stay Zig-first. Do not pull in the dashboard/Telegram rename work unless the build requires a minimal type alignment.
- Use the existing `arb_events` persistence path already present in the embedded DB migration instead of adding a new schema step here.

**Further Considerations**
1. If the workspace build fails because `StrategyName` changed on the Zig side, the smallest compatibility fix is to update the shared IPC type union in TypeScript without pulling in the rest of the phase 8 UI work.
2. If margin-aware exposure needs a precise mark price source that is not yet available in the current engine state, prefer a narrow DB helper or query abstraction over broad schema changes in this phase.