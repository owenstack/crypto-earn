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
const news = @import("news_sources.zig");
const ws = @import("websocket.zig");

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

    // Initialize news client (before scanner so it can feed probability estimates)
    var nc = news.NewsClient.init(allocator, .{});

    // Spawn market scanner thread
    var scan = scanner.Scanner.init(allocator, &database, .{});
    scan.setWebSocketClient(&ws_client);
    scan.setNewsClient(&nc);
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

    // Initialize strategy engine
    var se = strategy.StrategyEngine.init(.{});
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

    // Spawn strategy worker thread
    var strategy_ctx = StrategyWorkerCtx{
        .se = &se,
        .om = &om,
        .nc = &nc,
        .database = &database,
        .should_stop = std.atomic.Value(bool).init(false),
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
    nc: *news.NewsClient,
    database: *db.DB,
    should_stop: std.atomic.Value(bool),
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
    for (0..ctx.nc.cached_count) |i| {
        if (ctx.nc.cached_estimates[i]) |est| {
            const market_id = est.market_id[0..est.market_id_len];
            const condition_id = est.condition_id[0..est.condition_id_len];

            // Query orderbook mid price using condition_id (matches WS market field)
            const mid = queryLastMid(ctx.database, condition_id) orelse continue;

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
}

fn evaluateLpSignals(ctx: *StrategyWorkerCtx) void {
    // Get the most recent bid/ask per market from the last 30 seconds
    const sql = "SELECT market, best_bid, best_ask FROM orderbooks WHERE id IN (SELECT MAX(id) FROM orderbooks WHERE created_at >= unixepoch() - 30 GROUP BY market);" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    if (db.c.sqlite3_prepare_v2(ctx.database.handle, sql.ptr, -1, &stmt, null) != db.c.SQLITE_OK) return;
    defer _ = db.c.sqlite3_finalize(stmt);

    while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
        const mid_raw = db.c.sqlite3_column_text(stmt, 0);
        const mid_span = if (mid_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;
        const bid_raw = db.c.sqlite3_column_text(stmt, 1);
        const bid_span = if (bid_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;
        const ask_raw = db.c.sqlite3_column_text(stmt, 2);
        const ask_span = if (ask_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;

        const best_bid = std.fmt.parseFloat(f64, bid_span) catch continue;
        const best_ask = std.fmt.parseFloat(f64, ask_span) catch continue;

        const lp_result = ctx.se.evaluateLiquidityProvision(mid_span, best_bid, best_ask);
        for (lp_result.signals[0..lp_result.count]) |signal| {
            dispatchSignal(ctx, signal);
        }
    }
}

fn dispatchSignal(ctx: *StrategyWorkerCtx, signal: strategy.Signal) void {
    const market_id = signal.market_id[0..signal.market_id_len];
    const side_str: []const u8 = if (signal.direction == .buy) "buy" else "sell";

    var price_buf: [32]u8 = undefined;
    const price_str = std.fmt.bufPrint(&price_buf, "{d:.4}", .{signal.price}) catch "0";
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

    const sql = "INSERT INTO orderbooks(market,asset_id,best_bid,best_ask,mid_price) VALUES(?,?,?,?,?);" ++ &[_:0]u8{};
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
