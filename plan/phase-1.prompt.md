# Phase 1 Implementation Plan — Codebase Pruning and Project Setup

## Overview
Phase 1 removes all Polymarket/Kalshi/Gamma-specific code from the codebase to prepare for Hyperliquid integration. This is a destructive phase with no new functionality added — purely cleanup.

**Estimated effort:** 1–2 hours  
**Verification:** `zig build` completes without errors

---

## Codebase Analysis Summary

### Files to Delete (7 total)
- `zig/src/polymarket_auth.zig`
- `zig/src/gamma_api.zig`
- `zig/src/kalshi_ws.zig`
- `zig/src/news_sources.zig`
- `zig/src/market_scanner.zig`
- `zig/src/probability_provider.zig`
- `zig/src/clob_orderbook.zig`

### Import Cleanup
- `zig/src/main.zig`: 4 imports to remove (lines 6, 8, 14, 15)
- `zig/src/tests.zig`: 6 imports to remove (lines 11, 12, 13, 22, 28, 34)

### Code Removal from main.zig (~150 lines total)
- Lines 65–117: Polymarket private key parsing and auth init
- Lines 120–135: Polymarket/Kalshi env vars (SIGNATURE_TYPE, FUNDER_ADDRESS)
- Line 136: `emitPolymarketStartupDiagnostic()` call
- Lines 153–165: Market scanner init and thread spawn
- Lines 220–226: Kalshi WebSocket client init and thread spawn
- Lines 228–233: Probability provider init
- Lines 305–369: Entire USDC balance ticker context (functions + struct field)
- Lines 1208–1210: BalanceTickerCtx struct field removal
- Lines 1263–1277: `fetchUsdcBalanceWithFallback()` function
- Lines 1289–1354: `emitPolymarketStartupDiagnostic()` function definition
- Lines 1378–1425: `validateLivePolymarketAuth()` function definition

### Code Removal from tests.zig (1 test)
- Lines 1278–1286: `test "news_sources: init and empty cache"`

### Environment Variables
- Remove from `.env.example`: `POLYMARKET_PRIVATE_KEY`, `KALSHI_API_KEY` (lines 6, 9)

### No Changes Needed
- `zig/build.zig` — no explicit module declarations
- `docker-compose.yml` — uses env var references; safe after .env.example update

---

## Implementation Steps

### Step 1: Delete Zig Source Files (PARALLEL)
- Delete all 7 files from `zig/src/`
- Expected outcome: compile errors in main.zig and tests.zig pointing to missing imports

### Step 2: Remove Imports from main.zig
- Line 6: Remove `const scanner = @import("market_scanner.zig");`
- Line 8: Remove `const poly_auth = @import("polymarket_auth.zig");`
- Line 14: Remove `const kalshi_ws = @import("kalshi_ws.zig");`
- Line 15: Remove `const prob_provider = @import("probability_provider.zig");`
- *Depends on Step 1*

### Step 3: Remove Imports from tests.zig
- Line 11: Remove gamma_api import
- Line 12: Remove clob_orderbook import
- Line 13: Remove market_scanner import
- Line 22: Remove news_sources import
- Line 28: Remove polymarket_auth import
- Line 34: Remove probability_provider import
- *Depends on Step 1*

### Step 4: Remove Code Blocks from main.zig (SEQUENTIAL — dependencies between blocks)
1. Remove `emitPolymarketStartupDiagnostic()` function call (line 136)
2. Remove polymarket private key parsing block (lines 65–117)
3. Remove polymarket/kalshi env vars (lines 120–135)
4. Remove market scanner init (lines 153–165) 
5. Remove kalshi WS init (lines 220–226)
6. Remove probability provider init (lines 228–233)
7. Remove entire USDC balance ticker context (lines 305–369)
8. Remove `BalanceTickerCtx` struct field (lines 1208–1210)
9. Remove `fetchUsdcBalanceWithFallback()` function (lines 1263–1277)
10. Remove function definitions (lines 1289–1354, 1378–1425)
- *Depends on Step 2*

### Step 5: Remove Test Case from tests.zig
- Lines 1278–1286: Remove `test "news_sources: init and empty cache"`
- *Depends on Step 3*

### Step 6: Update .env.example (INDEPENDENT)
- Remove line 6: `POLYMARKET_PRIVATE_KEY=...`
- Remove line 9: `KALSHI_API_KEY=...`
- *Can run in parallel with other steps*

### Step 7: Verification
- Run `zig build` — should complete without errors
- Run `zig build test` — all tests pass, news_sources test removed
- Grep `main.zig` for: `poly`, `kalshi`, `gamma`, `clob`, `news`, `probability`, `scanner` — should find 0 results
- Grep `tests.zig` for same keywords — should find 0 results
- *Depends on Steps 2–6*

---

## Dependency Graph

```
Step 1 (Delete Files)
    ↓
    ├─→ Step 2 (Remove imports from main.zig)
    │   ↓
    │   └─→ Step 4 (Remove code blocks from main.zig)
    │       ↓
    │       └─→ Step 7 (Verification)
    │
    └─→ Step 3 (Remove imports from tests.zig)
        ↓
        └─→ Step 5 (Remove tests)
            ↓
            └─→ Step 7 (Verification)

Step 6 (Update .env.example) — can run in parallel with 1–5
```

---

## Rollback Plan
- Phase 1 is destructive (no new code added, only deletions).
- Rollback: `git checkout HEAD -- zig/src/*.zig .env.example` will restore all deleted files.
- Recommended: Commit Phase 1 changes to a branch (e.g., `phase-1-cleanup`) before proceeding to Phase 2.

---

## Notes
- After Phase 1, the Zig codebase will not compile standalone (missing auth, market data, strategy modules).
- Phase 2 must immediately follow to add Hyperliquid integration.
- No database migrations or IPC changes in Phase 1 — purely code cleanup.
