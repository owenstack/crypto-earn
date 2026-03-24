//! CEX Arbitrage Bot — Entry Point
//!
//! Phase 0 startup scaffold: loads config, initialises the logger, and exits.
//! Runtime bot behavior (fetchers, engine, risk gate, notifiers) is Phase 1+.

const std = @import("std");
const cex = @import("cex_zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Determine config path from args or default.
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

    // Phase 0: startup scaffold complete. Runtime loop is Phase 1+.
    logger.info("phase 0 scaffold — no runtime loop. exiting.", .{});
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
    // Verify all foundation modules are accessible through the library import.
    _ = cex.types.Exchange.binance;
    _ = cex.channel.BoundedChannel(u32, 4);
    _ = cex.log.Level.info;
    _ = cex.config.Config{};
}
