## Plan: Phase 7 Database Migrations

TL;DR - Implement only Phase 7: finalize DB schema changes for Hyperliquid (markets, positions/orders, new telemetry tables), embed the migrations in the Zig engine, and expose small DB helper APIs used by later phases. Keep changes scoped to DB migrations, Zig DB layer, and tests; do not modify strategy or UI code.

**Steps**

1. Review existing SQL migrations (`db/migrations/012_phase3_hl_market_data.sql`, `013_phase5_hl_portfolio.sql`) to identify which Phase-7 tasks are already applied and which remain. *depends on step 2*
2. Create new migration SQL `db/migrations/014_phase7_hl_schema_overhaul.sql` performing the remaining schema changes:
   - Recreate `markets` without `clob_token_ids`, `condition_id`, `neg_risk`; add `asset_index INTEGER DEFAULT -1`, `base_asset TEXT DEFAULT ''`, `max_leverage INTEGER DEFAULT 20` (use SQLite table-recreate pattern).
   - Add any missing ALTERs for positions/orders that are still required (verify against `013`).
   - Create any missing new tables if not present (e.g., `funding_snapshots`, `arb_events`) only if `013` did not already create them.
   - Add `INSERT OR IGNORE INTO schema_migrations(version) VALUES (14);` at the end.
3. Update `zig/src/db.zig`:
   - Add `MIGRATION_014` embedded SQL constant with the same SQL or minimal idempotent operations.
   - Extend `runMigrations()` to detect and apply migration 14 (mirror pattern used for 12/13).
   - Add DB helper methods: `pub fn insertArbEvent(self: *DB, ...) !void`, `pub fn insertFundingSnapshot(self: *DB, ...) !void`, and `pub fn queryArbEvents(self: *DB, limit: i32) ![]ArbEvent` (small, focused implementations).
   - Add small tests/hooks or compile-only checks for the new helpers.
4. Add migration SQL file to `db/migrations/` (so `scripts/migrate.sh` picks it up) and ensure content is idempotent or guarded by `INSERT OR IGNORE INTO schema_migrations` semantics used elsewhere.
5. Add/adjust unit tests:
   - Update or add a test in Zig that opens an in-memory DB, runs `runMigrations()`, and asserts the presence of the new columns/tables (`PRAGMA table_info(...)` or simple SELECTs).
   - Add lightweight insert/select tests for `insertArbEvent` and `insertFundingSnapshot`.
6. Run verification locally:
   - Run `scripts/migrate.sh <path-to-test-db>` to apply SQL migrations and confirm no errors.
   - Run `zig build test` to ensure new Zig code compiles and tests pass.
7. Commit changes with a focused message: "db: phase 7 migrations + db.zig helpers (MIGRATION_014)".

**Relevant files**

- `db/migrations/014_phase7_hl_schema_overhaul.sql` — new migration SQL to add/remove markets columns and other remaining schema changes.
- `zig/src/db.zig` — add `MIGRATION_014`, migrate application, and `insertArbEvent`/`insertFundingSnapshot` helpers.
- `scripts/migrate.sh` — no change expected, but run it to verify the new SQL is applied.
- `zig/src/tests.zig` — add small migration verification and helper unit tests.

**Verification**

1. Run `scripts/migrate.sh /tmp/cex.test.sqlite3` and confirm migration 14 is applied (or skipped if already applied) without error.
2. Unit tests: `zig build test` passes including the new migration + helper tests.
3. Schema check: run `sqlite3 /tmp/cex.test.sqlite3 "PRAGMA table_info(markets);"` and confirm new columns exist and dropped columns are absent.
4. Basic DB API smoke test: run a tiny Zig test that calls `insertArbEvent` and `insertFundingSnapshot` and reads them back.

**Decisions & Assumptions**

- Assume `013` already implements positions/orders/funding tables (repository shows `013` present); Phase 7 will only add markets overhaul and helper embedding where needed after step 1 verification.
- All DB changes will follow existing project pattern: embedded migrations in `zig/src/db.zig` and file-based SQL under `db/migrations/` for CLI runner parity.
- Keep changes Zig-first; do not change TypeScript IPC types or UI in this phase.

**Further Considerations**

1. Confirm whether `base_asset` should be derived from `markets.base` or stored separately (recommended to store to avoid string parsing in hot paths).
2. If tests rely on old `markets.condition_id`/`clob_token_ids`, plan a small compatibility shim (temporary columns) for test updates.
