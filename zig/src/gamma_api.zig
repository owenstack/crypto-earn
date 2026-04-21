//! Gamma API poller — fetches and filters Polymarket markets.
const std = @import("std");
const log = @import("logger.zig");
const http = @import("http_client.zig");

pub const GAMMA_API_BASE = "https://gamma-api.polymarket.com";

pub const FilterConfig = struct {
    min_volume_24h: f64 = 5000.0,
    min_liquidity: f64 = 1000.0,
    max_resolution_days: u32 = 30,
    limit: u32 = 100,
};

pub const GammaMarket = struct {
    id: []const u8,
    question: []const u8,
    condition_id: []const u8,
    slug: []const u8,
    end_date: []const u8,
    volume_24h: f64,
    liquidity: f64,
    clob_token_ids: []const u8, // raw JSON string
    outcome_prices: []const u8, // raw JSON string
    outcomes: []const u8, // raw JSON string
    best_bid: f64,
    best_ask: f64,
    active: bool,
    accepting_orders: bool,
    neg_risk: bool,
};

/// Poll markets from Gamma API via /events endpoint, filter by config, return filtered list.
/// Caller owns the returned slice and all string data within.
pub fn pollMarkets(allocator: std.mem.Allocator, client: *http.HttpClient, config: FilterConfig) ![]GammaMarket {
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/events?active=true&closed=false&limit={d}&offset=0&order=volume24hr&ascending=false", .{
        GAMMA_API_BASE,
        config.limit,
    }) catch return error.Overflow;

    var response = client.get(url) catch |e| {
        log.err("gamma", "GET /events failed: {s}", .{@errorName(e)});
        return error.RequestFailed;
    };
    defer response.deinit();

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch {
        log.err("gamma", "failed to parse events JSON", .{});
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const events = switch (parsed.value) {
        .array => |arr| arr.items,
        else => {
            log.err("gamma", "expected JSON array from /events", .{});
            return error.InvalidJson;
        },
    };

    // Collect all nested markets from events into a flat list
    var all_markets: std.ArrayList(std.json.Value) = .empty;
    defer all_markets.deinit(allocator);
    for (events) |event| {
        const obj = switch (event) {
            .object => |o| o,
            else => continue,
        };
        const nested = obj.get("markets") orelse continue;
        const nested_arr = switch (nested) {
            .array => |a| a.items,
            else => continue,
        };
        for (nested_arr) |m| {
            try all_markets.append(allocator, m);
        }
    }
    const items = all_markets.items;

    const now_s = std.time.timestamp();
    const max_ts: i64 = now_s + @as(i64, @intCast(config.max_resolution_days)) * 86400;

    var results: std.ArrayList(GammaMarket) = .empty;
    errdefer {
        for (results.items) |m| freeMarketStrings(allocator, m);
        results.deinit(allocator);
    }

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const vol24 = jsonFloat(obj.get("volume24hr"));
        const liq = jsonFloat(obj.get("liquidityClob"));
        const is_active = jsonBool(obj.get("active"));
        const accepting = jsonBool(obj.get("acceptingOrders"));

        if (!is_active or !accepting) continue;
        if (vol24 < config.min_volume_24h) continue;
        if (liq < config.min_liquidity) continue;

        const end_str = jsonString(obj.get("endDate"));
        if (end_str.len > 0) {
            if (parseIso8601(end_str)) |end_ts| {
                if (end_ts > max_ts) continue;
            }
        }

        const id_buf = try allocator.dupe(u8, jsonString(obj.get("id")));
        const question_buf = try allocator.dupe(u8, jsonString(obj.get("question")));
        const condition_id_buf = try allocator.dupe(u8, jsonString(obj.get("conditionId")));
        const slug_buf = try allocator.dupe(u8, jsonString(obj.get("slug")));
        const end_date_buf = try allocator.dupe(u8, end_str);
        const clob_token_ids_buf = try allocator.dupe(u8, jsonString(obj.get("clobTokenIds")));
        const outcome_prices_buf = try allocator.dupe(u8, jsonString(obj.get("outcomePrices")));
        const outcomes_buf = try allocator.dupe(u8, jsonString(obj.get("outcomes")));

        var market_owned_by_results = false;
        errdefer if (!market_owned_by_results) allocator.free(id_buf);
        errdefer if (!market_owned_by_results) allocator.free(question_buf);
        errdefer if (!market_owned_by_results) allocator.free(condition_id_buf);
        errdefer if (!market_owned_by_results) allocator.free(slug_buf);
        errdefer if (!market_owned_by_results) allocator.free(end_date_buf);
        errdefer if (!market_owned_by_results) allocator.free(clob_token_ids_buf);
        errdefer if (!market_owned_by_results) allocator.free(outcome_prices_buf);
        errdefer if (!market_owned_by_results) allocator.free(outcomes_buf);

        const market = GammaMarket{
            .id = id_buf,
            .question = question_buf,
            .condition_id = condition_id_buf,
            .slug = slug_buf,
            .end_date = end_date_buf,
            .volume_24h = vol24,
            .liquidity = liq,
            .clob_token_ids = clob_token_ids_buf,
            .outcome_prices = outcome_prices_buf,
            .outcomes = outcomes_buf,
            .best_bid = jsonFloat(obj.get("bestBid")),
            .best_ask = jsonFloat(obj.get("bestAsk")),
            .active = is_active,
            .accepting_orders = accepting,
            .neg_risk = jsonBool(obj.get("negRisk")),
        };

        try results.append(allocator, market);
        market_owned_by_results = true;
    }

    log.info("gamma", "polled {d} markets, {d} passed filters", .{ items.len, results.items.len });

    return results.toOwnedSlice(allocator);
}

/// Free a slice of GammaMarket returned by pollMarkets.
pub fn freeMarkets(allocator: std.mem.Allocator, markets: []GammaMarket) void {
    for (markets) |m| freeMarketStrings(allocator, m);
    allocator.free(markets);
}

fn freeMarketStrings(allocator: std.mem.Allocator, m: GammaMarket) void {
    allocator.free(m.id);
    allocator.free(m.question);
    allocator.free(m.condition_id);
    allocator.free(m.slug);
    allocator.free(m.end_date);
    allocator.free(m.clob_token_ids);
    allocator.free(m.outcome_prices);
    allocator.free(m.outcomes);
}

/// Extract optional f64 from JSON value, defaulting to 0.
pub fn jsonFloat(val: ?std.json.Value) f64 {
    const v = val orelse return 0;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

/// Extract optional string from JSON value, defaulting to "".
pub fn jsonString(val: ?std.json.Value) []const u8 {
    const v = val orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

/// Extract optional bool from JSON value, defaulting to false.
pub fn jsonBool(val: ?std.json.Value) bool {
    const v = val orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

/// Parse an ISO 8601 date string (e.g. "2025-06-15T00:00:00Z") to epoch seconds.
/// Returns null if the string cannot be parsed.
fn parseIso8601(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    if (s[4] != '-') return null;
    const month = std.fmt.parseInt(u4, s[5..7], 10) catch return null;
    if (s[7] != '-') return null;
    const day = std.fmt.parseInt(u5, s[8..10], 10) catch return null;
    if (s[10] != 'T') return null;
    const hour = std.fmt.parseInt(u5, s[11..13], 10) catch return null;
    if (s[13] != ':') return null;
    const minute = std.fmt.parseInt(u6, s[14..16], 10) catch return null;
    if (s[16] != ':') return null;
    const second = std.fmt.parseInt(u6, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    // Days from epoch (1970-01-01) to target date
    var days: i64 = 0;
    var y: u16 = std.time.epoch.epoch_year;
    while (y < year) : (y += 1) {
        days += std.time.epoch.getDaysInYear(y);
    }
    const m_enum: std.time.epoch.Month = @enumFromInt(month);
    const days_in_month = std.time.epoch.getDaysInMonth(year, m_enum);
    if (day > days_in_month) return null;

    var m: u4 = 1;
    while (m < month) : (m += 1) {
        days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
    }
    days += day - 1;

    var tz_offset_seconds: i64 = 0;
    if (s.len > 19) {
        const tz = s[19..];
        if (tz.len == 1) {
            if (tz[0] != 'Z') return null;
        } else {
            if (tz.len != 6) return null;
            if (tz[0] != '+' and tz[0] != '-') return null;
            const tz_hour = std.fmt.parseInt(u5, tz[1..3], 10) catch return null;
            if (tz[3] != ':') return null;
            const tz_minute = std.fmt.parseInt(u6, tz[4..6], 10) catch return null;
            if (tz_hour > 23 or tz_minute > 59) return null;

            tz_offset_seconds = @as(i64, @intCast(tz_hour)) * 3600 + @as(i64, @intCast(tz_minute)) * 60;
            if (tz[0] == '-') tz_offset_seconds = -tz_offset_seconds;
        }
    }

    const date_seconds = days * std.time.epoch.secs_per_day;
    const time_seconds = @as(i64, @intCast(hour)) * 3600 + @as(i64, @intCast(minute)) * 60 + @as(i64, @intCast(second));
    // ISO 8601 timezone offset is local->UTC; subtract it to normalize to UTC epoch.
    return date_seconds + time_seconds - tz_offset_seconds;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "gamma_api: FilterConfig defaults" {
    const config = FilterConfig{};
    try std.testing.expectEqual(@as(f64, 5000.0), config.min_volume_24h);
    try std.testing.expectEqual(@as(f64, 1000.0), config.min_liquidity);
    try std.testing.expectEqual(@as(u32, 30), config.max_resolution_days);
    try std.testing.expectEqual(@as(u32, 100), config.limit);
}

test "gamma_api: jsonFloat extracts number" {
    const int_val = std.json.Value{ .integer = 42 };
    try std.testing.expectEqual(@as(f64, 42.0), jsonFloat(int_val));

    const float_val = std.json.Value{ .float = 3.14 };
    try std.testing.expectEqual(@as(f64, 3.14), jsonFloat(float_val));

    const str_val = std.json.Value{ .string = "99.5" };
    try std.testing.expectEqual(@as(f64, 99.5), jsonFloat(str_val));

    try std.testing.expectEqual(@as(f64, 0), jsonFloat(null));
}

test "gamma_api: jsonString extracts string" {
    const str_val = std.json.Value{ .string = "hello" };
    try std.testing.expectEqualStrings("hello", jsonString(str_val));

    try std.testing.expectEqualStrings("", jsonString(null));

    const int_val = std.json.Value{ .integer = 42 };
    try std.testing.expectEqualStrings("", jsonString(int_val));
}

test "gamma_api: jsonBool extracts bool" {
    const true_val = std.json.Value{ .bool = true };
    try std.testing.expect(jsonBool(true_val));

    const false_val = std.json.Value{ .bool = false };
    try std.testing.expect(!jsonBool(false_val));

    try std.testing.expect(!jsonBool(null));
}

test "gamma_api: parseIso8601 parses valid date" {
    const ts = parseIso8601("2025-01-01T00:00:00Z");
    try std.testing.expect(ts != null);
    try std.testing.expect(ts.? > 0);
}

test "gamma_api: parseIso8601 returns null for invalid input" {
    try std.testing.expect(parseIso8601("bad") == null);
    try std.testing.expect(parseIso8601("") == null);
    try std.testing.expect(parseIso8601("20251301") == null);
    try std.testing.expect(parseIso8601("2025-01-01") == null);
    try std.testing.expect(parseIso8601("2025-01-01T24:00:00Z") == null);
    try std.testing.expect(parseIso8601("2025-01-01T23:60:00Z") == null);
    try std.testing.expect(parseIso8601("2025-01-01T23:59:60Z") == null);
    try std.testing.expect(parseIso8601("2025-01-01T00:00:00+24:00") == null);
}

test "gamma_api: parseIso8601 parses time and timezone offset" {
    const utc = parseIso8601("2025-01-01T01:02:03Z") orelse unreachable;
    const plus_two = parseIso8601("2025-01-01T03:02:03+02:00") orelse unreachable;
    const minus_five = parseIso8601("2024-12-31T20:02:03-05:00") orelse unreachable;

    try std.testing.expectEqual(utc, plus_two);
    try std.testing.expectEqual(utc, minus_five);
}
