//! Adapter tests for Binance, ByBit, Coinbase and OKX using fixture JSON data.
//!
//! These tests verify JSON parsing and validation without network calls.

const std = @import("std");
const testing = std.testing;
const cex = @import("cex_zig");
const types = cex.types;
const mock = @import("mock_data.zig");

// ---------------------------------------------------------------------------
// Binance adapter tests
// ---------------------------------------------------------------------------

const BinanceAdapter = cex.gateway.binance.Adapter;

test "binance: valid ticker parses correctly" {
    const body =
        \\{"symbol":"BTCUSDC","bidPrice":"82450.00","bidQty":"0.15","askPrice":"82460.00","askQty":"0.10"}
    ;
    const bbo = try BinanceAdapter.parseResponse(testing.allocator, body, mock.btc_usdc);
    try testing.expect(bbo.isValid());
    try testing.expectEqual(types.Exchange.binance, bbo.exchange);
    try testing.expectApproxEqRel(@as(f64, 82450.0), bbo.bid.price, 1e-9);
    try testing.expectApproxEqRel(@as(f64, 0.15), bbo.bid.size, 1e-9);
    try testing.expectApproxEqRel(@as(f64, 82460.0), bbo.ask.price, 1e-9);
    try testing.expectApproxEqRel(@as(f64, 0.10), bbo.ask.size, 1e-9);
}

test "binance: missing field returns parse error" {
    const body =
        \\{"symbol":"BTCUSDC","bidPrice":"82450.00"}
    ;
    try testing.expectError(error.ParseFailure, BinanceAdapter.parseResponse(testing.allocator, body, mock.btc_usdc));
}

test "binance: non-finite price returns validation error" {
    const body =
        \\{"symbol":"BTCUSDC","bidPrice":"NaN","bidQty":"0.15","askPrice":"82460.00","askQty":"0.10"}
    ;
    try testing.expectError(error.ValidationFailure, BinanceAdapter.parseResponse(testing.allocator, body, mock.btc_usdc));
}

test "binance: zero size returns validation error" {
    const body =
        \\{"symbol":"BTCUSDC","bidPrice":"82450.00","bidQty":"0.0","askPrice":"82460.00","askQty":"0.10"}
    ;
    try testing.expectError(error.ValidationFailure, BinanceAdapter.parseResponse(testing.allocator, body, mock.btc_usdc));
}

test "binance: bid > ask returns validation error" {
    const body =
        \\{"symbol":"BTCUSDC","bidPrice":"82470.00","bidQty":"0.15","askPrice":"82460.00","askQty":"0.10"}
    ;
    try testing.expectError(error.ValidationFailure, BinanceAdapter.parseResponse(testing.allocator, body, mock.btc_usdc));
}

test "binance: malformed JSON returns parse error" {
    try testing.expectError(error.ParseFailure, BinanceAdapter.parseResponse(testing.allocator, "not json at all", mock.btc_usdc));
}

test "binance: pairToSymbol covers all combinations" {
    const bases = [_]types.BaseAsset{ .BTC, .ETH, .SOL, .XRP, .DOGE };
    const quotes = [_]types.QuoteAsset{ .USDC, .USDT };
    for (bases) |b| {
        for (quotes) |q| {
            try testing.expect(BinanceAdapter.pairToSymbol(.{ .base = b, .quote = q }) != null);
        }
    }
}

// ---------------------------------------------------------------------------
// ByBit adapter tests
// ---------------------------------------------------------------------------

const BybitAdapter = cex.gateway.bybit.Adapter;

test "bybit: valid ticker parses correctly" {
    const body =
        \\{"retCode":0,"retMsg":"OK","result":{"category":"spot","list":[{"symbol":"BTCUSDC","bid1Price":"82450.00","bid1Size":"0.15","ask1Price":"82460.00","ask1Size":"0.10"}]}}
    ;
    const bbo = try BybitAdapter.parseResponse(testing.allocator, body, mock.btc_usdc);
    try testing.expect(bbo.isValid());
    try testing.expectEqual(types.Exchange.bybit, bbo.exchange);
    try testing.expectApproxEqRel(@as(f64, 82450.0), bbo.bid.price, 1e-9);
    try testing.expectApproxEqRel(@as(f64, 0.15), bbo.bid.size, 1e-9);
    try testing.expectApproxEqRel(@as(f64, 82460.0), bbo.ask.price, 1e-9);
    try testing.expectApproxEqRel(@as(f64, 0.10), bbo.ask.size, 1e-9);
}

test "bybit: empty list returns parse error" {
    const body =
        \\{"retCode":0,"retMsg":"OK","result":{"category":"spot","list":[]}}
    ;
    try testing.expectError(error.ParseFailure, BybitAdapter.parseResponse(testing.allocator, body, mock.btc_usdc));
}

test "bybit: non-zero retCode returns parse error" {
    const body =
        \\{"retCode":10001,"retMsg":"error","result":{"category":"spot","list":[]}}
    ;
    try testing.expectError(error.ParseFailure, BybitAdapter.parseResponse(testing.allocator, body, mock.btc_usdc));
}

test "bybit: zero size returns validation error" {
    const body =
        \\{"retCode":0,"retMsg":"OK","result":{"category":"spot","list":[{"symbol":"BTCUSDC","bid1Price":"82450.00","bid1Size":"0.0","ask1Price":"82460.00","ask1Size":"0.10"}]}}
    ;
    try testing.expectError(error.ValidationFailure, BybitAdapter.parseResponse(testing.allocator, body, mock.btc_usdc));
}

test "bybit: bid > ask returns validation error" {
    const body =
        \\{"retCode":0,"retMsg":"OK","result":{"category":"spot","list":[{"symbol":"BTCUSDC","bid1Price":"82470.00","bid1Size":"0.15","ask1Price":"82460.00","ask1Size":"0.10"}]}}
    ;
    try testing.expectError(error.ValidationFailure, BybitAdapter.parseResponse(testing.allocator, body, mock.btc_usdc));
}

test "bybit: malformed JSON returns parse error" {
    try testing.expectError(error.ParseFailure, BybitAdapter.parseResponse(testing.allocator, "not json", mock.btc_usdc));
}

// ---------------------------------------------------------------------------
// Coinbase adapter tests with fixtures
// ---------------------------------------------------------------------------

const CoinbaseAdapter = cex.gateway.coinbase.Adapter;

test "coinbase: valid fixture JSON parses correctly" {
    const bbo = try CoinbaseAdapter.parseResponse(testing.allocator, mock.coinbase_valid_json, mock.btc_usdc);
    try testing.expect(bbo.isValid());
    try testing.expectEqual(types.Exchange.coinbase, bbo.exchange);
    try testing.expectApproxEqRel(@as(f64, 82_450.0), bbo.bid.price, 1e-9);
    try testing.expectApproxEqRel(@as(f64, 82_460.0), bbo.ask.price, 1e-9);
    try testing.expectApproxEqRel(@as(f64, 0.15), bbo.bid.size, 1e-9);
}

test "coinbase: missing bid field returns parse error" {
    try testing.expectError(error.ParseFailure, CoinbaseAdapter.parseResponse(testing.allocator, mock.coinbase_missing_bid_json, mock.btc_usdc));
}

test "coinbase: zero size returns validation error" {
    try testing.expectError(error.ValidationFailure, CoinbaseAdapter.parseResponse(testing.allocator, mock.coinbase_zero_size_json, mock.btc_usdc));
}

test "coinbase: bid > ask returns validation error" {
    try testing.expectError(error.ValidationFailure, CoinbaseAdapter.parseResponse(testing.allocator, mock.coinbase_bid_gt_ask_json, mock.btc_usdc));
}

test "coinbase: malformed JSON returns parse error" {
    try testing.expectError(error.ParseFailure, CoinbaseAdapter.parseResponse(testing.allocator, "not json", mock.btc_usdc));
}

test "coinbase: pairToSymbol covers all combinations" {
    const bases = [_]types.BaseAsset{ .BTC, .ETH, .SOL, .XRP, .DOGE };
    const quotes = [_]types.QuoteAsset{ .USDC, .USDT };
    for (bases) |b| {
        for (quotes) |q| {
            try testing.expect(CoinbaseAdapter.pairToSymbol(.{ .base = b, .quote = q }) != null);
        }
    }
}

// ---------------------------------------------------------------------------
// OKX adapter tests with fixtures
// ---------------------------------------------------------------------------

const OkxAdapter = cex.gateway.okx.Adapter;

test "okx: valid fixture JSON parses correctly" {
    const bbo = try OkxAdapter.parseResponse(testing.allocator, mock.okx_valid_json, mock.btc_usdc);
    try testing.expect(bbo.isValid());
    try testing.expectEqual(types.Exchange.okx, bbo.exchange);
    try testing.expectApproxEqRel(@as(f64, 82_450.0), bbo.bid.price, 1e-9);
    try testing.expectApproxEqRel(@as(f64, 82_460.0), bbo.ask.price, 1e-9);
    try testing.expectApproxEqRel(@as(f64, 0.15), bbo.bid.size, 1e-9);
    try testing.expectApproxEqRel(@as(f64, 0.10), bbo.ask.size, 1e-9);
}

test "okx: non-zero code returns parse error" {
    try testing.expectError(error.ParseFailure, OkxAdapter.parseResponse(testing.allocator, mock.okx_nonzero_code_json, mock.btc_usdc));
}

test "okx: empty data array returns parse error" {
    try testing.expectError(error.ParseFailure, OkxAdapter.parseResponse(testing.allocator, mock.okx_empty_data_json, mock.btc_usdc));
}

test "okx: zero size returns validation error" {
    try testing.expectError(error.ValidationFailure, OkxAdapter.parseResponse(testing.allocator, mock.okx_zero_size_json, mock.btc_usdc));
}

test "okx: bid > ask returns validation error" {
    try testing.expectError(error.ValidationFailure, OkxAdapter.parseResponse(testing.allocator, mock.okx_bid_gt_ask_json, mock.btc_usdc));
}

test "okx: malformed JSON returns parse error" {
    try testing.expectError(error.ParseFailure, OkxAdapter.parseResponse(testing.allocator, "not json", mock.btc_usdc));
}

test "okx: pairToSymbol covers all combinations" {
    const bases = [_]types.BaseAsset{ .BTC, .ETH, .SOL, .XRP, .DOGE };
    const quotes = [_]types.QuoteAsset{ .USDC, .USDT };
    for (bases) |b| {
        for (quotes) |q| {
            try testing.expect(OkxAdapter.pairToSymbol(.{ .base = b, .quote = q }) != null);
        }
    }
}
