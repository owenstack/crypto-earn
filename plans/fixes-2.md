# cex-zig Hardening Plan
## Small-Account Live Deployment ($10 Initial Capital)

**Version:** 1.0  
**Status:** Pre-implementation  
**Goal:** Make the engine safe, self-scaling, and verifiably profitable before deploying real funds.

---

## Overview

This document is the complete engineering plan for hardening cex-zig into a $10 live deployment. It covers seven phases executed in strict order. Phases 0 and 1 are safety-critical and must be completed before any other work begins. The engine must not touch real funds until the dry-run gate in Phase 7 is passed.

The two core design principles that run through every change are:

**All risk limits scale with balance.** Hardcoding absolute USD values means a profitable bot stays permanently constrained. Every limit is expressed as a ratio of current USDC balance. Absolute USD values exist only as cold-start fallbacks for the period before the first balance snapshot is recorded.

**No manual configuration for market discovery.** The Kalshi market mapping is the single biggest operability gap. Auto-discovery must work from day one with zero manual setup.

---

## Phase 0: Risk Parameter Calibration

**Timeline:** Day 1, morning  
**Risk if skipped:** Account blown within hours of going live.

### 0.1 — Replace absolute risk limits with ratio-based limits

The current `RiskConfig` has hardcoded values tuned for a $500+ account. Replace the three main USD limits with percentage-of-balance equivalents and retain absolute values only as cold-start fallbacks.

**File: `zig/src/risk_gate.zig`**

```zig
pub const RiskConfig = struct {
    // --- Ratio-based limits (scale automatically with balance) ---

    /// Max notional for a single order as a fraction of balance.
    /// 0.15 on $10 = $1.50 order. On $100 = $15. On $500 = $75.
    max_position_pct: f64 = 0.15,

    /// Max total open exposure as fraction of balance.
    /// 0.80 leaves 20% undeployed as buffer for fees and drawdown.
    max_portfolio_exposure_pct: f64 = 0.80,

    /// Daily loss kill-switch as fraction of balance.
    /// 0.30 on $10 = halt at -$3. On $100 = halt at -$30.
    max_daily_drawdown_pct: f64 = 0.30,

    // --- Absolute fallbacks (used only before first balance snapshot) ---
    max_position_usd_fallback: f64 = 1.50,
    max_portfolio_exposure_usd_fallback: f64 = 8.0,
    max_daily_drawdown_usd_fallback: f64 = 3.0,

    // --- Unchanged fields ---
    max_open_orders: u32 = 200,
    allow_duplicate_positions: bool = false,
    max_balance_commitment_ratio: f64 = 0.70,
    balance_snapshot_max_age_seconds: i64 = 600,
    nominal_order_notional_usd: f64 = 0.75,
};
```

### 0.2 — Add a limit resolver

Add `ResolvedLimits` and `resolveLimits` directly below `RiskConfig`:

```zig
pub const ResolvedLimits = struct {
    max_position_usd: f64,
    max_portfolio_exposure_usd: f64,
    max_daily_drawdown_usd: f64,
};

pub fn resolveLimits(config: RiskConfig, balance: ?f64) ResolvedLimits {
    const bal = balance orelse {
        return .{
            .max_position_usd           = config.max_position_usd_fallback,
            .max_portfolio_exposure_usd = config.max_portfolio_exposure_usd_fallback,
            .max_daily_drawdown_usd     = config.max_daily_drawdown_usd_fallback,
        };
    };
    return .{
        .max_position_usd           = bal * config.max_position_pct,
        .max_portfolio_exposure_usd = bal * config.max_portfolio_exposure_pct,
        .max_daily_drawdown_usd     = bal * config.max_daily_drawdown_pct,
    };
}
```

### 0.3 — Update `validateOrder` to use resolved limits

`validateOrder` currently queries balance for the commitment ratio check. It already has `balance_opt` in scope. Replace the three hardcoded limit comparisons:

```zig
pub fn validateOrder(request: OrderRequest, database: *db.DB, config: RiskConfig) ValidationResult {
    // balance_opt is already queried for commitment ratio check — reuse it
    const balance_opt = database.queryLatestUsdcBalance(
        config.balance_snapshot_max_age_seconds
    ) catch null;

    const limits = resolveLimits(config, balance_opt);

    // Check 1: Max position size (was config.max_position_usd)
    if (notional > limits.max_position_usd) { ... }

    // Check 2: Max portfolio exposure (was config.max_portfolio_exposure_usd)
    if (current_exposure + notional > limits.max_portfolio_exposure_usd) { ... }

    // Check 3: Daily drawdown (was config.max_daily_drawdown_usd)
    if (@abs(daily_loss) >= limits.max_daily_drawdown_usd) { ... }

    // All other checks unchanged
}
```

### 0.4 — Scale strategy order sizes with balance

**File: `zig/src/strategy_engine.zig`**

```zig
pub const StrategyConfig = struct {
    news_delta_threshold: f64 = 0.06,
    news_confidence_min: f64 = 0.40,

    /// News order size as fraction of balance. 0.12 on $10 = $1.20.
    news_order_size_pct: f64 = 0.12,
    news_order_size_fallback: f64 = 1.20,

    lp_min_spread: f64 = 0.06,
    lp_exit_spread: f64 = 0.03,

    /// LP order size as fraction of balance. 0.07 on $10 = $0.70.
    lp_order_size_pct: f64 = 0.07,
    lp_order_size_fallback: f64 = 0.70,
};
```

Add a resolver function in the same file:

```zig
pub fn resolveOrderSize(balance: f64, pct: f64, fallback: f64) f64 {
    if (balance <= 0) return fallback;
    // Floor at $0.50 — Polymarket minimum viable order
    return @max(balance * pct, 0.50);
}
```

Update `evaluateNewsRepricing` and `evaluateLiquidityProvision` to accept a `balance: f64` parameter and call `resolveOrderSize` in place of `self.config.news_order_size` and `self.config.lp_order_size`.

Pass `ctx.pt.usdc_balance` from `dispatchSignal` in `main.zig` when calling into these functions.

### 0.5 — Add a runtime order-size cap override

In `dispatchSignal` in `main.zig`, before calling `placeOrder`, check for an optional cap:

```zig
var size_cap_buf: [16]u8 = undefined;
const size_cap_str = ctx.database.getConfig("max_order_size_usd", &size_cap_buf);
if (size_cap_str) |cap_str| {
    if (std.fmt.parseFloat(f64, cap_str)) |cap| {
        if (signal_size > cap) signal_size = cap;
    } else |_| {}
}
```

This allows `/config set max_order_size_usd 5.00` from Telegram to temporarily cap orders during volatile periods without a restart.

### 0.6 — How limits scale in practice

| Balance | Max order (15%) | Max exposure (80%) | Daily halt (30%) | Max open orders |
|---------|----------------|-------------------|-----------------|-----------------|
| $10 | $1.50 | $8.00 | $3.00 | 9 |
| $25 | $3.75 | $20.00 | $7.50 | 23 |
| $50 | $7.50 | $40.00 | $15.00 | 46 |
| $100 | $15.00 | $80.00 | $30.00 | 93 |
| $500 | $75.00 | $400.00 | $150.00 | 200 (hard cap) |

---

## Phase 1: LP Inventory Management Fix

**Timeline:** Day 1, afternoon  
**Risk if skipped:** LP strategy builds unlimited one-sided exposure. A bad run can lose the entire account.

The `updateInventory` function is fully implemented in `strategy_engine.zig` but is never called anywhere. The LP pair linking after order placement is also missing. This phase closes both gaps.

### 1.1 — Add `StrategyEngine` reference to `FillPoller`

**File: `zig/src/fill_poller.zig`**

```zig
pub const FillPoller = struct {
    allocator: std.mem.Allocator,
    database: *db_mod.DB,
    om: *order_mgr.OrderManager,
    pt: *portfolio.PortfolioTracker,
    se: ?*strategy.StrategyEngine,   // ADD
    // ... rest unchanged
};

pub fn init(
    allocator: std.mem.Allocator,
    database: *db_mod.DB,
    om: *order_mgr.OrderManager,
    pt: *portfolio.PortfolioTracker,
    se: ?*strategy.StrategyEngine,   // ADD
) FillPoller {
    return .{
        // ... existing fields
        .se = se,
    };
}
```

**File: `zig/src/main.zig`** — update the init call:

```zig
var fp = fill_poller.FillPoller.init(allocator, &database, &om, &pt, &se);
```

### 1.2 — Create a shared fill-confirmation handler

Add this function to `fill_poller.zig`. It is called from both `runFillCheck` (REST path) and `handleWsMessage` (WebSocket path), so fill logic is never duplicated:

```zig
fn onFillConfirmed(
    self: *FillPoller,
    order_id: []const u8,
    market_id: []const u8,
    direction: []const u8,   // "buy" or "sell"
    fill_size_f: f64,
    is_fully_filled: bool,
) void {
    if (self.se) |se| {
        // Update per-market inventory
        const dir: strategy.SignalDirection = if (std.mem.eql(u8, direction, "buy"))
            .buy
        else
            .sell;
        se.updateInventory(market_id, dir, fill_size_f);

        // On full fill, cancel the paired LP order
        if (is_fully_filled) {
            if (se.findPairedOrder(order_id)) |paired_id| {
                if (self.om.cancelOrder(paired_id)) {
                    se.untrackOrder(paired_id);
                    se.incrementCancels(.liquidity_provision);
                    log.info("fill_poller", "cancelled LP pair: {s}", .{paired_id});
                }
            }
            se.untrackOrder(order_id);
        }
    }
}
```

Replace the ad-hoc IPC publish blocks in both `runFillCheck` and `handleWsMessage` with a call to `onFillConfirmed` followed by the IPC publish. The IPC publish stays in each call site because the payload differs slightly between REST and WebSocket paths.

### 1.3 — Wire up LP pair linking in `dispatchSignal`

**File: `zig/src/main.zig`**

Currently `evaluateLpSignals` calls `dispatchSignal` twice (once per signal) with no awareness that they are a pair. Refactor so both LP signals are placed atomically and then linked:

```zig
fn dispatchLpPair(ctx: *StrategyWorkerCtx, buy_signal: strategy.Signal, sell_signal: strategy.Signal) void {
    // Place buy leg
    const buy_result = ctx.om.placeOrder(
        buy_signal.market_id[0..buy_signal.market_id_len],
        "buy", buy_size_str, buy_price_str, "limit", "liquidity_provision"
    );

    // Place sell leg
    const sell_result = ctx.om.placeOrder(
        sell_signal.market_id[0..sell_signal.market_id_len],
        "sell", sell_size_str, sell_price_str, "limit", "liquidity_provision"
    );

    // Track and link both orders
    if (buy_result == .success and sell_result == .success) {
        const buy_tracked  = ctx.se.trackOrder(buy_result.success.order_id,  ...);
        const sell_tracked = ctx.se.trackOrder(sell_result.success.order_id, ...);

        if (buy_tracked and sell_tracked) {
            if (ctx.se.findOrderIndex(buy_result.success.order_id))  |bi|
            if (ctx.se.findOrderIndex(sell_result.success.order_id)) |si| {
                ctx.se.linkPair(bi, si);
            }
        }
        ctx.se.incrementOrdersAccepted(.liquidity_provision);
        ctx.se.incrementOrdersAccepted(.liquidity_provision);
    }

    // Free heap-owned order IDs
    if (buy_result == .success)  ctx.om.allocator.free(buy_result.success.order_id);
    if (sell_result == .success) ctx.om.allocator.free(sell_result.success.order_id);
}
```

Replace the two `dispatchSignal` calls inside `evaluateLpSignals` with one call to `dispatchLpPair`.

### 1.4 — Update `lp_max_position_usd` to scale with balance

The LP per-market position cap has the same hardcoded problem as order sizes. In `main.zig` where `se.lp_max_position_usd` is loaded from `runtime_config`, fall back to a ratio if no override is set:

```zig
// After loading lp_max_position_usd from runtime_config:
// If not explicitly set, default to 20% of current balance
if (database.getConfig("lp_max_position_usd", &lp_buf) == null) {
    const bal = pt.usdc_balance;
    se.lp_max_position_usd = if (bal > 0) bal * 0.20 else 2.0;
}
```

Seed a ratio-aware default in migration 010 (added in Phase 2):
```sql
INSERT OR IGNORE INTO runtime_config(key,value) VALUES('lp_max_position_usd_pct','0.20');
```

---

## Phase 2: Automatic Kalshi Market Mapping

**Timeline:** Day 2–3  
**Risk if skipped:** News strategy fires zero signals or fires on low-quality Manifold data.

The manual `kalshi_market_map` runtime config key is eliminated entirely. A three-tier auto-discovery system replaces it, with all discovered mappings persisted across restarts.

### 2.1 — Add `kalshi_market_map` table (migration 010)

**File: `zig/src/db.zig`**

```zig
const MIGRATION_010 =
    \\CREATE TABLE IF NOT EXISTS kalshi_market_map(
    \\  ticker TEXT PRIMARY KEY,
    \\  gamma_id TEXT NOT NULL,
    \\  confidence REAL NOT NULL DEFAULT 0.0,
    \\  match_method TEXT NOT NULL DEFAULT 'auto',
    \\  created_at INTEGER NOT NULL DEFAULT(unixepoch()),
    \\  updated_at INTEGER NOT NULL DEFAULT(unixepoch())
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_kalshi_map_gamma ON kalshi_market_map(gamma_id);
    \\INSERT OR IGNORE INTO runtime_config(key,value) VALUES('lp_cooldown_seconds','15');
    \\INSERT OR IGNORE INTO runtime_config(key,value) VALUES('lp_max_position_usd_pct','0.20');
    \\INSERT OR IGNORE INTO schema_migrations(version)VALUES(10);
;
```

Add three DB helpers:

```zig
pub fn upsertKalshiMapping(
    self: DB,
    ticker: []const u8,
    gamma_id: []const u8,
    confidence: f64,
    method: []const u8,
) !void { ... }

pub fn lookupKalshiMapping(self: DB, ticker: []const u8, buf: []u8) ?[]const u8 { ... }

pub const KalshiMapRow = struct {
    ticker_buf: [64]u8,
    ticker_len: usize,
    gamma_id_buf: [64]u8,
    gamma_id_len: usize,
    confidence: f64,
    match_method_buf: [32]u8,
    match_method_len: usize,
};

pub fn getAllKalshiMappings(self: DB, alloc: std.mem.Allocator) ![]KalshiMapRow { ... }
```

### 2.2 — Three-tier resolution in `probability_provider.zig`

Replace `queryKalshiMappedMarketId` with `resolveKalshiTicker`:

```zig
fn resolveKalshiTicker(
    self: *ProbabilityProvider,
    ticker: []const u8,
    title: ?[]const u8,
    subtitle: ?[]const u8,
    out: *[64]u8,
) ?[]const u8 {
    // Tier 1: DB-persisted mapping (survives restarts, highest confidence)
    if (self.database.lookupKalshiMapping(ticker, out)) |id| return id;

    // Tier 2: In-memory auto-map seeded during current session
    if (self.kalshi) |kws| {
        kws.mu.lock();
        defer kws.mu.unlock();
        for (0..kws.auto_map_count) |i| {
            const t = kws.auto_map_tickers[i][0..kws.auto_map_ticker_lens[i]];
            if (std.mem.eql(u8, t, ticker)) {
                const len = kws.auto_map_market_id_lens[i];
                @memcpy(out[0..len], kws.auto_map_market_ids[i][0..len]);
                return out[0..len];
            }
        }
    }

    // Tier 3: Fuzzy title match against markets table
    if (title) |t| {
        if (self.queryMarketIdByQuestion(t, out)) |id| {
            self.database.upsertKalshiMapping(ticker, id, 0.75, "title_match") catch {};
            if (self.kalshi) |kws| kws.upsertAutoMapping(ticker, id);
            return id;
        }
    }
    if (subtitle) |s| {
        if (self.queryMarketIdByQuestion(s, out)) |id| {
            self.database.upsertKalshiMapping(ticker, id, 0.60, "subtitle_match") catch {};
            if (self.kalshi) |kws| kws.upsertAutoMapping(ticker, id);
            return id;
        }
    }

    return null;
}
```

### 2.3 — Persist mappings from Kalshi REST responses

In `parseKalshiRestInto`, after every successful `gamma_id` resolution, write to the DB:

```zig
self.database.upsertKalshiMapping(ticker, gamma_id, confidence, match_method) catch {};
```

This means each session that successfully matches markets makes the next cold start faster.

### 2.4 — Remove manual config dependency

- Remove `kalshi_market_map` from all references in `probability_provider.zig` as a primary lookup path. It remains readable for backward compatibility but is no longer required.
- Remove it from `.env.example` required keys section.
- Remove it from the `config.validate` IPC handler's checked fields.

### 2.5 — Add `/mappings` Telegram command

**File: `ts/src/telegram/bot.ts`**

```typescript
bot.command("mappings", guard(async ctx => {
    if (!ipc.connected) { await ctx.reply("🔴 Engine IPC offline."); return; }
    const res = await ipc.request("config.get");
    // Query mappings via a new IPC message type, or via direct DB read
    // Show ticker → gamma_id, confidence, method, last updated
    await ctx.reply(
        `🗺️ *Kalshi Market Mappings*\n\n` +
        `Use /config to inspect or override specific tickers.\n` +
        `Mappings are discovered automatically.`,
        { parse_mode: "Markdown" }
    );
}));
```

Add a `kalshi_mappings` IPC request type that returns the full `kalshi_market_map` table. Wire it through `ipc_types.zig` and `ipc.zig` in the same pattern as existing handlers.

---

## Phase 3: Dry-Run Mode Overhaul

**Timeline:** Day 3–4  
**Risk if skipped:** No verifiable signal that the strategy works before real money is deployed.

Currently dry-run writes signals to a table and stops there. The balance never moves, orders have no lifecycle, and the only feedback is a manual `dry_run.analysis` call. This phase makes dry-run indistinguishable from live trading in terms of feedback — except no real orders are placed.

### 3.1 — Add `dry_run_orders` table (in migration 010)

Append to the migration 010 SQL:

```sql
CREATE TABLE IF NOT EXISTS dry_run_orders(
  id TEXT PRIMARY KEY,
  market_id TEXT NOT NULL,
  strategy TEXT NOT NULL,
  direction TEXT NOT NULL,
  signal_price REAL NOT NULL,
  size REAL NOT NULL,
  status TEXT NOT NULL DEFAULT 'open',
  fill_price REAL,
  fill_ts INTEGER,
  pnl REAL,
  fees REAL,
  created_at INTEGER NOT NULL DEFAULT(unixepoch()),
  updated_at INTEGER NOT NULL DEFAULT(unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_dry_run_orders_status  ON dry_run_orders(status);
CREATE INDEX IF NOT EXISTS idx_dry_run_orders_market  ON dry_run_orders(market_id, status);
CREATE INDEX IF NOT EXISTS idx_dry_run_orders_created ON dry_run_orders(created_at DESC);
```

Add DB helpers:

```zig
pub fn insertDryRunOrder(
    self: DB,
    id: []const u8,
    market_id: []const u8,
    strategy_name: []const u8,
    direction: []const u8,
    signal_price: f64,
    size: f64,
) !void { ... }

pub fn settleDryRunOrder(
    self: DB,
    id: []const u8,
    status: []const u8,   // "filled", "cancelled", "expired"
    fill_price: f64,
    pnl: f64,
    fees: f64,
) !void { ... }

pub fn getOpenDryRunOrders(self: DB, out: []DryRunOrderRow) !usize { ... }
```

### 3.2 — Rewrite the dry-run dispatch branch

**File: `zig/src/main.zig`**

Replace the current dry-run log-and-return block in `dispatchSignal` with a proper function:

```zig
fn dispatchDryRun(ctx: *StrategyWorkerCtx, signal: strategy.Signal) void {
    const market_id = signal.market_id[0..signal.market_id_len];
    const direction: []const u8 = if (signal.direction == .buy) "buy" else "sell";

    // Generate a deterministic fake order ID
    var id_buf: [64]u8 = undefined;
    const order_id = std.fmt.bufPrint(&id_buf, "dry-{s}-{d}", .{
        market_id[0..@min(market_id.len, 8)],
        std.time.milliTimestamp(),
    }) catch "dry-unknown";

    const bid: ?f64 = if (signal.best_bid > 0) signal.best_bid else null;
    const ask: ?f64 = if (signal.best_ask > 0) signal.best_ask else null;
    const mid = if (bid != null and ask != null) (bid.? + ask.?) / 2.0 else signal.price;
    const delta = @abs(signal.price - mid);
    const spread = if (bid != null and ask != null) ask.? - bid.? else 0.0;

    // Persist to dry_run_signals (existing analytics table)
    ctx.database.insertDryRunSignal(
        market_id, @tagName(signal.strategy), direction,
        signal.price, signal.size, delta, signal.confidence,
        signal.timestamp, bid, ask,
    ) catch {};

    // NEW: persist to dry_run_orders for lifecycle tracking
    ctx.database.insertDryRunOrder(
        order_id, market_id, @tagName(signal.strategy),
        direction, signal.price, signal.size,
    ) catch {};

    log.info("dry_run", "[{s}] {s} {s} x{d:.2} @ {d:.4} | conf={d:.2} spread={d:.4}", .{
        order_id[0..@min(order_id.len, 14)],
        direction,
        market_id[0..@min(market_id.len, 20)],
        signal.size,
        signal.price,
        signal.confidence,
        spread,
    });
}
```

### 3.3 — Dry-run fill simulation worker

Add a function called from the strategy worker loop every 30 seconds when `ctx.dry_run` is true:

```zig
fn simulateDryRunFills(ctx: *StrategyWorkerCtx) void {
    var orders: [64]db_mod.DB.DryRunOrderRow = undefined;
    const count = ctx.database.getOpenDryRunOrders(&orders) catch return;

    const now = std.time.timestamp();
    const fee_bps: f64 = 2.0;   // 2bps per side, matches live config

    for (orders[0..count]) |order| {
        const oid  = order.id[0..order.id_len];
        const mid  = order.market_id[0..order.market_id_len];
        const dir  = order.direction[0..order.direction_len];
        const is_buy = std.mem.eql(u8, dir, "buy");

        // Expire orders older than 30 minutes
        if (now - order.created_at > 1800) {
            ctx.database.settleDryRunOrder(oid, "expired", 0, 0, 0) catch {};
            continue;
        }

        // Look up current live orderbook for this market
        const ob = queryLatestOrderbook(ctx.database, mid) orelse continue;

        // Fill condition: buy fills if ask <= signal_price, sell fills if bid >= signal_price
        const fills = if (is_buy)
            ob.best_ask <= order.signal_price
        else
            ob.best_bid >= order.signal_price;

        if (!fills) continue;

        const fill_price = if (is_buy) ob.best_ask else ob.best_bid;
        const notional = fill_price * order.size;
        const fees = notional * (fee_bps / 10000.0) * 2.0;  // entry + exit

        // P&L is mark-to-mid at fill time (conservative estimate)
        const pnl_gross = if (is_buy)
            (ob.mid_price - fill_price) * order.size
        else
            (fill_price - ob.mid_price) * order.size;
        const pnl_net = pnl_gross - fees;

        ctx.database.settleDryRunOrder(oid, "filled", fill_price, pnl_net, fees) catch {};

        log.info("dry_run", "FILL [{s}] {s} {d:.4} -> pnl={d:.4} fees={d:.4}", .{
            oid[0..@min(oid.len, 14)], dir, fill_price, pnl_net, fees,
        });
    }

    // Update simulated balance after all fills
    updateDryRunBalance(ctx);
}

fn updateDryRunBalance(ctx: *StrategyWorkerCtx) void {
    // Read current dry-run balance (last balance_snapshot)
    // Add sum of pnl from newly settled dry_run_orders
    // Write a new balance_snapshot
    // This makes /balance, risk gate, and dynamic limits all work in dry-run
    const filled_sql =
        "SELECT COALESCE(SUM(pnl), 0.0) FROM dry_run_orders " ++
        "WHERE status='filled' AND updated_at > ?;" ++ &[_:0]u8{};
    // ... query, then insertBalanceSnapshot with adjusted balance
}
```

Add `simulateDryRunFills` to the strategy worker loop:

```zig
// In strategyWorker, inside the loop:
if (ctx.dry_run) {
    ctx.sim_tick +%= 1;
    if (ctx.sim_tick % 6 == 0) {   // every ~30s (6 × 5s eval interval)
        simulateDryRunFills(ctx);
    }
}
```

Add `sim_tick: u64 = 0` to `StrategyWorkerCtx`.

### 3.4 — New Telegram commands for dry-run

**File: `ts/src/telegram/bot.ts`**

```typescript
bot.command("drystatus", guard(async ctx => {
    if (!ipc.connected) { await ctx.reply("🔴 Engine IPC offline."); return; }
    const res = await ipc.request<DryRunAnalysisResponsePayload>("dry_run.analysis");
    const p = res.payload;

    const diagEmoji: Record<string, string> = {
        paper_viable:       "✅",
        paper_loss:         "❌",
        fill_rate_too_low:  "⚠️",
        no_fills_detected:  "🔴",
        no_data:            "⏳",
    };
    const emoji = diagEmoji[p.diagnosis] ?? "❓";

    await ctx.reply(
        `🔬 *Dry-Run Status*\n` +
        `${emoji} Diagnosis: \`${p.diagnosis}\`\n\n` +
        "```\n" +
        `Total Signals:    ${p.total_signals}\n` +
        `Persistent:       ${p.persistent_signals} (${p.persistence_pct.toFixed(1)}%)\n` +
        `─────────────────────────────\n` +
        `Paper Trades:     ${p.paper_filled_trades} filled\n` +
        `Missed Fills:     ${p.paper_unfilled_signals}\n` +
        `Fill Rate:        ${p.paper_fill_rate_pct.toFixed(1)}%\n` +
        `─────────────────────────────\n` +
        `Wins / Losses:    ${p.paper_winning_trades} / ${p.paper_losing_trades}\n` +
        `Win Rate:         ${p.paper_win_rate_pct.toFixed(1)}%\n` +
        `Net P&L:          $${p.paper_net_pnl.toFixed(4)}\n` +
        `Avg per Trade:    $${p.paper_avg_pnl_per_trade.toFixed(4)}\n` +
        `Expectancy/Sig:   $${p.paper_expectancy_per_signal.toFixed(4)}\n` +
        `Profit Factor:    ${p.paper_profit_factor.toFixed(2)}\n` +
        `Max Drawdown:     $${p.paper_max_drawdown.toFixed(4)}\n` +
        `Avg Hold:         ${p.paper_avg_hold_seconds.toFixed(0)}s\n` +
        "```",
        { parse_mode: "Markdown" }
    );
}));
```

Update `/balance` to show a dry-run banner:

```typescript
// At the top of the /balance handler, before the IPC call:
const isDryRun = process.env.DRY_RUN === "1" || process.env.DRY_RUN === "true";
const dryRunBadge = isDryRun ? "🔬 *[DRY RUN — simulated balance]*\n\n" : "";
// Prepend dryRunBadge to the reply string
```

---

## Phase 4: `portfolio_tracker.syncFromDB()` Optimization

**Timeline:** Day 4  
**Risk if skipped:** Performance only — not safety-critical, but noisy logs and unnecessary DB load on every fill.

### 4.1 — Add targeted in-memory position update

**File: `zig/src/portfolio_tracker.zig`**

Add a new method that updates only the affected position without touching SQLite:

```zig
pub fn applyFillDelta(
    self: *PortfolioTracker,
    market_id: []const u8,
    fill_size: f64,
    fill_price: f64,
    side: []const u8,
) void {
    // Search existing positions for this market_id
    for (self.positions[0..self.position_count]) |*pos| {
        if (!std.mem.eql(u8, pos.market_id[0..pos.market_id_len], market_id)) continue;

        // Update current price and recalculate unrealized PnL
        pos.current_price = fill_price;
        pos.unrealized_pnl = calculateUnrealizedPnl(pos.*);
        return;
    }

    // Not found — this is an opening fill, add new position
    if (self.position_count >= MAX_POSITIONS) {
        log.warn("portfolio", "applyFillDelta: position array full, deferring to syncFromDB", .{});
        return;
    }

    var pos = Position{
        .market_id     = [_]u8{0} ** 64,
        .market_id_len = @min(market_id.len, 64),
        .side          = [_]u8{0} ** 8,
        .side_len      = @min(side.len, 8),
        .size          = fill_size,
        .entry_price   = fill_price,
        .current_price = fill_price,
        .unrealized_pnl = 0.0,
    };
    @memcpy(pos.market_id[0..pos.market_id_len], market_id[0..pos.market_id_len]);
    @memcpy(pos.side[0..pos.side_len], side[0..pos.side_len]);
    self.positions[self.position_count] = pos;
    self.position_count += 1;
}
```

### 4.2 — Rate-limit full syncs in `processFill`

```zig
pub fn processFill(
    self: *PortfolioTracker,
    order_id: []const u8,
    fill_id: []const u8,
    fill_size: []const u8,
    fill_price: []const u8,
    is_maker: bool,
) void {
    // ... existing fee/pnl parsing ...

    // Targeted in-memory update (no DB read at all)
    self.applyFillDelta(market_id_str, size_f, price_f, side_str);

    // Persist fill to DB — write only, no read
    self.database.insertFill(fill_id, order_id, fill_size, fill_price, fee_str) catch |e| {
        log.err("portfolio", "failed to persist fill: {any}", .{e});
    };

    // Full sync only if last sync was more than 60 seconds ago
    const now = std.time.timestamp();
    if (now - self.last_sync_ts > 60) {
        self.syncFromDB();
    }

    log.info("portfolio", "fill: order={s} size={s} price={s} fee={s} pnl={d:.4}", .{
        order_id, fill_size, fill_price, fee_str, self.realized_pnl_today,
    });
}
```

### 4.3 — Add balance dirty tracking

Add two fields to the `PortfolioTracker` struct:

```zig
balance_dirty: bool = false,
balance_cache_ts: i64 = 0,
```

Add a method called by the strategy worker's `persistBalanceSnapshot` after it writes:

```zig
pub fn markBalanceDirty(self: *PortfolioTracker) void {
    self.balance_dirty = true;
}
```

In `syncFromDB`, only re-query `balance_snapshots` when `balance_dirty` is true or when `now - balance_cache_ts > 300`:

```zig
const now = std.time.timestamp();
if (self.balance_dirty or now - self.balance_cache_ts > 300) {
    // ... existing balance_snapshots query ...
    self.balance_dirty = false;
    self.balance_cache_ts = now;
}
```

---

## Phase 5: Configurable LP Cooldown

**Timeline:** Day 4, afternoon — 30 minutes  
**Risk if skipped:** Minor. 60-second cooldown misses signals on active markets.

### 5.1 — Read cooldown from runtime config

**File: `zig/src/main.zig`** in `evaluateLpSignals`:

```zig
fn evaluateLpSignals(ctx: *StrategyWorkerCtx) void {
    // Read cooldown from runtime_config, default 15s, clamp 5–300s
    var cd_buf: [16]u8 = undefined;
    const cd_str = ctx.database.getConfig("lp_cooldown_seconds", &cd_buf) orelse "15";
    const cooldown_s = std.fmt.parseInt(i64, cd_str, 10) catch 15;
    const cooldown = std.math.clamp(cooldown_s, 5, 300);

    // ... existing orderbook query ...

    while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
        // ...
        if (ctx.se.checkLpCooldown(gid_span, cooldown)) continue;
        // ...
    }
}
```

The seed for `lp_cooldown_seconds = 15` is already included in migration 010 above.

Live tuning via Telegram: `/config set lp_cooldown_seconds 10`

---

## Phase 6: Documentation Update

**Timeline:** Day 5  
**Risk if skipped:** None at runtime.

### 6.1 — Update `README.md`

**Remove** the following outdated note:
> Native WebSocket upgrade support is not yet implemented in the Zig client. Current runtime behavior uses REST polling fallback for market updates.

**Replace** the Market Data Transport section with:

```markdown
## Market Data Transport

Real-time CLOB price feeds are delivered via WebSocket to
`ws-subscriptions-clob.polymarket.com`. Token IDs are subscribed dynamically
as markets are discovered by the scanner. New markets are subscribed without
reconnecting via dynamic subscription messages on the live socket.
```

**Replace** the manual Kalshi mapping instructions with:

```markdown
## Kalshi Integration

The engine automatically maps Kalshi tickers to Polymarket markets using a
three-tier resolution strategy:

1. **DB-persisted map** — previously discovered mappings (survives restarts)
2. **Runtime auto-map** — mappings discovered during the current session via
   the Kalshi WebSocket ticker stream
3. **Title fuzzy-match** — normalized string matching against market questions
   in the local `markets` table

No manual configuration is required. All discovered mappings are written to
the `kalshi_market_map` table and persist across restarts. Use `/mappings`
on the Telegram bot to inspect current mappings.

The optional `kalshi_market_map` runtime config key still works as a manual
override for edge cases where auto-discovery produces incorrect mappings.
```

**Add** a Runtime Tuning section:

```markdown
## Runtime Tuning

All values below can be changed live without restarting:
`/config set <key> <value>`

| Key | Default | Description |
|-----|---------|-------------|
| `lp_cooldown_seconds` | 15 | Seconds between LP signals per market |
| `lp_max_position_usd_pct` | 0.20 | LP max exposure as fraction of balance |
| `max_order_size_usd` | (unset) | Hard cap on any single order, overrides ratio |
| `prob_source_poll_seconds` | 60 | Kalshi REST poll interval |
| `kalshi_series_tickers` | (unset) | Comma-separated Kalshi series to focus on |
| `kalshi_api_key` | (unset) | Required for Kalshi WS primary source |
```

**Update** the Environment Variables section — remove `kalshi_market_map` from required keys. Move it to a new "Optional overrides" subsection.

**Update** the Dry-Run section:

```markdown
## Dry-Run Mode

Set `DRY_RUN=1` in `.env` to run without placing real orders.

In dry-run mode the engine:
- Generates real signals against live market data
- Simulates order fills using live bid/ask prices from the orderbook
- Tracks order lifecycle (open → filled/expired) in `dry_run_orders`
- Updates a virtual USDC balance in `balance_snapshots`
- Applies the full risk gate against the virtual balance

Because the risk gate and dynamic limits use `balance_snapshots`, dry-run
behaviour accurately mirrors what live trading would do at the same balance.

### Reading dry-run results

Use `/drystatus` on the Telegram bot for a live P&L summary.

The `diagnosis` field is your go/no-go gate:

| Diagnosis | Meaning |
|-----------|---------|
| `paper_viable` | Strategy is profitable on paper. Consider going live. |
| `paper_loss` | Do not go live. Review signal quality. |
| `fill_rate_too_low` | Signals exist but aren't filling. Widen thresholds. |
| `no_fills_detected` | Probability source not matching any markets. |
| `no_data` | Not enough signals yet. Run for at least 7 days. |
```

### 6.2 — Update `.env.example`

```bash
# Required
IPC_SOCKET=/ipc/cex-engine.sock
DB_PATH=/app/data/cex.db
TELEGRAM_BOT_TOKEN=your_token_here
TELEGRAM_ALLOWED_CHAT_IDS=your_chat_id
DASHBOARD_SECRET=generate_with_openssl_rand_hex_32
POLYMARKET_PRIVATE_KEY=your_64_char_hex_key

# Strongly recommended (enables primary probability source)
KALSHI_API_KEY=your_kalshi_api_key

# Strategy toggles (1 = enabled at startup)
ENABLE_NEWS_REPRICING=1
ENABLE_LIQUIDITY_PROVISION=1

# Dry-run mode (remove this line to go live)
DRY_RUN=1

# Optional
DASHBOARD_PORT=3000
LOG_LEVEL=info
NODE_ENV=production
DRY_RUN_INITIAL_BALANCE=10.0
```

---

## Phase 7: Pre-Live Go/No-Go Gate

**Timeline:** Day 6–14 (dry-run observation), Day 14 (decision)

### 7.1 — Preflight script

**File: `scripts/preflight.sh`**

```bash
#!/usr/bin/env bash
# Pre-live checklist for $10 deployment
set -euo pipefail

DB="${1:-data/cex.db}"
PASS=0
FAIL=0

check() {
    local label="$1"
    local condition="$2"
    local note="$3"
    if eval "$condition"; then
        echo "✅  $label"
        ((PASS++))
    else
        echo "❌  $label — $note"
        ((FAIL++))
    fi
}

echo ""
echo "══════════════════════════════════════"
echo "  cex-zig \$10 Pre-Live Preflight"
echo "══════════════════════════════════════"
echo ""

# Dry-run data volume
SIG_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM dry_run_signals;" 2>/dev/null || echo 0)
check "Dry-run signals > 500" \
    "[ '$SIG_COUNT' -gt 500 ]" \
    "Have $SIG_COUNT signals. Need at least 500 (run for ~7 days)."

# Dry-run orders exist
ORDER_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM dry_run_orders WHERE status='filled';" 2>/dev/null || echo 0)
check "Dry-run filled orders > 10" \
    "[ '$ORDER_COUNT' -gt 10 ]" \
    "Have $ORDER_COUNT filled paper orders. Strategy may not be signalling correctly."

# Kalshi mappings
MAP_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM kalshi_market_map;" 2>/dev/null || echo 0)
check "Kalshi mappings discovered > 0" \
    "[ '$MAP_COUNT' -gt 0 ]" \
    "No auto-mappings found. News strategy will use Manifold fallback only."

# Private key is set
check "POLYMARKET_PRIVATE_KEY is set" \
    "[ -n \"\${POLYMARKET_PRIVATE_KEY:-}\" ]" \
    "Set POLYMARKET_PRIVATE_KEY in .env"

# DRY_RUN is unset or 0
check "DRY_RUN is not set" \
    "[ -z \"\${DRY_RUN:-}\" ] || [ \"\${DRY_RUN:-}\" = '0' ]" \
    "Remove DRY_RUN from .env before going live."

echo ""
echo "══════════════════════════════════════"
echo "  Manual checks (verify these too):"
echo "══════════════════════════════════════"
echo "  [ ] Wallet has ≥ \$10 USDC on Polygon"
echo "  [ ] /config validate on Telegram shows all green"
echo "  [ ] /balance shows correct starting balance"
echo "  [ ] /drystatus diagnosis is paper_viable"
echo "  [ ] /strategy list shows strategies enabled"
echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "⛔  Not ready for live deployment."
    exit 1
else
    echo "🟢  Preflight passed. You may go live."
    exit 0
fi
```

### 7.2 — Minimum dry-run duration and acceptance criteria

Do not go live until all of the following are true:

| Gate | Minimum Threshold | Why |
|------|-------------------|-----|
| Dry-run runtime | 7 days | Enough market cycles to see statistical signal |
| Total signals | > 500 | Minimum for `analyzeDryRunSignals` to be meaningful |
| Filled paper orders | > 10 | Confirms fill simulation is working, not just signalling |
| Diagnosis | `paper_viable` | P&L positive, fill rate > 10%, profit factor > 1 |
| Kalshi mappings | > 0 | News strategy has real inputs |
| Preflight script | All pass | — |

---

## Implementation Order Summary

| Day | Phase | Tasks | Risk if skipped |
|-----|-------|-------|-----------------|
| 1 AM | 0 | Ratio-based risk limits, strategy size scaling, cold-start fallbacks | Account blown immediately |
| 1 PM | 1.1–1.2 | FillPoller gets StrategyEngine ref, shared fill handler | Unlimited LP exposure |
| 1 PM | 1.3 | LP pair linking in dispatchSignal | Orphaned orders, double exposure |
| 1 PM | 1.4 | lp_max_position_usd scales with balance | Same unlimited exposure problem |
| 2 | 2.1–2.2 | Migration 010, kalshi_market_map table, three-tier resolver | News strategy fires no signals |
| 2 | 2.3–2.4 | Persist mappings from REST, remove manual config | Mappings lost on restart |
| 2 | 2.5 | /mappings Telegram command | Observability only |
| 3 | 3.1–3.2 | dry_run_orders table, rewrite dispatch branch | No lifecycle tracking |
| 4 AM | 3.3 | Fill simulation worker, balance update | No simulated P&L |
| 4 AM | 3.4 | /drystatus and /balance dry-run commands | No feedback loop |
| 4 PM | 4.1–4.3 | applyFillDelta, rate-limited syncFromDB, dirty balance | Performance only |
| 4 PM | 5 | Configurable LP cooldown from runtime_config | Minor, free money |
| 5 | 6 | README, .env.example, docs | No runtime impact |
| 6–13 | — | Run dry-run. Check /drystatus daily. Watch logs. | — |
| 14 | 7 | Run preflight.sh. Make go/no-go decision. | — |

---

## Key Invariants That Must Hold Throughout

These are the properties that all changes must preserve. If a PR breaks any of them, it must not merge.

- **Risk gate is the only path to order submission.** `placeOrder` is the only entry point and it always calls `validateOrder` first. No bypass path exists.
- **Dry-run and live share the same risk gate.** The virtual balance in dry-run must feed the same `queryLatestUsdcBalance` call that the risk gate uses, so simulated limits match live limits exactly.
- **LP pairs are always linked before either order can fill.** The link must be established synchronously in `dispatchLpPair` before returning.
- **`updateInventory` is called for every confirmed fill.** Both the REST and WebSocket fill paths must go through `onFillConfirmed` without exception.
- **All limits are ratios of balance, never hardcoded USD values,** except in cold-start fallback paths that are only reachable when `queryLatestUsdcBalance` returns `null`.