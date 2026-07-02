const std = @import("std");
const log = @import("logger.zig");
const db = @import("db.zig");
const ipc = @import("ipc.zig");
const ipc_types = @import("ipc_types.zig");
const order_mgr = @import("order_manager.zig");
const risk = @import("risk_gate.zig");
const portfolio = @import("portfolio_tracker.zig");
const strategy = @import("strategy_engine.zig");
const ws = @import("websocket.zig");
const fill_poller = @import("fill_poller.zig");
const crash_trace = @import("crash_trace.zig");
const hl_auth = @import("hl_auth.zig");
const hl_market_meta = @import("hl_market_meta.zig");
const hl_orderbook = @import("hl_orderbook.zig");
const binance_ws = @import("binance_ws.zig");
const cex_dex_arb = @import("cex_dex_arb.zig");

const HlEnvError = error{
    HlMissingPrivateKey,
    HlInvalidPrivateKey,
    HlMissingNetwork,
    HlInvalidNetwork,
    HlInvalidVerifier,
    HlInvalidChainIdOverride,
    HlAuthInternal,
};

/// Load Hyperliquid signing config from the environment. In dry-run mode
/// missing fields fall back to safe defaults (network=testnet, zero key);
/// in live mode the private key + network are mandatory.
fn loadHlConfig(dry_run: bool) HlEnvError!order_mgr.HlConfig {
    var cfg = order_mgr.HlConfig{};

    // Network: testnet|mainnet
    if (std.posix.getenv("HL_NETWORK")) |raw| {
        cfg.network = hl_auth.parseNetwork(raw) catch return error.HlInvalidNetwork;
    } else if (!dry_run) {
        return error.HlMissingNetwork;
    }

    // Optional chain id override
    if (std.posix.getenv("HL_CHAIN_ID")) |raw| {
        cfg.chain_id = std.fmt.parseInt(u64, raw, 10) catch
            return error.HlInvalidChainIdOverride;
    } else {
        cfg.chain_id = hl_auth.resolveChainId(cfg.network, null);
    }

    // Domain name + version (configurable, with safe defaults)
    if (std.posix.getenv("HL_EIP712_NAME")) |raw| cfg.domain_name = raw;
    if (std.posix.getenv("HL_EIP712_VERSION")) |raw| cfg.domain_version = raw;

    // Verifying contract per network
    const verifier_env: ?[]const u8 = switch (cfg.network) {
        .mainnet => std.posix.getenv("HL_EIP712_VERIFIER_MAINNET"),
        .testnet => std.posix.getenv("HL_EIP712_VERIFIER_TESTNET"),
    };
    if (verifier_env) |raw| {
        cfg.verifying_contract = hl_auth.parseAddressHex(raw) catch
            return error.HlInvalidVerifier;
    }

    // API base URL derived from network.
    cfg.api_base = switch (cfg.network) {
        .mainnet => order_mgr.HL_API_BASE_MAINNET,
        .testnet => order_mgr.HL_API_BASE_TESTNET,
    };

    // Private key — never logged.
    if (std.posix.getenv("HL_API_PRIVATE_KEY")) |raw| {
        cfg.private_key = hl_auth.parsePrivateKeyHex(raw) catch
            return error.HlInvalidPrivateKey;
        cfg.signer_address = hl_auth.derivePublicAddress(cfg.private_key) catch
            return error.HlAuthInternal;
        cfg.enabled = true;
    } else if (!dry_run) {
        return error.HlMissingPrivateKey;
    }

    return cfg;
}

test "loadHlConfig: chain id resolution from network" {
    try std.testing.expectEqual(@as(u64, 998), hl_auth.resolveChainId(.testnet, null));
    try std.testing.expectEqual(@as(u64, 999), hl_auth.resolveChainId(.mainnet, null));
    try std.testing.expectEqual(@as(u64, 31337), hl_auth.resolveChainId(.testnet, 31337));
}

pub fn main() !void {
    // The engine fans out work across many threads (WS, IPC, scanner, fill
    // poller, strategy worker, retention, etc). GeneralPurposeAllocator is
    // not safe to share across threads, and doing so causes sporadic memory
    // corruption/segfaults under live WS traffic. Use the libc allocator here
    // because malloc/free are thread-safe and the process is long-lived.
    const allocator = std.heap.c_allocator;

    log.init();
    crash_trace.install();
    crash_trace.breadcrumb("engine", "main entry", .{});
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

    // Phase 2: parse Hyperliquid config from env. dry_run can run with
    // defaults; live mode requires a valid private key + network.
    const dry_run_env = if (std.posix.getenv("DRY_RUN")) |v|
        (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true"))
    else
        false;

    // Initialize risk config after DRY_RUN is known so dry-run validation
    // counts paper orders/exposure instead of live exchange rows.
    const risk_config = risk.RiskConfig{
        .dry_run_enabled = dry_run_env,
    };

    const hl_config = loadHlConfig(dry_run_env) catch |e| {
        log.err("engine", "Hyperliquid config invalid: {s}", .{@errorName(e)});
        return e;
    };

    if (hl_config.enabled) {
        const addr_hex = hl_auth.formatAddressEip55(hl_config.signer_address);
        log.info("engine", "HL signer address: {s} (network={s} chainId={d})", .{
            addr_hex,
            @tagName(hl_config.network),
            hl_config.chain_id,
        });
    } else {
        log.warn("engine", "HL signing disabled (dry_run={any}); orders will not be submitted to /exchange", .{dry_run_env});
    }

    // Phase 4: read the dry-run initial balance early so we can plumb it
    // into the OrderManager config (used by simulated balance / telemetry).
    const dry_run_initial_balance_env: f64 = if (std.posix.getenv("DRY_RUN_INITIAL_BALANCE")) |v|
        std.fmt.parseFloat(f64, v) catch 10.0
    else
        10.0;

    if (dry_run_env) {
        log.info("engine", "DRY_RUN mode: enabled, initial balance: ${d:.2}", .{dry_run_initial_balance_env});
    } else {
        log.info("engine", "DRY_RUN mode: disabled (live order submission)", .{});
    }

    // Order manager config. Phase 2 wired HL signing into the submit path;
    // Phase 4 wires DRY_RUN here so dry-run interception happens centrally
    // in placeOrder/cancelOrder (not bypassing the shared risk gate).
    const om_config = order_mgr.OrderManagerConfig{
        .hl = hl_config,
        .dry_run_enabled = dry_run_env,
        .dry_run_initial_balance = dry_run_initial_balance_env,
    };

    // Initialize order manager
    var om = order_mgr.OrderManager.init(allocator, &database, risk_config, om_config);
    log.info("engine", "order manager ready", .{});

    // Initialize portfolio tracker
    var pt = portfolio.PortfolioTracker.init(allocator, &database, .{});
    log.info("engine", "portfolio tracker ready", .{});

    // Phase 5: live HL equity/margin polling. This feeds `/portfolio` with
    // clearinghouseState semantics while preserving the legacy balance cache
    // used by existing risk/strategy paths. In dry-run, simulated balances are
    // authoritative; live/testnet account equity can be zero and must not
    // overwrite the paper balance snapshots used by risk and sizing.
    var hl_portfolio_user_addr = hl_auth.formatAddressEip55(hl_config.signer_address);
    var hl_portfolio_thread: ?std.Thread = null;
    if (hl_config.enabled and !dry_run_env) {
        hl_portfolio_thread = try std.Thread.spawn(.{}, portfolio.PortfolioTracker.hlPollingLoop, .{
            &pt,
            hl_config.api_base,
            hl_portfolio_user_addr[0..],
        });
        log.info("engine", "HL portfolio polling thread started", .{});
    } else if (dry_run_env) {
        log.info("engine", "HL portfolio polling skipped in dry-run mode", .{});
    }
    defer {
        pt.stop();
        if (hl_portfolio_thread) |t| t.join();
    }

    // ─── Phase 3: HL asset metadata preload ─────────────────────────────
    // Pull the HL universe before strategy/feed threads so the orderbook
    // module and order manager can resolve asset_index lookups against a
    // populated cache. Failure is fatal in live mode (no asset_index =
    // bad orders); a warning suffices in dry-run.
    var asset_meta = hl_market_meta.AssetMeta.init(allocator, hl_config.api_base);
    defer asset_meta.deinit();
    g_database = &database;

    {
        const loaded = asset_meta.fetchAndLoad() catch |e| blk: {
            if (dry_run_env) {
                log.warn("engine", "HL meta preload failed in dry-run, continuing: {s}", .{@errorName(e)});
                break :blk @as(usize, 0);
            } else {
                log.err("engine", "HL meta preload failed: {s}", .{@errorName(e)});
                return e;
            }
        };
        log.info("engine", "HL asset metadata loaded: {d} assets (network={s})", .{
            loaded, @tagName(hl_config.network),
        });
        // Persist the universe → markets.asset_index so DB joins (Phase 7
        // reports, dashboards) can lift the index without a roundtrip.
        var i: usize = 0;
        while (i < loaded) : (i += 1) {
            const sym = asset_meta.assets.items[i].name();
            database.upsertMarketAssetIndex(sym, @intCast(i)) catch |e| {
                log.warn("engine", "upsertMarketAssetIndex failed for {s}: {s}", .{ sym, @errorName(e) });
            };
        }
    }
    om.setAssetMeta(&asset_meta);

    // Spawn the metadata refresh loop (24h cadence).
    const meta_thread = try std.Thread.spawn(.{}, hl_market_meta.AssetMeta.refreshLoop, .{&asset_meta});
    defer {
        asset_meta.stop();
        meta_thread.join();
    }
    log.info("engine", "HL asset metadata refresh loop started", .{});

    const disable_market_data = if (std.posix.getenv("DISABLE_MARKET_DATA")) |v|
        (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true"))
    else
        false;

    if (disable_market_data) {
        log.warn("engine", "market data feeds disabled by DISABLE_MARKET_DATA", .{});
    } else {
        log.info("engine", "market data feeds enabled", .{});
    }

    // ─── Phase 3: HL l2Book orderbook feed ──────────────────────────────
    // Configurable symbol list via HL_SYMBOLS=BTC,ETH,SOL.
    var hl_symbols_buf: [4096]u8 = undefined;
    var hl_symbols: ?[][]const u8 = null;
    defer if (hl_symbols) |symbols| allocator.free(symbols);

    var hl_ob: hl_orderbook.Orderbook = undefined;
    var hl_ob_started = false;
    var hl_ob_thread: ?std.Thread = null;
    var hl_persist_ctx = HlPersistCtx{ .database = &database, .meta = &asset_meta };
    defer if (hl_ob_started) {
        hl_ob.stop();
        if (hl_ob_thread) |t| t.join();
        hl_ob.deinit();
    };

    // ─── Phase 3: Binance bookTicker feed ───────────────────────────────
    var binance_symbols_buf: [4096]u8 = undefined;
    var binance_symbols: ?[][]const u8 = null;
    defer if (binance_symbols) |symbols| allocator.free(symbols);

    var binance_feed: binance_ws.BinanceFeed = undefined;
    var binance_started = false;
    var binance_thread: ?std.Thread = null;
    var binance_watchdog_thread: ?std.Thread = null;
    var binance_persist_ctx = BinancePersistCtx{ .database = &database };
    defer if (binance_started) {
        binance_feed.stop();
        if (binance_thread) |t| t.join();
        if (binance_watchdog_thread) |t| t.join();
        binance_feed.deinit();
    };

    if (!disable_market_data) {
        hl_symbols = parseSymbolList(
            std.posix.getenv("HL_SYMBOLS") orelse "BTC,ETH,SOL",
            &hl_symbols_buf,
            allocator,
        ) catch |e| {
            log.err("engine", "failed to parse HL_SYMBOLS: {s}", .{@errorName(e)});
            return e;
        };

        const hl_ws_host = switch (hl_config.network) {
            .mainnet => hl_orderbook.HL_WS_HOST_MAINNET,
            .testnet => hl_orderbook.HL_WS_HOST_TESTNET,
        };
        hl_ob = hl_orderbook.Orderbook.init(allocator, hl_ws_host, hl_symbols.?);
        hl_ob_started = true;
        hl_ob.setPersistCallback(&hlOrderbookPersistCallback, &hl_persist_ctx);

        hl_ob_thread = try std.Thread.spawn(.{}, hl_orderbook.Orderbook.run, .{&hl_ob});
        log.info("engine", "HL l2Book feed started ({d} symbols, host={s})", .{
            hl_symbols.?.len, hl_ws_host,
        });

        binance_symbols = parseSymbolList(
            std.posix.getenv("BINANCE_SYMBOLS") orelse "BTCUSDT,ETHUSDT,SOLUSDT",
            &binance_symbols_buf,
            allocator,
        ) catch |e| {
            log.err("engine", "failed to parse BINANCE_SYMBOLS: {s}", .{@errorName(e)});
            return e;
        };

        binance_feed = binance_ws.BinanceFeed.init(allocator, binance_symbols.?);
        binance_started = true;
        binance_feed.setPersistCallback(&binancePersistCallback, &binance_persist_ctx);

        binance_thread = try std.Thread.spawn(.{}, binance_ws.BinanceFeed.run, .{&binance_feed});
        binance_watchdog_thread = try std.Thread.spawn(.{}, binance_ws.BinanceFeed.watchdogLoop, .{&binance_feed});
        log.info("engine", "Binance bookTicker feed started ({d} symbols)", .{binance_symbols.?.len});
    }

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
    var arb_runtime = cex_dex_arb.ArbRuntime.init(.{});

    // Initialize fill poller (with strategy engine reference for inventory + LP pair cancel)
    var fp = fill_poller.FillPoller.init(allocator, &database, &om, &pt, &se);
    fp.setArbRuntime(&arb_runtime);
    log.info("engine", "fill poller ready", .{});

    // Run startup reconciliation (blocking, before strategy worker)
    {
        var reconcile_ok = false;
        var attempt: u32 = 0;
        while (attempt < 3) : (attempt += 1) {
            const result = fp.reconcileOnStartup();
            if (result.complete) {
                reconcile_ok = true;
                break;
            }
            log.warn("engine", "reconciliation attempt {d}/3 returned empty, retrying...", .{attempt + 1});
            std.Thread.sleep(2 * std.time.ns_per_s);
        }
        if (!reconcile_ok) {
            if (!dry_run_env and hl_config.enabled) {
                log.err("engine", "reconciliation failed after 3 retries; live order gate remains closed", .{});
                om.halted.store(true, .seq_cst);
                return error.StartupReconciliationFailed;
            }
            log.warn("engine", "reconciliation failed after 3 retries in dry-run/offline mode, proceeding anyway", .{});
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
    const enable_market_making_env =
        std.posix.getenv("ENABLE_MARKET_MAKING") orelse
        std.posix.getenv("ENABLE_LIQUIDITY_PROVISION");
    if (enable_market_making_env) |v| {
        if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) {
            se.enableStrategy(.market_making);
        }
    }

    // Phase 6: CEX↔DEX arb. ENABLE_CEX_DEX_ARB turns the evaluator on.
    // ARB_SUBMIT_ORDERS additionally enables HL taker submission through the
    // same risk-gated OrderManager path used by every other strategy.
    const arb_enabled_initial = if (std.posix.getenv("ENABLE_CEX_DEX_ARB")) |v|
        (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true"))
    else
        false;
    var arb_enabled = std.atomic.Value(bool).init(arb_enabled_initial);
    const arb_submit_orders = if (std.posix.getenv("ARB_SUBMIT_ORDERS")) |v|
        (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true"))
    else
        false;
    if (arb_enabled_initial) {
        log.info("engine", "CEX↔DEX arb evaluator enabled (submit_orders={any})", .{arb_submit_orders});
    }

    // Dry-run mode: log signals without placing real orders
    const dry_run = if (std.posix.getenv("DRY_RUN")) |v|
        (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true"))
    else
        false;
    const dry_run_session_start = std.time.timestamp();
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

    // USDC balance refresh ticker removed in Phase 1 (Polymarket-specific).
    // HL equity/portfolio polling lands in Phase 2 via hl_portfolio_tracker.

    // Spawn strategy worker thread
    var strategy_ctx = StrategyWorkerCtx{
        .se = &se,
        .om = &om,
        .pt = &pt,
        .database = &database,
        .should_stop = std.atomic.Value(bool).init(false),
        .dry_run = dry_run,
        .dry_run_session_start = dry_run_session_start,
        // Phase 6: live market-data sources for arb (and future MM source
        // switch). Only wired when the corresponding feed thread started.
        .hl_ob = if (hl_ob_started) &hl_ob else null,
        .hl_symbols = hl_symbols,
        .binance_feed = if (binance_started) &binance_feed else null,
        .binance_symbols = binance_symbols,
        .arb = &arb_runtime,
        .arb_enabled = &arb_enabled,
        .arb_submit_orders = arb_submit_orders,
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
    try ipc.serve(allocator, socket_path, &database, &om, &pt, &se, &arb_runtime, &arb_enabled);
}

const StrategyWorkerCtx = struct {
    se: *strategy.StrategyEngine,
    om: *order_mgr.OrderManager,
    pt: *portfolio.PortfolioTracker,
    database: *db.DB,
    should_stop: std.atomic.Value(bool),
    dry_run: bool,
    dry_run_session_start: i64,
    /// True when the engine has reached max_open_orders or balance commitment
    /// cap. While set, dispatchSignal silently skips submission so we focus on
    /// managing existing orders. Cleared when capacity frees (a fill closes
    /// an order or balance grows).
    saturated: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Throttle repeated max_position_usd preflight logs while strategies are
    /// generating signals that are obviously above the current per-order cap.
    max_position_log_after_ms: i64 = 0,
    /// Counter ticking 5s per increment; used to throttle balance/stats DB
    /// inserts so they happen ~1/min instead of every 5s.
    persist_tick: u64 = 0,
    /// Counter for dry-run fill simulation (every ~30s when in dry-run).
    sim_tick: u64 = 0,

    // ─── Phase 6 engine integration: live market-data sources ───────────
    /// In-memory HL top-of-book cache (null when market data is disabled).
    /// Used as the live source for both market-making evaluation and the
    /// CEX↔DEX arb evaluator instead of the legacy `orderbooks` table.
    hl_ob: ?*hl_orderbook.Orderbook = null,
    /// HL coin symbols (e.g. BTC, ETH, SOL) the orderbook feed tracks.
    hl_symbols: ?[][]const u8 = null,
    /// In-memory Binance bookTicker cache for arb mid prices.
    binance_feed: ?*binance_ws.BinanceFeed = null,
    /// Binance symbols (e.g. BTCUSDT) index-aligned with `hl_symbols`.
    binance_symbols: ?[][]const u8 = null,

    // ─── Phase 6 CEX↔DEX arb ────────────────────────────────────────────
    /// Shared arb evaluator/breaker state. The strategy worker evaluates
    /// signals, while fill ingestion reports realized P&L.
    arb: *cex_dex_arb.ArbRuntime,
    /// Whether the arb evaluator runs at all (ENABLE_CEX_DEX_ARB).
    arb_enabled: *std.atomic.Value(bool),
    /// Whether confirmed arb signals are submitted as HL taker orders.
    /// Defaults false so operators must explicitly opt in, but when enabled
    /// confirmed signals place IOC-style orders through OrderManager.
    arb_submit_orders: bool = false,
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
        if (ctx.om.isPaused()) {
            log.debug("strategy_worker", "skipping evaluation: engine paused", .{});
            continue;
        }

        // News repricing strategy was removed in Phase 1 (no probability
        // provider on Hyperliquid). The arb strategy lands in Phase 6.

        // Evaluate liquidity provision using recent orderbook data
        if (ctx.se.isEnabled(.market_making)) {
            evaluateLpSignals(ctx);
        }

        // Phase 6: CEX↔DEX arb evaluation and optional taker submission.
        if (ctx.arb_enabled.load(.seq_cst)) {
            evaluateArbSignals(ctx);
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

fn evaluateLpSignals(ctx: *StrategyWorkerCtx) void {
    cancelOrphanLpBuys(ctx);

    const hl_ob = ctx.hl_ob orelse {
        log.debug("strategy_worker", "skipping market_making: HL orderbook cache unavailable", .{});
        return;
    };
    const hl_syms = ctx.hl_symbols orelse {
        log.debug("strategy_worker", "skipping market_making: HL symbols unavailable", .{});
        return;
    };
    const now_ns = std.time.nanoTimestamp();
    const max_age_ns: i128 = 10 * std.time.ns_per_s;

    // Read cooldown from runtime_config; default 15s, clamp 5–300s.
    var cd_buf: [16]u8 = undefined;
    const cd_str = ctx.database.getConfig("lp_cooldown_seconds", &cd_buf) orelse "15";
    const cooldown_s = std.fmt.parseInt(i64, cd_str, 10) catch 15;
    const cooldown = std.math.clamp(cooldown_s, @as(i64, 5), @as(i64, 300));

    for (hl_syms) |sym| {
        const quote = hl_ob.quote(sym) orelse continue;
        if (quote.ts_ns == 0) continue;
        if (now_ns - @as(i128, quote.ts_ns) > max_age_ns) continue;
        if (quote.bid <= 0 or quote.ask <= 0 or quote.ask <= quote.bid) continue;

        // Per-market cooldown: configurable via runtime_config.lp_cooldown_seconds.
        if (ctx.se.checkLpCooldown(sym, cooldown)) continue;

        const lp_result = ctx.se.evaluateLiquidityProvision(sym, quote.bid, quote.ask, ctx.pt.usdc_balance);
        if (lp_result.count == 2) {
            dispatchLpPair(ctx, lp_result.signals[0], lp_result.signals[1]);
        } else {
            for (lp_result.signals[0..lp_result.count]) |signal| {
                dispatchSignal(ctx, signal);
            }
        }
    }
}

/// Phase 6: evaluate CEX↔DEX (Binance↔Hyperliquid) basis arbitrage.
///
/// Reads the live in-memory HL and Binance mids per asset, runs the pure
/// `ArbState` evaluator (signed delta → confirm window → circuit breaker),
/// persists every confirmed signal to `arb_events`, and, when
/// `arb_submit_orders` is enabled, submits an IOC-style HL taker order
/// through the shared OrderManager/risk-gate path.
fn evaluateArbSignals(ctx: *StrategyWorkerCtx) void {
    const hl_ob = ctx.hl_ob orelse return;
    const hl_syms = ctx.hl_symbols orelse return;
    const now = std.time.timestamp();
    const now_ns = std.time.nanoTimestamp();
    const max_age_ns: i128 = 10 * std.time.ns_per_s;

    for (hl_syms, 0..) |sym, i| {
        const hlq = hl_ob.quote(sym) orelse continue;
        if (hlq.ts_ns == 0) continue;
        if (now_ns - @as(i128, hlq.ts_ns) > max_age_ns) continue;
        if (hlq.mid <= 0) continue;

        const binance_mid = arbBinanceMid(ctx, sym, i, now_ns, max_age_ns) orelse continue;

        const sig = ctx.arb.evaluate(sym, binance_mid, hlq.mid, now) orelse continue;

        const side: []const u8 = switch (sig.direction) {
            .short_hl_long_cex => "sell",
            .long_hl_short_cex => "buy",
        };
        log.info("arb", "confirmed signal {s} hl_side={s} delta={d:.2}bps binance={d:.4} hl={d:.4} submit={any}", .{
            sym, side, sig.delta_bps, sig.binance_mid, sig.hl_mid, ctx.arb_submit_orders,
        });

        var submitted_order_id: ?[]u8 = null;
        if (ctx.arb_submit_orders) {
            submitted_order_id = dispatchArbSignal(ctx, sig, hlq);
        }
        defer if (submitted_order_id) |oid| ctx.om.allocator.free(oid);

        ctx.database.insertArbEvent(
            sym,
            sig.binance_mid,
            sig.hl_mid,
            sig.delta_bps,
            submitted_order_id,
        ) catch |e| {
            log.warn("arb", "failed to persist arb event for {s}: {s}", .{ sym, @errorName(e) });
        };
    }
}

const ArbOrderParams = struct {
    side: []const u8,
    price: f64,
    size: f64,
};

fn arbOrderParams(sig: cex_dex_arb.ArbSignal, hlq: hl_orderbook.Quote) ?ArbOrderParams {
    const side: []const u8 = switch (sig.direction) {
        .short_hl_long_cex => "sell",
        .long_hl_short_cex => "buy",
    };
    const raw_price = switch (sig.direction) {
        .short_hl_long_cex => hlq.bid,
        .long_hl_short_cex => hlq.ask,
    };
    const price = normalizePerpLimitPrice(raw_price) orelse return null;
    if (sig.size_usd <= 0 or !std.math.isFinite(sig.size_usd)) return null;
    const size = sig.size_usd / price;
    if (size <= 0 or !std.math.isFinite(size)) return null;
    return .{ .side = side, .price = price, .size = size };
}

fn dispatchArbSignal(
    ctx: *StrategyWorkerCtx,
    sig: cex_dex_arb.ArbSignal,
    hlq: hl_orderbook.Quote,
) ?[]u8 {
    if (ctx.om.isHalted() or ctx.om.isPaused()) return null;
    if (checkSaturation(ctx)) return null;

    var params = arbOrderParams(sig, hlq) orelse {
        log.warn("arb", "skipping signal with invalid taker quote: asset={s} bid={d} ask={d}", .{
            sig.asset, hlq.bid, hlq.ask,
        });
        ctx.arb.recordTradeResult(-sig.size_usd, sig.timestamp);
        return null;
    };

    var cap_buf: [16]u8 = undefined;
    if (ctx.database.getConfig("max_order_size_usd", &cap_buf)) |cap_str| {
        if (std.fmt.parseFloat(f64, cap_str)) |cap_usd| {
            if (cap_usd > 0 and cap_usd < sig.size_usd) {
                params.size = cap_usd / params.price;
            }
        } else |_| {}
    }

    const notional = params.size * params.price;
    if (shouldSkipForMaxPosition(ctx, sig.asset, params.side, notional)) {
        ctx.arb.recordTradeResult(-notional, sig.timestamp);
        return null;
    }

    var price_buf: [32]u8 = undefined;
    const price_str = std.fmt.bufPrint(&price_buf, "{d:.6}", .{params.price}) catch return null;
    var size_buf: [32]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{d:.6}", .{params.size}) catch return null;

    const result = ctx.om.placeOrder(sig.asset, params.side, size_str, price_str, "market", "cex_dex_arb");
    switch (result) {
        .success => |s| {
            log.info("arb", "submitted HL taker order asset={s} side={s} size={s} price={s} order_id={s}", .{
                sig.asset, params.side, size_str, price_str, s.order_id,
            });
            return s.order_id;
        },
        .rejected => |r| {
            log.warn("arb", "HL taker order rejected asset={s} side={s} reason={s}", .{
                sig.asset, params.side, r.reason,
            });
            ctx.arb.recordTradeResult(-notional, sig.timestamp);
            return null;
        },
        .failed => |f| {
            log.warn("arb", "HL taker order failed asset={s} side={s} reason={s}", .{
                sig.asset, params.side, f.reason,
            });
            ctx.arb.recordTradeResult(-notional, sig.timestamp);
            return null;
        },
    }
}

/// Resolve the latest Binance mid for an HL coin symbol. Prefers the live
/// in-memory feed (index-aligned `binance_symbols`, else `<SYM>USDT`) and
/// falls back to the most recent persisted `binance_prices` row. Returns
/// null when no sufficiently-fresh quote is available.
fn arbBinanceMid(
    ctx: *StrategyWorkerCtx,
    hl_symbol: []const u8,
    idx: usize,
    now_ns: i128,
    max_age_ns: i128,
) ?f64 {
    var sym_buf: [32]u8 = undefined;
    const bsym: []const u8 = blk: {
        if (ctx.binance_symbols) |bs| {
            if (idx < bs.len) break :blk bs[idx];
        }
        break :blk std.fmt.bufPrint(&sym_buf, "{s}USDT", .{hl_symbol}) catch return null;
    };

    if (ctx.binance_feed) |feed| {
        if (feed.quote(bsym)) |q| {
            if (q.ts_ns != 0 and now_ns - @as(i128, q.ts_ns) <= max_age_ns and q.mid > 0) {
                return q.mid;
            }
        }
    }

    if (ctx.database.queryLatestBinancePrice(bsym)) |row| {
        if (row.ts_ns != 0 and now_ns - @as(i128, row.ts_ns) <= max_age_ns and row.mid > 0) {
            return row.mid;
        }
    }
    return null;
}

fn cancelOrphanLpBuys(ctx: *StrategyWorkerCtx) void {
    const sql =
        "SELECT o.id, o.market_id FROM orders o " ++
        "WHERE o.status IN ('placed','partially_filled') " ++
        "AND o.strategy_origin IN ('liquidity_provision','market_making') " ++
        "AND o.side='buy' " ++
        "AND NOT EXISTS (" ++
        "SELECT 1 FROM orders s " ++
        "WHERE s.market_id=o.market_id " ++
        "AND s.status IN ('placed','partially_filled') " ++
        "AND s.strategy_origin IN ('liquidity_provision','market_making') " ++
        "AND s.side='sell'" ++
        ");" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    if (db.c.sqlite3_prepare_v2(ctx.database.handle, sql.ptr, -1, &stmt, null) != db.c.SQLITE_OK) return;
    defer _ = db.c.sqlite3_finalize(stmt);

    while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
        const oid_raw = db.c.sqlite3_column_text(stmt, 0);
        const mid_raw = db.c.sqlite3_column_text(stmt, 1);
        const oid_span = if (oid_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else continue;
        const mid_span = if (mid_raw) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "unknown";

        var oid_buf: [68]u8 = undefined;
        const oid_len = @min(oid_span.len, oid_buf.len);
        @memcpy(oid_buf[0..oid_len], oid_span[0..oid_len]);
        const order_id = oid_buf[0..oid_len];

        if (ctx.om.cancelOrder(order_id)) {
            ctx.se.untrackOrder(order_id);
            ctx.se.incrementCancels(.market_making);
            log.warn("strategy_worker", "cancelled orphan LP buy {s} on {s}", .{ order_id, mid_span });
        } else {
            log.err("strategy_worker", "failed to cancel orphan LP buy {s} on {s}", .{ order_id, mid_span });
        }
    }
}

const DryRunQuote = struct {
    best_bid: f64,
    best_ask: f64,
    mid_price: f64,
};

/// Resolve a dry-run settlement quote from HL-native market data. Prefer the
/// live in-memory HL top-of-book cache; fall back to persisted HL snapshots
/// keyed by the HL coin symbol in `orderbooks.market`.
fn queryDryRunQuote(hl_ob: ?*hl_orderbook.Orderbook, database: *db.DB, market_id: []const u8) ?DryRunQuote {
    if (hl_ob) |ob| {
        if (ob.quote(market_id)) |q| {
            if (q.bid > 0 and q.ask > 0 and q.ask > q.bid and q.mid > 0) {
                return .{ .best_bid = q.bid, .best_ask = q.ask, .mid_price = q.mid };
            }
        }
    }

    return queryPersistedHlOrderbookForMarket(database, market_id);
}

/// Query the latest persisted HL orderbook (best bid/ask + mid) for a coin symbol.
fn queryPersistedHlOrderbookForMarket(database: *db.DB, market_id: []const u8) ?DryRunQuote {
    const sql = "SELECT best_bid, best_ask, mid_price FROM orderbooks WHERE market=? ORDER BY created_at DESC LIMIT 1;" ++ &[_:0]u8{};
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

test "dry-run quote lookup ignores legacy gamma_id matches" {
    var database = try db.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO orderbooks(market,asset_id,best_bid,best_ask,mid_price,gamma_id) VALUES('legacy-market','legacy-asset','99.0','101.0',100.0,'BTC');");
    try std.testing.expect(queryDryRunQuote(null, &database, "BTC") == null);

    try database.execZ("INSERT INTO orderbooks(market,asset_id,best_bid,best_ask,mid_price,gamma_id) VALUES('BTC','BTC','100.0','102.0',101.0,'legacy-gamma');");
    const quote = queryDryRunQuote(null, &database, "BTC") orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), quote.best_bid, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 102.0), quote.best_ask, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 101.0), quote.mid_price, 1e-9);
}

test "dry-run quote lookup prefers live HL orderbook cache" {
    var database = try db.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO orderbooks(market,asset_id,best_bid,best_ask,mid_price,gamma_id) VALUES('BTC','BTC','1.0','2.0',1.5,'legacy-gamma');");

    var syms = [_][]const u8{"BTC"};
    var ob = hl_orderbook.Orderbook.init(std.testing.allocator, hl_orderbook.HL_WS_HOST_TESTNET, &syms);
    defer ob.deinit();

    const bids = [_]hl_orderbook.Level{.{ .price = 100.0, .size = 1.0 }};
    const asks = [_]hl_orderbook.Level{.{ .price = 101.0, .size = 1.0 }};
    ob.applySnapshot("BTC", &bids, &asks, 42);

    const quote = queryDryRunQuote(&ob, &database, "BTC") orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), quote.best_bid, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 101.0), quote.best_ask, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 100.5), quote.mid_price, 1e-9);
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

        const ob = queryDryRunQuote(ctx.hl_ob, ctx.database, mid) orelse continue;

        const fills = if (is_buy)
            ob.best_ask <= order.signal_price
        else
            ob.best_bid >= order.signal_price;

        if (!fills) continue;

        const fill_price = if (is_buy) ob.best_ask else ob.best_bid;
        const notional = fill_price * order.size;
        const fee_bps = dryRunFeeBpsPerSide(order.strategy());
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

        if (isMarketMakingStrategy(order.strategy())) {
            cancelDryRunPairedOrder(ctx, oid);
        }
        ctx.se.untrackOrder(oid);
    }

    if (any_settled) {
        updateDryRunBalance(ctx);
    }
}

fn cancelDryRunPairedOrder(ctx: *StrategyWorkerCtx, filled_order_id: []const u8) void {
    const paired = ctx.se.findPairedOrder(filled_order_id) orelse return;
    var paired_buf: [68]u8 = undefined;
    const paired_len = @min(paired.len, paired_buf.len);
    @memcpy(paired_buf[0..paired_len], paired[0..paired_len]);
    const paired_id = paired_buf[0..paired_len];

    if (ctx.om.cancelOrder(paired_id)) {
        ctx.se.untrackOrder(paired_id);
        ctx.se.incrementCancels(.market_making);
        log.info("dry_run", "cancelled paired LP order after fill: filled={s} paired={s}", .{
            filled_order_id,
            paired_id,
        });
    } else {
        log.warn("dry_run", "failed to cancel paired LP order after fill: filled={s} paired={s}", .{
            filled_order_id,
            paired_id,
        });
    }
}

fn isMarketMakingStrategy(strategy_name: []const u8) bool {
    return std.mem.eql(u8, strategy_name, "market_making") or
        std.mem.eql(u8, strategy_name, "liquidity_provision");
}

fn dryRunFeeBpsPerSide(strategy_name: []const u8) f64 {
    if (isMarketMakingStrategy(strategy_name)) {
        return 1.5; // HL maker fee bps per side for resting quotes.
    }
    return 4.5; // HL taker fee bps per side for taker-style simulations.
}

test "dry-run fee model uses maker fees for market making" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), dryRunFeeBpsPerSide("market_making"), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), dryRunFeeBpsPerSide("liquidity_provision"), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), dryRunFeeBpsPerSide("cex_dex_arb"), 1e-9);
}

/// After dry-run fills settle, sum filled-order P&L and write a fresh balance
/// snapshot. This makes /balance, the risk gate, and dynamic order-size
/// limits all reflect simulated profitability so dry-run mirrors live exactly.
fn updateDryRunBalance(ctx: *StrategyWorkerCtx) void {
    const sql = "SELECT COALESCE(SUM(pnl), 0.0), COALESCE(SUM(fees), 0.0) FROM dry_run_orders WHERE status='filled' AND created_at >= ?;" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    if (db.c.sqlite3_prepare_v2(ctx.database.handle, sql.ptr, -1, &stmt, null) != db.c.SQLITE_OK) return;
    defer _ = db.c.sqlite3_finalize(stmt);
    if (db.c.sqlite3_bind_int64(stmt, 1, ctx.dry_run_session_start) != db.c.SQLITE_OK) return;
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
    // Phase 4: dry-run signal analytics. Persist every emitted signal to
    // `dry_run_signals` so analyzeDryRunSignals (paper P&L) keeps working.
    // The actual order persistence happens inside `OrderManager.placeOrder`
    // via the shared risk-gate path (AC-016-4).
    if (ctx.dry_run) {
        const dr_market_id = signal.market_id[0..signal.market_id_len];
        const dr_side: []const u8 = if (signal.direction == .buy) "buy" else "sell";
        const dr_bid: ?f64 = if (signal.best_bid > 0) signal.best_bid else null;
        const dr_ask: ?f64 = if (signal.best_ask > 0) signal.best_ask else null;
        const dr_mid = if (dr_bid != null and dr_ask != null) (dr_bid.? + dr_ask.?) / 2.0 else signal.price;
        const dr_delta = @abs(signal.price - dr_mid);

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
    const order_price = normalizePerpLimitPrice(signal.price) orelse {
        log.warn("strategy_worker", "skipping signal with invalid price: market={s} price={d}", .{ market_id, signal.price });
        ctx.se.incrementOrdersRejected(signal.strategy);
        return;
    };

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
                const cap_size = cap_usd / order_price;
                if (effective_size > cap_size) effective_size = cap_size;
            } else |_| {}
        }
    }

    var price_buf: [32]u8 = undefined;
    const price_str = std.fmt.bufPrint(&price_buf, "{d:.6}", .{order_price}) catch "0";
    var size_buf: [32]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{d:.8}", .{effective_size}) catch "0";

    const notional = effective_size * order_price;
    if (shouldSkipForMaxPosition(ctx, market_id, side_str, notional)) return;

    const origin = @tagName(signal.strategy);

    const result = ctx.om.placeOrder(market_id, side_str, size_str, price_str, "limit", origin);
    crash_trace.breadcrumb("strategy", "placeOrder returned market={s} side={s}", .{
        market_id[0..@min(market_id.len, 24)],
        side_str,
    });
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

fn normalizePerpLimitPrice(price: f64) ?f64 {
    if (!std.math.isFinite(price) or price <= 0) return null;
    const tick: f64 = 0.01;
    const rounded = @round(price / tick) * tick;
    if (rounded <= 0) return null;
    return rounded;
}

test "normalizePerpLimitPrice keeps perp-scale prices above prediction-market range" {
    const rounded = normalizePerpLimitPrice(50_000.123) orelse return error.TestExpectedEqual;
    try std.testing.expectApproxEqAbs(@as(f64, 50_000.12), rounded, 1e-9);
    try std.testing.expectEqual(@as(?f64, null), normalizePerpLimitPrice(0.0));
}

test "arbOrderParams builds IOC taker params from confirmed arb signal" {
    const quote = hl_orderbook.Quote{
        .bid = 65000.011,
        .ask = 65001.019,
        .mid = 65000.515,
        .ts_ns = 1,
    };
    const short_sig = cex_dex_arb.ArbSignal{
        .asset = "BTC",
        .direction = .short_hl_long_cex,
        .delta_bps = 12.0,
        .binance_mid = 64920.0,
        .hl_mid = 65000.515,
        .size_usd = 10.0,
        .timestamp = 1,
    };
    const short_params = arbOrderParams(short_sig, quote) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("sell", short_params.side);
    try std.testing.expectApproxEqAbs(@as(f64, 65000.01), short_params.price, 1e-9);
    try std.testing.expect(short_params.size > 0.00015);
    try std.testing.expect(short_params.size < 0.00016);

    var long_sig = short_sig;
    long_sig.direction = .long_hl_short_cex;
    const long_params = arbOrderParams(long_sig, quote) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("buy", long_params.side);
    try std.testing.expectApproxEqAbs(@as(f64, 65001.02), long_params.price, 1e-9);
}

fn shouldSkipForMaxPosition(ctx: *StrategyWorkerCtx, market_id: []const u8, side: []const u8, notional: f64) bool {
    const balance_opt = ctx.database.queryLatestUsdcBalance(ctx.om.risk_config.balance_snapshot_max_age_seconds) catch null;
    const limits = risk.resolveLimits(ctx.om.risk_config, balance_opt);
    if (notional <= limits.max_position_usd) return false;

    const now_ms = std.time.milliTimestamp();
    if (now_ms >= ctx.max_position_log_after_ms) {
        log.warn(
            "strategy_worker",
            "preflight skipped signal: check=max_position_usd market={s} side={s} limit={d:.2} actual={d:.2}; suppressing repeated risk rejections",
            .{ market_id, side, limits.max_position_usd, notional },
        );
        ctx.max_position_log_after_ms = now_ms + 60_000;
    }
    return true;
}

/// Dispatch a paired LP buy+sell signal, placing both legs and linking them
/// so a fill on one cancels the other (handled in fill_poller). Falls back
/// to dispatchSignal individually for dry-run.
fn dispatchLpPair(ctx: *StrategyWorkerCtx, buy_signal: strategy.Signal, sell_signal: strategy.Signal) void {
    // Phase 4: dry-run takes the same pair preflight + per-leg placeOrder
    // path as live so the shared risk gate (AC-016-4) and pair-atomicity
    // semantics apply. Per-leg dry-run interception happens inside
    // OrderManager.placeOrder. Analytics signals are recorded by
    // dispatchSignal — call it through the buy/sell legs below as needed.
    if (ctx.dry_run) {
        // Persist analytics for both legs (dispatchSignal would do this if
        // called directly; we keep paired semantics through placeOrder so
        // mark each leg here without dispatching).
        const dr_buy_market_id = buy_signal.market_id[0..buy_signal.market_id_len];
        const dr_sell_market_id = sell_signal.market_id[0..sell_signal.market_id_len];
        const buy_bid: ?f64 = if (buy_signal.best_bid > 0) buy_signal.best_bid else null;
        const buy_ask: ?f64 = if (buy_signal.best_ask > 0) buy_signal.best_ask else null;
        const sell_bid: ?f64 = if (sell_signal.best_bid > 0) sell_signal.best_bid else null;
        const sell_ask: ?f64 = if (sell_signal.best_ask > 0) sell_signal.best_ask else null;
        const buy_mid = if (buy_bid != null and buy_ask != null) (buy_bid.? + buy_ask.?) / 2.0 else buy_signal.price;
        const sell_mid = if (sell_bid != null and sell_ask != null) (sell_bid.? + sell_ask.?) / 2.0 else sell_signal.price;
        ctx.database.insertDryRunSignal(
            dr_buy_market_id,
            @tagName(buy_signal.strategy),
            "buy",
            buy_signal.price,
            buy_signal.size,
            @abs(buy_signal.price - buy_mid),
            buy_signal.confidence,
            buy_signal.timestamp,
            buy_bid,
            buy_ask,
        ) catch |e| {
            log.err("dry_run", "failed to persist dry-run signal (lp_pair buy): {s}", .{@errorName(e)});
        };
        ctx.database.insertDryRunSignal(
            dr_sell_market_id,
            @tagName(sell_signal.strategy),
            "sell",
            sell_signal.price,
            sell_signal.size,
            @abs(sell_signal.price - sell_mid),
            sell_signal.confidence,
            sell_signal.timestamp,
            sell_bid,
            sell_ask,
        ) catch |e| {
            log.err("dry_run", "failed to persist dry-run signal (lp_pair sell): {s}", .{@errorName(e)});
        };
        // Fall through to the shared pair preflight + placeOrder path.
    }

    if (ctx.om.isHalted()) return;
    if (checkSaturation(ctx)) return;

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

    const buy_price = normalizePerpLimitPrice(buy_signal.price) orelse {
        log.warn("strategy_worker", "lp_pair: invalid buy price market={s} price={d}", .{ buy_market_id, buy_signal.price });
        ctx.se.incrementOrdersRejected(.market_making);
        return;
    };
    const sell_price = normalizePerpLimitPrice(sell_signal.price) orelse {
        log.warn("strategy_worker", "lp_pair: invalid sell price market={s} price={d}", .{ sell_market_id, sell_signal.price });
        ctx.se.incrementOrdersRejected(.market_making);
        return;
    };

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

    const buy_price_str = std.fmt.bufPrint(&buy_price_buf, "{d:.6}", .{buy_price}) catch "0";
    const sell_price_str = std.fmt.bufPrint(&sell_price_buf, "{d:.6}", .{sell_price}) catch "0";
    const buy_size_str = std.fmt.bufPrint(&buy_size_buf, "{d:.8}", .{buy_size}) catch "0";
    const sell_size_str = std.fmt.bufPrint(&sell_size_buf, "{d:.8}", .{sell_size}) catch "0";

    const origin = "market_making";

    // PAIR PRE-FLIGHT: Validate the COMBINED notional of both legs against
    // the risk gate before placing either. The per-order gate would otherwise
    // accept the buy (which then bumps current_exposure) and reject the sell,
    // leaving a naked buy on the CLOB. This is the root cause of the bug
    // where 7 buys ended up unpaired.
    const buy_notional = buy_size * buy_price;
    const sell_notional = sell_size * sell_price;
    const preflight = risk.validatePairPreflight(
        ctx.om.database,
        ctx.om.risk_config,
        buy_notional,
        sell_notional,
    );
    if (preflight == .reject) {
        ctx.se.incrementOrdersRejected(.market_making);
        ctx.se.incrementOrdersRejected(.market_making);
        log.warn(
            "strategy_worker",
            "lp_pair: preflight rejected ({s}); skipping pair (buy_notional={d:.2} sell_notional={d:.2})",
            .{ preflight.reject.check_name, buy_notional, sell_notional },
        );
        return;
    }

    // ATOMICITY: Place buy first. Only attempt the sell if the buy was
    // accepted AND tracked. If the sell is rejected (e.g. by the risk gate
    // because the buy already committed capital), cancel the buy so we
    // never leave a naked long leg on the CLOB.

    // Place buy leg
    const buy_result = ctx.om.placeOrder(buy_market_id, "buy", buy_size_str, buy_price_str, "limit", origin);
    crash_trace.breadcrumb("strategy", "lp pair buy returned market={s}", .{
        buy_market_id[0..@min(buy_market_id.len, 24)],
    });

    if (buy_result != .success) {
        ctx.se.incrementOrdersRejected(.market_making);
        const reason: []const u8 = switch (buy_result) {
            .rejected => |r| r.reason,
            .failed => |f| f.reason,
            else => "unknown",
        };
        log.warn("strategy_worker", "lp_pair: buy leg not placed ({s}); skipping sell leg", .{reason});
        return;
    }

    // Buy succeeded — attempt to track it. If tracking fails, cancel and bail.
    const buy_tracked = ctx.se.trackOrder(buy_result.success.order_id, buy_market_id, .market_making, .buy, buy_signal.price);
    if (!buy_tracked) {
        ctx.se.incrementOrdersRejected(.market_making);
        log.err("strategy_worker", "lp_pair: failed to track buy leg, cancelling: {s}", .{buy_result.success.order_id});
        _ = ctx.om.cancelOrder(buy_result.success.order_id);
        ctx.om.allocator.free(buy_result.success.order_id);
        return;
    }
    ctx.se.incrementOrdersAccepted(.market_making);
    ctx.database.insertStrategySignal(buy_market_id, origin, buy_signal.confidence, "") catch {};

    // Place sell leg. From here on, any failure must roll back the buy.
    const sell_result = ctx.om.placeOrder(sell_market_id, "sell", sell_size_str, sell_price_str, "limit", origin);
    crash_trace.breadcrumb("strategy", "lp pair sell returned market={s}", .{
        sell_market_id[0..@min(sell_market_id.len, 24)],
    });

    if (sell_result != .success) {
        ctx.se.incrementOrdersRejected(.market_making);
        const reason: []const u8 = switch (sell_result) {
            .rejected => |r| r.reason,
            .failed => |f| f.reason,
            else => "unknown",
        };
        log.warn("strategy_worker", "lp_pair: sell rejected ({s}); cancelling paired buy {s}", .{
            reason, buy_result.success.order_id,
        });
        _ = ctx.om.cancelOrder(buy_result.success.order_id);
        ctx.se.untrackOrder(buy_result.success.order_id);
        ctx.om.allocator.free(buy_result.success.order_id);
        return;
    }

    // Sell succeeded — attempt to track it. If tracking fails, cancel both legs.
    const sell_tracked = ctx.se.trackOrder(sell_result.success.order_id, sell_market_id, .market_making, .sell, sell_signal.price);
    if (!sell_tracked) {
        ctx.se.incrementOrdersRejected(.market_making);
        log.err("strategy_worker", "lp_pair: failed to track sell leg, cancelling both legs: buy={s} sell={s}", .{
            buy_result.success.order_id, sell_result.success.order_id,
        });
        _ = ctx.om.cancelOrder(sell_result.success.order_id);
        _ = ctx.om.cancelOrder(buy_result.success.order_id);
        ctx.se.untrackOrder(buy_result.success.order_id);
        ctx.om.allocator.free(buy_result.success.order_id);
        ctx.om.allocator.free(sell_result.success.order_id);
        return;
    }
    ctx.se.incrementOrdersAccepted(.market_making);
    ctx.database.insertStrategySignal(sell_market_id, origin, sell_signal.confidence, "") catch {};

    // Link the two tracked orders so a fill on one triggers cancel of the other.
    if (ctx.se.findOrderIndex(buy_result.success.order_id)) |bi| {
        if (ctx.se.findOrderIndex(sell_result.success.order_id)) |si| {
            ctx.se.linkPair(bi, si);
            log.info("strategy_worker", "lp_pair linked: buy={s} sell={s}", .{
                buy_result.success.order_id, sell_result.success.order_id,
            });
        }
    }

    // Free heap-owned order IDs returned by placeOrder.
    ctx.om.allocator.free(buy_result.success.order_id);
    ctx.om.allocator.free(sell_result.success.order_id);
}

/// Returns true if the engine is at capacity (max open orders OR balance
/// commitment ratio reached) and should suppress new order submissions.
/// Emits exactly one IPC event on transition into saturation, and one on
/// transition back out — never per-signal.
fn checkSaturation(ctx: *StrategyWorkerCtx) bool {
    const cfg = &ctx.om.risk_config;
    const open_count = (if (cfg.dry_run_enabled)
        ctx.database.queryOpenDryRunOrderCount()
    else
        ctx.database.queryOpenOrderCount()) catch 0;

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
        const exposure = (if (cfg.dry_run_enabled)
            ctx.database.queryOpenDryRunExposureUsd()
        else
            ctx.database.queryOpenExposureUsd()) catch 0.0;
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
    const ls = ctx.se.getStats(.market_making);
    ctx.database.insertStrategyStats(
        "market_making",
        ls.signals_emitted,
        ls.orders_accepted,
        ls.orders_rejected,
        ls.cancels,
        ls.realized_pnl_estimate,
    ) catch {};
}

fn persistBalanceSnapshot(ctx: *StrategyWorkerCtx) void {
    if (ctx.dry_run) {
        updateDryRunBalance(ctx);
        return;
    }

    const snap = ctx.pt.getSnapshot();
    ctx.database.insertBalanceSnapshot(
        snap.usdc_balance,
        snap.total_exposure_usd,
        snap.unrealized_pnl,
        snap.realized_pnl_today,
    ) catch {};
    ctx.pt.markBalanceDirty();
}

// Polymarket-specific balance ticker, USDC balance fallback fetch, and
// auth validation/diagnostic helpers were removed in Phase 1. HL equivalents
// will be reintroduced in Phase 2 (hl_portfolio_tracker / hl_auth).

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

const BookTop = struct { mid: f64, best_bid: f64, best_ask: f64 };

/// Query the most recent mid_price + best_bid + best_ask for an asset_id.
fn queryLastBookByAsset(database: *db.DB, asset_id: []const u8) ?BookTop {
    const sql = "SELECT mid_price, best_bid, best_ask FROM orderbooks WHERE asset_id=? ORDER BY created_at DESC LIMIT 1;" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    if (db.c.sqlite3_prepare_v2(database.handle, sql.ptr, -1, &stmt, null) != db.c.SQLITE_OK) return null;
    defer _ = db.c.sqlite3_finalize(stmt);
    if (db.c.sqlite3_bind_text(stmt, 1, asset_id.ptr, @intCast(asset_id.len), null) != db.c.SQLITE_OK) return null;
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return null;
    if (db.c.sqlite3_column_type(stmt, 0) == db.c.SQLITE_NULL) return null;

    const mid = db.c.sqlite3_column_double(stmt, 0);
    // best_bid / best_ask are stored as TEXT in orderbooks; parse defensively.
    var best_bid: f64 = 0.0;
    var best_ask: f64 = 0.0;
    if (db.c.sqlite3_column_type(stmt, 1) != db.c.SQLITE_NULL) {
        const raw = db.c.sqlite3_column_text(stmt, 1);
        if (raw) |p| {
            const span = std.mem.span(@as([*c]const u8, @ptrCast(p)));
            best_bid = std.fmt.parseFloat(f64, span) catch 0.0;
        }
    }
    if (db.c.sqlite3_column_type(stmt, 2) != db.c.SQLITE_NULL) {
        const raw = db.c.sqlite3_column_text(stmt, 2);
        if (raw) |p| {
            const span = std.mem.span(@as([*c]const u8, @ptrCast(p)));
            best_ask = std.fmt.parseFloat(f64, span) catch 0.0;
        }
    }
    return .{ .mid = mid, .best_bid = best_bid, .best_ask = best_ask };
}

/// Global database handle for the WS callback (set before spawning WS thread).
var g_database: ?*db.DB = null;

/// Parse a comma-separated symbol list ("BTC,ETH,SOL") into a heap-owned
/// slice of slices. Caller frees the outer slice via `allocator.free`.
/// Each inner slice references `scratch` (storage).
fn parseSymbolList(
    raw: []const u8,
    scratch: []u8,
    allocator: std.mem.Allocator,
) ![][]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return try allocator.alloc([]const u8, 0);

    if (trimmed.len > scratch.len) return error.SymbolListTooLong;
    @memcpy(scratch[0..trimmed.len], trimmed);
    const buf = scratch[0..trimmed.len];

    // Count separators to size the slice up front.
    var n: usize = 1;
    for (buf) |ch| if (ch == ',') {
        n += 1;
    };

    var out = try allocator.alloc([]const u8, n);
    errdefer allocator.free(out);

    var idx: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= buf.len) : (i += 1) {
        if (i == buf.len or buf[i] == ',') {
            const sym = std.mem.trim(u8, buf[start..i], " \t");
            if (sym.len > 0) {
                out[idx] = sym;
                idx += 1;
            }
            start = i + 1;
        }
    }
    return out[0..idx];
}

/// Phase 3 persistence callback context for HL orderbook updates.
const HlPersistCtx = struct {
    database: *db.DB,
    meta: *hl_market_meta.AssetMeta,
};

fn hlOrderbookPersistCallback(ctx_opt: ?*anyopaque, symbol: []const u8, book: *const hl_orderbook.Book) void {
    const ctx_raw = ctx_opt orelse return;
    const ctx: *HlPersistCtx = @ptrCast(@alignCast(ctx_raw));
    const bid = book.bestBid() orelse return;
    const ask = book.bestAsk() orelse return;
    const mid = book.mid() orelse return;
    const asset_idx: ?i64 = if (ctx.meta.lookup(symbol)) |i| @intCast(i) else null;
    ctx.database.insertHlOrderbookSnapshot(symbol, asset_idx, bid, ask, mid) catch |e| {
        log.warn("hl_ob", "persist failed for {s}: {s}", .{ symbol, @errorName(e) });
    };
}

/// Phase 3 persistence callback context for Binance bookTicker updates.
const BinancePersistCtx = struct {
    database: *db.DB,
};

fn binancePersistCallback(ctx_opt: ?*anyopaque, symbol: []const u8, q: binance_ws.Quote) void {
    const ctx_raw = ctx_opt orelse return;
    const ctx: *BinancePersistCtx = @ptrCast(@alignCast(ctx_raw));
    ctx.database.insertBinancePrice(symbol, q.bid, q.ask, q.mid, q.ts_ns) catch |e| {
        log.warn("binance", "persist failed for {s}: {s}", .{ symbol, @errorName(e) });
    };
}

/// Callback for real-time WebSocket price updates.
/// Persists price snapshots so the strategy worker can query mid prices.
fn wsPriceCallback(update: ws.PriceUpdate) void {
    crash_trace.breadcrumb("ws_feed", "update type={s} asset={s} market={s}", .{
        update.event_type,
        update.asset_id[0..@min(update.asset_id.len, 24)],
        update.market[0..@min(update.market.len, 24)],
    });
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
    crash_trace.breadcrumb("ws_feed", "persisted asset={s} mid={d:.4}", .{
        update.asset_id[0..@min(update.asset_id.len, 24)],
        mid,
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
