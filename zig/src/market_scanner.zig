//! Market scanner — polls Gamma API, manages in-memory market registry,
//! subscribes to CLOB WebSocket for real-time price feeds.
const std = @import("std");
const log = @import("logger.zig");
const db = @import("db.zig");
const gamma = @import("gamma_api.zig");
const clob = @import("clob_orderbook.zig");
const http = @import("http_client.zig");
const ws = @import("websocket.zig");
const atomic = std.atomic;

pub const ScannerConfig = struct {
    poll_interval_min: u32 = 10,
    filter: gamma.FilterConfig = .{},
};

pub const Scanner = struct {
    allocator: std.mem.Allocator,
    database: *db.DB,
    config: ScannerConfig,
    markets: []gamma.GammaMarket,
    last_poll_ts: i64,
    running: atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, database: *db.DB, config: ScannerConfig) Scanner {
        return .{
            .allocator = allocator,
            .database = database,
            .config = config,
            .markets = &.{},
            .last_poll_ts = 0,
            .running = atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Scanner) void {
        if (self.markets.len > 0) {
            gamma.freeMarkets(self.allocator, self.markets);
            self.markets = &.{};
        }
    }

    /// Run the scanner loop. Blocks until stopped.
    /// Call from a dedicated thread.
    pub fn run(self: *Scanner) void {
        self.running.store(true, .seq_cst);
        log.info("scanner", "starting market scanner (poll every {d}min)", .{self.config.poll_interval_min});

        // Ensure orderbooks table exists
        self.database.execZ(clob.CREATE_ORDERBOOKS_TABLE ++ &[_:0]u8{}) catch |e| {
            log.err("scanner", "failed to create orderbooks table: {any}", .{e});
            return;
        };

        while (self.running.load(.seq_cst)) {
            self.pollOnce();
            const sleep_ns: u64 = @as(u64, self.config.poll_interval_min) * 60 * std.time.ns_per_s;
            std.Thread.sleep(sleep_ns);
        }

        log.info("scanner", "scanner stopped", .{});
    }

    /// Execute a single poll cycle.
    pub fn pollOnce(self: *Scanner) void {
        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        const new_markets = gamma.pollMarkets(self.allocator, &client, self.config.filter) catch |e| {
            log.err("scanner", "poll failed: {any}", .{e});
            return;
        };

        // Log changes
        if (self.markets.len > 0) {
            const added = countNew(self.markets, new_markets);
            const removed = countNew(new_markets, self.markets);
            if (added > 0 or removed > 0) {
                log.info("scanner", "registry update: +{d} -{d} markets (total {d})", .{ added, removed, new_markets.len });
            }
            gamma.freeMarkets(self.allocator, self.markets);
        } else {
            log.info("scanner", "initial poll: {d} markets", .{new_markets.len});
        }

        self.markets = new_markets;
        self.last_poll_ts = std.time.timestamp();

        // Persist to SQLite
        self.persistMarkets();
    }

    fn persistMarkets(self: *Scanner) void {
        for (self.markets) |m| {
            var buf: [2048:0]u8 = @splat(0);
            _ = std.fmt.bufPrint(&buf, "INSERT OR REPLACE INTO markets(id,symbol,base,quote,status)VALUES('{s}','{s}','{s}','USDC','{s}');", .{
                m.id,
                m.slug,
                m.question,
                if (m.active) "active" else "inactive",
            }) catch continue;
            self.database.execZ(&buf) catch |e| {
                log.warn("scanner", "persist market failed: {any}", .{e});
            };
        }
    }

    pub fn stop(self: *Scanner) void {
        self.running.store(false, .seq_cst);
    }
};

/// Count how many markets in `new` are not in `old` (by id).
fn countNew(old: []const gamma.GammaMarket, new: []const gamma.GammaMarket) usize {
    var n: usize = 0;
    for (new) |nm| {
        var found = false;
        for (old) |om| {
            if (std.mem.eql(u8, nm.id, om.id)) {
                found = true;
                break;
            }
        }
        if (!found) n += 1;
    }
    return n;
}

test "scanner: init and deinit" {
    var database = try db.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    var scanner = Scanner.init(std.testing.allocator, &database, .{});
    defer scanner.deinit();

    try std.testing.expectEqual(@as(usize, 0), scanner.markets.len);
    try std.testing.expect(!scanner.running.load(.seq_cst));
}

test "scanner: ScannerConfig defaults" {
    const config = ScannerConfig{};
    try std.testing.expectEqual(@as(u32, 10), config.poll_interval_min);
    try std.testing.expectEqual(@as(f64, 5000.0), config.filter.min_volume_24h);
}
