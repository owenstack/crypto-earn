## Plan: Phase 8 — Dry-Run Calibration & Monitoring Fixes

TL;DR — Recalibrate the dry-run test conditions to remove sizing distortions
found during review (balance below the engine's own order-notional floor,
and a fixed-dollar exposure cap that silently overrides the intended
balance-scaled one), and adopt the new `scripts/check-dry-run.sh` (which
wraps `jq`) as the *only* way status is checked going forward. The
`lp_max_position_usd` fix should be made **permanent** via a proper
migration, not a one-off manual `DELETE`, so every future fresh deploy
gets balance-scaled sizing by default. The monitoring loop is owned and
operated by a separate long-running agent outside this phase — do not
diagnose, restart, or take ownership of it; this phase only adds a
read-only status check for visibility. This is otherwise a calibration/ops
phase — do not modify strategy signal logic (spread thresholds, skew
config, arb thresholds) or `HL_SYMBOLS`. `cex_dex_arb` stays disabled;
symbol expansion is explicitly out of scope and deferred to a future phase.

**Steps**

1. Permanently remove the `lp_max_position_usd` $50 seed so balance-scaled
   sizing (`lp_max_position_usd_pct`, default 20%) is the default for every
   deploy — current and future. Do this via migration, matching the
   project's own pattern (mirror `zig/src/db.zig` migrations 14/15/16 and
   `plan/phase-7.prompt.md`'s approach), not a manual one-off `DELETE`:
   - Confirm the next unused migration number (currently `017` — check
     `db/migrations/` and the highest `migrationApplied(N)` call in
     `db.zig` before assuming).
   - Add `db/migrations/017_remove_lp_max_position_usd_default.sql`:
     ```sql
     DELETE FROM runtime_config WHERE key = 'lp_max_position_usd';
     INSERT OR IGNORE INTO schema_migrations(version) VALUES (17);
     ```
   - In `zig/src/db.zig`, add a `MIGRATION_017` embedded constant with the
     same SQL and a `runMigrations()` block guarded by
     `if (!self.migrationApplied(17))`, mirroring the existing pattern for
     14–16. This is what makes the fix apply automatically to your
     already-migrated DB on next startup, without a manual `sqlite3` command.
   - In migration 008's block (~L497–500), remove the
     `INSERT OR IGNORE INTO runtime_config(key,value) VALUES('lp_max_position_usd','50.0')`
     line entirely, so brand-new fresh databases never seed it in the
     first place and go straight to balance-derivation in `main.zig`.
     Leave the rest of migration 008 (the `ALTER TABLE` statements) untouched.
   - Confirm `lp_max_position_usd_pct` still seeds `0.20` (migration 004,
     `db.zig` ~L122) — leave this as-is, it's the ratio that will now
     actually be used.

2. Raise `DRY_RUN_INITIAL_BALANCE`.
   - In `.env`, set `DRY_RUN_INITIAL_BALANCE=200` (was unset → defaulted
     to `10`, which sits below the engine's own `MIN_ORDER_NOTIONAL_USD=11.0`
     floor in `strategy_engine.zig`, forcing every order to be sized
     larger than the entire paper account).
   - Leave `DRY_RUN=1` unchanged.

3. Rebuild and restart the engine so migration 017 runs and both fixes apply.
   - `docker compose down && docker compose up -d --build` (rebuild is
     required since `db.zig` changed, not just a plain restart).
   - Confirm in engine logs (`docker compose logs engine`):
     - Migration log shows `applying migration 017` (or `already applied`
       on subsequent restarts).
     - The line reads `lp_max_position_usd derived from balance: $40.00 (pct=0.20, balance=$200.00)` — **not** `lp_max_position_usd=50.00`. If it still says the latter, migration 017 didn't run; check `schema_migrations` and logs before retrying.
     - Balance/portfolio reflects the new $200 starting point.

4. Monitoring loop: out of scope, do not touch.
   - The monitoring loop is owned and operated by a separate long-running
     agent. This phase must not diagnose, restart, reconfigure, or add a
     restart policy to it — that's someone else's process to manage, and
     duplicate intervention risks conflicting with what that agent is
     already doing.
   - The only thing this phase does with it is add a **read-only** status
     check in `scripts/check-dry-run.sh` (step 5) purely for visibility
     when a human runs the script — not as a remediation mechanism.

5. Install and adopt `scripts/check-dry-run.sh`.
   - Add the script (provided separately) to `scripts/check-dry-run.sh`,
     `chmod +x` it.
   - Wire its `TODO` monitoring-loop block to a **read-only** status query
     only (e.g. `systemctl is-active <unit>`, `pm2 jlist | jq ...`, or
     equivalent) so the check reports whether the loop is up. Ask the
     long-running monitoring agent (or check its own docs/logs) what the
     correct process/service name is — do not guess, and do not add any
     start/restart/reconfigure logic here, per step 4.
   - From this point forward, **all dry-run status checks — by any agent
     or script, ad hoc or scheduled — must go through `scripts/check-dry-run.sh`**,
     not raw `curl`/`jq` one-offs. It appends a JSONL history entry,
     computes `pnl_bps_of_equity` (comparable across balance changes,
     unlike raw dollar PnL), and gates a confidence label on fill count.
   - Confirm it runs cleanly against the new $200 balance and produces a
     first entry in `~/.cex-earn-health.jsonl` (or `$CEX_HEALTH_HISTORY`
     if overridden).

6. Confirm `cex_dex_arb` stays disabled — explicit product decision, not a gap.
   - Verify `.env` still has `ENABLE_CEX_DEX_ARB=0` (or unset) and
     `ARB_SUBMIT_ORDERS=0`. Do not enable in this phase — market_making is
     being calibrated first as the primary strategy.

7. Do not touch symbol scope in this phase.
   - `HL_SYMBOLS` stays as-is (`BTC,ETH,SOL`). Do not add smaller/volatile
     tokens yet.
   - Note for a future phase (do not implement now): `strategy_engine.zig`
     has no toxic-flow/trend detection — only `lp_min_spread_bps` (entry
     filter) and reactive post-fill inventory skew (`mm_skew_enter_pct`/
     `mm_skew_exit_pct`). Before expanding into thinner/more volatile
     markets, a momentum/trend filter or a per-market daily-loss circuit
     breaker should be designed first. Log this as a backlog item.

8. Re-establish a check cadence instead of on-demand checks.
   - Schedule `scripts/check-dry-run.sh` every 6–12h via cron (this
     phase's own scheduling, independent of the separately-owned
     monitoring loop), rather than running it manually.
   - Do not treat the `diagnosis` field as a verdict below the script's
     own confidence threshold (~30 filled trades) — `db.zig`'s diagnosis
     logic flips to `paper_loss` on any `net_pnl <= 0.0`, regardless of
     magnitude, so small-sample runs will look worse than they are.

**Relevant files**

- `.env` — `DRY_RUN_INITIAL_BALANCE`, `ENABLE_CEX_DEX_ARB`, `ARB_SUBMIT_ORDERS`, `HL_SYMBOLS` (verify unchanged).
- `db/migrations/017_remove_lp_max_position_usd_default.sql` — new migration to add.
- `zig/src/db.zig` — remove the `lp_max_position_usd` seed line from migration 008 (~L497–500); add `MIGRATION_017` constant + `runMigrations()` block (mirror pattern used for 14–16).
- `zig/src/main.zig` (~L390–415) — reference only; confirms boot-only resolution of `lp_max_position_usd`, unaffected by this change.
- `scripts/check-dry-run.sh` — new script to add and adopt as the standard check; its monitoring-loop block is read-only status only.
- Monitoring-loop process — **out of scope**, owned by a separate long-running agent; do not modify.

**Verification**

1. `sqlite3 ./data/cex.db "SELECT * FROM runtime_config WHERE key='lp_max_position_usd';"` returns no row, confirming the permanent removal (not just a manual delete that a future migration could re-seed).
2. `schema_migrations` includes version `17`; engine logs after rebuild+restart show `applying migration 017` (first boot) or already-applied on subsequent boots, followed by `lp_max_position_usd derived from balance: $40.00 (pct=0.20, balance=$200.00)`.
3. `.env` shows `DRY_RUN_INITIAL_BALANCE=200`, `DRY_RUN=1`, `ENABLE_CEX_DEX_ARB=0`, `HL_SYMBOLS=BTC,ETH,SOL` (unchanged).
4. `zig build test` still passes after the `db.zig` edits (migration 008 edit + new migration 017), matching the verification pattern used in `plan/phase-7.prompt.md`.
5. `scripts/check-dry-run.sh` runs end-to-end with no errors, prints a `jq`-parsed snapshot including `pnl_bps_of_equity` and a `confidence` label, reports the monitoring loop's status read-only (without attempting to manage it), and appends a line to the history JSONL file.
6. A scheduled job (cron or equivalent) is confirmed to call `scripts/check-dry-run.sh` on a fixed cadence — this phase may set up the schedule, but must not route it through or depend on the separately-owned monitoring loop.

**Decisions & Assumptions**

- Confirmed by Owen: balance-derived exposure cap (20% via
  `lp_max_position_usd_pct`) should be the **permanent** default, not a
  one-time manual override — hence the migration-based fix in step 1
  instead of a runtime `DELETE`.
- This phase is calibration/ops only — no changes to `lp_min_spread_bps`,
  `news_delta_threshold`, `cex_dex_arb` thresholds, or any strategy logic.
- Confirmed by Owen: the monitoring loop is owned and operated by a
  separate long-running agent. This phase must not diagnose, fix, restart,
  or add supervision to it — only a read-only status query for the
  check script's visibility.

**Further Considerations**

1. Once ~30+ fills accumulate on the recalibrated $200 run, re-run
   `scripts/analyze-dry-run.sh` section 5 (per-market profitability
   estimate) and compare the `pnl_bps_of_equity` trend from the new
   history file, rather than judging off a single `diagnosis` snapshot.
2. Before any future phase expands `HL_SYMBOLS` into smaller/more volatile
   markets, design a toxic-flow guard (momentum/trend filter or per-market
   daily-loss circuit breaker) — flag as backlog, not part of this phase.
3. Worth a discussion with Owen (not an autonomous change): should the
   `paper_loss` diagnosis in `db.zig` require a minimum `filled_trades`
   count before it can fire, so the label itself reflects statistical
   confidence instead of a bare `net_pnl <= 0.0` check?
