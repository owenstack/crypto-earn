# Project Audit Pass - 2026-06-25

## Scope

Reviewed the current worktree against `audit-findings.md`, searched for remaining legacy Polymarket/Kalshi/liquidity-provision surfaces, fixed issues found during verification, and ran build/test gates.

## Summary

All nine issues from `audit-findings.md` are either fixed in current runtime behavior or reduced to backward-compatible legacy aliases. I did not find an unfixed live-trading bug from the original findings.

Residual cleanup remains:
- Dormant legacy modules/helpers still exist (`zig/src/websocket.zig`, `kalshi_market_map` DB helpers). They are not wired into the active HL strategy/order path.
- `news_repricing` is still present in the Zig strategy enum and some tests/history, but the active strategy worker no longer evaluates it for HL.
- The DB migration path logs expected "orderbooks missing" errors in tests when older migrations attempt optional alters before the table exists. Tests pass, but the log noise is worth cleaning separately.

## Fixes Made During This Pass

- Added `ENABLE_MARKET_MAKING` startup support in `zig/src/main.zig`, while preserving `ENABLE_LIQUIDITY_PROVISION` as a legacy alias.
- Updated `docker-compose.yml` and `README.md` to prefer `ENABLE_MARKET_MAKING`.
- Updated `scripts/analyze-dry-run.sh` to include both `market_making` and legacy `liquidity_provision` strategy rows.
- Fixed `ts/src/ipc/types.ts` reconciliation status typing to match Zig (`pending | complete | error`) and include `remote_checked`/`error`.
- Fixed strict TypeScript errors in `ts/build.ts`.
- Fixed `ts/src/db/client.ts` so the cached read-only SQLite handle reopens when `DB_PATH` changes between tests/process contexts.
- Hardened `ts/test/ipc-client.test.ts` by unlinking socket paths before `Bun.listen`.

## Original Findings Status

### 1. Market-making legacy lookup/pricing semantics

Status: fixed.

Evidence:
- `zig/src/main.zig` now evaluates market-making from the live HL orderbook cache (`ctx.hl_ob.quote(sym)`) and HL symbols, not `orderbooks.gamma_id`.
- Dry-run persisted fallback queries `orderbooks WHERE market=?`, not `gamma_id`.
- Tests cover ignoring legacy `gamma_id` matches and preferring live HL cache.

### 2. Arb telemetry-only

Status: fixed, with explicit opt-in for live submission.

Evidence:
- `ENABLE_CEX_DEX_ARB` enables evaluation.
- `ARB_SUBMIT_ORDERS` enables IOC-style HL taker submission through the shared `OrderManager`/risk gate.
- Confirmed signals are persisted to `arb_events`; submitted order IDs are attached when placement succeeds.

### 3. Unknown HL symbols falling back to asset index 0

Status: fixed.

Evidence:
- `OrderManager.resolveAssetIndex` returns `null` on missing metadata/cache.
- Live order placement rejects unknown symbols with `unknown_hl_symbol` before HL submission.

### 4. Reconciliation minimal sweep

Status: fixed.

Evidence:
- Startup reconciliation polls user fills, queries HL `openOrders`, compares local and remote open orders, closes stale local orders, adopts missing remote orders, and reports adopted/closed/unchanged counters.
- IPC returns the real reconciliation status rather than a hard-coded complete payload.

### 5. Dry-run fill simulation legacy lookup

Status: fixed.

Evidence:
- Dry-run quote resolution prefers live HL top-of-book.
- Persisted fallback is keyed by HL coin symbol in `orderbooks.market`.
- Tests prove `gamma_id` rows are ignored.

### 6. Control-plane terminology legacy names

Status: mostly fixed.

Evidence:
- Telegram exposes `/mappings` as "asset market mappings", not Kalshi mappings.
- Telegram `/strategy` accepts `market_making` and `cex_dex_arb`.
- TS `StrategyName` is now `market_making | cex_dex_arb`.

Residual:
- Legacy aliases/DB helpers for `liquidity_provision` and Kalshi mapping tables remain for historical data compatibility.

### 7. HL portfolio partly surfaced

Status: fixed for primary operator surfaces.

Evidence:
- Telegram `/balance` displays account equity, margin used, funding accrued, committed exposure, open-order exposure, unrealized PnL, realized PnL, and snapshot timestamp.
- Dashboard KPI derivation prefers HL fields (`equity`, `margin_used`, `funding_accrued`) and only falls back to `usdc_balance` for older payloads.
- Dashboard `/api/portfolio` test verifies HL portfolio snapshot behavior from IPC.

### 8. Funding and arb operator commands missing

Status: fixed.

Evidence:
- Telegram start menu lists `/funding` and `/arb`.
- `/funding` requests `funding.snapshot`.
- `/arb` requests `arb.events`.
- Telegram tests cover both command handlers and formatting.

### 9. Documentation stale

Status: fixed for the cited stale content.

Evidence:
- README documents Hyperliquid env vars, HL/Binance market data, `funding.snapshot`, `arb.events`, unknown-symbol rejection, and current Docker/local startup.
- The old cited `POLYMARKET_PRIVATE_KEY`, Polymarket WebSocket endpoint, and Kalshi integration section are no longer present.

## Verification Results

Passed:
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test`
- `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build -Doptimize=ReleaseFast`
- `bun run typecheck`
- `bun test` (run outside sandbox because Bun Unix socket listen gets `EPERM` inside sandbox)
- `bun run build`
- `docker compose config`
- `git diff --check`

Notes:
- Running `zig build test` without `ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache` fails in this managed environment because Zig tries to write `/home/ubuntu/.cache/zig`, which is read-only.
- Running `bun test` inside the sandbox fails only at Unix-domain socket listen setup (`EPERM`). The same suite passes outside the sandbox.

