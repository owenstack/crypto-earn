## Plan: Phase 0 Foundation Delivery

Deliver only Phase 0 from the PRD: infrastructure + split architecture setup (zig and ts), SQLite WAL, and local Zig↔Node IPC using JSON-lines over UNIX domain sockets. The approach is to build thin but runnable vertical slices first (boot, connect, read/write), then expand to live status/positions/orders surfaces without implementing strategy/risk/order execution logic from later phases.

**Steps**
1. Phase A - Restructure and bootstrap repositories (parallel start)
1.1 Move current Zig project into zig/ while preserving buildability; keep current entry and module behavior intact. Depends on none.
1.2 Initialize ts/ project with Bun + TypeScript workspace, lint/test skeleton, env loader, and process entrypoints for Telegram service and dashboard service. Parallel with 1.1.
1.3 Add top-level shared operational assets: .env.example, scripts/ orchestration, and README phase map. Parallel with 1.1 and 1.2.

2. Phase B - Infrastructure and deployment foundation (parallel with Phase C where possible)
2.1 Add shell provisioning scripts for VPS (Ubuntu 24.04 and AL2023 compatible paths): user/bootstrap, Zig install, Bun install, SQLite/runtime deps, service registration.
2.2 Add systemd units for zig engine and ts interface with ordering and restart policy; ts service must require zig service availability.

3. Phase C - SQLite WAL and persistence baseline
3.1 Define initial schema and migration runner for markets, positions, orders, fills, strategy_signals, config_changes, and logs (minimum fields only, extensible).
3.2 Implement Zig-side DB init that enforces PRAGMA journal_mode=WAL, synchronous=NORMAL, busy_timeout, and boot-time migration execution.
3.3 Implement TS read-path using and/or drizzle-orm DB client for dashboard/telegram queries with safe read-only access patterns.

4. Phase D - Local IPC contract and transport (critical path)
4.1 Define JSON-lines request/response + event envelope contract and version field; include correlation_id, timestamp, type, and payload.
4.2 Implement Zig UNIX domain socket server: lifecycle, accept loop, request dispatch stubs, heartbeat endpoint, and graceful shutdown cleanup of socket path.
4.3 Implement TS UNIX socket client with reconnect/backoff, request timeout handling, and subscription stream handling.
4.4 Add contract tests validating framing, malformed input behavior, and compatibility between zig and ts.

5. Phase E - Phase-0 functional surface (read-only control plane)
5.1 Telegram bot skeleton with authenticated chat allowlist and commands routed through IPC: status, portfolio, orders, config get.
5.2 Web dashboard with authentication gate and live status + open positions/orders tables (read-only), fed by IPC and/or SQLite reads.
5.3 Implement structured logging pipeline with secret redaction and recent log stream endpoint used by dashboard panel.

6. Phase F - Integration hardening and handoff
6.1 End-to-end local smoke: start zig, start ts, run command roundtrip, see dashboard updates, confirm DB WAL and concurrent read/write behavior.
6.2 EC2 smoke via scripts/Terraform: deploy, start services under systemd, verify health endpoints and IPC connectivity.
6.3 Freeze Phase 0 boundary: explicitly defer strategy logic, CLOB signing, risk checks, and execution automation to Phase 1+.

**Dependency and Parallelism Notes**
1. Can run in parallel: 1.1, 1.2, 1.3, 2.1, 2.2, and schema drafting in 3.1.
2. Blocks: 4.2 and 4.3 both depend on 4.1 contract finalization.
3. Blocks: 5.1 and 5.2 depend on 4.2/4.3 transport being stable.
4. Preferred critical path: 1.1 → 3.2 → 4.1 → 4.2/4.3 → 5.1/5.2 → 6.1.

**Relevant files**
- /home/owenstack/repos/personal/cex-zig/build.zig — migrate into zig/ and preserve executable wiring.
- /home/owenstack/repos/personal/cex-zig/build.zig.zon — migrate and extend dependencies for DB/IPC needs.
- /home/owenstack/repos/personal/cex-zig/src/main.zig — convert into service bootstrap for DB + IPC server init.
- /home/owenstack/repos/personal/cex-zig/src/root.zig — keep module root and adapt to new package layout.
- /home/owenstack/repos/personal/cex-zig/plan.md — source-of-truth requirements used to scope Phase 0 boundary.
- New roots to create: /home/owenstack/repos/personal/cex-zig/zig, /home/owenstack/repos/personal/cex-zig/ts, /home/owenstack/repos/personal/cex-zig/infrastructure, /home/owenstack/repos/personal/cex-zig/scripts, /home/owenstack/repos/personal/cex-zig/systemd, /home/owenstack/repos/personal/cex-zig/db, /home/owenstack/repos/personal/cex-zig/config.

**Verification**
1. Zig build passes from zig/: zig build -Doptimize=ReleaseFast.
2. TS build/typecheck passes from ts/: bun ci && bun run build && bun run typecheck.
3. IPC loopback test: TS client sends status request, receives response from Zig in expected envelope format.
4. SQLite checks: PRAGMA journal_mode returns wal; concurrent Zig write + TS read test runs without lock failures.
5. Telegram smoke: authorized chat can call status/portfolio/orders/config get; unauthorized chat is rejected.
6. Dashboard smoke: authenticated session shows live status plus open positions/orders table updates.
7. Systemd smoke on EC2: both services restart cleanly; ts reconnects after zig restart.

**Decisions**
- Repo layout: split into zig/ and ts/.
- IPC format for Phase 0: JSON-lines over UNIX domain sockets.
- Dashboard scope in Phase 0: include live positions/orders tables (read-only).
- Infrastructure scope in Phase 0: shell scripts plus Terraform starter.
- Included: architecture scaffolding, deployment foundation, DB/IPC baseline, read-only control plane.
- Excluded: strategy logic, risk gate enforcement rules, CLOB signed execution, and advanced trading automation.

**Further Considerations**
1. Keep JSON-lines for Phase 1 unless measured IPC p95 exceeds latency budget; only then migrate to MessagePack.
2. Add a lightweight shared schema definition process to prevent zig/ts contract drift (versioned message types + compatibility test in CI).
3. Decide early whether dashboard pulls primarily from IPC or SQLite snapshots to avoid duplicate read paths.