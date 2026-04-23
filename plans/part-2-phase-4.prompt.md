## Implement Phase 4 — Hardening and Test Coverage

This plan covers only Phase 4 from the PRD, focusing on reconciliation performance, fill poller latency, retry hardening, runtime config validation, and test coverage. No changes will be made to other phases or unrelated features.

---

**Steps**

### 1. Reconciliation Performance and Timeout Enforcement
1. Update the reconciliation logic to support paginated `GET /orders` (max 25 pages, 200 orders/page).
2. Enforce a hard timeout of 30 seconds for the reconciliation process.
3. Add a benchmark test using a mock CLOB with 500 orders to verify completion within 30 seconds.

### 2. Fill Poller Latency Measurement
1. Add a `detected_at INTEGER` column to the `fills` table via `MIGRATION_007`.
2. Update `insertFill()` to populate `detected_at` with the current timestamp.
3. Log `fill_latency_ms = detected_at * 1000 - filled_at_ms` for each fill using `log.info`.

### 3. Retry Hardening for Fill Poller HTTP Calls
1. Reuse `backoffDelayMs()` from `order_manager.zig` for all retry paths in `fill_poller.zig`.
2. Add a circuit-breaker to `FillPoller` that pauses polling for 60 seconds after 5 consecutive HTTP failures.

### 4. Runtime Config Validation for Probability Source
1. Add a `/config validate` Telegram subcommand that triggers a new IPC message `config.validate`.
2. Implement validation logic for probability source config: valid URL, poll interval (10–3600s), non-empty field names.
3. Add `config.validate` and `config.validate.response` to `ipc_types.zig`.

### 5. Test Coverage Enforcement
1. Add tests in `tests.zig` for all new functions in `fill_poller.zig` and `probability_provider.zig`.
2. Add tests for each new migration (including `MIGRATION_007` and any others from this phase).
3. Ensure `zig build test` is run in CI and fails the build on any test failure.

---

**Relevant files**
- `zig/src/fill_poller.zig` — Update fill poller logic, add retry/circuit-breaker, latency logging.
- `zig/src/order_manager.zig` — Reuse `backoffDelayMs()`.
- `zig/src/db.zig` — Add/modify migrations for `fills` table and others as needed.
- `zig/src/probability_provider.zig` — Add/modify config validation logic.
- `zig/src/ipc_types.zig` — Add new IPC message types.
- `ts/src/telegram/bot.ts` — Add `/config validate` command handler.
- `zig/src/tests.zig` — Add/expand tests for new logic and migrations.
- CI config (if present) — Ensure `zig build test` is enforced.

---

**Verification**
1. Run reconciliation against a mock CLOB with 500 orders; confirm completion within 30 seconds.
2. Confirm `detected_at` is recorded and `fill_latency_ms` is logged for each fill.
3. Simulate HTTP failures in fill poller; verify circuit-breaker pauses polling after 5 failures.
4. Use Telegram `/config validate` to check config validation and IPC response.
5. Run all tests with `zig build test` and confirm all pass; CI fails on test failure.

---

**Decisions**
- Only Phase 4 tasks are included; no changes to other phases.
- Per PRD, paginated reconciliation, latency logging, retry/circuit-breaker, config validation, and test coverage are in scope.
- All DB schema changes use the existing migration pattern.

---

**Further Considerations**
1. If any migrations from earlier phases are not yet applied, ensure migration numbering does not conflict.
2. If CI is not currently set up to run `zig build test`, add this step to the pipeline.
3. For `/config validate`, clarify if validation errors should block strategy execution or only warn.