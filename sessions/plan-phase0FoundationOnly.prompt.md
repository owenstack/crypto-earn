## Plan: Phase 0 Foundation Only

Deliver only the foundation layer now: build/test harness alignment, core domain types, bounded channel abstraction, structured logger, and validated configuration with real TOML parsing plus env-secret overrides. Exclude all fetchers, engine logic, risk strategy execution, notifier posting, metrics endpoints, and signal lifecycle behavior beyond what is required for compile/test scaffolding.

**Steps**
1. Phase A: Baseline and boundaries
2. Confirm and preserve the existing build graph and dual test wiring in build.zig as the execution harness for Phase 0 deliverables only.
3. Freeze scope boundaries in code comments and module docs so later phases do not leak into current implementation (no exchange adapters, no arb loop, no webhooks, no runtime worker topology).
4. Phase B: Core contracts (blocks Phase C and D)
5. Introduce the core domain model module with explicit, allocator-free value types for exchange identity, token pair, price level, BBO update, opportunity snapshot, and risk metrics snapshot.
6. Include multi-pair scaffolding in type contracts now (collection shape and validation rules), while keeping runtime behavior for multi-pair processing out of scope in Phase 0.
7. Add unit tests for all invariants that can be validated without I/O (required fields, value ranges, profit/notional helper math boundaries, timestamp monotonic assumptions as contract-level checks).
8. Phase C: Foundation runtime primitives (depends on Phase B)
9. Add bounded channel primitive(s) with explicit capacity, deterministic backpressure behavior, and clear ownership semantics suitable for later MPSC/SPMC usage.
10. Validate channel behavior through deterministic tests: enqueue/dequeue order, full-capacity policy, empty reads, and concurrency safety expectations relevant to Zig threading primitives.
11. Add structured JSON logging primitive with stable schema fields (timestamp, level, component, msg, contextual key-values) and level filtering.
12. Add logger tests for schema correctness, escaping, and level gating.
13. Phase D: Configuration foundation (depends on Phase B, parallel with Step 11-12)
14. Implement real TOML-based startup config parsing for Phase 0-required keys, including defaults where specified by PRD.
15. Implement environment-variable override precedence for secret fields and validate required/optional semantics.
16. Add explicit startup validation rules with descriptive failure outcomes for missing/out-of-range values.
17. Add config parser/validator tests covering valid file load, invalid TOML, missing required fields, range violations, and env override precedence.
18. Phase E: Module wiring and test harness completion (depends on Phase C and D)
19. Replace placeholder public exports with proper module re-exports from root.zig so package consumers can import the new foundation APIs.
20. Convert main.zig into a minimal startup scaffold for Phase 0 that exercises config load and logger initialization without implementing runtime bot behavior.
21. Remove placeholder demo tests and add a focused Phase 0 smoke test that verifies module linkage and initialization path.
22. Ensure zig build test passes for both module and executable test targets.

**Parallelism and dependencies**
1. Phase B is a hard prerequisite for channel/config contracts.
2. In Phase C and D, logger work can proceed in parallel with TOML parser work after types are stable.
3. Final wiring in Phase E must wait until modules and tests from prior phases are in place.

**Relevant files**
- /home/owenstack/repos/personal/cex-zig/build.zig — preserve and, if needed, minimally tune test/build steps for Phase 0 verification.
- /home/owenstack/repos/personal/cex-zig/src/root.zig — replace placeholder API with Phase 0 module exports.
- /home/owenstack/repos/personal/cex-zig/src/main.zig — replace placeholder behavior with Phase 0 startup smoke scaffold.
- /home/owenstack/repos/personal/cex-zig/src (new foundation modules) — add config/types/channel/log modules and their tests.

**Verification**
1. Run zig build test and confirm both root-module tests and executable-module tests pass.
2. Add targeted unit test groups and run them through zig build test to validate channel semantics, TOML parsing, env precedence, and logger schema.
3. Run zig build run with a valid config and verify startup path initializes logger + config cleanly and exits/continues per scaffold design.
4. Run zig build run with intentionally invalid config values and verify fail-fast behavior and descriptive error output.
5. Run a short sanitizer pass (address) on test target to validate memory-safety assumptions for foundation modules.

**Decisions**
- Included: strict Phase 0 only.
- Included: real TOML parsing in Phase 0.
- Included: multi-pair scaffolding at type/config level only.
- Included: forward-compatible API design for future websocket/metrics phases.
- Excluded: all Phase 1+ behavior implementation, including exchange integrations, arbitrage evaluation loop, risk strategy execution, notifier posting, and observability endpoints.

**Further Considerations**
1. TOML parser choice should stay within Zig standard capabilities first; only introduce external dependency if standard approach materially blocks schema requirements.
2. Define a strict config schema version field now to ease backward-compatible changes in later phases.
3. Add a tiny fixture set for config tests early to keep future phase regressions visible.