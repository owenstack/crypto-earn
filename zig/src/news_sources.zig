//! External probability client — fetches probability estimates from Gamma market data.
const std = @import("std");
const log = @import("logger.zig");
const gamma = @import("gamma_api.zig");

pub const Provider = enum { gamma_markets };

pub const ProbabilityEstimate = struct {
    market_id: [64]u8,
    market_id_len: usize,
    probability: f64,
    confidence: f64,
    provider: Provider,
    fetched_at: i64,
};

pub const NewsSourceConfig = struct {
    provider: Provider = .gamma_markets,
    cache_ttl_seconds: i64 = 60,
};

pub const NewsClient = struct {
    allocator: std.mem.Allocator,
    config: NewsSourceConfig,
    last_fetch_ts: i64,
    cached_estimates: [MAX_CACHED]?ProbabilityEstimate,
    cached_count: usize,

    const MAX_CACHED = 128;

    pub fn init(allocator: std.mem.Allocator, config: NewsSourceConfig) NewsClient {
        return .{
            .allocator = allocator,
            .config = config,
            .last_fetch_ts = 0,
            .cached_estimates = [_]?ProbabilityEstimate{null} ** MAX_CACHED,
            .cached_count = 0,
        };
    }

    /// Fetch probability estimate for a market from the configured provider.
    /// Uses cache if within TTL.
    pub fn getEstimate(self: *NewsClient, market_id: []const u8) ?ProbabilityEstimate {
        const now = std.time.timestamp();
        for (self.cached_estimates) |slot| {
            if (slot) |est| {
                if (std.mem.eql(u8, est.market_id[0..est.market_id_len], market_id)) {
                    if (now - est.fetched_at <= self.config.cache_ttl_seconds) {
                        return est;
                    }
                    return null;
                }
            }
        }
        return null;
    }

    /// Update cache from Gamma market data (called when scanner refreshes).
    pub fn updateFromGammaMarkets(self: *NewsClient, markets: []const gamma.GammaMarket) void {
        const now = std.time.timestamp();
        var count: usize = 0;

        for (markets) |market| {
            if (count >= MAX_CACHED) break;

            const prob = parseOutcomePrice(market.outcome_prices, self.allocator) orelse continue;

            var mid: [64]u8 = undefined;
            const mid_len = @min(market.id.len, 64);
            if (market.id.len > 64) {
                log.warn("news", "market id truncated from {d} to 64 bytes: {s}", .{ market.id.len, market.id[0..mid_len] });
            }
            @memcpy(mid[0..mid_len], market.id[0..mid_len]);

            self.cached_estimates[count] = ProbabilityEstimate{
                .market_id = mid,
                .market_id_len = mid_len,
                .probability = prob,
                .confidence = 0.8,
                .provider = .gamma_markets,
                .fetched_at = now,
            };
            count += 1;
        }

        // Clear remaining slots
        var i = count;
        while (i < MAX_CACHED) : (i += 1) {
            self.cached_estimates[i] = null;
        }
        self.cached_count = count;
        self.last_fetch_ts = now;

        log.info("news", "updated cache from gamma: {d} estimates", .{count});
    }

    /// Parse outcome_prices JSON string like "[\"0.55\",\"0.45\"]" to get the Yes probability.
    fn parseOutcomePrice(outcome_prices: []const u8, allocator: std.mem.Allocator) ?f64 {
        if (outcome_prices.len == 0) return null;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, outcome_prices, .{}) catch return null;
        defer parsed.deinit();

        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return null,
        };

        if (arr.items.len == 0) return null;

        const first = arr.items[0];
        const price_str = switch (first) {
            .string => |s| s,
            .float => |f| return f,
            .integer => |i| return @floatFromInt(i),
            else => return null,
        };

        return std.fmt.parseFloat(f64, price_str) catch null;
    }
};
