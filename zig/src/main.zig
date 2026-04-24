const std = @import("std");
const log = @import("logger.zig");
const db = @import("db.zig");
const ipc = @import("ipc.zig");
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

    // Initialize fill poller
    var fp = fill_poller.FillPoller.init(allocator, &database, &om, &pt);
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

    // Initialize strategy engine
    var se = strategy.StrategyEngine.init(.{});

    // Load lp_max_position_usd from runtime_config
    {
        var lp_buf: [32]u8 = undefined;
        if (database.getConfig("lp_max_position_usd", &lp_buf)) |val| {
            if (std.fmt.parseFloat(f64, val)) |v| {
                se.lp_max_position_usd = v;
                log.info("engine", "lp_max_position_usd={d:.2}", .{v});
            } else |_| {
                log.warn("engine", "invalid lp_max_position_usd in runtime_config: {s}", .{val});
            }
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
        log.info("engine", "DRY-RUN mode enabled — no orders will be placed", .{});
    }

    // Spawn strategy worker thread
    var strategy_ctx = StrategyWorkerCtx{
        .se = &se,
        .om = &om,
        .pp = &pp,
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

    // Start IPC server (blocks)
    try ipc.serve(allocator, socket_path, &database, &om, &pt, &se);
}

const StrategyWorkerCtx = struct {
    se: *strategy.StrategyEngine,
    om: *order_mgr.OrderManager,
    pp: *prob_provider.ProbabilityProvider,
    database: *db.DB,
    should_stop: std.atomic.Value(bool),
    dry_run: bool,
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

        // Persist strategy stats periodically
        persistStrategyStats(ctx);
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

        if (ctx.se.evaluateNewsRepricing(market_id, est.probability, implied_prob)) |signal| {
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

        // Pass gamma_id (Gamma market id) so placeOrder receives a Gamma id
        const lp_result = ctx.se.evaluateLiquidityProvision(gid_span, best_bid, best_ask);
        for (lp_result.signals[0..lp_result.count]) |signal| {
            dispatchSignal(ctx, signal);
        }
    }
}

fn dispatchSignal(ctx: *StrategyWorkerCtx, signal: strategy.Signal) void {
    if (ctx.dry_run) {
        const dr_market_id = signal.market_id[0..signal.market_id_len];
        const dr_side: []const u8 = if (signal.direction == .buy) "buy" else "sell";

        // Look up current best bid/ask for delta and spread
        var dr_bid: ?f64 = null;
        var dr_ask: ?f64 = null;
        {
            const ob_sql = "SELECT best_bid, best_ask FROM orderbooks WHERE gamma_id=? ORDER BY created_at DESC LIMIT 1;" ++ &[_:0]u8{};
            var ob_stmt: ?*db.c.sqlite3_stmt = null;
            if (db.c.sqlite3_prepare_v2(ctx.database.handle, ob_sql.ptr, -1, &ob_stmt, null) == db.c.SQLITE_OK) {
                defer _ = db.c.sqlite3_finalize(ob_stmt);
                if (db.c.sqlite3_bind_text(ob_stmt, 1, dr_market_id.ptr, @intCast(dr_market_id.len), null) == db.c.SQLITE_OK) {
                    if (db.c.sqlite3_step(ob_stmt) == db.c.SQLITE_ROW) {
                        const bid_raw = db.c.sqlite3_column_text(ob_stmt, 0);
                        const ask_raw = db.c.sqlite3_column_text(ob_stmt, 1);
                        if (bid_raw) |p| {
                            dr_bid = std.fmt.parseFloat(f64, std.mem.span(@as([*c]const u8, @ptrCast(p)))) catch null;
                        }
                        if (ask_raw) |p| {
                            dr_ask = std.fmt.parseFloat(f64, std.mem.span(@as([*c]const u8, @ptrCast(p)))) catch null;
                        }
                    }
                }
            }
        }

        const dr_mid = if (dr_bid != null and dr_ask != null) (dr_bid.? + dr_ask.?) / 2.0 else signal.price;
        const dr_delta = @abs(signal.price - dr_mid);

        log.info("dry_run", "signal: market={s} strategy={s} dir={s} price={d:.4} size={d:.2} delta={d:.4} conf={d:.4} bid={d:.4} ask={d:.4}", .{
            dr_market_id,
            @tagName(signal.strategy),
            dr_side,
            signal.price,
            signal.size,
            dr_delta,
            signal.confidence,
            dr_bid orelse 0.0,
            dr_ask orelse 0.0,
        });

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
        return;
    }

    const market_id = signal.market_id[0..signal.market_id_len];
    const side_str: []const u8 = if (signal.direction == .buy) "buy" else "sell";

    // Round price to 0.01 tick size (Polymarket default min_tick_size)
    const tick = 0.01;
    const rounded_price = @round(signal.price / tick) * tick;
    // Clamp to valid Polymarket price range (0.01 to 0.99)
    const clamped_price = std.math.clamp(rounded_price, 0.01, 0.99);

    var price_buf: [32]u8 = undefined;
    const price_str = std.fmt.bufPrint(&price_buf, "{d:.2}", .{clamped_price}) catch "0";
    var size_buf: [32]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{d:.2}", .{signal.size}) catch "0";

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
