//! Hyperliquid asset metadata loader.
//!
//! Phase 3 (TASK-3.1): Fetch the HL `meta` payload from `${api_base}/info`,
//! parse the `universe` array into a deterministic symbol → asset_index
//! map, expose a thread-safe lookup API, and refresh every 24h. Startup
//! fetch retries up to 3 times with a 2-second backoff before failing the
//! caller.
//!
//! The map is small (HL has < 200 perps), so an O(N) scan during lookup is
//! fine and avoids the complexity of a hashmap with custom string keys.

const std = @import("std");
const log = @import("logger.zig");
const http = @import("http_client.zig");

pub const MAX_SYMBOL_LEN: usize = 24;

pub const Asset = struct {
    name_buf: [MAX_SYMBOL_LEN]u8 = [_]u8{0} ** MAX_SYMBOL_LEN,
    name_len: u8 = 0,
    sz_decimals: u8 = 0,

    pub fn name(self: *const Asset) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const FetchError = error{
    OutOfMemory,
    HttpFailed,
    InvalidJson,
    NoUniverse,
    SymbolTooLong,
};

/// Thread-safe asset metadata cache. Initialized empty; populated by
/// `fetchAndLoad`. `refreshLoop` runs every 24h to re-pull the universe.
pub const AssetMeta = struct {
    allocator: std.mem.Allocator,
    api_base: []const u8,
    http_client: http.HttpClient,
    mu: std.Thread.Mutex,
    assets: std.ArrayList(Asset),
    last_refresh_unix: std.atomic.Value(i64),
    fetch_count: std.atomic.Value(u64),
    failure_count: std.atomic.Value(u64),
    should_stop: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, api_base: []const u8) AssetMeta {
        return .{
            .allocator = allocator,
            .api_base = api_base,
            .http_client = http.HttpClient.init(allocator),
            .mu = .{},
            .assets = .empty,
            .last_refresh_unix = std.atomic.Value(i64).init(0),
            .fetch_count = std.atomic.Value(u64).init(0),
            .failure_count = std.atomic.Value(u64).init(0),
            .should_stop = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *AssetMeta) void {
        self.http_client.deinit();
        self.assets.deinit(self.allocator);
    }

    pub fn stop(self: *AssetMeta) void {
        self.should_stop.store(true, .seq_cst);
    }

    /// Lookup the asset index for an HL coin symbol (e.g., "BTC", "ETH").
    /// Returns null if the universe doesn't contain the symbol.
    pub fn lookup(self: *AssetMeta, symbol: []const u8) ?u32 {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.assets.items, 0..) |asset, i| {
            if (std.mem.eql(u8, asset.name(), symbol)) {
                return @intCast(i);
            }
        }
        return null;
    }

    pub fn count(self: *AssetMeta) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.assets.items.len;
    }

    /// Replace the cached universe with the parsed contents of `assets`.
    /// Caller-owned slice is copied into the internal store.
    pub fn replace(self: *AssetMeta, new_assets: []const Asset) !void {
        self.mu.lock();
        defer self.mu.unlock();
        self.assets.clearRetainingCapacity();
        try self.assets.ensureTotalCapacity(self.allocator, new_assets.len);
        for (new_assets) |a| {
            try self.assets.append(self.allocator, a);
        }
        self.last_refresh_unix.store(std.time.timestamp(), .seq_cst);
    }

    /// Fetch the HL meta payload with retries and replace the cache. Returns
    /// the loaded count on success. 3 attempts × 2-second backoff.
    pub fn fetchAndLoad(self: *AssetMeta) FetchError!usize {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/info", .{self.api_base}) catch
            return error.HttpFailed;

        const body = "{\"type\":\"meta\"}";

        var attempt: u32 = 0;
        while (attempt < 3) : (attempt += 1) {
            var response = self.http_client.postJson(url, body) catch |e| {
                log.warn("hl_meta", "fetch attempt {d}/3 http err: {s}", .{ attempt + 1, @errorName(e) });
                if (attempt + 1 < 3) std.Thread.sleep(2 * std.time.ns_per_s);
                continue;
            };
            defer response.deinit();

            if (response.status.class() != .success) {
                log.warn("hl_meta", "fetch attempt {d}/3 status={d}", .{ attempt + 1, @intFromEnum(response.status) });
                if (attempt + 1 < 3) std.Thread.sleep(2 * std.time.ns_per_s);
                continue;
            }

            var parsed = parseMetaJson(self.allocator, response.body) catch |e| {
                log.warn("hl_meta", "fetch attempt {d}/3 parse err: {s}", .{ attempt + 1, @errorName(e) });
                if (attempt + 1 < 3) std.Thread.sleep(2 * std.time.ns_per_s);
                continue;
            };
            defer parsed.deinit(self.allocator);

            self.replace(parsed.items) catch |e| {
                log.err("hl_meta", "replace failed: {s}", .{@errorName(e)});
                _ = self.failure_count.fetchAdd(1, .seq_cst);
                return error.OutOfMemory;
            };

            const n = parsed.items.len;
            _ = self.fetch_count.fetchAdd(1, .seq_cst);
            log.info("hl_meta", "loaded {d} HL assets from {s}", .{ n, self.api_base });
            return n;
        }

        _ = self.failure_count.fetchAdd(1, .seq_cst);
        return error.HttpFailed;
    }

    /// Background loop: refresh every 24h. Exits promptly when `stop()` is
    /// called. Wakes once per second to allow fast shutdown.
    pub fn refreshLoop(self: *AssetMeta) void {
        const interval_s: i64 = 24 * 3600;
        while (!self.should_stop.load(.seq_cst)) {
            const now = std.time.timestamp();
            const last = self.last_refresh_unix.load(.seq_cst);
            if (now - last >= interval_s) {
                _ = self.fetchAndLoad() catch |e| {
                    log.warn("hl_meta", "scheduled refresh failed: {s}", .{@errorName(e)});
                };
            }
            // Wake every second so the should_stop signal is responsive.
            std.Thread.sleep(std.time.ns_per_s);
        }
    }
};

/// Parse an HL `meta` JSON payload and return a list of Assets sorted by
/// universe index. The caller owns the returned ArrayList.
///
/// Expected shape:
///   { "universe": [ { "name": "BTC", "szDecimals": 5, ... }, ... ] }
pub fn parseMetaJson(allocator: std.mem.Allocator, body: []const u8) FetchError!std.ArrayList(Asset) {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidJson,
    };
    const universe_val = root.get("universe") orelse return error.NoUniverse;
    const universe = switch (universe_val) {
        .array => |arr| arr,
        else => return error.NoUniverse,
    };

    var out: std.ArrayList(Asset) = .empty;
    errdefer out.deinit(allocator);

    for (universe.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name_val = obj.get("name") orelse continue;
        const name_str = switch (name_val) {
            .string => |s| s,
            else => continue,
        };
        if (name_str.len > MAX_SYMBOL_LEN) return error.SymbolTooLong;

        var asset: Asset = .{};
        @memcpy(asset.name_buf[0..name_str.len], name_str);
        asset.name_len = @intCast(name_str.len);

        if (obj.get("szDecimals")) |sd| switch (sd) {
            .integer => |i| asset.sz_decimals = @intCast(@max(0, @min(255, i))),
            else => {},
        };

        try out.append(allocator, asset);
    }

    return out;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "hl_market_meta: parseMetaJson extracts universe symbols and indices" {
    const body =
        \\{"universe":[
        \\  {"name":"BTC","szDecimals":5},
        \\  {"name":"ETH","szDecimals":4},
        \\  {"name":"SOL","szDecimals":2}
        \\]}
    ;
    var assets = try parseMetaJson(testing.allocator, body);
    defer assets.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), assets.items.len);
    try testing.expectEqualStrings("BTC", assets.items[0].name());
    try testing.expectEqual(@as(u8, 5), assets.items[0].sz_decimals);
    try testing.expectEqualStrings("ETH", assets.items[1].name());
    try testing.expectEqualStrings("SOL", assets.items[2].name());
}

test "hl_market_meta: parseMetaJson rejects payload without universe" {
    const body =
        \\{"foo":"bar"}
    ;
    try testing.expectError(error.NoUniverse, parseMetaJson(testing.allocator, body));
}

test "hl_market_meta: AssetMeta.lookup returns asset index" {
    var meta = AssetMeta.init(testing.allocator, "https://api.hyperliquid-testnet.xyz");
    defer meta.deinit();

    const a0 = Asset{ .name_buf = "BTC".* ++ ([_]u8{0} ** (MAX_SYMBOL_LEN - 3)), .name_len = 3, .sz_decimals = 5 };
    const a1 = Asset{ .name_buf = "ETH".* ++ ([_]u8{0} ** (MAX_SYMBOL_LEN - 3)), .name_len = 3, .sz_decimals = 4 };
    try meta.replace(&[_]Asset{ a0, a1 });

    try testing.expectEqual(@as(u32, 0), meta.lookup("BTC").?);
    try testing.expectEqual(@as(u32, 1), meta.lookup("ETH").?);
    try testing.expect(meta.lookup("DOGE") == null);
    try testing.expectEqual(@as(usize, 2), meta.count());
}
