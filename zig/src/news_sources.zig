//! External probability client — fetches probability estimates from Gamma market data.
const std = @import("std");
const log = @import("logger.zig");
const gamma = @import("gamma_api.zig");

pub const Provider = enum { gamma_markets };

pub const ProbabilityEstimate = struct {
    market_id: [64]u8,
    market_id_len: usize,
    condition_id: [128]u8,
    condition_id_len: usize,
    yes_token_id: [80]u8,
    yes_token_id_len: usize,
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
    mu: std.Thread.Mutex,

    pub const MAX_CACHED = 128;

    pub fn init(allocator: std.mem.Allocator, config: NewsSourceConfig) NewsClient {
        return .{
            .allocator = allocator,
            .config = config,
            .last_fetch_ts = 0,
            .cached_estimates = [_]?ProbabilityEstimate{null} ** MAX_CACHED,
            .cached_count = 0,
            .mu = .{},
        };
    }

    /// Fetch probability estimate for a market from the configured provider.
    /// Uses cache if within TTL.
    pub fn getEstimate(self: *NewsClient, market_id: []const u8) ?ProbabilityEstimate {
        self.mu.lock();
        defer self.mu.unlock();

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
    /// Builds new cache off to the side, then publishes under lock.
    pub fn updateFromGammaMarkets(self: *NewsClient, markets: []const gamma.GammaMarket) void {
        const now = std.time.timestamp();
        var next = [_]?ProbabilityEstimate{null} ** MAX_CACHED;
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

            var cid: [128]u8 = undefined;
            const cid_len = @min(market.condition_id.len, 128);
            @memcpy(cid[0..cid_len], market.condition_id[0..cid_len]);

            // Extract Yes token ID (first element of clob_token_ids JSON array)
            var ytid: [80]u8 = undefined;
            var ytid_len: usize = 0;
            if (extractFirstJsonString(market.clob_token_ids)) |token| {
                ytid_len = @min(token.len, 80);
                @memcpy(ytid[0..ytid_len], token[0..ytid_len]);
            }

            next[count] = ProbabilityEstimate{
                .market_id = mid,
                .market_id_len = mid_len,
                .condition_id = cid,
                .condition_id_len = cid_len,
                .yes_token_id = ytid,
                .yes_token_id_len = ytid_len,
                .probability = prob,
                .confidence = 0.8,
                .provider = .gamma_markets,
                .fetched_at = now,
            };
            count += 1;
        }

        self.mu.lock();
        defer self.mu.unlock();

        self.cached_estimates = next;
        self.cached_count = count;
        self.last_fetch_ts = now;

        log.info("news", "updated cache from gamma: {d} estimates", .{count});
    }

    /// Copy a thread-safe snapshot of cached estimates. Returns the count.
    pub fn snapshot(self: *NewsClient, out: *[MAX_CACHED]ProbabilityEstimate) usize {
        self.mu.lock();
        defer self.mu.unlock();

        const count = self.cached_count;
        for (0..count) |i| {
            out[i] = self.cached_estimates[i].?;
        }
        return count;
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

/// Extract the first quoted string from a JSON array like '["abc","def"]'.
/// Returns a slice into the input (no allocation).
/// Note: Does not handle escape sequences; assumes simple unescaped strings.
fn extractFirstJsonString(raw: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '"') {
            const start = i + 1;
            i += 1;
            while (i < raw.len and raw[i] != '"') : (i += 1) {}
            return raw[start..i];
        }
    }
    return null;
}
