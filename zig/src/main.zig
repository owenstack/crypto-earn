const std = @import("std");
const log = @import("logger.zig");
const db = @import("db.zig");
const ipc = @import("ipc.zig");
const ipc_types = @import("ipc_types.zig");
const scanner = @import("market_scanner.zig");
const order_mgr = @import("order_manager.zig");
const poly_auth = @import("polymarket_auth.zig");
const risk = @import("risk_gate.zig");
const portfolio = @import("portfolio_tracker.zig");
const strategy = @import("strategy_engine.zig");
const ws = @import("websocket.zig");
const fill_poller = @import("fill_poller.zig");
const kalshi_ws = @import("kalshi_ws.zig");
const prob_provider = @import("probability_provider.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.init();
    log.info("engine", "starting cex-engine", .{});

    // Read config from environment
    const db_path = std.posix.getenv("DB_PATH") orelse "./data/cex.db";
    const socket_path = std.posix.getenv("IPC_SOCKET") orelse "/tmp/cex-engine.sock";

    // Ensure data directory exists
    std.fs.cwd().makeDir("data") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    // Allocate null-terminated DB path
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);

    log.info("engine", "opening db: {s}", .{db_path});
    var database = try db.DB.open(db_path_z);
    defer database.close();

    try database.runMigrations();
    log.info("engine", "db ready", .{});

    // Initialize risk config
    const risk_config = risk.RiskConfig{};

    // Parse private key from environment and bootstrap Polymarket auth
    var om_config = order_mgr.OrderManagerConfig{};
    if (std.posix.getenv("POLYMARKET_PRIVATE_KEY")) |pk_env| {
        // Strip optional "0x" prefix
        const hex = if (pk_env.len >= 2 and pk_env[0] == '0' and (pk_env[1] == 'x' or pk_env[1] == 'X'))
            pk_env[2..]
        else
            pk_env;
        if (hex.len == 64) {
            var valid = true;
            for (0..32) |i| {
                om_config.private_key[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch {
                    valid = false;
                    break;
                };
            }
            if (valid) {
                log.info("engine", "loaded POLYMARKET_PRIVATE_KEY", .{});

                // Derive Ethereum address and bootstrap API credentials
                if (poly_auth.deriveAddress(om_config.private_key)) |addr| {
                    om_config.signer_address = addr;
                    var addr_hex: [42]u8 = undefined;
                    addr_hex[0] = '0';
                    addr_hex[1] = 'x';
                    const charset = "0123456789abcdef";
                    for (om_config.signer_address, 0..) |b, i| {
                        addr_hex[2 + i * 2] = charset[b >> 4];
                        addr_hex[2 + i * 2 + 1] = charset[b & 0x0f];
                    }
                    log.info("engine", "signer address: {s}", .{&addr_hex});

                    // Bootstrap API credentials
                    if (poly_auth.bootstrapApiCredentials(
                        allocator,
                        om_config.private_key,
                        om_config.signer_address,
                    )) |creds| {
                        om_config.api_creds = creds;
                        log.info("engine", "API credentials bootstrapped (key={s}...)", .{
                            creds.api_key[0..@min(creds.api_key_len, 8)],
                        });
                    } else |e| {
                        log.err("engine", "failed to bootstrap API credentials: {s}", .{@errorName(e)});
                        log.warn("engine", "engine will start but order submission will fail", .{});
                    }
                } else |_| {
                    log.err("engine", "failed to derive signer address from private key", .{});
                }
            } else {
                log.err("engine", "invalid POLYMARKET_PRIVATE_KEY hex", .{});
                om_config.private_key = [_]u8{0} ** 32;
            }
        } else {
            log.err("engine", "POLYMARKET_PRIVATE_KEY must be 64 hex chars (got {d})", .{hex.len});
        }
    } else {
        log.warn("engine", "POLYMARKET_PRIVATE_KEY not set — orders will fail", .{});
    }

    // Initialize order manager
    var om = order_mgr.OrderManager.init(allocator, &database, risk_config, om_config);
    log.info("engine", "order manager ready", .{});

    // Initialize portfolio tracker
    var pt = portfolio.PortfolioTracker.init(allocator, &database, .{});
    log.info("engine", "portfolio tracker ready", .{});

    // Initialize WebSocket client for real-time CLOB updates
    var ws_client = ws.WebSocketClient.init(allocator);
    ws_client.setCallback(&wsPriceCallback);
    g_database = &database;
    log.info("engine", "websocket client ready", .{});

    // Spawn market scanner thread (no longer feeds news client — Phase 3 removed that dependency)
    var scan = scanner.Scanner.init(allocator, &database, .{});
    scan.setWebSocketClient(&ws_client);
    const scanner_thread = try std.Thread.spawn(.{}, scanner.Scanner.run, .{&scan});
    defer {
        scan.stop();
        scanner_thread.join();
        scan.deinit();
    }
    log.info("engine", "market scanner started", .{});

    // Spawn WebSocket thread for real-time orderbook feeds
    const ws_thread = try std.Thread.spawn(.{}, ws.WebSocketClient.connectAndRun, .{&ws_client});
    defer {
        ws_client.stop();
        ws_thread.join();
        ws_client.deinit();
    }
    log.info("engine", "websocket feed started", .{});

    // Spawn stale order scan ticker
    om.should_stop.store(false, .seq_cst);
    const stale_thread = try std.Thread.spawn(.{}, staleOrderTicker, .{&om});
    defer {
        om.should_stop.store(true, .seq_cst);
        stale_thread.join();
    }
    log.info("engine", "stale order ticker started", .{});

    // Initialize strategy engine early so the fill poller can be wired with it.
    var se = strategy.StrategyEngine.init(.{});

    // Initialize fill poller (with strategy engine reference for inventory + LP pair cancel)
    var fp = fill_poller.FillPoller.init(allocator, &database, &om, &pt, &se);
    log.info("engine", "fill poller ready", .{});

    // Run startup reconciliation (blocking, before strategy worker)
    {
        var reconcile_ok = false;
        var attempt: u32 = 0;
        while (attempt < 3) : (attempt += 1) {
            const result = fp.reconcileOnStartup();
            if (result.adopted > 0 or result.closed > 0 or result.unchanged > 0) {
                reconcile_ok = true;
                break;
            }
            log.warn("engine", "reconciliation attempt {d}/3 returned empty, retrying...", .{attempt + 1});
            std.Thread.sleep(2 * std.time.ns_per_s);
        }
        if (!reconcile_ok) {
            log.warn("engine", "reconciliation failed after 3 retries, proceeding anyway", .{});
        }
        om.reconciliation_complete.store(true, .seq_cst);
        log.info("engine", "reconciliation gate open — orders unblocked", .{});
    }

    // Spawn fill poller WebSocket thread (primary fill detection)
    const fp_ws_thread = try std.Thread.spawn(.{}, fill_poller.FillPoller.wsLoop, .{&fp});
    const fp_poll_thread = try std.Thread.spawn(.{}, fill_poller.FillPoller.pollLoop, .{&fp});
    defer {
        fp.stop();
        fp_ws_thread.join();
        fp_poll_thread.join();
    }
    log.info("engine", "fill poller WebSocket thread started", .{});
    log.info("engine", "fill poller REST polling thread started", .{});

    // Initialize Kalshi WebSocket client (primary probability source)
    var kws = kalshi_ws.KalshiWsClient.init(allocator, &database);
    const kalshi_thread = try std.Thread.spawn(.{}, kalshi_ws.KalshiWsClient.run, .{&kws});
    defer {
        kws.stop();
        kalshi_thread.join();
    }
    log.info("engine", "Kalshi WebSocket client started", .{});

    // Initialize probability provider (Kalshi WS primary, HTTP polling fallback)
    var pp = prob_provider.ProbabilityProvider.init(allocator, &database, &kws);
    const pp_thread = try std.Thread.spawn(.{}, prob_provider.ProbabilityProvider.run, .{&pp});
    defer {
        pp.stop();
        pp_thread.join();
    }
    log.info("engine", "probability provider started", .{});

    // Strategy engine was initialized earlier (above fill poller). Now load
    // its runtime config and resolve lp_max_position_usd.

    // Load lp_max_position_usd from runtime_config; if absent, fall back to a
    // ratio of current balance (20%) so a small account doesn't get blown by
    // the legacy $50 default.
    {
        var lp_buf: [32]u8 = undefined;
        const explicit = database.getConfig("lp_max_position_usd", &lp_buf);
        if (explicit) |val| {
            if (std.fmt.parseFloat(f64, val)) |v| {
                se.lp_max_position_usd = v;
                log.info("engine", "lp_max_position_usd={d:.2}", .{v});
            } else |_| {
                log.warn("engine", "invalid lp_max_position_usd in runtime_config: {s}", .{val});
            }
        } else {
            // No explicit override → derive from balance using a ratio
            // (default 20%, configurable via lp_max_position_usd_pct).
            var pct_buf: [16]u8 = undefined;
            const pct_str = database.getConfig("lp_max_position_usd_pct", &pct_buf) orelse "0.20";
            const pct = std.fmt.parseFloat(f64, pct_str) catch 0.20;
            const bal = pt.usdc_balance;
            se.lp_max_position_usd = if (bal > 0) bal * pct else 2.0;
            log.info("engine", "lp_max_position_usd derived from balance: ${d:.2} (pct={d:.2}, balance=${d:.2})", .{
                se.lp_max_position_usd, pct, bal,
            });
        }
    }
    log.info("engine", "strategy engine ready", .{});

    // Auto-enable strategies from environment
    if (std.posix.getenv("ENABLE_NEWS_REPRICING")) |v| {
        if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) {
            se.enableStrategy(.news_repricing);
        }
    }
    if (std.posix.getenv("ENABLE_LIQUIDITY_PROVISION")) |v| {
        if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) {
            se.enableStrategy(.liquidity_provision);
        }
    }

    // Dry-run mode: log signals without placing real orders
    const dry_run = if (std.posix.getenv("DRY_RUN")) |v|
        (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true"))
    else
        false;
    if (dry_run) {
        log.info("engine", "DRY-RUN mode enabled -- no orders will be placed", .{});

        // Seed initial simulated balance for dry-run profitability analysis
        const dry_run_initial_balance = if (std.posix.getenv("DRY_RUN_INITIAL_BALANCE")) |v|
            std.fmt.parseFloat(f64, v) catch 10.0
        else
            10.0; // Default $10

        // Insert initial balance snapshot so risk gate and P&L calculations work
        database.insertBalanceSnapshot(dry_run_initial_balance, 0.0, 0.0, 0.0) catch |e| {
            log.warn("engine", "failed to seed dry-run initial balance: {s}", .{@errorName(e)});
        };
        // Re-sync portfolio tracker so in-memory usdc_balance reflects the
        // freshly-seeded snapshot (init ran earlier when no snapshot existed).
        pt.syncFromDB();
        log.info("engine", "dry-run initial balance: ${d:.2}", .{dry_run_initial_balance});
    }

    // Spawn USDC balance refresh ticker (live mode only — when API credentials
    // are available and not in dry-run). Polls Polymarket's L2
    // /balance-allowance endpoint every 60s and writes the result to
    // balance_snapshots so the risk gate, /balance dashboard, and dynamic
    // order sizing see the user's real on-exchange USDC balance.
    var balance_ticker_ctx_opt: ?*BalanceTickerCtx = null;
    var balance_thread_opt: ?std.Thread = null;
    if (!dry_run) {
        if (om_config.api_creds) |creds| {
            // Initial synchronous fetch so the engine has a real balance
            // before the strategy worker (and risk gate) start firing.
            const bal0 = poly_auth.fetchUsdcBalance(
                allocator,
                creds,
                om_config.signer_address,
                om_config.signature_type,
            ) catch |e| blk: {
                log.warn("engine", "initial USDC balance fetch failed: {s}", .{@errorName(e)});
                break :blk @as(?f64, null);
            };
            if (bal0) |b| {
                database.insertBalanceSnapshot(b, 0.0, 0.0, 0.0) catch |e| {
                    log.warn("engine", "failed to seed initial balance snapshot: {s}", .{@errorName(e)});
                };
                pt.markBalanceDirty();
                pt.syncFromDB();
                log.info("engine", "initial USDC balance: ${d:.6}", .{b});
            }

            const ctx = try allocator.create(BalanceTickerCtx);
            ctx.* = .{
                .database = &database,
                .pt = &pt,
                .creds = creds,
                .signer_address = om_config.signer_address,
                .signature_type = om_config.signature_type,
                .allocator = allocator,
                .should_stop = std.atomic.Value(bool).init(false),
            };
            balance_ticker_ctx_opt = ctx;
            balance_thread_opt = try std.Thread.spawn(.{}, balanceTicker, .{ctx});
            log.info("engine", "balance refresh ticker started (60s interval)", .{});
        } else {
            log.warn("engine", "no API credentials — USDC balance ticker disabled (orders will be rejected by risk gate)", .{});
        }
    }
    defer {
        if (balance_ticker_ctx_opt) |ctx| {
            ctx.should_stop.store(true, .seq_cst);
            if (balance_thread_opt) |t| t.join();
            allocator.destroy(ctx);
        }
    }

    // Spawn strategy worker thread
    var strategy_ctx = StrategyWorkerCtx{
        .se = &se,
        .om = &om,
        .pp = &pp,
        .pt = &pt,
        .database = &database,
        .should_stop = std.atomic.Value(bool).init(false),
        .dry_run = dry_run,
    };
    const strategy_thread = try std.Thread.spawn(.{}, strategyWorker, .{&strategy_ctx});
    defer {
        strategy_ctx.should_stop.store(true, .seq_cst);
        strategy_thread.join();
    }
    log.info("engine", "strategy worker started", .{});

    // Spawn DB retention/vacuum ticker. Runs every 15 minutes to prune high-churn rows
    // (orderbooks, risk_events, balance_snapshots, etc) so the database
    // doesn't grow unbounded over long deployments.
    var retention_should_stop = std.atomic.Value(bool).init(false);
    const retention_thread = try std.Thread.spawn(.{}, dbRetentionTicker, .{ &database, &retention_should_stop });
    defer {
        retention_should_stop.store(true, .seq_cst);
        retention_thread.join();
    }
    log.info("engine", "db retention ticker started", .{});

    // Start IPC server (blocks)
    try ipc.serve(allocator, socket_path, &database, &om, &pt, &se);
}

const StrategyWorkerCtx = struct {
    se: *strategy.StrategyEngine,
    om: *order_mgr.OrderManager,
    pp: *prob_provider.ProbabilityProvider,
    pt: *portfolio.PortfolioTracker,
    database: *db.DB,
    should_stop: std.atomic.Value(bool),
    dry_run: bool,
    /// True when the engine has reached max_open_orders or balance commitment
    /// cap. While set, dispatchSignal silently skips submission so we focus on
    /// managing existing orders. Cleared when capacity frees (a fill closes
    /// an order or balance grows).
    saturated: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Counter ticking 5s per increment; used to throttle balance/stats DB
    /// inserts so they happen ~1/min instead of every 5s.
    persist_tick: u64 = 0,
    /// Counter for dry-run fill simulation (every ~30s when in dry-run).
    sim_tick: u64 = 0,
};

/// Strategy worker: periodically evaluates enabled strategies and dispatches signals.
/// Respects halt state — blocks dispatch when engine is halted.
fn strategyWorker(ctx: *StrategyWorkerCtx) void {
    const eval_interval_ns: u64 = 5 * std.time.ns_per_s;
    log.info("strategy_worker", "strategy evaluation loop started (5s interval)", .{});

    while (!ctx.should_stop.load(.seq_cst)) {
        std.Thread.sleep(eval_interval_ns);
        if (ctx.should_stop.load(.seq_cst)) break;

        // Skip evaluation if engine is halted
        if (ctx.om.isHalted()) {
            log.debug("strategy_worker", "skipping evaluation: engine halted", .{});
            continue;
        }

        // Evaluate news repricing for cached estimates
        if (ctx.se.isEnabled(.news_repricing)) {
            evaluateNewsSignals(ctx);
        }

        // Evaluate liquidity provision using recent orderbook data
        if (ctx.se.isEnabled(.liquidity_provision)) {
            evaluateLpSignals(ctx);
        }

        // Persist strategy stats + balance snapshot once every 5 minutes.
        // Long-running deployments otherwise accumulate ~17k rows/day per
        // table at 1/min cadence. 1/5min keeps the DB compact while still
        // providing fresh balance data for risk-gate checks (max-age 600s).
        ctx.persist_tick +%= 1;
        if (ctx.persist_tick % 60 == 0) {
            persistStrategyStats(ctx);
            persistBalanceSnapshot(ctx);
        }

        // Dry-run fill simulation (~every 30s = 6 × 5s eval interval).
        if (ctx.dry_run) {
            ctx.sim_tick +%= 1;
            if (ctx.sim_tick % 6 == 0) {
                simulateDryRunFills(ctx);
            }
        }
    }

    log.info("strategy_worker", "strategy evaluation loop stopped", .{});
}

fn evaluateNewsSignals(ctx: *StrategyWorkerCtx) void {
    var snap: [prob_provider.MAX_ESTIMATES]prob_provider.ExternalEstimate = undefined;
    const snap_count = ctx.pp.snapshot(&snap);

    for (snap[0..snap_count]) |est| {
        const market_id = est.market_id[0..est.market_id_len];
        const yes_token_id = est.yes_token_id[0..est.yes_token_id_len];

        if (yes_token_id.len == 0) continue;
        if (market_id.len == 0) continue;

        const mid = queryLastMidByAsset(ctx.database, yes_token_id) orelse continue;
        const implied_prob = priceToImpliedProb(mid);

        if (ctx.se.evaluateNewsRepricing(market_id, est.probability, implied_prob, ctx.pt.usdc_balance)) |signal| {
            dispatchSignal(ctx, signal);
        }

        // Check for collapsed edges — cancel orders where edge disappeared
        const delta = @abs(est.probability - implied_prob);
        const collapsed = ctx.se.findCollapsedEdgeOrders(market_id, delta);
        for (0..collapsed.count) |ci| {
            const oid = collapsed.order_ids[ci][0..collapsed.order_id_lens[ci]];
            if (ctx.om.cancelOrder(oid)) {
                ctx.se.untrackOrder(oid);
                ctx.se.incrementCancels(.news_repricing);
                log.info("strategy_worker", "cancelled collapsed-edge order: {s}", .{oid});
            }
        }
    }
}

fn evaluateLpSignals(ctx: *StrategyWorkerCtx) void {
    // Read cooldown from runtime_config; default 15s, clamp 5–300s.
    var cd_buf: [16]u8 = undefined;
    const cd_str = ctx.database.getConfig("lp_cooldown_seconds", &cd_buf) orelse "15";
    const cooldown_s = std.fmt.parseInt(i64, cd_str, 10) catch 15;
    const cooldown = std.math.clamp(cooldown_s, @as(i64, 5), @as(i64, 300));

    // Get the most recent bid/ask per market from the last 30 seconds, using gamma_id as the market identifier
    const sql = "SELECT gamma_id, best_bid, best_ask FROM orderbooks WHERE gamma_id IS NOT NULL AND id IN (SELECT MAX(id) FROM orderbooks WHERE created_at >= unixepoch() - 30 AND gamma_id IS NOT NULL GROUP BY gamma_id);" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    if (db.c.sqlite3_prepare_v2(ctx.database.handle, sql.ptr, -1, &stmt, null) != db.c.SQLITE_OK) return;
    defer _ = db.c.sqlite3_finalize(stmt);

    while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
        const gid_raw = db.c.sqlite3_column_text(stmt, 0);
        const gid_span = if (gid_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;
        const bid_raw = db.c.sqlite3_column_text(stmt, 1);
        const bid_span = if (bid_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;
        const ask_raw = db.c.sqlite3_column_text(stmt, 2);
        const ask_span = if (ask_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;

        const best_bid = std.fmt.parseFloat(f64, bid_span) catch continue;
        const best_ask = std.fmt.parseFloat(f64, ask_span) catch continue;

        // Per-market cooldown: configurable via runtime_config.lp_cooldown_seconds.
        if (ctx.se.checkLpCooldown(gid_span, cooldown)) continue;

        // Pass gamma_id (Gamma market id) so placeOrder receives a Gamma id
        const lp_result = ctx.se.evaluateLiquidityProvision(gid_span, best_bid, best_ask, ctx.pt.usdc_balance);
        if (lp_result.count == 2) {
            dispatchLpPair(ctx, lp_result.signals[0], lp_result.signals[1]);
        } else {
            for (lp_result.signals[0..lp_result.count]) |signal| {
                dispatchSignal(ctx, signal);
            }
        }
    }
}

/// Query the latest orderbook (best bid/ask + mid) for a Gamma market id.
fn queryOrderbookForMarket(database: *db.DB, market_id: []const u8) ?struct {
    best_bid: f64,
    best_ask: f64,
    mid_price: f64,
} {
    const sql = "SELECT best_bid, best_ask, mid_price FROM orderbooks WHERE gamma_id=? ORDER BY created_at DESC LIMIT 1;" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    if (db.c.sqlite3_prepare_v2(database.handle, sql.ptr, -1, &stmt, null) != db.c.SQLITE_OK) return null;
    defer _ = db.c.sqlite3_finalize(stmt);
    if (db.c.sqlite3_bind_text(stmt, 1, market_id.ptr, @intCast(market_id.len), null) != db.c.SQLITE_OK) return null;
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return null;

    const bid_raw = db.c.sqlite3_column_text(stmt, 0);
    const ask_raw = db.c.sqlite3_column_text(stmt, 1);
    const bid_span = if (bid_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else return null;
    const ask_span = if (ask_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else return null;

    const bid = std.fmt.parseFloat(f64, bid_span) catch return null;
    const ask = std.fmt.parseFloat(f64, ask_span) catch return null;
    const mid = db.c.sqlite3_column_double(stmt, 2);

    return .{ .best_bid = bid, .best_ask = ask, .mid_price = mid };
}

/// Settle open dry-run orders against current orderbook prices.
/// Buy fills if ask <= signal_price; sell fills if bid >= signal_price.
/// Orders older than 30 minutes are expired. After settlements, the simulated
/// USDC balance is updated so risk gate / dynamic limits track P&L exactly
/// like the live engine.
fn simulateDryRunFills(ctx: *StrategyWorkerCtx) void {
    var orders: [64]db.DB.DryRunOrderRow = [_]db.DB.DryRunOrderRow{.{}} ** 64;
    const count = ctx.database.getOpenDryRunOrders(&orders) catch return;
    if (count == 0) return;

    const now = std.time.timestamp();
    const fee_bps: f64 = 2.0; // 2bps per side, matches taker fee config

    var any_settled = false;

    for (orders[0..count]) |order| {
        const oid = order.id();
        const mid = order.marketId();
        const dir = order.direction();
        const is_buy = std.mem.eql(u8, dir, "buy");

        // Expire orders older than 30 minutes.
        if (now - order.created_at > 1800) {
            ctx.database.settleDryRunOrder(oid, "expired", 0, 0, 0) catch {};
            any_settled = true;
            continue;
        }

        const ob = queryOrderbookForMarket(ctx.database, mid) orelse continue;

        const fills = if (is_buy)
            ob.best_ask <= order.signal_price
        else
            ob.best_bid >= order.signal_price;

        if (!fills) continue;

        const fill_price = if (is_buy) ob.best_ask else ob.best_bid;
        const notional = fill_price * order.size;
        // Fees: entry + exit, charged at fee_bps each side.
        const fees = notional * (fee_bps / 10000.0) * 2.0;

        // Mark-to-mid P&L (conservative — assumes immediate exit at mid).
        const pnl_gross = if (is_buy)
            (ob.mid_price - fill_price) * order.size
        else
            (fill_price - ob.mid_price) * order.size;
        const pnl_net = pnl_gross - fees;

        ctx.database.settleDryRunOrder(oid, "filled", fill_price, pnl_net, fees) catch {};
        any_settled = true;

        log.info("dry_run", "FILL [{s}] {s} {d:.4} -> pnl={d:.4} fees={d:.4}", .{
            oid[0..@min(oid.len, 24)], dir, fill_price, pnl_net, fees,
        });
    }

    if (any_settled) {
        updateDryRunBalance(ctx);
    }
}

/// After dry-run fills settle, sum filled-order P&L and write a fresh balance
/// snapshot. This makes /balance, the risk gate, and dynamic order-size
/// limits all reflect simulated profitability so dry-run mirrors live exactly.
fn updateDryRunBalance(ctx: *StrategyWorkerCtx) void {
    const sql = "SELECT COALESCE(SUM(pnl), 0.0), COALESCE(SUM(fees), 0.0) FROM dry_run_orders WHERE status='filled';" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    if (db.c.sqlite3_prepare_v2(ctx.database.handle, sql.ptr, -1, &stmt, null) != db.c.SQLITE_OK) return;
    defer _ = db.c.sqlite3_finalize(stmt);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return;

    const cumulative_pnl = db.c.sqlite3_column_double(stmt, 0);
    const cumulative_fees = db.c.sqlite3_column_double(stmt, 1);
    _ = cumulative_fees; // cumulative_pnl is already net of fees.

    // Initial seeded balance (from DRY_RUN_INITIAL_BALANCE or default).
    const initial_balance = if (std.posix.getenv("DRY_RUN_INITIAL_BALANCE")) |v|
        std.fmt.parseFloat(f64, v) catch 10.0
    else
        10.0;

    const simulated_balance = initial_balance + cumulative_pnl;

    ctx.database.insertBalanceSnapshot(
        simulated_balance,
        0.0,
        0.0,
        cumulative_pnl,
    ) catch |e| {
        log.warn("dry_run", "failed to write simulated balance snapshot: {s}", .{@errorName(e)});
        return;
    };

    // Resync portfolio tracker so in-memory balance reflects the new snapshot.
    ctx.pt.syncFromDB();
}

fn dispatchSignal(ctx: *StrategyWorkerCtx, signal: strategy.Signal) void {
    if (ctx.dry_run) {
        const dr_market_id = signal.market_id[0..signal.market_id_len];
        const dr_side: []const u8 = if (signal.direction == .buy) "buy" else "sell";

        // Use bid/ask from the signal to avoid re-querying (values may drift between reads)
        const dr_bid: ?f64 = if (signal.best_bid > 0) signal.best_bid else null;
        const dr_ask: ?f64 = if (signal.best_ask > 0) signal.best_ask else null;

        const dr_mid = if (dr_bid != null and dr_ask != null) (dr_bid.? + dr_ask.?) / 2.0 else signal.price;
        const dr_delta = @abs(signal.price - dr_mid);

        // Generate a deterministic-ish fake order ID
        var id_buf: [64]u8 = undefined;
        const id_market_slice = dr_market_id[0..@min(dr_market_id.len, 8)];
        const dr_order_id = std.fmt.bufPrint(&id_buf, "dry-{s}-{d}", .{ id_market_slice, std.time.milliTimestamp() }) catch "dry-unknown";

        log.info("dry_run", "[{s}] {s} {s} x{d:.2} @ {d:.4} | conf={d:.2} delta={d:.4}", .{
            dr_order_id[0..@min(dr_order_id.len, 24)],
            dr_side,
            id_market_slice,
            signal.size,
            signal.price,
            signal.confidence,
            dr_delta,
        });

        // Existing analytics table (keeps backwards-compat for analyzeDryRunSignals).
        ctx.database.insertDryRunSignal(
            dr_market_id,
            @tagName(signal.strategy),
            dr_side,
            signal.price,
            signal.size,
            dr_delta,
            signal.confidence,
            signal.timestamp,
            dr_bid,
            dr_ask,
        ) catch |e| {
            log.err("dry_run", "failed to persist dry-run signal: {s}", .{@errorName(e)});
        };

        // New: lifecycle order tracking. simulateDryRunFills will settle these
        // against live orderbook prices in the strategy worker loop.
        ctx.database.insertDryRunOrder(
            dr_order_id,
            dr_market_id,
            @tagName(signal.strategy),
            dr_side,
            signal.price,
            signal.size,
        ) catch |e| {
            log.err("dry_run", "failed to insert dry_run_order: {s}", .{@errorName(e)});
        };
        return;
    }

    // Saturation gate: if we're at max open orders or have already committed
    // ~70% of balance, suppress new submissions. This prevents notification
    // spam (one notification per signal otherwise) and tells the engine to
    // focus on managing existing orders. Capacity naturally returns when a
    // fill closes an order or balance grows from realized profits — the next
    // signal then transitions us back out of saturated state.
    if (checkSaturation(ctx)) return;

    const market_id = signal.market_id[0..signal.market_id_len];
    const side_str: []const u8 = if (signal.direction == .buy) "buy" else "sell";

    // Round price to 0.01 tick size (Polymarket default min_tick_size)
    const tick = 0.01;
    const rounded_price = @round(signal.price / tick) * tick;
    // Clamp to valid Polymarket price range (0.01 to 0.99)
    const clamped_price = std.math.clamp(rounded_price, 0.01, 0.99);

    // Optional runtime override: hard cap on order notional (USD).
    // Allows `/config set max_order_size_usd 5.00` to throttle orders during
    // volatile periods without a restart. Applied as a notional cap on the
    // size used for this order.
    var effective_size: f64 = signal.size;
    {
        var cap_buf: [16]u8 = undefined;
        const cap_str_opt = ctx.database.getConfig("max_order_size_usd", &cap_buf);
        if (cap_str_opt) |cap_str| {
            if (std.fmt.parseFloat(f64, cap_str)) |cap_usd| {
                if (clamped_price > 0) {
                    const cap_size = cap_usd / clamped_price;
                    if (effective_size > cap_size) effective_size = cap_size;
                }
            } else |_| {}
        }
    }

    var price_buf: [32]u8 = undefined;
    const price_str = std.fmt.bufPrint(&price_buf, "{d:.2}", .{clamped_price}) catch "0";
    var size_buf: [32]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{d:.2}", .{effective_size}) catch "0";

    const origin = @tagName(signal.strategy);

    const result = ctx.om.placeOrder(market_id, side_str, size_str, price_str, "limit", origin);
    switch (result) {
        .success => |s| {
            const tracked = ctx.se.trackOrder(s.order_id, market_id, signal.strategy, signal.direction, signal.price);
            if (tracked) {
                ctx.se.incrementOrdersAccepted(signal.strategy);
            } else {
                log.err("strategy_worker", "failed to track order due to active-order cap; attempting to cancel placed order {s}", .{s.order_id});
                const max_retries = 3;
                var attempt: usize = 0;
                var cancelled = false;
                while (attempt < max_retries) : (attempt += 1) {
                    if (ctx.om.cancelOrder(s.order_id)) {
                        cancelled = true;
                        break;
                    } else {
                        log.err("strategy_worker", "cancelOrder failed for {s} (attempt {d}/{d})", .{ s.order_id, attempt + 1, max_retries });
                        std.Thread.sleep(100_000_000 * (attempt + 1)); // Exponential backoff: 100ms, 200ms, 300ms
                    }
                }
                if (cancelled) {
                    ctx.se.untrackOrder(s.order_id);
                } else {
                    log.err("strategy_worker", "cancelOrder failed for {s} after {d} attempts; halting engine", .{ s.order_id, max_retries });
                    // Escalate: halt engine or propagate error. Here, we return to halt the worker.
                    return;
                }
                ctx.se.incrementOrdersRejected(signal.strategy);
            }
            ctx.om.allocator.free(s.order_id);

            // Persist signal to DB
            ctx.database.insertStrategySignal(market_id, origin, signal.confidence, "") catch {};
        },
        .rejected => {
            ctx.se.incrementOrdersRejected(signal.strategy);
        },
        .failed => {
            ctx.se.incrementOrdersRejected(signal.strategy);
        },
    }
}

/// Dispatch a paired LP buy+sell signal, placing both legs and linking them
/// so a fill on one cancels the other (handled in fill_poller). Falls back
/// to dispatchSignal individually for dry-run.
fn dispatchLpPair(ctx: *StrategyWorkerCtx, buy_signal: strategy.Signal, sell_signal: strategy.Signal) void {
    if (ctx.dry_run) {
        dispatchSignal(ctx, buy_signal);
        dispatchSignal(ctx, sell_signal);
        return;
    }

    if (ctx.om.isHalted()) return;
    if (checkSaturation(ctx)) return;

    const tick: f64 = 0.01;

    const buy_market_id = buy_signal.market_id[0..buy_signal.market_id_len];
    const sell_market_id = sell_signal.market_id[0..sell_signal.market_id_len];

    // Apply the same runtime cap as dispatchSignal to both legs.
    var cap_size_usd: ?f64 = null;
    {
        var cap_buf: [16]u8 = undefined;
        if (ctx.database.getConfig("max_order_size_usd", &cap_buf)) |cap_str| {
            if (std.fmt.parseFloat(f64, cap_str)) |cap_usd| {
                cap_size_usd = cap_usd;
            } else |_| {}
        }
    }

    const buy_price = std.math.clamp(@round(buy_signal.price / tick) * tick, 0.01, 0.99);
    const sell_price = std.math.clamp(@round(sell_signal.price / tick) * tick, 0.01, 0.99);

    var buy_size = buy_signal.size;
    var sell_size = sell_signal.size;
    if (cap_size_usd) |cap_usd| {
        if (buy_price > 0) {
            const cap = cap_usd / buy_price;
            if (buy_size > cap) buy_size = cap;
        }
        if (sell_price > 0) {
            const cap = cap_usd / sell_price;
            if (sell_size > cap) sell_size = cap;
        }
    }

    var buy_price_buf: [32]u8 = undefined;
    var sell_price_buf: [32]u8 = undefined;
    var buy_size_buf: [32]u8 = undefined;
    var sell_size_buf: [32]u8 = undefined;

    const buy_price_str = std.fmt.bufPrint(&buy_price_buf, "{d:.2}", .{buy_price}) catch "0";
    const sell_price_str = std.fmt.bufPrint(&sell_price_buf, "{d:.2}", .{sell_price}) catch "0";
    const buy_size_str = std.fmt.bufPrint(&buy_size_buf, "{d:.2}", .{buy_size}) catch "0";
    const sell_size_str = std.fmt.bufPrint(&sell_size_buf, "{d:.2}", .{sell_size}) catch "0";

    const origin = "liquidity_provision";

    // Place buy leg
    const buy_result = ctx.om.placeOrder(buy_market_id, "buy", buy_size_str, buy_price_str, "limit", origin);
    // Place sell leg
    const sell_result = ctx.om.placeOrder(sell_market_id, "sell", sell_size_str, sell_price_str, "limit", origin);

    var buy_tracked = false;
    var sell_tracked = false;

    if (buy_result == .success) {
        buy_tracked = ctx.se.trackOrder(buy_result.success.order_id, buy_market_id, .liquidity_provision, .buy, buy_signal.price);
        if (buy_tracked) {
            ctx.se.incrementOrdersAccepted(.liquidity_provision);
            ctx.database.insertStrategySignal(buy_market_id, origin, buy_signal.confidence, "") catch {};
        } else {
            ctx.se.incrementOrdersRejected(.liquidity_provision);
            log.err("strategy_worker", "lp_pair: failed to track buy leg, attempting cancel: {s}", .{buy_result.success.order_id});
            _ = ctx.om.cancelOrder(buy_result.success.order_id);
        }
    } else {
        ctx.se.incrementOrdersRejected(.liquidity_provision);
    }

    if (sell_result == .success) {
        sell_tracked = ctx.se.trackOrder(sell_result.success.order_id, sell_market_id, .liquidity_provision, .sell, sell_signal.price);
        if (sell_tracked) {
            ctx.se.incrementOrdersAccepted(.liquidity_provision);
            ctx.database.insertStrategySignal(sell_market_id, origin, sell_signal.confidence, "") catch {};
        } else {
            ctx.se.incrementOrdersRejected(.liquidity_provision);
            log.err("strategy_worker", "lp_pair: failed to track sell leg, attempting cancel: {s}", .{sell_result.success.order_id});
            _ = ctx.om.cancelOrder(sell_result.success.order_id);
        }
    } else {
        ctx.se.incrementOrdersRejected(.liquidity_provision);
    }

    // Link the two tracked orders so a fill on one triggers cancel of the other.
    if (buy_tracked and sell_tracked) {
        if (ctx.se.findOrderIndex(buy_result.success.order_id)) |bi| {
            if (ctx.se.findOrderIndex(sell_result.success.order_id)) |si| {
                ctx.se.linkPair(bi, si);
                log.info("strategy_worker", "lp_pair linked: buy={s} sell={s}", .{
                    buy_result.success.order_id, sell_result.success.order_id,
                });
            }
        }
    }

    // Free heap-owned order IDs returned by placeOrder.
    if (buy_result == .success) ctx.om.allocator.free(buy_result.success.order_id);
    if (sell_result == .success) ctx.om.allocator.free(sell_result.success.order_id);
}

/// Returns true if the engine is at capacity (max open orders OR balance
/// commitment ratio reached) and should suppress new order submissions.
/// Emits exactly one IPC event on transition into saturation, and one on
/// transition back out — never per-signal.
fn checkSaturation(ctx: *StrategyWorkerCtx) bool {
    const open_count = ctx.database.queryOpenOrderCount() catch 0;
    const cfg = &ctx.om.risk_config;

    // Resolve current USDC balance (may be null if no recent snapshot).
    const max_age = cfg.balance_snapshot_max_age_seconds;
    const balance_opt = ctx.database.queryLatestUsdcBalance(max_age) catch null;

    // Compute the balance-derived max open orders. Falls back to the static
    // safety cap when no balance is available so the engine still operates
    // on a cold start.
    const max_orders = risk.dynamicMaxOpenOrders(
        balance_opt,
        cfg.max_balance_commitment_ratio,
        cfg.nominal_order_notional_usd,
        cfg.max_open_orders,
    );

    var at_capacity = open_count >= max_orders;
    var reason: []const u8 = "max_open_orders";
    var balance_committed: f64 = 0.0;
    var balance_limit: f64 = 0.0;

    if (!at_capacity) {
        // Also treat the 70% balance-commitment ratio as a saturation
        // condition. The risk gate would reject these too, but checking
        // up-front avoids spamming risk_events / event_risk_rejection.
        const exposure = ctx.database.queryOpenExposureUsd() catch 0.0;
        if (balance_opt) |bal| {
            if (bal > 0) {
                balance_limit = bal * cfg.max_balance_commitment_ratio;
                balance_committed = exposure;
                if (exposure >= balance_limit) {
                    at_capacity = true;
                    reason = "balance_commitment";
                }
            }
        }
    }

    if (at_capacity) {
        // Fire one notification on transition into saturation.
        const was_sat = ctx.saturated.swap(true, .seq_cst);
        if (!was_sat) {
            log.info(
                "strategy_worker",
                "engine SATURATED ({s}): open_orders={d}/{d} exposure={d:.2}/{d:.2}; pausing new submissions until capacity frees",
                .{ reason, open_count, max_orders, balance_committed, balance_limit },
            );
            var evt_buf: [256]u8 = undefined;
            const evt = std.fmt.bufPrint(
                &evt_buf,
                "{{\"reason\":\"{s}\",\"open_orders\":{d},\"max_open_orders\":{d},\"committed_usd\":{d:.2},\"limit_usd\":{d:.2}}}",
                .{ reason, open_count, max_orders, balance_committed, balance_limit },
            ) catch "{}";
            ipc.publishEvent(ipc_types.T.event_engine_saturated, evt);
        }
        return true;
    }

    // Capacity available — clear the flag (one event on transition).
    const was_sat = ctx.saturated.swap(false, .seq_cst);
    if (was_sat) {
        log.info(
            "strategy_worker",
            "engine capacity restored: open_orders={d}/{d}; resuming new submissions",
            .{ open_count, max_orders },
        );
        var evt_buf: [128]u8 = undefined;
        const evt = std.fmt.bufPrint(
            &evt_buf,
            "{{\"open_orders\":{d},\"max_open_orders\":{d}}}",
            .{ open_count, max_orders },
        ) catch "{}";
        ipc.publishEvent(ipc_types.T.event_engine_capacity_restored, evt);
    }
    return false;
}

/// Periodic database retention task — prunes old high-churn rows and
/// reclaims disk space. Runs once on startup and then every 15 minutes so
/// orderbooks (highest-churn table) doesn't balloon between cycles.
fn dbRetentionTicker(database: *db.DB, should_stop: *std.atomic.Value(bool)) void {
    const interval_ns: u64 = 15 * 60 * std.time.ns_per_s; // 15 minutes
    if (should_stop.load(.seq_cst)) return;
    database.runRetention();

    while (!should_stop.load(.seq_cst)) {
        // Sleep in 1s slices so shutdown is responsive.
        var slept: u64 = 0;
        while (slept < interval_ns and !should_stop.load(.seq_cst)) {
            std.Thread.sleep(std.time.ns_per_s);
            slept += std.time.ns_per_s;
        }
        if (should_stop.load(.seq_cst)) break;
        database.runRetention();
    }
}

fn persistStrategyStats(ctx: *StrategyWorkerCtx) void {
    const ns = ctx.se.getStats(.news_repricing);
    ctx.database.insertStrategyStats(
        "news_repricing",
        ns.signals_emitted,
        ns.orders_accepted,
        ns.orders_rejected,
        ns.cancels,
        ns.realized_pnl_estimate,
    ) catch {};
    const ls = ctx.se.getStats(.liquidity_provision);
    ctx.database.insertStrategyStats(
        "liquidity_provision",
        ls.signals_emitted,
        ls.orders_accepted,
        ls.orders_rejected,
        ls.cancels,
        ls.realized_pnl_estimate,
    ) catch {};
}

fn persistBalanceSnapshot(ctx: *StrategyWorkerCtx) void {
    const snap = ctx.pt.getSnapshot();
    ctx.database.insertBalanceSnapshot(
        snap.usdc_balance,
        snap.total_exposure_usd,
        snap.unrealized_pnl,
        snap.realized_pnl_today,
    ) catch {};
    ctx.pt.markBalanceDirty();
}

/// Context for the live USDC balance refresh ticker. Spawned only when
/// API credentials are bootstrapped and DRY_RUN is false.
const BalanceTickerCtx = struct {
    database: *db.DB,
    pt: *portfolio.PortfolioTracker,
    creds: poly_auth.ApiCredentials,
    signer_address: [20]u8,
    signature_type: u8,
    allocator: std.mem.Allocator,
    should_stop: std.atomic.Value(bool),
};

/// Periodically poll Polymarket's L2 /balance-allowance endpoint and write
/// the result to balance_snapshots. Sleeps in 1s slices so shutdown is
/// responsive. Logs a warning on each failed fetch but keeps the loop alive
/// — transient network errors should not take the engine down.
fn balanceTicker(ctx: *BalanceTickerCtx) void {
    const interval_ns: u64 = 60 * std.time.ns_per_s;
    log.info("balance_ticker", "balance refresh loop started (60s interval)", .{});

    while (!ctx.should_stop.load(.seq_cst)) {
        var slept: u64 = 0;
        while (slept < interval_ns and !ctx.should_stop.load(.seq_cst)) {
            std.Thread.sleep(std.time.ns_per_s);
            slept += std.time.ns_per_s;
        }
        if (ctx.should_stop.load(.seq_cst)) break;

        const bal = poly_auth.fetchUsdcBalance(
            ctx.allocator,
            ctx.creds,
            ctx.signer_address,
            ctx.signature_type,
        ) catch |e| {
            log.warn("balance_ticker", "failed to fetch USDC balance: {s}", .{@errorName(e)});
            continue;
        };

        // Preserve current exposure / pnl values from the in-memory snapshot
        // so dashboard rows stay coherent.
        const snap = ctx.pt.getSnapshot();
        ctx.database.insertBalanceSnapshot(
            bal,
            snap.total_exposure_usd,
            snap.unrealized_pnl,
            snap.realized_pnl_today,
        ) catch |e| {
            log.warn("balance_ticker", "failed to insert balance snapshot: {s}", .{@errorName(e)});
            continue;
        };

        ctx.pt.markBalanceDirty();
        log.info("balance_ticker", "USDC balance: ${d:.6}", .{bal});
    }

    log.info("balance_ticker", "balance refresh loop stopped", .{});
}

fn queryLastMid(database: *db.DB, market_id: []const u8) ?f64 {
    const sql = "SELECT mid_price FROM orderbooks WHERE market=? ORDER BY created_at DESC LIMIT 1;" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    if (db.c.sqlite3_prepare_v2(database.handle, sql.ptr, -1, &stmt, null) != db.c.SQLITE_OK) return null;
    defer _ = db.c.sqlite3_finalize(stmt);
    if (db.c.sqlite3_bind_text(stmt, 1, market_id.ptr, @intCast(market_id.len), null) != db.c.SQLITE_OK) return null;
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return null;
    if (db.c.sqlite3_column_type(stmt, 0) == db.c.SQLITE_NULL) return null;
    const mid = db.c.sqlite3_column_double(stmt, 0);
    return mid;
}

/// Query the last mid price for a specific asset_id (token) from the orderbooks table.
fn queryLastMidByAsset(database: *db.DB, asset_id: []const u8) ?f64 {
    const sql = "SELECT mid_price FROM orderbooks WHERE asset_id=? ORDER BY created_at DESC LIMIT 1;" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    if (db.c.sqlite3_prepare_v2(database.handle, sql.ptr, -1, &stmt, null) != db.c.SQLITE_OK) return null;
    defer _ = db.c.sqlite3_finalize(stmt);
    if (db.c.sqlite3_bind_text(stmt, 1, asset_id.ptr, @intCast(asset_id.len), null) != db.c.SQLITE_OK) return null;
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return null;
    if (db.c.sqlite3_column_type(stmt, 0) == db.c.SQLITE_NULL) return null;
    return db.c.sqlite3_column_double(stmt, 0);
}

/// Global database handle for the WS callback (set before spawning WS thread).
var g_database: ?*db.DB = null;

/// Callback for real-time WebSocket price updates.
/// Persists price snapshots so the strategy worker can query mid prices.
fn wsPriceCallback(update: ws.PriceUpdate) void {
    log.debug("ws_feed", "{s} {s}: bid={s} ask={s}", .{
        update.event_type,
        update.asset_id[0..@min(update.asset_id.len, 16)],
        update.best_bid,
        update.best_ask,
    });

    const database = g_database orelse return;

    // Persist events that carry bid/ask data
    const dominated = std.mem.eql(u8, update.event_type, "best_bid_ask") or
        std.mem.eql(u8, update.event_type, "book") or
        std.mem.eql(u8, update.event_type, "price_change");
    if (!dominated) return;

    const bid_f = std.fmt.parseFloat(f64, update.best_bid) catch return;
    const ask_f = std.fmt.parseFloat(f64, update.best_ask) catch return;
    const mid = (bid_f + ask_f) / 2.0;

    // Resolve gamma_id (Gamma market id) from condition_id via markets table
    var gamma_id_buf: [128]u8 = undefined;
    var gamma_id_ptr: ?[*]const u8 = null;
    var gamma_id_len: usize = 0;
    {
        const lookup_sql = "SELECT id FROM markets WHERE condition_id=? LIMIT 1;" ++ &[_:0]u8{};
        var lookup_stmt: ?*db.c.sqlite3_stmt = null;
        if (db.c.sqlite3_prepare_v2(database.handle, lookup_sql.ptr, -1, &lookup_stmt, null) == db.c.SQLITE_OK) {
            defer _ = db.c.sqlite3_finalize(lookup_stmt);
            const bind_rc = db.c.sqlite3_bind_text(lookup_stmt, 1, update.market.ptr, @intCast(update.market.len), null);
            if (bind_rc != db.c.SQLITE_OK) {
                log.warn("ws_feed", "failed to bind condition_id for gamma_id lookup: rc={d}", .{bind_rc});
            } else if (db.c.sqlite3_step(lookup_stmt) == db.c.SQLITE_ROW) {
                const gid_raw = db.c.sqlite3_column_text(lookup_stmt, 0);
                if (gid_raw) |p| {
                    const gid = std.mem.span(@as([*c]const u8, @ptrCast(p)));
                    const gid_len = @min(gid.len, gamma_id_buf.len);
                    @memcpy(gamma_id_buf[0..gid_len], gid[0..gid_len]);
                    gamma_id_ptr = &gamma_id_buf;
                    gamma_id_len = gid_len;
                }
            } else {
                log.warn("ws_feed", "no gamma_id found for condition_id={s}", .{update.market});
            }
        }
    }

    const sql = "INSERT INTO orderbooks(market,asset_id,best_bid,best_ask,mid_price,gamma_id) VALUES(?,?,?,?,?,?);" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    const rc_prepare = db.c.sqlite3_prepare_v2(database.handle, sql.ptr, -1, &stmt, null);
    if (rc_prepare != db.c.SQLITE_OK) {
        const err_msg = std.mem.span(db.c.sqlite3_errmsg(database.handle));
        log.err("ws_feed", "sqlite3_prepare_v2 failed: rc={d} err={s} sql={s}", .{ rc_prepare, err_msg, sql });
        return;
    }
    defer _ = db.c.sqlite3_finalize(stmt);

    _ = db.c.sqlite3_bind_text(stmt, 1, update.market.ptr, @intCast(update.market.len), null);
    _ = db.c.sqlite3_bind_text(stmt, 2, update.asset_id.ptr, @intCast(update.asset_id.len), null);
    _ = db.c.sqlite3_bind_text(stmt, 3, update.best_bid.ptr, @intCast(update.best_bid.len), null);
    _ = db.c.sqlite3_bind_text(stmt, 4, update.best_ask.ptr, @intCast(update.best_ask.len), null);
    _ = db.c.sqlite3_bind_double(stmt, 5, mid);
    if (gamma_id_ptr) |gp| {
        _ = db.c.sqlite3_bind_text(stmt, 6, gp, @intCast(gamma_id_len), null);
    } else {
        _ = db.c.sqlite3_bind_null(stmt, 6);
    }
    const rc_step = db.c.sqlite3_step(stmt);
    if (rc_step != db.c.SQLITE_DONE and rc_step != db.c.SQLITE_OK) {
        const err_msg = std.mem.span(db.c.sqlite3_errmsg(database.handle));
        log.err("ws_feed", "sqlite3_step failed: rc={d} err={s} sql={s} market={s} asset_id={s} bid={s} ask={s} mid={d}", .{ rc_step, err_msg, sql, update.market, update.asset_id, update.best_bid, update.best_ask, mid });
        return;
    }
}

fn priceToImpliedProb(mid_price: f64) f64 {
    return std.math.clamp(mid_price, 0.0, 1.0);
}

fn staleOrderTicker(om: *order_mgr.OrderManager) void {
    const interval_ns: u64 = @as(u64, om.config.stale_scan_interval_min) * 60 * std.time.ns_per_s;
    if (om.should_stop.load(.seq_cst)) return;
    om.scanStaleOrders();

    while (true) {
        if (om.should_stop.load(.seq_cst)) break;
        std.Thread.sleep(interval_ns);
        if (om.should_stop.load(.seq_cst)) break;
        om.scanStaleOrders();
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
