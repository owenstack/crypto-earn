## Plan: Phase 2 — Engine + Remaining Gateways

**TL;DR**: Implement the arbitrage engine that consumes BBO updates, maintains per-exchange state, evaluates spreads across all 4 exchanges, validates against profit thresholds, and emits the best opportunity per cycle. Add Coinbase and OKX adapters. Test with deterministic mock data in a dedicated `tests/` folder.

### Steps

**Phase A: Engine Architecture** (preparatory)
- Define engine module structure and threading model (single consumer from BBO channel)
- Document state table design: thread-safe map from (exchange, pair) → BboUpdate
- Confirm opportunity emission model to bounded alert channel

**Phase B: BBO State Table** (blocks Phase C)
- Implement thread-safe `BboStateTable` with methods: `getLatest()`, `set()`, `iterate()`
- Unit tests in `tests/engine.zig` for state updates, concurrent reads, multi-pair isolation

**Phase C: Spread Evaluation Engine** (depends on B)
- Implement `ArbEngine` with `evaluateAllPairs(pair)` logic
- Check spreads: sell_bid > buy_ask AND profit_pct ≥ min_profit_pct
- Return best opportunity (highest profit %) or null
- Implement `processBboUpdate()` to update state and emit opportunities
- Comprehensive unit tests: valid/invalid spreads, threshold rejection, multi-pair isolation, best-opportunity logic

**Phase D: Coinbase Adapter** (parallel with C)
- Implement `coinbase.zig` following Binance/ByBit pattern
- Fetch: `/api/v2/products/{product_id}/ticker` (e.g., `BTC-USDC`)
- Parse: `bid`, `ask`, `size`, `time` → validate and normalize to `BboUpdate`
- Unit tests in `tests/adapters.zig` with fixture JSON

**Phase E: OKX Adapter** (parallel with D)
- Implement `okx.zig` following same adapter contract
- Fetch: `/api/v5/market/ticker?instId={INST_ID}` (e.g., `BTC-USDC`)
- Parse nested response: `bidPx`, `askPx`, `bidSz`, `askSz` from data[0] → normalize to `BboUpdate`
- Unit tests in `tests/adapters.zig` with fixture responses

**Phase F: Module Wiring** (depends on B, C, D, E)
- Update `gateway.zig` imports/exports for Coinbase and OKX
- Update `root.zig` to export engine module
- Preserve `--verify-phase1` behavior in main.zig

**Phase G: Integration Testing** (depends on C, D, E, F)
- Create `tests/mock_data.zig` with fixture BBO updates (multi-exchange, multi-pair scenarios)
- Create `tests/engine.zig` with test groups:
  - State table: updates, concurrent reads, multi-pair isolation
  - Spread detection: inject fixtures, verify `ArbOpportunity` produced for known spreads
  - Threshold rejection: same fixtures, different `min_profit_pct`, verify no opportunity emitted below threshold
  - Multi-pair isolation: update pair A, verify pair B state unchanged
  - Best-opportunity: inject overlapping spreads, verify only highest profit_pct emitted
  - State consistency: verify state table reflects all recent BBOs correctly
- Create `tests/adapters.zig` for Coinbase/OKX adapter tests (JSON parsing, error paths, edge cases)
- Add `--verify-phase2-spread-detection` flag to main.zig for deterministic mock integration tests
- Ensure all tests are deterministic (no randomness, no real network calls)

**Phase H: Verification** (depends on G)
- `zig build test` passes all Phase 2 tests
- `zig build run -- --verify-phase2-spread-detection` demonstrates mock spread detection
- Confirm `--verify-phase1` still works (no regression)

### Relevant Files

**New files to create:**
- `src/engine.zig` — ArbEngine struct, BboStateTable, spread evaluation logic
- `src/gateway/coinbase.zig` — Coinbase REST adapter
- `src/gateway/okx.zig` — OKX REST adapter
- `tests/mock_data.zig` — Fixture BBO updates and integration test data
- `tests/engine.zig` — Engine unit and integration tests
- `tests/adapters.zig` — Coinbase and OKX adapter unit tests

**Existing files to modify (minimal):**
- `src/gateway.zig` — add imports/exports for new adapters if needed
- `src/root.zig` — export engine module if not already public
- `build.zig` — add test targets if needed
- `src/main.zig` — add `--verify-phase2-spread-detection` flag

### Verification Checklist

1. `zig build test` passes all engine, adapter, and integration tests
2. Mock spread detection correctly identifies valid/invalid opportunities
3. Adapter tests validate parsing, error handling for Coinbase and OKX
4. Multi-pair isolation: BBO to one pair doesn't affect others
5. `--verify-phase2-spread-detection` runs successfully with fixture data
6. `--verify-phase1` still works (regression check)

### Finalized Decisions

**Threading Model**
- Single-threaded for Phase 2: Engine runs synchronously in tests; deterministic and easier to validate. Background thread spawning deferred to Phase 6 hardening after Phase 3-5 components (risk gate, notifiers) are ready.

**Mock Channel**
- Real bounded channel in tests: Use actual bounded channel with capacity 256+ to avoid drops and stay close to production behavior. Log any drops for visibility during testing.

**Test Organization**
- Dedicated `tests/` folder: All Phase 2 unit tests, adapter tests, and integration tests live in `tests/` subdirectory with named test files (`tests/engine.zig`, `tests/adapters.zig`, `tests/mock_data.zig`) for clarity and maintainability.