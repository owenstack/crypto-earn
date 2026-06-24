# Codebase Audit Findings

Date: 2026-06-24

## Summary

The Zig engine compiles and its Zig test suite passes, but the migration is not complete. The remaining work is mostly in active runtime wiring, HL-native semantics, and the TypeScript control plane.

## Findings

### 1. Market-making still uses legacy prediction-market lookup and pricing semantics

The main strategy loop reads `orderbooks.gamma_id` and treats that as the market identifier instead of using the live HL orderbook cache. It also clamps prices to `0.01..0.99`, which is a prediction-market price range, not a perpetual futures range.

Evidence:
- [zig/src/main.zig](/home/ubuntu/repos/crypto-earn/zig/src/main.zig:617) reads `SELECT gamma_id, best_bid, best_ask FROM orderbooks ...`
- [zig/src/main.zig](/home/ubuntu/repos/crypto-earn/zig/src/main.zig:929) clamps prices to `0.01..0.99`
- [zig/src/main.zig](/home/ubuntu/repos/crypto-earn/zig/src/main.zig:766) queries the orderbook by `gamma_id`

Impact:
- Market-making can run against stale legacy persistence semantics instead of HL-native live quotes.
- HL perp pricing/sizing is not fully integrated into the active quote path.

### 2. Arb is telemetry-only, not a full trading path

The arb evaluator computes and persists signals, but live taker submission and P&L feedback are explicitly deferred.

Evidence:
- [zig/src/main.zig](/home/ubuntu/repos/crypto-earn/zig/src/main.zig:649) documents arb as telemetry-only
- [zig/src/main.zig](/home/ubuntu/repos/crypto-earn/zig/src/main.zig:687) says live taker submission and circuit-breaker feedback are deferred

Impact:
- The arb strategy does not actually place trades yet.
- FR-22/23/24 are only partially satisfied.

### 3. Unknown HL symbols can silently fall back to asset index 0

The order manager resolves missing metadata to `0` instead of rejecting the order.

Evidence:
- [zig/src/order_manager.zig](/home/ubuntu/repos/crypto-earn/zig/src/order_manager.zig:170) returns `0` on metadata miss

Impact:
- A misconfigured or unknown symbol can be sent with the wrong asset index.
- This is a live-trading safety issue.

### 4. Reconciliation is a minimal sweep, not full open-order reconciliation

Startup reconciliation does one fill sweep, then reports success with hard-coded values.

Evidence:
- [zig/src/fill_poller.zig](/home/ubuntu/repos/crypto-earn/zig/src/fill_poller.zig:160) returns a fixed `ReconcileResult`
- [zig/src/ipc.zig](/home/ubuntu/repos/crypto-earn/zig/src/ipc.zig:595) returns a hard-coded `"status":"complete"` response

Impact:
- Local state mismatches against HL open orders are not fully reconciled.
- The reconciliation gate exists, but the implementation is still shallow.

### 5. Dry-run fill simulation still depends on legacy orderbook lookup

The dry-run settlement path reads `orderbooks WHERE gamma_id=?`, which keeps dry-run behavior tied to legacy identifiers.

Evidence:
- [zig/src/main.zig](/home/ubuntu/repos/crypto-earn/zig/src/main.zig:766) uses `gamma_id` for the orderbook lookup

Impact:
- Dry-run P&L and fill behavior are not fully HL-native.

### 6. Control-plane terminology is still partially Polymarket/Kalshi-era

The Telegram bot and IPC types still expose legacy strategy names and Kalshi labels.

Evidence:
- [ts/src/telegram/bot.ts](/home/ubuntu/repos/crypto-earn/ts/src/telegram/bot.ts:211) advertises `/mappings — Kalshi market mappings`
- [ts/src/telegram/bot.ts](/home/ubuntu/repos/crypto-earn/ts/src/telegram/bot.ts:558) only accepts `news_repricing|liquidity_provision`
- [ts/src/ipc/types.ts](/home/ubuntu/repos/crypto-earn/ts/src/ipc/types.ts:30) still defines `kalshi.mappings`
- [ts/src/ipc/types.ts](/home/ubuntu/repos/crypto-earn/ts/src/ipc/types.ts:336) still defines `StrategyName` as `"news_repricing" | "liquidity_provision"`

Impact:
- The operator UI is not fully migrated to HL terminology.
- Phase 8-style cleanup is still outstanding.

### 7. HL portfolio data is only partly surfaced in the control plane

Zig emits HL-oriented portfolio fields, but the TS control plane still renders and validates around `usdc_balance`.

Evidence:
- [ts/src/telegram/bot.ts](/home/ubuntu/repos/crypto-earn/ts/src/telegram/bot.ts:245) rejects `/balance` if `usdc_balance` is missing
- [ts/src/components/Dashboard.tsx](/home/ubuntu/repos/crypto-earn/ts/src/components/Dashboard.tsx:181) derives KPI values from `usdc_balance`
- [ts/src/dashboard/server.ts](/home/ubuntu/repos/crypto-earn/ts/src/dashboard/server.ts:39) serves `/api/portfolio` from SQLite positions, not the HL portfolio snapshot

Impact:
- The dashboard and Telegram views are not yet HL-native.
- Equity/margin/funding data are not the primary operator surface.

### 8. Funding and arb operator commands are missing

The Zig IPC layer exposes `funding.snapshot` and `arb.events`, but Telegram does not expose commands for them.

Evidence:
- [zig/src/ipc.zig](/home/ubuntu/repos/crypto-earn/zig/src/ipc.zig:208) dispatches `funding.snapshot`
- [zig/src/ipc.zig](/home/ubuntu/repos/crypto-earn/zig/src/ipc.zig:209) dispatches `arb.events`
- [ts/src/telegram/bot.ts](/home/ubuntu/repos/crypto-earn/ts/src/telegram/bot.ts:203) command list has no `/funding` or `/arb`

Impact:
- FR-32 and FR-33 remain unimplemented in the control plane.

### 9. Documentation is stale

The root README still refers to Polymarket, Kalshi, and old env vars.

Evidence:
- [README.md](/home/ubuntu/repos/crypto-earn/README.md:68) lists `POLYMARKET_PRIVATE_KEY`
- [README.md](/home/ubuntu/repos/crypto-earn/README.md:169) refers to a Polymarket WebSocket endpoint
- [README.md](/home/ubuntu/repos/crypto-earn/README.md:176) starts a Kalshi integration section

Impact:
- The setup docs are misleading for the current HL migration state.

## Verification

Passed:
- `zig build test`
- `zig build -Doptimize=ReleaseFast`

Failed:
- `bun run typecheck` in `ts/build.ts`
- `bun test` in `ts/test/db-client.test.ts` and `ts/test/ipc-client.test.ts`

Unavailable:
- `sqlite3 --version` failed because `sqlite3` is not installed in this environment
- Full `scripts/verify.sh` could not be completed because it depends on the missing `sqlite3` CLI

