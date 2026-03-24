//! CEX Arbitrage Bot — Entry Point
//!
//! Phase 1 startup: loads config, initialises the logger, and runs a
//! lightweight BBO verification fetch from Binance and ByBit.

const std = @import("std");
const cex = @import("cex_zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Determine config path from args or default.
    var run_verify = false;
    const config_path = blk: {
        var args = std.process.args();
        _ = args.next(); // skip argv[0]
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--config")) {
                break :blk args.next() orelse {
                    std.debug.print("error: --config requires a path argument\n", .{});
                    std.process.exit(1);
                };
            }
            if (std.mem.eql(u8, arg, "--verify-phase1")) {
                run_verify = true;
            }
        }
        break :blk "config.toml";
    };

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

    if (run_verify) {
        verifyPhase1(allocator, &config, &logger);
    } else {
        logger.info("phase 1 scaffold — pass --verify-phase1 to run live BBO verification.", .{});
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

fn parseLogLevel(s: []const u8) cex.log.Level {
    if (std.ascii.eqlIgnoreCase(s, "DEBUG")) return .debug;
    if (std.ascii.eqlIgnoreCase(s, "WARN")) return .warn;
    if (std.ascii.eqlIgnoreCase(s, "ERROR")) return .err;
    return .info;
}

// ---------------------------------------------------------------------------
// Executable-level smoke test
// ---------------------------------------------------------------------------

test "module linkage smoke test" {
    _ = cex.types.Exchange.binance;
    _ = cex.channel.BoundedChannel(u32, 4);
    _ = cex.log.Level.info;
    _ = cex.config.Config{};
    _ = cex.http.HttpClient;
    _ = cex.gateway.GatewayError;
    _ = cex.gateway.binance.Adapter;
    _ = cex.gateway.bybit.Adapter;
}
