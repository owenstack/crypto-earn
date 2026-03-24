## Plan: Phase 1 Gateway + HTTP Only

Implement only the Phase 1 milestone by adding a reusable HTTP layer and two exchange gateway adapters (Binance and ByBit) that produce validated BBO updates. Keep scope limited to data-fetch plumbing and verification; do not implement engine/risk/notifier/metrics features from later phases.

**Steps**
1. Phase A: Lock scope and align contracts
2. Confirm Phase 1 boundaries from the PRD milestone: HTTP wrapper + gateway contract + Binance/ByBit adapters + live BBO verification; explicitly exclude Phase 2+ runtime features (engine loop, remaining exchanges, risk/notifier/metrics).
3. Reuse existing domain contracts for outputs and validation (`BboUpdate`, `PriceLevel`, exchange identifiers, config timeout/backoff fields, logger schema).
4. Phase B: HTTP foundation (blocks gateway implementations)
5. Add a shared HTTP module with persistent client lifecycle support, per-request timeout enforcement, JSON payload retrieval/parsing hooks, and explicit error mapping (timeout, status, malformed payload, transport).
6. Keep connection behavior compatible with persistent HTTP/1.1 + keep-alive expectations and avoid hidden allocations beyond explicit allocator inputs.
7. Add unit tests for HTTP module behavior using deterministic fixtures/mocks for success, timeout, non-2xx status, and malformed JSON.
8. Phase C: Gateway contract and adapters (depends on Phase B)
9. Define a gateway interface contract for exchange adapters that returns normalized `BboUpdate` values and a consistent typed error surface.
10. Implement Binance adapter: request ticker endpoint, parse bid/ask/size fields, normalize into validated `BboUpdate`, include monotonic fetch timestamp, and surface parse/transport/status failures.
11. Implement ByBit adapter with equivalent normalization and validation flow, handling its response schema differences from Binance.
12. Add adapter-focused tests for parsing and normalization edge cases (missing fields, non-finite values, bid/ask inversion, zero/negative sizes).
13. Phase D: Wiring and exposure (depends on Phase C)
14. Export the new HTTP and gateway modules through the package root so they are available to subsequent phases without additional refactoring.
15. Keep `main.zig` changes minimal and phase-safe: only add lightweight verification entrypoint/harness behavior needed to exercise Phase 1 fetching, without introducing engine/risk/notifier orchestration.
16. Phase E: Phase-1 verification and acceptance
17. Add a live-fetch verification path that performs real Binance + ByBit BBO fetches and validates each result with existing `BboUpdate` invariants.
18. Verify request timeout behavior and retry/backoff expectations at the gateway layer in a way that does not require Phase 2 engine threading.
19. Ensure project tests pass and Phase 1 verification can run independently of later-phase modules.

**Dependencies and parallelism**
1. Phase B must complete before Phase C adapter implementation.
2. Binance and ByBit adapter work can run in parallel once the gateway contract is finalized.
3. Phase D wiring waits on Phase C; Phase E verification waits on B/C/D.

**Relevant files**
- `/home/owenstack/repos/personal/cex-zig/src/types.zig` — reuse `BboUpdate`/price invariants as adapter output contract.
- `/home/owenstack/repos/personal/cex-zig/src/config.zig` — reuse timeout/backoff/poll settings and existing validation approach.
- `/home/owenstack/repos/personal/cex-zig/src/log.zig` — reuse structured logging patterns for fetch success/failure observability.
- `/home/owenstack/repos/personal/cex-zig/src/root.zig` — expose new phase-1 modules publicly.
- `/home/owenstack/repos/personal/cex-zig/src/main.zig` — keep to minimal phase-1 verification harness updates only.
- `/home/owenstack/repos/personal/cex-zig/build.zig` — include any needed build/test wiring for phase-1 verification targets.

**Verification**
1. Run `zig build test` and confirm all unit tests pass, including new HTTP and gateway parsing/error-path tests.
2. Run a phase-1 verification command/path to fetch live BBO data from Binance and ByBit, then confirm each payload normalizes into valid `BboUpdate` values.
3. Validate timeout handling by forcing a low timeout and confirming deterministic timeout errors are surfaced and logged cleanly.
4. Confirm no Phase 2+ modules are required for Phase 1 verification to pass.

**Decisions**
- Included: shared HTTP abstraction, gateway contract, Binance + ByBit adapters, live BBO verification.
- Included: normalized typed errors and parser hardening for malformed exchange responses.
- Excluded: engine state table, spread evaluation loop, Coinbase/OKX adapters, risk gate, notifier pipeline, metrics/health endpoints.
- Assumption: live verification uses public endpoints (no authenticated order routes), with optional environment overrides if endpoint URLs differ by environment.

**Further Considerations**
1. Keep adapter outputs strictly normalized at boundary so later phases consume one canonical BBO shape.
2. If Zig stdlib HTTP API differences exist by version, pin the implementation to current project Zig toolchain conventions in `build.zig`/`build.zig.zon` rather than introducing cross-version shims in Phase 1.
3. Keep retry policy implementation shallow in Phase 1 (single adapter-layer policy) and defer advanced orchestration retry strategies to Phase 2 runtime threading work.
