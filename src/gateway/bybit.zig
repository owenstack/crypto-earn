//! ByBit exchange gateway adapter.
//!
//! Fetches BBO data from the ByBit v5 REST API and normalizes into `BboUpdate`.

const std = @import("std");
const types = @import("../types.zig");
const http_mod = @import("../http.zig");
const gateway = @import("../gateway.zig");

pub const Adapter = struct {
    http_client: http_mod.HttpClient,

    pub fn init(allocator: std.mem.Allocator, timeout_ms: u32) Adapter {
        return .{
            .http_client = http_mod.HttpClient.init(allocator, timeout_ms),
        };
    }

    pub fn deinit(self: *Adapter) void {
        self.http_client.deinit();
    }

    pub fn fetchBbo(self: *Adapter, pair: types.TokenPair) gateway.GatewayError!types.BboUpdate {
        const url_buf = buildUrl(pair) orelse return gateway.GatewayError.ParseFailure;
        const url = std.mem.sliceTo(&url_buf, 0);

        const result = self.http_client.fetch(url) catch return gateway.GatewayError.HttpFailure;
        defer self.http_client.allocator.free(result.body);

        return parseResponse(self.http_client.allocator, result.body, pair) catch |err| switch (err) {
            error.ValidationFailure => gateway.GatewayError.ValidationFailure,
            else => gateway.GatewayError.ParseFailure,
        };
    }

    fn buildUrl(pair: types.TokenPair) ?[160]u8 {
        var buf: [160]u8 = undefined;
        const sym = pairToSymbol(pair) orelse return null;
        const written = std.fmt.bufPrint(&buf, "https://api.bybit.com/v5/market/tickers?category=spot&symbol={s}", .{sym}) catch return null;
        @memset(buf[written.len..], 0);
        return buf;
    }

    pub fn pairToSymbol(pair: types.TokenPair) ?[]const u8 {
        return switch (pair.base) {
            .BTC => switch (pair.quote) {
                .USDC => "BTCUSDC",
                .USDT => "BTCUSDT",
            },
            .ETH => switch (pair.quote) {
                .USDC => "ETHUSDC",
                .USDT => "ETHUSDT",
            },
            .SOL => switch (pair.quote) {
                .USDC => "SOLUSDC",
                .USDT => "SOLUSDT",
            },
            .XRP => switch (pair.quote) {
                .USDC => "XRPUSDC",
                .USDT => "XRPUSDT",
            },
            .DOGE => switch (pair.quote) {
                .USDC => "DOGEUSDC",
                .USDT => "DOGEUSDT",
            },
        };
    }

    pub fn parseResponse(allocator: std.mem.Allocator, body: []const u8, pair: types.TokenPair) !types.BboUpdate {
        const Ticker = struct {
            bid1Price: []const u8,
            bid1Size: []const u8,
            ask1Price: []const u8,
            ask1Size: []const u8,
        };
        const Result = struct {
            list: []const Ticker,
        };
        const ByBitResponse = struct {
            retCode: i32,
            result: Result,
        };

        const parsed = std.json.parseFromSlice(ByBitResponse, allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return error.ParseFailure;
        defer parsed.deinit();

        if (parsed.value.retCode != 0) return error.ParseFailure;
        if (parsed.value.result.list.len == 0) return error.ParseFailure;

        const ticker = parsed.value.result.list[0];

        const bid_price = std.fmt.parseFloat(f64, ticker.bid1Price) catch return error.ParseFailure;
        const bid_size = std.fmt.parseFloat(f64, ticker.bid1Size) catch return error.ParseFailure;
        const ask_price = std.fmt.parseFloat(f64, ticker.ask1Price) catch return error.ParseFailure;
        const ask_size = std.fmt.parseFloat(f64, ticker.ask1Size) catch return error.ParseFailure;

        const bid = types.PriceLevel{ .price = bid_price, .size = bid_size };
        const ask = types.PriceLevel{ .price = ask_price, .size = ask_size };

        if (!bid.isValid() or !ask.isValid()) return error.ValidationFailure;
        if (ask.price < bid.price) return error.ValidationFailure;

        const timestamp: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_us));

        return types.BboUpdate{
            .exchange = .bybit,
            .pair = pair,
            .bid = bid,
            .ask = ask,
            .fetched_at_us = timestamp,
        };
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "parseResponse valid ByBit ticker" {
    const body =
        \\{"retCode":0,"retMsg":"OK","result":{"category":"spot","list":[{"symbol":"BTCUSDC","bid1Price":"82450.00","bid1Size":"0.15","ask1Price":"82460.00","ask1Size":"0.10"}]}}
    ;
    const bbo = try Adapter.parseResponse(testing.allocator, body, .{ .base = .BTC, .quote = .USDC });
    try testing.expect(bbo.isValid());
    try testing.expectEqual(types.Exchange.bybit, bbo.exchange);
    try testing.expectApproxEqRel(@as(f64, 82450.0), bbo.bid.price, 1e-9);
    try testing.expectApproxEqRel(@as(f64, 0.15), bbo.bid.size, 1e-9);
    try testing.expectApproxEqRel(@as(f64, 82460.0), bbo.ask.price, 1e-9);
    try testing.expectApproxEqRel(@as(f64, 0.10), bbo.ask.size, 1e-9);
}

test "parseResponse empty list returns error" {
    const body =
        \\{"retCode":0,"retMsg":"OK","result":{"category":"spot","list":[]}}
    ;
    try testing.expectError(error.ParseFailure, Adapter.parseResponse(testing.allocator, body, .{ .base = .BTC, .quote = .USDC }));
}

test "parseResponse non-zero retCode returns error" {
    const body =
        \\{"retCode":10001,"retMsg":"error","result":{"category":"spot","list":[]}}
    ;
    try testing.expectError(error.ParseFailure, Adapter.parseResponse(testing.allocator, body, .{ .base = .BTC, .quote = .USDC }));
}

test "parseResponse zero size returns error" {
    const body =
        \\{"retCode":0,"retMsg":"OK","result":{"category":"spot","list":[{"symbol":"BTCUSDC","bid1Price":"82450.00","bid1Size":"0.0","ask1Price":"82460.00","ask1Size":"0.10"}]}}
    ;
    try testing.expectError(error.ValidationFailure, Adapter.parseResponse(testing.allocator, body, .{ .base = .BTC, .quote = .USDC }));
}

test "parseResponse bid > ask returns error" {
    const body =
        \\{"retCode":0,"retMsg":"OK","result":{"category":"spot","list":[{"symbol":"BTCUSDC","bid1Price":"82470.00","bid1Size":"0.15","ask1Price":"82460.00","ask1Size":"0.10"}]}}
    ;
    try testing.expectError(error.ValidationFailure, Adapter.parseResponse(testing.allocator, body, .{ .base = .BTC, .quote = .USDC }));
}

test "parseResponse malformed JSON returns error" {
    try testing.expectError(error.ParseFailure, Adapter.parseResponse(testing.allocator, "not json", .{ .base = .BTC, .quote = .USDC }));
}
