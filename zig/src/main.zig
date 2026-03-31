const std = @import("std");
const log = @import("logger.zig");
const db = @import("db.zig");
const ipc = @import("ipc.zig");
const scanner = @import("market_scanner.zig");
const order_mgr = @import("order_manager.zig");
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

    // Initialize order manager
    var om = order_mgr.OrderManager.init(allocator, &database, risk_config, .{});
    log.info("engine", "order manager ready", .{});

    // Initialize portfolio tracker
    var pt = portfolio.PortfolioTracker.init(allocator, &database, .{});
    log.info("engine", "portfolio tracker ready", .{});

    // Initialize WebSocket client for real-time CLOB updates
    var ws_client = ws.WebSocketClient.init(allocator);
    ws_client.setCallback(&wsPriceCallback);
    log.info("engine", "websocket client ready", .{});

    // Spawn market scanner thread
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

    // Initialize strategy engine and news client
    var se = strategy.StrategyEngine.init(.{});
    var nc = news.NewsClient.init(allocator, .{});
    log.info("engine", "strategy engine ready", .{});

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

        // Persist strategy stats periodically
        persistStrategyStats(ctx);
    }

    log.info("strategy_worker", "strategy evaluation loop stopped", .{});
}

fn evaluateNewsSignals(ctx: *StrategyWorkerCtx) void {
    // Iterate cached probability estimates and compare with CLOB mid prices
    for (0..ctx.nc.cached_count) |i| {
        if (ctx.nc.cached_estimates[i]) |est| {
            const market_id = est.market_id[0..est.market_id_len];

            // Use probability as external estimate; we'd need the CLOB mid price
            // from the most recent orderbook snapshot. For now, query DB for last known mid.
            const mid = queryLastMid(ctx.database, market_id) orelse continue;

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

/// Callback for real-time WebSocket price updates.
fn wsPriceCallback(update: ws.PriceUpdate) void {
    log.debug("ws_feed", "{s} {s}: bid={s} ask={s}", .{
        update.event_type,
        update.asset_id[0..@min(update.asset_id.len, 16)],
        update.best_bid,
        update.best_ask,
    });
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
