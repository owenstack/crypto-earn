## Plan: Phase 2 with Polymarket User-Channel WebSocket for Fill Detection
This plan covers only Phase 2 of the PRD, focusing on reliable fill detection, startup reconciliation, and real-time fill event propagation to the Telegram bot. The goal is to ensure the engine always has an accurate view of open orders and positions, and operators are notified of fills promptly. Implementation will closely follow the latest [Polymarket user-channel WebSocket documentation](https://docs.polymarket.com/market-data/websocket/user-channel).

---

Steps

1. WebSocket-Based Fill Detection (Task-2.1)
Add MIGRATION_007 to the Zig DB schema:
Add filled_size TEXT DEFAULT '0', average_fill_price TEXT DEFAULT NULL, last_checked_at INTEGER DEFAULT 0 to the orders table.
Create zig/src/fill_poller.zig:
Implement checkOrderFills(order_id, allocator) to call GET /clob.polymarket.com/orders/{order_id} with HMAC headers, parse status and fills, and return a struct with new fill info.
Add unit tests for all CLOB order statuses using mock HTTP responses.
Implement FillPoller struct:
Method runFillCheck(database, om, pt):
Query all placed/partially_filled orders.
For each, call checkOrderFills().
For new fills, call pt.processFill() and update DB.
Update last_checked_at.
Publish event.order.filled or event.order.partially_filled via IPC.
Poll interval: every 3 seconds for orders not checked in last 3s, max 20 concurrent HTTP calls.
Spawn fill poller thread in main.zig.
On status canceled or matched, reconcile DB status.
Wire processFill() so DB and in-memory state update atomically.
Add integration test: simulate fill, verify DB and IPC event.
   - Review the latest Polymarket user-channel WebSocket docs for authentication, event types, and reconnect logic.
   - In `zig/src/fill_poller.zig` (or a new `user_ws.zig` if separation is preferred):
     - Implement a WebSocket client that connects to the user-channel endpoint with required authentication (address, signature, timestamp, etc.).
     - Subscribe to fill/cancel events for the engine’s account.
     - On receiving a fill/cancel event:
       - Parse event payload for order ID, fill size, price, status, etc.
       - Call `pt.processFill()` and update the DB as in the polling path.
       - Publish `event.order.filled` or `event.order.partially_filled` via IPC.
     - On connection loss, attempt reconnect with exponential backoff.
     - Log all connection and event errors for operator visibility.

2. REST Polling as Fallback (Secondary)
   - Retain the REST polling logic from the original plan, but only activate it if:
     - The WebSocket connection cannot be established after N retries.
     - The WebSocket disconnects for more than X seconds.
   - Polling logic remains as previously described (every 3s, max 20 concurrent, etc.).
   - If the WebSocket reconnects, polling is suspended.

3. Startup Account Reconciliation
  In fill_poller.zig, implement reconcileOnStartup(allocator, database, om, pt):
Call GET /clob.polymarket.com/orders?maker_address=<signer>&status=open (paginated).
For CLOB orders absent from DB, insert with status placed, strategy_origin = 'reconciled'.
For DB orders absent from CLOB, call checkOrderFills() to resolve status.
Call pt.syncFromDB() after reconciliation.
Add ReconcileGate (std.atomic.Value(bool)) in OrderManager as reconciliation_complete.
Block placeOrder() until reconciliation completes.
Call reconcileOnStartup() after PortfolioTracker.init() and before strategy worker thread in main.zig.
Retry up to 3 times; on failure, log error and set reconciliation_complete = true.
Log summary and publish IPC event for Telegram.
Add IPC message type reconcile.status/reconcile.status.response for Telegram /status.
Add tests for all reconciliation cases.

4. Fill Event IPC to Telegram
   Ensure fill_poller.zig publishes event.order.filled and event.order.partially_filled via ipc.publishEvent() with required payload.
In bot.ts:
Add handler for event.order.partially_filled in formatEvent().
Update event.order.filled formatter to include realized_pnl.
Add/extend TypeScript types for new payloads in types.ts.

---

Relevant files
- `zig/src/fill_poller.zig` - WebSocket client and event handler
- `zig/src/db.zig` — add `MIGRATION_007` for schema changes
- `zig/src/order_manager.zig` — `ReconcileGate`, block `placeOrder()` until reconciliation
- `zig/src/portfolio_tracker.zig` — ensure `processFill()` is called correctly
- `zig/src/main.zig` — wire up WebSocket/poller and reconciliation at startup
- `zig/src/ipc.zig`, `zig/src/ipc_types.zig` — add new IPC event/message types
- `ts/src/telegram/bot.ts` — handle new fill events, update formatters
- `ts/src/ipc/types.ts` — update/add TypeScript types for new events
- `zig/src/tests.zig` — add unit/integration tests for WebSocket and polling fallback

---

Verification
Unit tests for checkOrderFills() (all CLOB statuses).
Integration test: simulate fill, verify DB and IPC event.
Test reconciliation: DB/CLOB mismatches resolved as specified.
1. Simulate fills via WebSocket; verify DB and IPC event.
2. Simulate WebSocket failure; verify polling fallback triggers and detects fills.
3. Test reconciliation with both WebSocket and polling.
4. Confirm Telegram notifications are sent within 10s of fill.
5. Run all new tests and verify pass.

---

Decisions & Scope
- WebSocket is primary; polling is fallback only.
- Implementation will strictly follow the latest Polymarket user-channel WebSocket docs.
- Only Phase 2 tasks are included.
- All DB changes use migration pattern.

---

Further Considerations
1. Ensure robust reconnect and failover logic between WebSocket and polling.
2. Document all event types and payloads handled from the WebSocket.
3. Validate deduplication of fill events between WebSocket and polling.