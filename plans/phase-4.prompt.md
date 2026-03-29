## Plan: Phase 4 Telegram Event Bridge

Phase 4 in this codebase is mostly complete for command-driven Telegram control. The remaining milestone-critical gap is event-driven notifications (webhook or equivalent listener path) so the Telegram bot can push order or risk updates without operator polling. This plan implements only that missing slice and avoids Phase 5+ command expansion.

**Steps**
1. Define Phase 4 boundary and acceptance checks
1.1 Lock scope to: Grammy runtime present, existing read commands unchanged, add event-driven push pipeline only. Exclude new control commands and dashboard features.
1.2 Translate milestone acceptance into concrete checks: receive engine event, map to Telegram message, deliver to allowed chats, survive temporary IPC disconnects.

2. Add IPC event subscription contract (blocks downstream work)
2.1 Extend Zig and TS IPC type registries with subscription messages and event payload envelope for order and risk lifecycle events.
2.2 Keep backward compatibility for request or response flows already used by status or portfolio or orders commands.
2.3 Document event schema fields used by Telegram formatter (event type, market or order identifiers, reason, timestamp, optional pnl values).

3. Implement Zig-side event publisher over UNIX socket
3.1 In Zig IPC server, add subscriber tracking for connected clients that opt into event stream mode.
3.2 Emit structured events from existing order manager and risk rejection points to all active subscribers.
3.3 Ensure events are best-effort non-blocking so slow clients cannot stall trading loop or command responses.

4. Implement TS-side event listener in IPC client
4.1 Extend IPC client parser to route non-correlated envelopes (events without pending request id match) to registered handlers.
4.2 Add subscribe or unsubscribe API in IPC client for event listeners with reconnect re-subscription behavior.
4.3 Add bounded in-memory queue or retry-safe handling for short disconnect windows to avoid dropping critical notifications during reconnect churn.

5. Wire Telegram push notifications
5.1 In Telegram module, register event listener during bot startup and map each supported event to concise operator-facing text.
5.2 Send pushes only to configured allowed chat ids; preserve existing guard behavior for inbound commands.
5.3 Add lightweight deduplication keying per event id or timestamp to prevent duplicate pushes on reconnect replay.

6. Startup and lifecycle integration
6.1 Update TypeScript service bootstrap to initialize event subscription after IPC connect and before or alongside bot start.
6.2 Add clean shutdown unsubscription or socket teardown path so stale subscriptions are not retained.

7. Tests and verification
7.1 Expand TypeScript tests to cover: event dispatch routing in IPC client, Telegram notification formatting and fanout, and no send on unauthorized chat ids.
7.2 Expand Zig tests around IPC publish path to confirm events are emitted for order placed or filled or cancelled and risk rejections.
7.3 Run end-to-end local check: simulate order and risk events in Zig, verify Telegram push occurs without invoking command endpoints.

**Relevant files**
- /home/owenstack/repos/personal/cex-zig/ts/src/ipc/types.ts — add subscription and event payload types for Phase 4 push channel.
- /home/owenstack/repos/personal/cex-zig/ts/src/ipc/client.ts — add non-correlated event routing, listener registration, reconnect re-subscription.
- /home/owenstack/repos/personal/cex-zig/ts/src/telegram/bot.ts — add event-to-message mapping and proactive send path to allowed chats.
- /home/owenstack/repos/personal/cex-zig/ts/src/index.ts — wire startup order so event listener is active during runtime.
- /home/owenstack/repos/personal/cex-zig/ts/test/telegram-bot.test.ts — add push notification behavior coverage.
- /home/owenstack/repos/personal/cex-zig/ts/test/ipc-client.test.ts — add event stream parsing and callback dispatch coverage.
- /home/owenstack/repos/personal/cex-zig/zig/src/ipc_types.zig — add matching message constants for subscription and event stream payloads.
- /home/owenstack/repos/personal/cex-zig/zig/src/ipc.zig — add subscriber registry and publish logic for async event envelopes.
- /home/owenstack/repos/personal/cex-zig/zig/src/order_manager.zig — publish order lifecycle events through IPC event channel.
- /home/owenstack/repos/personal/cex-zig/zig/src/risk_gate.zig — publish rejection events with check context.
- /home/owenstack/repos/personal/cex-zig/zig/src/tests.zig — add Zig-side event emission tests.

**Verification**
1. Contract parity: TS and Zig message constants and payload fields are aligned for all event types.
2. Runtime behavior: with bot running idle, simulated order event triggers Telegram push within target latency.
3. Auth safety: pushes go only to allowlisted chat ids and no unauthorized inbound behavior regresses.
4. Resilience: restarting Zig process causes TS reconnect and event listener resumes automatically.
5. Regression: existing /status, /portfolio, /orders command responses remain unchanged.

**Decisions**
- Included scope: only the missing event-driven Telegram push bridge needed to complete practical Phase 4 behavior.
- Excluded scope: /config set, /pause, /pnl, market management commands, approval mode, and dashboard feature expansion.
- Recommended transport: keep using UNIX socket IPC with pub or sub style events instead of introducing a separate HTTP webhook service for this phase.

**Further Considerations**
1. If strict wording requires literal HTTP webhook listener, implement a small local-only webhook adapter in TS that receives Zig-posted events and forwards into the same Telegram formatter; otherwise keep direct IPC events for lower complexity.
2. Add per-event severity tags so future Phase 5 notification queueing can prioritize halt or risk alerts over informational fills.
3. Decide replay policy on reconnect: no replay, last-N replay, or durable event table replay from SQLite.