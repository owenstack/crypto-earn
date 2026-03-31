# TODO_product-planner.md — cex-zig Codebase Fix PRD

**Document title:** cex-zig Hardening & Quality Remediation PRD
**Version:** 1.0
**Status:** Complete
**Date:** 2026-03-31
**Source:** Post-review findings from automated and manual codebase audit

---

## Context

### Project description and business objectives

cex-zig is a production autonomous trading engine targeting Polymarket's CLOB API. The Zig core handles all latency-sensitive order placement, risk gating, market scanning, and strategy evaluation. A TypeScript control plane (Grammy Telegram bot + Bun dashboard) handles operator interaction, push notifications, and monitoring. The system is deployed to a single AWS EC2 instance running under systemd.

This PRD captures all defects, security vulnerabilities, and quality issues identified during code review that must be resolved before the system handles live capital. Issues are classified by severity and grouped into implementation phases.

### Target users and key personas

| Persona | Role | Concern addressed by this PRD |
|---|---|---|
| **Solo operator** | Deploys and monitors the bot | Silent data drops, missed notifications, broken deploy scripts |
| **Risk-conscious operator** | Monitors drawdown and limits | Risk gate bypass risk if SQL injection alters order state |
| **Developer / maintainer** | Extends and debugs | Unmaintainable dispatch function, two migration sources of truth |

### Technical constraints and preferences

- Language: Zig 0.15.x (core engine), TypeScript/Bun (control plane)
- Database: SQLite 3.35+ in WAL mode
- Deployment: systemd on Ubuntu 24.04 EC2
- No new external Zig dependencies unless strictly necessary
- All fixes must pass existing test suites; new tests required for new behaviour

### Severity classification

| Level | Meaning |
|---|---|
| **CRITICAL** | Exploitable, data-corrupting, or deployment-breaking defect. Must fix before any live capital use. |
| **HIGH** | Functional correctness issue that causes silent failures or financial data loss. |
| **MEDIUM** | Maintainability, observability, or latent risk issue. Should fix before Phase 2 scale-up. |
| **LOW** | Code quality or developer experience improvement. Address as capacity allows. |

---

## Planning items

- [x] **PP-PLAN-1.1 Security Remediation**
  - **Section:** Functional requirements — security
  - **Status:** Complete
  - **Priority:** CRITICAL

- [x] **PP-PLAN-1.2 Zig Core Quality Fixes**
  - **Section:** Functional requirements — engine correctness
  - **Status:** Complete
  - **Priority:** HIGH

- [x] **PP-PLAN-1.3 TypeScript Control Plane Fixes**
  - **Section:** Functional requirements — control plane correctness
  - **Status:** Complete
  - **Priority:** HIGH

- [x] **PP-PLAN-1.4 Infrastructure and Scripts Remediation**
  - **Section:** Functional requirements — DevOps
  - **Status:** Complete
  - **Priority:** HIGH

- [x] **PP-PLAN-1.5 Architecture Decomposition**
  - **Section:** Non-functional requirements — maintainability
  - **Status:** Complete
  - **Priority:** MEDIUM

---

## Deliverable items

### Group A — CRITICAL security fixes

---

- [x] **PP-ITEM-A.1 — Fix SQL injection in `market_scanner.zig::persistMarkets`**
  - **ID:** SEC-001
  - **Severity:** CRITICAL
  - **File:** `zig/src/market_scanner.zig`, function `persistMarkets`
  - **Description:** Market fields `id`, `slug`, and `question` arrive from the untrusted Gamma API and are interpolated directly into a SQL statement via `std.fmt.bufPrint`. A maliciously crafted or unexpected market payload can corrupt the `markets` table or execute arbitrary SQL.
  - **Acceptance criteria:**
    - AC-001.1: `persistMarkets` uses `sqlite3_prepare_v2` + `sqlite3_bind_text` for all columns derived from API responses.
    - AC-001.2: No `std.fmt.bufPrint` or equivalent string interpolation is used to construct SQL containing external data.
    - AC-001.3: A unit test seeds a market with a `slug` containing a single-quote (`it's`) and verifies the insert succeeds without error and the value is stored verbatim.
    - AC-001.4: `zig build test` passes with no regressions.

  **Proposed code change — `zig/src/market_scanner.zig`:**

  ```zig
  // BEFORE (unsafe):
  fn persistMarkets(self: *Scanner) void {
      for (self.markets) |m| {
          var buf: [2048:0]u8 = @splat(0);
          _ = std.fmt.bufPrint(&buf,
              "INSERT OR REPLACE INTO markets(id,symbol,base,quote,status)VALUES('{s}','{s}','{s}','USDC','{s}');",
              .{ m.id, m.slug, m.question, if (m.active) "active" else "inactive" },
          ) catch continue;
          self.database.execZ(&buf) catch |e| { ... };
      }
  }

  // AFTER (safe — prepared statement):
  fn persistMarket(self: *Scanner, m: gamma.GammaMarket) !void {
      const sql =
          "INSERT OR REPLACE INTO markets(id,symbol,base,quote,status)" ++
          "VALUES(?,?,?,?,'USDC');" ++ &[_:0]u8{};
      var stmt: ?*db.c.sqlite3_stmt = null;
      if (db.c.sqlite3_prepare_v2(self.database.handle, sql.ptr, -1, &stmt, null) != db.c.SQLITE_OK)
          return error.DBExecFailed;
      defer _ = db.c.sqlite3_finalize(stmt);

      const status = if (m.active) "active" else "inactive";
      if (db.c.sqlite3_bind_text(stmt, 1, m.id.ptr,       @intCast(m.id.len),       null) != db.c.SQLITE_OK or
          db.c.sqlite3_bind_text(stmt, 2, m.slug.ptr,     @intCast(m.slug.len),     null) != db.c.SQLITE_OK or
          db.c.sqlite3_bind_text(stmt, 3, m.question.ptr, @intCast(m.question.len), null) != db.c.SQLITE_OK or
          db.c.sqlite3_bind_text(stmt, 4, status.ptr,     @intCast(status.len),     null) != db.c.SQLITE_OK)
          return error.DBExecFailed;

      if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE)
          return error.DBExecFailed;
  }

  fn persistMarkets(self: *Scanner) void {
      for (self.markets) |m| {
          self.persistMarket(m) catch |e| {
              log.warn("scanner", "persist market failed: {s} market_id={s}", .{ @errorName(e), m.id });
          };
      }
  }
  ```

---

- [x] **PP-ITEM-A.2 — Fix SQL injection in `order_manager.zig::cancelAll` and `scanStaleOrders`**
  - **ID:** SEC-002
  - **Severity:** CRITICAL
  - **File:** `zig/src/order_manager.zig`, functions `cancelAll` and `scanStaleOrders`
  - **Description:** Both functions collect order IDs from the database and then construct a `UPDATE` statement by calling `escapeSqlLiteral` and `std.fmt.allocPrintSentinel`. While the IDs originate from the database rather than user input, the pattern is fragile — a bug in ID generation, a database encoding edge case, or future refactoring that passes an external value could introduce injection. All mutations must use prepared statements.
  - **Acceptance criteria:**
    - AC-002.1: The `UPDATE orders SET status=...` statement in `cancelAll` uses `sqlite3_prepare_v2` + `sqlite3_bind_text` for the order ID, not string interpolation.
    - AC-002.2: The `UPDATE orders SET status=...` statement in `scanStaleOrders` uses the same prepared-statement pattern.
    - AC-002.3: The `escapeSqlLiteral` helper function is removed or marked `deprecated` with a doc comment explaining it must not be used for SQL construction.
    - AC-002.4: A unit test verifies `cancelAll` correctly updates status for orders whose IDs contain special characters (single-quote, backslash).
    - AC-002.5: `zig build test` passes with no regressions.

  **Proposed code change — `cancelAll` inner loop:**

  ```zig
  // AFTER: replace allocPrintSentinel + execZ with prepared statement
  const update_sql =
      "UPDATE orders SET status='cancelled', updated_at=unixepoch() WHERE id=?;" ++
      &[_:0]u8{};
  var upd_stmt: ?*c.sqlite3_stmt = null;
  if (c.sqlite3_prepare_v2(self.database.handle, update_sql.ptr, -1, &upd_stmt, null) != c.SQLITE_OK) {
      log.err("order_mgr", "cancelAll failed to prepare UPDATE", .{});
      continue;
  }
  defer _ = c.sqlite3_finalize(upd_stmt);

  for (order_ids.items) |order_id| {
      _ = c.sqlite3_reset(upd_stmt);
      if (c.sqlite3_bind_text(upd_stmt, 1, order_id.ptr, @intCast(order_id.len), null) != c.SQLITE_OK)
          continue;
      if (c.sqlite3_step(upd_stmt) != c.SQLITE_DONE) {
          log.err("order_mgr", "cancelAll UPDATE failed for order {s}", .{order_id});
          continue;
      }
      cancelled_count += 1;
  }
  ```

---

- [x] **PP-ITEM-A.3 — Fix shell quoting bug in `scripts/deploy.sh`**
  - **ID:** SEC-003
  - **Severity:** CRITICAL
  - **File:** `scripts/deploy.sh`, Step 3 environment sourcing block
  - **Description:** The `elif` branch sourcing `.env` is missing the closing double-quote on the `source` command, causing a shell syntax error. This means `DB_PATH` is never populated and `scripts/migrate.sh` fails silently or uses the wrong path on first deploy.
  - **Acceptance criteria:**
    - AC-003.1: `bash -n scripts/deploy.sh` exits with status 0 (no syntax errors).
    - AC-003.2: A dry-run of `deploy.sh --skip-build` on a machine with a valid `.env` sources `DB_PATH` correctly and migrate.sh receives a non-empty path.
    - AC-003.3: The fix is a single-character insertion of the missing `"`.

  **Proposed code change — `scripts/deploy.sh`:**

  ```bash
  # BEFORE (broken — missing closing quote):
  elif [[ -f "$DIR/.env" ]]; then
    set -a; source "$DIR/.env; set +a
  fi

  # AFTER (fixed):
  elif [[ -f "$DIR/.env" ]]; then
    set -a; source "$DIR/.env"; set +a
  fi
  ```

---

- [x] **PP-ITEM-A.4 — Remove `Bun.env.API_KEY` from browser-bundled `Dashboard.tsx`**
  - **ID:** SEC-004
  - **Severity:** CRITICAL
  - **File:** `ts/src/components/Dashboard.tsx`
  - **Description:** `const API_KEY = Bun.env.API_KEY` is evaluated at bundle time and the value is inlined into the JavaScript served to the browser. Any user who views page source or opens DevTools can retrieve `DASHBOARD_SECRET`. The dashboard must authenticate at the server layer only; the browser should send no secret.
  - **Acceptance criteria:**
    - AC-004.1: `Dashboard.tsx` contains no reference to `Bun.env`, `process.env`, or any environment variable.
    - AC-004.2: All `/api/*` fetch calls from the frontend omit the `Authorization` header.
    - AC-004.3: `dashboardRoutes` in `server.ts` continues to enforce Bearer auth — this requirement is not relaxed.
    - AC-004.4: The dashboard is accessed through a reverse-proxy or the operator provides the Bearer token at the network layer (e.g., via a browser extension, mTLS, or an operator-supplied cookie set by a thin auth endpoint), OR a lightweight server-side session cookie is introduced (see open question Q-001).
    - AC-004.5: `bun run build` produces a bundle that, when searched for the value of `DASHBOARD_SECRET`, returns no matches.
    - AC-004.6: The existing dashboard tests continue to pass.

---

- [x] **PP-ITEM-A.5 — Zero private key memory after use in `order_manager.zig::cancelOnCLOB`**
  - **ID:** SEC-005
  - **Severity:** HIGH
  - **File:** `zig/src/order_manager.zig`, function `cancelOnCLOB`
  - **Description:** The 32-byte EIP-712 private key stored in `OrderManagerConfig.private_key` is used to sign cancel payloads. After signing, the key material remains in the stack frame and may be recoverable from a core dump or memory scan. The key must be zeroed immediately after use.
  - **Acceptance criteria:**
    - AC-005.1: Immediately after `crypto.signEip712` returns (or errors), `@memset(&local_key_copy, 0, 32)` is called on any local copy of the key used during signing.
    - AC-005.2: `OrderManagerConfig.private_key` is never logged — a unit test asserts that `log.writeRecentLogs` output does not contain any 64-character hex string matching the test key after a sign operation.
    - AC-005.3: A code comment documents the zeroing rationale inline.

  **Proposed code change — `cancelOnCLOB`:**

  ```zig
  // Make a local copy, use it, then zero immediately
  var key_copy: [32]u8 = self.config.private_key;
  defer @memset(&key_copy, 0, key_copy.len);

  const digest = crypto.Keccak256.hash(payload);
  const sig = crypto.signEip712(digest, key_copy) catch |e| {
      log.err("order_mgr", "failed to sign cancel payload: {s}", .{@errorName(e)});
      return false;
  };
  ```

---

### Group B — HIGH: Zig engine correctness

---

- [x] **PP-ITEM-B.1 — Replace raw `std.http.Client` in `cancelOnCLOB` with `HttpClient` wrapper**
  - **ID:** ZIG-001
  - **Severity:** HIGH
  - **File:** `zig/src/order_manager.zig`, function `cancelOnCLOB`
  - **Description:** `cancelOnCLOB` instantiates a raw `std.http.Client` instead of using the project's `http_client.HttpClient` wrapper. This bypasses the unified error handling, structured logging, and user-agent header applied by `HttpClient`. It also means cancel requests do not benefit from future improvements to `HttpClient`.
  - **Acceptance criteria:**
    - AC-B1.1: `cancelOnCLOB` creates an `HttpClient` instance and calls `client.postJson(url, payload)` (or a new `postJsonWithHeaders` variant if auth headers are needed).
    - AC-B1.2: If `HttpClient` needs extension to support custom request headers (for `POLY_TIMESTAMP` and `POLY_SIGNATURE`), a new `postJsonWithHeaders(url, body, headers)` method is added to `HttpClient` and covered by a unit test.
    - AC-B1.3: The local `var client = std.http.Client{ .allocator = self.allocator }` declaration is removed from `cancelOnCLOB`.
    - AC-B1.4: `zig build test` passes with no regressions.

---

- [x] **PP-ITEM-B.2 — Make `portfolio_tracker::writeOrdersJson` serialization failures non-silent**
  - **ID:** ZIG-002
  - **Severity:** HIGH
  - **File:** `zig/src/portfolio_tracker.zig`, function `writeOrdersJson`
  - **Description:** When `writeOrderJsonObject` fails during JSON serialization, the current code silently skips the order and logs a warning. Operators viewing the dashboard may see an incomplete order list without any indication that data is missing, which is dangerous in a financial context.
  - **Acceptance criteria:**
    - AC-B2.1: When one or more orders are skipped due to serialization errors, the JSON response includes a top-level `"truncated": true` field and a `"skipped_count": N` field.
    - AC-B2.2: The IPC response type for `/api/orders` is updated in `ts/src/ipc/types.ts` to include optional `truncated?: boolean` and `skipped_count?: number` fields on `OrdersPayload`.
    - AC-B2.3: The dashboard UI in `Dashboard.tsx` displays a visible warning banner when `truncated === true`.
    - AC-B2.4: A unit test seeds a malformed order record and asserts the response contains `"truncated": true`.

  **Proposed code change — `writeOrdersJson` return path:**

  ```zig
  // Replace the current silent-skip pattern:
  if (skipped_orders > 0) {
      // Append truncation metadata before closing bracket
      var meta_buf: [64]u8 = undefined;
      const meta = std.fmt.bufPrint(
          &meta_buf,
          "],\"truncated\":true,\"skipped_count\":{d}}}",
          .{skipped_orders},
      ) catch return error.Overflow;
      try writer.writeAll(meta);
  } else {
      try writer.writeAll("]}");
  }
  ```

---

- [x] **PP-ITEM-B.3 — Surface `strategy_engine` active-order overflow as an observable error**
  - **ID:** ZIG-003
  - **Severity:** HIGH
  - **File:** `zig/src/strategy_engine.zig`, function `trackOrder`
  - **Description:** When `MAX_ACTIVE_ORDERS` (64) is reached, `trackOrder` logs a warning and returns without tracking. This silently breaks cancel-on-collapse and LP pair lifecycle logic — the system continues placing orders it cannot manage. The overflow must be surfaced as a strategy stat and optionally block new placements.
  - **Acceptance criteria:**
    - AC-B3.1: `trackOrder` returns a `bool` (or `error.ActiveOrderCapExceeded`) indicating whether tracking succeeded.
    - AC-B3.2: All callers of `trackOrder` in `main.zig` check the return value; if tracking fails, the order placement is rolled back (cancelled) and the event is logged at `ERROR` level.
    - AC-B3.3: `StrategyStats` gains an `active_order_overflow_count: u64` field, incremented on each failed track.
    - AC-B3.4: The IPC `strategy.list` response includes `active_order_overflow_count` in each strategy's stats payload.
    - AC-B3.5: A unit test fills `MAX_ACTIVE_ORDERS` slots, attempts one more `trackOrder`, and asserts failure is returned.

---

- [x] **PP-ITEM-B.4 — Clarify `websocket.zig` API to make REST-poll fallback explicit**
  - **ID:** ZIG-004
  - **Severity:** MEDIUM
  - **File:** `zig/src/websocket.zig`
  - **Description:** `WebSocketClient.connectAndRun` is a public API that callers expect to establish a native WebSocket connection. It instead silently falls back to REST polling because `performUpgrade` always returns `error.NotImplemented`. Callers in `main.zig` should explicitly choose `pollAndNotify` until the WebSocket upgrade is implemented.
  - **Acceptance criteria:**
    - AC-B4.1: `performUpgrade` is renamed to `performUpgrade_unimplemented` and marked `// TODO(ws): implement RFC 6455 handshake`.
    - AC-B4.2: `connectAndRun` is removed from the public API surface (made `pub` → package-private or deleted) until the upgrade is implemented.
    - AC-B4.3: `main.zig` calls `ws_client.pollAndNotify(poll_interval_ms)` directly from the market scanner thread, with an inline comment explaining it is a REST fallback.
    - AC-B4.4: `README.md` in `zig/` documents that native WebSocket is deferred and REST polling is the current mechanism.
    - AC-B4.5: The existing `websocket.zig` unit tests continue to pass.

---

- [x] **PP-ITEM-B.5 — Resolve dual migration source-of-truth between `db.zig` and `db/migrations/`**
  - **ID:** ZIG-005
  - **Severity:** HIGH
  - **File:** `zig/src/db.zig`, `db/migrations/`, `scripts/migrate.sh`
  - **Description:** Migration SQL exists in two places: embedded as Zig string constants (`MIGRATION_001` through `MIGRATION_004`) and as files under `db/migrations/` (only 001 and 002 currently exist as files). The shell `migrate.sh` only applies file-based migrations. Migration 003 (strategy stats) and 004 (runtime config) are only applied when the Zig engine runs. A fresh database set up by the shell tooling alone is not fully migrated, breaking the e2e smoke test gate for versions 3 and 4.
  - **Acceptance criteria:**
    - AC-B5.1: `db/migrations/003_phase3_strategy_stats.sql` is created, containing the SQL from `MIGRATION_003` in `db.zig`, plus `INSERT OR IGNORE INTO schema_migrations(version)VALUES(3);`.
    - AC-B5.2: `db/migrations/004_phase5_runtime_config.sql` is created, containing the SQL from `MIGRATION_004` in `db.zig`, plus `INSERT OR IGNORE INTO schema_migrations(version)VALUES(4);`.
    - AC-B5.3: `scripts/e2e-test.sh` is updated to verify migration versions 1, 2, 3, and 4 are all present.
    - AC-B5.4: `scripts/migrate.sh` is run on a clean database and correctly applies all four migrations in order.
    - AC-B5.5: The Zig embedded constants (`MIGRATION_001` – `MIGRATION_004`) are retained as they are — they serve as the in-process bootstrap — but a CI lint step (or a comment in `db.zig`) documents that any change to an embedded migration must also be reflected in the corresponding `db/migrations/*.sql` file.

  **Proposed file: `db/migrations/003_phase3_strategy_stats.sql`:**

  ```sql
  CREATE TABLE IF NOT EXISTS strategy_stats(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    strategy TEXT NOT NULL,
    signals_emitted INTEGER NOT NULL DEFAULT 0,
    orders_accepted INTEGER NOT NULL DEFAULT 0,
    orders_rejected INTEGER NOT NULL DEFAULT 0,
    cancels INTEGER NOT NULL DEFAULT 0,
    realized_pnl_estimate REAL NOT NULL DEFAULT 0.0,
    snapshot_at INTEGER NOT NULL DEFAULT(unixepoch())
  );
  CREATE INDEX IF NOT EXISTS idx_strategy_stats_at ON strategy_stats(snapshot_at DESC);
  ALTER TABLE orders ADD COLUMN strategy_origin TEXT DEFAULT NULL;
  INSERT OR IGNORE INTO schema_migrations(version) VALUES(3);
  ```

  **Proposed file: `db/migrations/004_phase5_runtime_config.sql`:**

  ```sql
  CREATE TABLE IF NOT EXISTS runtime_config(
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at INTEGER NOT NULL DEFAULT(unixepoch())
  );
  CREATE INDEX IF NOT EXISTS idx_runtime_config_key ON runtime_config(key);
  INSERT OR IGNORE INTO schema_migrations(version) VALUES(4);
  ```

---

### Group C — HIGH: TypeScript control plane correctness

---

- [x] **PP-ITEM-C.1 — Fix IPC type mismatch: `pnl.query` → `pnl.response` vs `pnl.query.response`**
  - **ID:** TS-001
  - **Severity:** HIGH
  - **File:** `ts/src/ipc/types.ts`, `ts/test/ipc-client.test.ts`
  - **Description:** The Zig IPC handler responds to `pnl.query` with `pnl.response` (constant `ipc_types.T.pnl_response`). However, the IPC client test's echo server maps `pnl.query` to `pnl.query.response`, and the test asserts `res.type === "pnl.query.response"`. This mismatch is masked by the echo server and will fail in real integration — `ipc.pnl()` will time out waiting for a correlated response that never matches.
  - **Acceptance criteria:**
    - AC-C1.1: `ResponseMessageType` in `ts/src/ipc/types.ts` contains `"pnl.response"`, not `"pnl.query.response"`.
    - AC-C1.2: The echo server in `ipc-client.test.ts` maps `"pnl.query"` → `"pnl.response"` (not `"pnl.query.response"`).
    - AC-C1.3: The test assertion reads `expect(res.type).toBe("pnl.response")`.
    - AC-C1.4: `bun test` passes with no regressions.
    - AC-C1.5: An integration test (or a comment in the test file) documents the Zig-side constant `T.pnl_response = "pnl.response"` as the authoritative source.

  **Proposed code change — `ts/src/ipc/types.ts`:**

  ```typescript
  // BEFORE:
  export type ResponseMessageType =
    | ...
    | "pnl.response";  // already correct here

  // The bug is in the test echo server and the test assertion only.
  ```

  **Proposed code change — `ts/test/ipc-client.test.ts`:**

  ```typescript
  // BEFORE (echo server):
  type: `${req.type}.response` as Envelope["type"],
  // For pnl.query this produces "pnl.query.response" — wrong.

  // AFTER: special-case pnl.query in the echo server:
  const responseType = req.type === "pnl.query"
    ? "pnl.response"
    : `${req.type}.response`;

  // BEFORE (assertion):
  expect(res.type).toBe("pnl.query.response");

  // AFTER:
  expect(res.type).toBe("pnl.response");
  ```

---

- [x] **PP-ITEM-C.2 — Log errors swallowed in `IPCClient._dispatchEvent`**
  - **ID:** TS-002
  - **Severity:** HIGH
  - **File:** `ts/src/ipc/client.ts`, function `_dispatchEvent`
  - **Description:** Event handler errors are silently swallowed. When a Telegram push notification fails due to a formatting error in `formatEvent`, the operator receives no notification and no log entry. This can cause missed risk alerts and missed fill notifications.
  - **Acceptance criteria:**
    - AC-C2.1: Each `catch` block in `_dispatchEvent` logs the error at `WARN` level with the event type and handler identity (e.g., `console.error(JSON.stringify({...}))`).
    - AC-C2.2: The structured log entry includes `ts`, `level: "WARN"`, `component: "ipc"`, and `msg` containing the error message and event type.
    - AC-C2.3: A unit test simulates a handler that throws and asserts the log output contains the error message.
    - AC-C2.4: `bun test` passes with no regressions.

  **Proposed code change — `ts/src/ipc/client.ts`:**

  ```typescript
  private _dispatchEvent(env: Envelope): void {
    const dispatch = (handler: EventHandler) => {
      try {
        handler(env);
      } catch (err) {
        console.error(JSON.stringify({
          ts: Date.now(),
          level: "WARN",
          component: "ipc",
          msg: `event handler error for type=${env.type}: ${err instanceof Error ? err.message : String(err)}`,
        }));
      }
    };
    this.eventHandlers.get(env.type)?.forEach(dispatch);
    this.eventHandlers.get("*")?.forEach(dispatch);
  }
  ```

---

- [x] **PP-ITEM-C.3 — Replace cache-busting import pattern in `telegram-bot.test.ts`**
  - **ID:** TS-003
  - **Severity:** MEDIUM
  - **File:** `ts/test/telegram-bot.test.ts`
  - **Description:** Tests use `await import(\`../src/telegram/bot.ts?t=${Date.now()}\`)` to bypass Bun's module cache and force `ALLOWED_IDS` re-initialisation per test. This creates multiple live module instances in a single test run, is brittle when the module has side effects, and will break under stricter module isolation. The `ALLOWED_IDS` set must be made injectable.
  - **Acceptance criteria:**
    - AC-C3.1: `ts/src/telegram/bot.ts` exports a `createAllowedIds(raw: string): Set<number>` factory function.
    - AC-C3.2: The module-level `ALLOWED_IDS` is replaced with a call to `createAllowedIds(Bun.env.TELEGRAM_ALLOWED_CHAT_IDS ?? "")` at module initialisation.
    - AC-C3.3: `isAllowedChatId` is refactored to accept an explicit `Set<number>` parameter, or `ALLOWED_IDS` is exported and reset in tests using `beforeEach`.
    - AC-C3.4: All cache-busting query-param imports (`?t=`, `?phase5=`, `?push_test=`, `?push_guard=`) are removed from the test file.
    - AC-C3.5: `bun test` passes with no regressions.

---

- [x] **PP-ITEM-C.4 — Document `bot.ts::dedup` eviction behaviour**
  - **ID:** TS-004
  - **Severity:** LOW
  - **File:** `ts/src/telegram/bot.ts`, function `dedup`
  - **Description:** The deduplication set uses a single-item eviction strategy (delete the oldest entry when the cap is reached) rather than a periodic flush. The intent and trade-offs are not documented, which could cause a maintainer to replace it with a broken implementation.
  - **Acceptance criteria:**
    - AC-C4.1: A JSDoc comment on the `dedup` function explains: (a) the cap is `DEDUP_MAX_SIZE`, (b) eviction is FIFO one-at-a-time, (c) the set intentionally stays near-full under sustained load, and (d) this is acceptable because event IDs are monotonically increasing.
    - AC-C4.2: A unit test verifies that after `DEDUP_MAX_SIZE + 1` unique event IDs are processed, the oldest ID is no longer deduplicated (i.e., would be re-delivered if reseen).

---

### Group D — HIGH: Infrastructure and scripts

---

- [x] **PP-ITEM-D.1 — Add `zig build test` to `scripts/verify.sh`**
  - **ID:** OPS-001
  - **Severity:** HIGH
  - **File:** `scripts/verify.sh`
  - **Description:** `verify.sh` runs `zig build -Doptimize=ReleaseFast` and TS typecheck, but does not run the Zig test suite (`zig build test`). Phase 7 verification gates require the full test suite. A release build succeeding while unit tests fail would be undetected.
  - **Acceptance criteria:**
    - AC-D1.1: `verify.sh` includes a step that runs `cd "$DIR/zig" && zig build test` after the release build step.
    - AC-D1.2: A failure in `zig build test` causes `verify.sh` to exit with a non-zero status.
    - AC-D1.3: The step summary output reads `OK zig build test succeeded`.
    - AC-D1.4: `bun test` (TS tests) is also added as a verification step, run after `bun run typecheck`.

  **Proposed code change — `scripts/verify.sh`:**

  ```bash
  # After the existing "Zig release build" step, add:

  # ── 1b. Zig unit tests ───────────────────────────────────────────────────────
  step "Zig unit tests"
  (cd "$DIR/zig" && zig build test)
  step_ok "zig build test succeeded"

  # After the existing "TS typecheck" step, add:

  # ── 2b. TS unit tests ────────────────────────────────────────────────────────
  step "TS unit tests"
  (cd "$DIR/ts" && bun test)
  step_ok "bun test succeeded"
  ```

---

- [x] **PP-ITEM-D.2 — Verify and pin correct Zig version in `provision.sh` and `README.md`**
  - **ID:** OPS-002
  - **Severity:** HIGH
  - **File:** `scripts/provision.sh`, `README.md`
  - **Description:** `provision.sh` attempts to install Zig 0.15.2, and `README.md` requires it. Zig 0.15.x had not been released as of the knowledge cutoff (stable was 0.13.x / 0.14.0-dev). If 0.15.2 does not exist at the specified download URL, the script will 404 silently, leaving the environment without Zig.
  - **Acceptance criteria:**
    - AC-D2.1: The Zig version in `provision.sh` is set to the actual latest stable release that the codebase has been verified to compile against. The download URL is tested with `curl -I` in a CI step.
    - AC-D2.2: `provision.sh` includes a checksum verification step (`sha256sum`) for the downloaded tarball, using the hash published on ziglang.org.
    - AC-D2.3: `provision.sh` exits with a non-zero status and a clear error message if the Zig download fails (currently it silently proceeds with `tar xf` on a non-existent file).
    - AC-D2.4: `README.md` and `build.zig.zon` `minimum_zig_version` are updated to match the pinned version.
    - AC-D2.5: A CI workflow step (GitHub Actions or equivalent) runs `scripts/provision.sh` on a clean Ubuntu 24.04 image and asserts `zig version` outputs the expected version string.

  **Proposed code change — `scripts/provision.sh`:**

  ```bash
  # Add after curl download:
  ZIG_SHA256="<sha256_from_ziglang.org>"
  echo "${ZIG_SHA256}  ${ZIG_TARBALL}" | sha256sum --check || {
    echo "ERROR: Zig tarball checksum mismatch. Aborting." >&2
    rm -f "${ZIG_TARBALL}"
    exit 1
  }
  ```

---

- [x] **PP-ITEM-D.3 — Add missing `db/migrations/003` and `db/migrations/004` files** *(cross-reference ZIG-005)*
  - **ID:** OPS-003
  - **Severity:** HIGH
  - **File:** `db/migrations/`, `scripts/e2e-test.sh`
  - **Description:** Covered by ZIG-005 above. This item tracks the infrastructure side: updating `e2e-test.sh` to verify all four migration versions and adding a CI check that the count of embedded Zig migration constants matches the count of `db/migrations/*.sql` files.
  - **Acceptance criteria:**
    - AC-D3.1: `scripts/e2e-test.sh` checks for migration versions 1, 2, 3, and 4 (currently only checks 1, 2, 4).
    - AC-D3.2: A CI step counts `MIGRATION_00N` constants in `zig/src/db.zig` and compares to `ls db/migrations/*.sql | wc -l`; a mismatch fails the build.
    - AC-D3.3: `scripts/migrate.sh` run on a clean DB applies all four files and exits with status 0.

---

### Group E — MEDIUM: Architecture decomposition

---

- [x] **PP-ITEM-E.1 — Decompose `ipc.zig::dispatch` into a handler-per-message-type structure**
  - **ID:** ARCH-001
  - **Severity:** MEDIUM
  - **File:** `zig/src/ipc.zig`, function `dispatch`
  - **Description:** `dispatch` is a single function with ~300 lines and 20+ `if/else` branches, one per message type. Adding new message types requires editing the same function, increasing merge conflict probability and cognitive load. Each handler must be extracted into its own function.
  - **Acceptance criteria:**
    - AC-E1.1: Each message type handled by `dispatch` has a corresponding `handle<MessageType>` function (e.g., `handleHeartbeat`, `handleStatus`, `handleOrderPlace`).
    - AC-E1.2: `dispatch` is reduced to: parse envelope → look up handler → call handler → flush. It contains no business logic.
    - AC-E1.3: Each handler function has a consistent signature: `fn handleXxx(ctx: *Context, req_id: []const u8, root: std.json.ObjectMap, writer: anytype) !void`.
    - AC-E1.4: `dispatch` total line count is under 60 lines after refactor.
    - AC-E1.5: All existing IPC tests pass without modification after refactor.
    - AC-E1.6: A new message type can be added by creating one handler function and one entry in the dispatch table, without touching any other handler.

  **Proposed structure sketch:**

  ```zig
  // zig/src/ipc.zig — after refactor

  const Handler = *const fn (ctx: *Context, req_id: []const u8, root: std.json.ObjectMap, writer: anytype, stream: std.net.Stream) anyerror!void;

  const dispatch_table = [_]struct { msg_type: []const u8, handler: Handler }{
      .{ .msg_type = types.T.heartbeat,       .handler = handleHeartbeat },
      .{ .msg_type = types.T.status,          .handler = handleStatus },
      .{ .msg_type = types.T.portfolio,       .handler = handlePortfolio },
      .{ .msg_type = types.T.orders,          .handler = handleOrders },
      .{ .msg_type = types.T.order_place,     .handler = handleOrderPlace },
      // ... one entry per message type
  };

  fn dispatch(ctx: *Context, line: []const u8, writer: anytype, stream: std.net.Stream) !void {
      // parse → look up → delegate
      for (dispatch_table) |entry| {
          if (std.mem.eql(u8, msg_type, entry.msg_type)) {
              try entry.handler(ctx, req_id, root, writer, stream);
              return;
          }
      }
      try types.writeError(writer, req_id, "unknown message type");
  }
  ```

---

## Development phases

### Phase 1 — CRITICAL security fixes (target: before any live capital)

| Task ID | Item | Estimated effort |
|---|---|---|
| SEC-001 | SQL injection: `persistMarkets` | 2h |
| SEC-002 | SQL injection: `cancelAll` / `scanStaleOrders` | 3h |
| SEC-003 | Shell quoting bug: `deploy.sh` | 15m |
| SEC-004 | Remove `Bun.env.API_KEY` from browser bundle | 2h |
| SEC-005 | Zero private key memory | 1h |

### Phase 2 — HIGH correctness fixes (target: before production scale-up)

| Task ID | Item | Estimated effort |
|---|---|---|
| ZIG-001 | Use `HttpClient` wrapper in `cancelOnCLOB` | 2h |
| ZIG-002 | Non-silent serialization failures in `writeOrdersJson` | 3h |
| ZIG-003 | Surface `trackOrder` overflow | 2h |
| ZIG-004 | Clarify WebSocket API as REST-poll fallback | 1h |
| ZIG-005 | Create migration SQL files 003 and 004 | 1h |
| TS-001 | Fix `pnl.query` response type mismatch | 1h |
| TS-002 | Log swallowed event handler errors | 1h |
| OPS-001 | Add `zig build test` + `bun test` to `verify.sh` | 30m |
| OPS-002 | Verify/pin Zig version + checksum in `provision.sh` | 2h |
| OPS-003 | Update `e2e-test.sh` for 4 migration versions | 1h |

### Phase 3 — MEDIUM quality improvements (target: next maintenance window)

| Task ID | Item | Estimated effort |
|---|---|---|
| TS-003 | Replace cache-busting import pattern in tests | 2h |
| TS-004 | Document `dedup` eviction behaviour | 30m |
| ARCH-001 | Decompose `ipc.zig::dispatch` | 4h |

---

## Traceability matrix

| Fix ID | Severity | Source finding | Affected file(s) | User story impact |
|---|---|---|---|---|
| SEC-001 | CRITICAL | SQL injection via Gamma API data | `market_scanner.zig` | US-001, US-008 (order integrity) |
| SEC-002 | CRITICAL | SQL injection via order IDs | `order_manager.zig` | US-008, US-011 (risk gate) |
| SEC-003 | CRITICAL | Shell syntax error | `scripts/deploy.sh` | US-019 (deploy) |
| SEC-004 | CRITICAL | Secret in browser bundle | `Dashboard.tsx` | US-019, FR-63 |
| SEC-005 | HIGH | Key not zeroed | `order_manager.zig` | US-019 (key isolation) |
| ZIG-001 | HIGH | Inconsistent HTTP client | `order_manager.zig` | US-008, US-017 |
| ZIG-002 | HIGH | Silent order data drop | `portfolio_tracker.zig` | US-013, FR-64 |
| ZIG-003 | HIGH | Silent strategy tracking drop | `strategy_engine.zig` | US-006, US-007 |
| ZIG-004 | MEDIUM | Misleading public API | `websocket.zig` | NFR-15 |
| ZIG-005 | HIGH | Migration drift | `db.zig`, `db/migrations/` | Phase 7 deployment |
| TS-001 | HIGH | IPC type mismatch | `types.ts`, `ipc-client.test.ts` | US-014, FR-56 |
| TS-002 | HIGH | Swallowed handler errors | `ipc/client.ts` | US-015 (push notifications) |
| TS-003 | MEDIUM | Brittle test pattern | `telegram-bot.test.ts` | NFR-15 |
| TS-004 | LOW | Undocumented dedup logic | `telegram/bot.ts` | NFR-15 |
| OPS-001 | HIGH | Test gap in verify.sh | `scripts/verify.sh` | Phase 7 verification |
| OPS-002 | HIGH | Zig version unverified | `scripts/provision.sh` | Phase 7 deployment |
| OPS-003 | HIGH | e2e checks missing versions 3+4 | `scripts/e2e-test.sh` | Phase 7 verification |
| ARCH-001 | MEDIUM | God function in IPC dispatch | `zig/src/ipc.zig` | NFR-15 (maintainability) |

---

## Open questions

- [x] **Q-001** — How should the dashboard authenticate after SEC-004 removes the browser-side `API_KEY`?
  - **Resolution:** Dashboard fetches from `/api/*` endpoints without an `Authorization` header. Server-side `dashboardRoutes` in `server.ts` continues to enforce Bearer auth at the network layer. The operator provides the token via reverse-proxy, SSH tunnel, or browser extension.

- [x] **Q-002** — Should the Zig embedded migration constants (`MIGRATION_001` – `MIGRATION_004`) be removed in favour of runtime file loading?
  - **Resolution:** Retained embedded constants as in-process bootstrap. Added corresponding `db/migrations/003_*.sql` and `004_*.sql` files. A CI lint step in `verify.sh` asserts embedded constant count matches file count to prevent drift.

- [x] **Q-003** — What is the confirmed released version of Zig that this codebase compiles against?
  - **Resolution:** Pinned to Zig 0.15.2. `provision.sh` downloads with `curl -fsSL` (fails on HTTP error), verifies SHA-256 checksum per architecture, and exits non-zero on mismatch.

- [x] **Q-004** — Should `MAX_ACTIVE_ORDERS` in `strategy_engine.zig` be configurable at runtime via `config.set`?
  - **Resolution:** Deferred. `trackOrder` now returns `bool` to indicate overflow, callers check the return value, and `active_order_overflow_count` is surfaced in `StrategyStats` / IPC `strategy.list` response. Runtime configurability can be added later if needed.