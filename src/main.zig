//! CEX Arbitrage Bot — Entry Point
//!
//! Phase 1/2 startup: loads config, initialises the logger, and runs
//! verification modes for live BBO fetches and mock spread detection.

const std = @import("std");
const cex = @import("cex_zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Determine config path and flags from args.
    var run_verify = false;
    var run_verify_phase2 = false;
    var config_path: []const u8 = "config.toml";
    {
        var args = std.process.args();
        _ = args.next(); // skip argv[0]
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--config")) {
                config_path = args.next() orelse {
                    std.debug.print("error: --config requires a path argument\n", .{});
                    std.process.exit(1);
                };
            } else if (std.mem.eql(u8, arg, "--verify-phase1")) {
                run_verify = true;
            } else if (std.mem.eql(u8, arg, "--verify-phase2-spread-detection")) {
                run_verify_phase2 = true;
            }
        }
    }

    // Load and validate configuration.
    const config = cex.config.loadFromFile(allocator, config_path) catch |e| {
        std.debug.print("fatal: failed to load config from '{s}': {}\n", .{ config_path, e });
        std.process.exit(1);
    };

    // Initialise logger.
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const min_level = parseLogLevel(config.log_level);
    var logger = cex.log.Logger.init("main", min_level, &stdout_writer.interface);

    logger.info("cex-zig starting", .{
        .schema_version = config.schema_version,
        .pairs = config.pairs.len,
        .poll_interval_ms = config.poll_interval_ms,
        .min_profit_pct = config.min_profit_pct,
        .dry_run = config.dry_run,
    });

    logger.info("configuration loaded successfully", .{
        .config_path = config_path,
    });

    if (run_verify_phase2) {
        verifyPhase2SpreadDetection(&config, &logger);
    } else if (run_verify) {
        verifyPhase1(allocator, &config, &logger);
    } else {
        logger.info("scaffold — pass --verify-phase1 or --verify-phase2-spread-detection", .{});
    }
}

/// Run live BBO fetches from Binance and ByBit and validate the results.
fn verifyPhase1(allocator: std.mem.Allocator, config: *const cex.config.Config, logger: *cex.log.Logger) void {
    const pair = if (config.pairs.len > 0) config.pairs.slice()[0] else cex.types.TokenPair{ .base = .BTC, .quote = .USDC };

    logger.info("phase 1 verification: fetching live BBO data", .{
        .timeout_ms = config.request_timeout_ms,
    });

    // Binance
    {
        var adapter = cex.gateway.binance.Adapter.init(allocator, config.request_timeout_ms);
        defer adapter.deinit();

        if (adapter.fetchBbo(pair)) |bbo| {
            if (bbo.isValid()) {
                logger.info("binance BBO verified", .{
                    .bid_price = bbo.bid.price,
                    .bid_size = bbo.bid.size,
                    .ask_price = bbo.ask.price,
                    .ask_size = bbo.ask.size,
                    .fetched_at_us = bbo.fetched_at_us,
                });
            } else {
                logger.warn("binance BBO invalid after fetch", .{});
            }
        } else |err| {
            logger.warn("binance BBO fetch failed", .{
                .@"error" = @errorName(err),
            });
        }
    }

    // ByBit
    {
        var adapter = cex.gateway.bybit.Adapter.init(allocator, config.request_timeout_ms);
        defer adapter.deinit();

        if (adapter.fetchBbo(pair)) |bbo| {
            if (bbo.isValid()) {
                logger.info("bybit BBO verified", .{
                    .bid_price = bbo.bid.price,
                    .bid_size = bbo.bid.size,
                    .ask_price = bbo.ask.price,
                    .ask_size = bbo.ask.size,
                    .fetched_at_us = bbo.fetched_at_us,
                });
            } else {
                logger.warn("bybit BBO invalid after fetch", .{});
            }
        } else |err| {
            logger.warn("bybit BBO fetch failed", .{
                .@"error" = @errorName(err),
            });
        }
    }

    logger.info("phase 1 verification complete", .{});
}

/// Run deterministic mock spread detection using fixture data.
fn verifyPhase2SpreadDetection(config: *const cex.config.Config, logger: *cex.log.Logger) void {
    const pair = cex.types.TokenPair{ .base = .BTC, .quote = .USDC };
    var eng = cex.engine.ArbEngine.init(pair, config.min_profit_pct, config.max_notional_usd);

    logger.info("phase 2 verification: mock spread detection", .{
        .min_profit_pct = config.min_profit_pct,
        .max_notional_usd = config.max_notional_usd,
    });

    // Fixture: Binance ask 82450, ByBit bid 82610 → ~0.194% spread
    const binance_bbo = cex.types.BboUpdate{
        .exchange = .binance,
        .pair = pair,
        .bid = .{ .price = 82_440.0, .size = 0.50 },
        .ask = .{ .price = 82_450.0, .size = 0.30 },
        .fetched_at_us = 1_000_000,
    };
    const bybit_bbo = cex.types.BboUpdate{
        .exchange = .bybit,
        .pair = pair,
        .bid = .{ .price = 82_610.0, .size = 0.20 },
        .ask = .{ .price = 82_620.0, .size = 0.15 },
        .fetched_at_us = 1_000_001,
    };

    _ = eng.processBboUpdate(binance_bbo);
    if (eng.processBboUpdate(bybit_bbo)) |opp| {
        logger.info("spread detected", .{
            .buy_exchange = opp.buy_exchange.label(),
            .sell_exchange = opp.sell_exchange.label(),
            .profit_pct = opp.profit_pct,
            .notional_usd = opp.notional_usd,
        });
    } else {
        logger.info("no spread above threshold", .{});
    }

    // Fixture: no-spread scenario
    const coinbase_bbo = cex.types.BboUpdate{
        .exchange = .coinbase,
        .pair = pair,
        .bid = .{ .price = 82_445.0, .size = 0.40 },
        .ask = .{ .price = 82_455.0, .size = 0.25 },
        .fetched_at_us = 1_000_002,
    };
    _ = eng.processBboUpdate(coinbase_bbo);

    // Add OKX with highest bid → should become new best
    const okx_bbo = cex.types.BboUpdate{
        .exchange = .okx,
        .pair = pair,
        .bid = .{ .price = 82_700.0, .size = 0.10 },
        .ask = .{ .price = 82_710.0, .size = 0.08 },
        .fetched_at_us = 1_000_003,
    };
    if (eng.processBboUpdate(okx_bbo)) |opp| {
        logger.info("best spread updated", .{
            .buy_exchange = opp.buy_exchange.label(),
            .sell_exchange = opp.sell_exchange.label(),
            .profit_pct = opp.profit_pct,
            .notional_usd = opp.notional_usd,
        });
    }

    logger.info("phase 2 verification complete", .{});
}

fn parseLogLevel(s: []const u8) cex.log.Level {
    if (std.ascii.eqlIgnoreCase(s, "DEBUG")) return .debug;
    if (std.ascii.eqlIgnoreCase(s, "WARN")) return .warn;
    if (std.ascii.eqlIgnoreCase(s, "ERROR")) return .err;
    return .info;
}


