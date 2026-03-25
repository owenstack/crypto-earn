//! OKX exchange gateway adapter.
//!
//! Fetches BBO data from the OKX v5 REST API and normalizes into `BboUpdate`.

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
        const written = std.fmt.bufPrint(&buf, "https://www.okx.com/api/v5/market/ticker?instId={s}", .{sym}) catch return null;
        @memset(buf[written.len..], 0);
        return buf;
    }

    pub fn pairToSymbol(pair: types.TokenPair) ?[]const u8 {
        return switch (pair.base) {
            .BTC => switch (pair.quote) {
                .USDC => "BTC-USDC",
                .USDT => "BTC-USDT",
            },
            .ETH => switch (pair.quote) {
                .USDC => "ETH-USDC",
                .USDT => "ETH-USDT",
            },
            .SOL => switch (pair.quote) {
                .USDC => "SOL-USDC",
                .USDT => "SOL-USDT",
            },
            .XRP => switch (pair.quote) {
                .USDC => "XRP-USDC",
                .USDT => "XRP-USDT",
            },
            .DOGE => switch (pair.quote) {
                .USDC => "DOGE-USDC",
                .USDT => "DOGE-USDT",
            },
        };
    }

    pub fn parseResponse(allocator: std.mem.Allocator, body: []const u8, pair: types.TokenPair) !types.BboUpdate {
        const Ticker = struct {
            bidPx: []const u8,
            askPx: []const u8,
            bidSz: []const u8,
            askSz: []const u8,
        };
        const OkxResponse = struct {
            code: []const u8,
            data: []const Ticker,
        };

        const parsed = std.json.parseFromSlice(OkxResponse, allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return error.ParseFailure;
        defer parsed.deinit();

        const code = std.fmt.parseInt(i32, parsed.value.code, 10) catch return error.ParseFailure;
        if (code != 0) return error.ParseFailure;
        if (parsed.value.data.len == 0) return error.ParseFailure;

        const ticker = parsed.value.data[0];

        const bid_price = std.fmt.parseFloat(f64, ticker.bidPx) catch return error.ParseFailure;
        const ask_price = std.fmt.parseFloat(f64, ticker.askPx) catch return error.ParseFailure;
        const bid_size = std.fmt.parseFloat(f64, ticker.bidSz) catch return error.ParseFailure;
        const ask_size = std.fmt.parseFloat(f64, ticker.askSz) catch return error.ParseFailure;

        const bid = types.PriceLevel{ .price = bid_price, .size = bid_size };
        const ask = types.PriceLevel{ .price = ask_price, .size = ask_size };

        if (!bid.isValid() or !ask.isValid()) return error.ValidationFailure;
        if (ask.price < bid.price) return error.ValidationFailure;

        const timestamp: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_us));

        return types.BboUpdate{
            .exchange = .okx,
            .pair = pair,
            .bid = bid,
            .ask = ask,
            .fetched_at_us = timestamp,
        };
    }
};


