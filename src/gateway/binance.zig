//! Binance exchange gateway adapter.
//!
//! Fetches BBO data from the Binance REST API and normalizes into `BboUpdate`.

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

    fn buildUrl(pair: types.TokenPair) ?[128]u8 {
        var buf: [128]u8 = undefined;
        const sym = pairToSymbol(pair) orelse return null;
        const written = std.fmt.bufPrint(&buf, "https://api.binance.com/api/v3/ticker/bookTicker?symbol={s}", .{sym}) catch return null;
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
        const BinanceResponse = struct {
            bidPrice: []const u8,
            bidQty: []const u8,
            askPrice: []const u8,
            askQty: []const u8,
        };

        const parsed = std.json.parseFromSlice(BinanceResponse, allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return error.ParseFailure;
        defer parsed.deinit();

        const bid_price = std.fmt.parseFloat(f64, parsed.value.bidPrice) catch return error.ParseFailure;
        const bid_size = std.fmt.parseFloat(f64, parsed.value.bidQty) catch return error.ParseFailure;
        const ask_price = std.fmt.parseFloat(f64, parsed.value.askPrice) catch return error.ParseFailure;
        const ask_size = std.fmt.parseFloat(f64, parsed.value.askQty) catch return error.ParseFailure;

        const bid = types.PriceLevel{ .price = bid_price, .size = bid_size };
        const ask = types.PriceLevel{ .price = ask_price, .size = ask_size };

        if (!bid.isValid() or !ask.isValid()) return error.ValidationFailure;
        if (ask.price < bid.price) return error.ValidationFailure;

        const timestamp: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_us));

        return types.BboUpdate{
            .exchange = .binance,
            .pair = pair,
            .bid = bid,
            .ask = ask,
            .fetched_at_us = timestamp,
        };
    }
};


