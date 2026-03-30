## Plan: Phase 7 Deployment And Hardening

Deliver Phase 7 only by adding production deployment orchestration, EC2/systemd runtime hardening, end-to-end integration validation, latency profiling, and operational documentation for a single-node EC2 deployment (systemd + local SQLite WAL). This plan explicitly excludes new trading features from earlier phases.

**Steps**
1. Phase A: Scope lock and acceptance mapping
1. Map PRD Phase 7 deliverables and NFRs to executable checks: end-to-end integration, systemd-on-EC2 readiness, latency profiling, and documentation updates. *blocks all later steps*
1. Define explicit exclusions: no new strategy/risk/order/telegram feature expansion beyond what is required to deploy and harden existing functionality.

2. Phase B: Deployment orchestration for single-node EC2
1. Add a deployment orchestrator script to run: prerequisite checks, build, migration application, service install/reload, enable/start, and post-start smoke checks. *depends on Phase A*
1. Add a migration runner script that applies SQL migrations in deterministic order with idempotent behavior and failure-safe exit codes.
1. Add a systemd installer/helper script that copies unit files into `/etc/systemd/system`, runs `daemon-reload`, enables units, and supports controlled restart flow.
1. Extend provisioning flow to avoid duplicate Bun install behavior, enforce required package checks, and produce clear operator output for failures.

3. Phase C: Service hardening and runtime safeguards
1. Harden `cex-control.service` to run as unprivileged service user instead of root, with filesystem and capability restrictions aligned to engine service constraints. *depends on Phase B*
1. Add service directives for startup/shutdown correctness: bounded restart behavior, timeout policies, and clean stop semantics.
1. Add environment and permissions guardrails for `.env`, IPC socket path, and writable directories.
1. Add non-invasive health/smoke checks to validate engine socket availability, dashboard auth response, and DB accessibility after startup.

4. Phase D: End-to-end integration test harness
1. Create an E2E test harness that validates full process integration for local/CI-like runs: service startup sequence, IPC request/response, dashboard authenticated read endpoints, and DB read/write visibility. *depends on Phase B and C*
1. Add failure-path tests for critical hardening paths: engine offline fallback, auth rejection, migration failure handling, and controlled service restarts.
1. Add a Phase 7 verification command path (single command or script) that runs core tests and smoke checks in the required order.

5. Phase E: Latency profiling and regression gates
1. Add lightweight timing instrumentation and profiling scripts for key paths required by PRD targets: WebSocket-event-to-order-dispatch, Telegram-command-to-Zig-response, and fill-event-to-notification. *parallel with Phase D once instrumentation points are agreed*
1. Add a report artifact (stdout or file) with p50/p95/p99 and max latency metrics for each target path.
1. Add threshold checks that clearly mark pass/fail against NFR targets and flag regressions.

6. Phase F: Documentation and runbook completion
1. Update root documentation with Phase 7 deployment instructions for EC2 systemd operations, including prerequisites, bootstrap, deploy, verify, rollback basics, and troubleshooting. *depends on Phases B-E*
1. Document operational commands: start/stop/restart/status/logs, migration workflows, and post-deploy validation flow.
1. Document security boundary and exposure model: dashboard is read-only, Telegram remains control surface, and recommended network/firewall posture for single-node deployment.

7. Phase G: Final acceptance pass
1. Run full Phase 7 checklist and record pass/fail for each required deliverable and NFR-linked gate.
1. Verify no scope creep from prior phases was introduced.
1. Produce a concise release readiness summary with known residual risks and deferred items.

**Relevant files**
- `/home/owenstack/repos/personal/cex-zig/scripts/build.sh` — keep as shared build primitive and integrate into deploy flow.
- `/home/owenstack/repos/personal/cex-zig/scripts/provision.sh` — tighten provisioning behavior and prerequisites handling.
- `/home/owenstack/repos/personal/cex-zig/systemd/cex-engine.service` — validate/extend runtime constraints and startup dependencies.
- `/home/owenstack/repos/personal/cex-zig/systemd/cex-control.service` — remove root execution and align hardening directives.
- `/home/owenstack/repos/personal/cex-zig/db/migrations/001_initial.sql` — migration chain baseline.
- `/home/owenstack/repos/personal/cex-zig/db/migrations/002_phase2_orders_risk.sql` — migration chain continuity.
- `/home/owenstack/repos/personal/cex-zig/db/migrations/004_phase5_runtime_config.sql` — migration chain continuity and runtime config table.
- `/home/owenstack/repos/personal/cex-zig/ts/src/dashboard/server.ts` — leverage existing authenticated API routes for smoke/E2E validation.
- `/home/owenstack/repos/personal/cex-zig/ts/src/index.ts` — runtime entrypoint used by service and integration checks.
- `/home/owenstack/repos/personal/cex-zig/ts/package.json` — test/start scripts used by verification gates.
- `/home/owenstack/repos/personal/cex-zig/zig/build.zig` — Zig build/test integration for release validation.
- `/home/owenstack/repos/personal/cex-zig/README.md` — expand Phase 7 deployment and hardening runbook guidance.

**Verification**
1. Build gates: run Zig release build and TS build/typecheck successfully.
2. Migration gate: run migration runner on a clean DB and on an already-migrated DB; both must be deterministic and safe.
3. Service gate: install/start systemd units on EC2 and confirm both units are active with expected dependency order.
4. API gate: authenticated dashboard endpoints return expected read-only payloads; unauthenticated requests fail closed.
5. IPC gate: control plane can reach engine socket; offline engine behavior is graceful and observable.
6. Latency gate: profiling output demonstrates compliance with NFR thresholds or clearly identifies failures.
7. Stability gate: restart and crash-recovery scenarios preserve process health and DB consistency.
8. Documentation gate: runbook steps can be followed end-to-end on a fresh node without ad hoc commands.

**Decisions**
- Scope: Phase 7 only, with full hardening depth.
- Deployment target: single-node EC2 with local SQLite WAL and systemd.
- Includes: deploy automation, migration automation, service hardening, E2E checks, latency profiling, and docs.
- Excludes: new trading strategy features, new Telegram product features, and multi-node/distributed architecture.

**Further Considerations**
1. Migration numbering continuity (`002` to `004`) should be handled explicitly in migration runner logic to avoid false assumptions.
2. Decide whether profiling artifacts are ephemeral CI logs or persisted release evidence in-repo.
3. Consider optional AWS integrations (CloudWatch/Secrets Manager) as post-Phase 7 enhancements, not blockers.