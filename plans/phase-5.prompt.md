## Plan: Phase 5 Bot Control Only

Implement only Phase 5 command/control work by extending the existing TS Telegram control plane and Zig IPC server for runtime config updates, P&L queries, and distinct pause behavior. Defer approval mode as requested, while preserving current Phase 4 event push and prior command behavior.

**Steps**
1. Phase A: Lock protocol contract for Phase 5 control messages.
2. Add new IPC request/response message types in TypeScript and Zig for config.set, pause, and pnl.query/pnl.response.
3. Define payload schemas and typed helpers in TS IPC client for configSet(), pause(), and pnl(window).
4. Dependency: Steps 2-3 must complete before command handlers can compile.
5. Phase B: Implement Zig-side handlers and persistence.
6. In Zig IPC dispatcher, add handlers for config.set, pause, and pnl.query with strict payload validation and explicit error responses.
7. Add persistent runtime config storage in SQLite using a dedicated config table plus config_changes audit entry writes; load effective runtime config at startup and update atomically on config.set.
8. Wire pause to stop strategy evaluation while keeping existing open orders untouched; keep halt semantics unchanged (halt still cancels all open orders).
9. Add P&L query path for windows today, 7d, 30d, all using fills/positions/balance snapshots; return realized P&L, win/loss counts, average win/loss, and current unrealized P&L summary for empty windows.
10. Dependency: Step 7 blocks risk-gate hot-reload correctness, so complete before exposing /config set in Telegram.
11. Phase C: Implement Telegram command UX.
12. Extend /config command to support get and set subcommands with argument validation and human-readable confirmations/errors.
13. Add /pause command and keep /resume behavior explicit; update /start help text and status wording to reflect paused state.
14. Add /pnl command parser for today, 7d, 30d, all with formatted monospace-friendly output.
15. Dependency: Step 12-14 require completed IPC types/client helpers from Phase A.
16. Phase D: Testing and regressions.
17. Expand TS unit tests for IPC type coverage and command parsing/guard behavior for /config set, /pause, /pnl.
18. Add Zig tests for IPC dispatch and DB-backed config persistence/P&L query window logic.
19. Validate no regressions in existing commands (/trade, /cancel, /halt, /resume, /strategy, event.subscribe).
20. Parallelism note: Steps 17 (TS tests) and 18 (Zig tests) can run in parallel once implementation is complete.

**Relevant files**
- /home/owenstack/repos/personal/cex-zig/ts/src/ipc/types.ts — add RequestMessageType/ResponseMessageType entries and Phase 5 payload interfaces.
- /home/owenstack/repos/personal/cex-zig/ts/src/ipc/client.ts — add typed helpers for configSet, pause, and pnl query.
- /home/owenstack/repos/personal/cex-zig/ts/src/telegram/bot.ts — add /config set, /pause, /pnl command handlers and update command help text.
- /home/owenstack/repos/personal/cex-zig/ts/test/ipc-types.test.ts — assert new request/response types are accepted by makeRequest usage.
- /home/owenstack/repos/personal/cex-zig/ts/test/ipc-client.test.ts — add helper-level request/response tests for new control messages.
- /home/owenstack/repos/personal/cex-zig/ts/test/telegram-bot.test.ts — add command-level tests for allowlist, parsing, and usage errors.
- /home/owenstack/repos/personal/cex-zig/zig/src/ipc_types.zig — define new type constants for config.set/pause/pnl query responses.
- /home/owenstack/repos/personal/cex-zig/zig/src/ipc.zig — implement dispatch branches with validation and structured responses.
- /home/owenstack/repos/personal/cex-zig/zig/src/db.zig — add config key/value persistence methods, config audit write, and P&L window query helpers.
- /home/owenstack/repos/personal/cex-zig/zig/src/order_manager.zig — add paused state handling separate from halted for non-canceling pause behavior.
- /home/owenstack/repos/personal/cex-zig/zig/src/strategy_engine.zig — gate strategy evaluation on paused state.
- /home/owenstack/repos/personal/cex-zig/db/migrations/002_phase2_orders_risk.sql — reference existing tables used in P&L derivation; add a new migration file if config table is introduced.

**Verification**
1. Run TypeScript checks: bun run typecheck from /home/owenstack/repos/personal/cex-zig/ts.
2. Run TS tests: bun test from /home/owenstack/repos/personal/cex-zig/ts.
3. Run Zig tests/build: zig build test and zig build from /home/owenstack/repos/personal/cex-zig/zig.
4. Manual IPC smoke: start Zig and TS, then verify /config get, /config set max_position_usd 250, /pause, /resume, and /pnl today from Telegram.
5. Verify semantics: after /pause, strategy engine stops emitting new orders while pre-existing open orders remain open; after /halt, open orders are cancelled.
6. Restart services and verify persisted config values survive restart and are returned by /config get.
7. Regression pass for existing commands and event push notifications.

**Decisions**
- In scope: Phase 5 only, with config.set persistence, pause semantics distinct from halt, and /pnl windows.
- Out of scope: Approval mode inline keyboards and approval queue/state machine (deferred P1).
- Config persistence is required across restarts and must be auditable.
- Pause semantics: stop strategy evaluation only, do not cancel existing orders.

**Further Considerations**
1. Migration strategy: introduce a dedicated migration 004 for runtime config table and indexes to avoid editing historical migration intent.
2. P&L source of truth: prefer fills plus position close events for realized values, with clear fallback when historical close linkage is incomplete.
3. Output formatting: keep Telegram /pnl response compact and deterministic to simplify snapshot testing.