//! Unit tests for core domain types.

const std = @import("std");
const math = std.math;
const testing = std.testing;
const types = @import("cex_zig").types;

const Exchange = types.Exchange;
const TokenPair = types.TokenPair;
const PriceLevel = types.PriceLevel;
const BboUpdate = types.BboUpdate;
const ArbOpportunity = types.ArbOpportunity;
const RiskMetrics = types.RiskMetrics;
const BaseAsset = types.BaseAsset;
const QuoteAsset = types.QuoteAsset;
const PairSet = types.PairSet;
const MAX_PAIRS = types.MAX_PAIRS;

test "Exchange.label returns display name" {
    try testing.expectEqualStrings("Binance", Exchange.binance.label());
    try testing.expectEqualStrings("ByBit", Exchange.bybit.label());
    try testing.expectEqualStrings("Coinbase", Exchange.coinbase.label());
    try testing.expectEqualStrings("OKX", Exchange.okx.label());
}

test "Exchange.count is 4" {
    try testing.expectEqual(@as(usize, 4), Exchange.count);
}

test "TokenPair equality" {
    const a = TokenPair{ .base = .BTC, .quote = .USDC };
    const b = TokenPair{ .base = .BTC, .quote = .USDC };
    const c = TokenPair{ .base = .ETH, .quote = .USDC };
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
}

test "PriceLevel validation" {
    const valid = PriceLevel{ .price = 100.0, .size = 0.5 };
    try testing.expect(valid.isValid());

    const zero_price = PriceLevel{ .price = 0.0, .size = 0.5 };
    try testing.expect(!zero_price.isValid());

    const neg_size = PriceLevel{ .price = 100.0, .size = -1.0 };
    try testing.expect(!neg_size.isValid());

    const nan_price = PriceLevel{ .price = math.nan(f64), .size = 0.5 };
    try testing.expect(!nan_price.isValid());

    const inf_size = PriceLevel{ .price = 100.0, .size = math.inf(f64) };
    try testing.expect(!inf_size.isValid());
}

test "PriceLevel.notional" {
    const pl = PriceLevel{ .price = 82450.0, .size = 0.15 };
    try testing.expectApproxEqRel(12367.5, pl.notional(), 1e-9);
}

test "BboUpdate validation" {
    const valid = BboUpdate{
        .exchange = .binance,
        .pair = .{ .base = .BTC, .quote = .USDC },
        .bid = .{ .price = 82000.0, .size = 0.5 },
        .ask = .{ .price = 82010.0, .size = 0.3 },
        .fetched_at_us = 1000,
    };
    try testing.expect(valid.isValid());

    // ask < bid is invalid
    const crossed = BboUpdate{
        .exchange = .binance,
        .pair = .{ .base = .BTC, .quote = .USDC },
        .bid = .{ .price = 82010.0, .size = 0.5 },
        .ask = .{ .price = 82000.0, .size = 0.3 },
        .fetched_at_us = 1000,
    };
    try testing.expect(!crossed.isValid());

    // zero timestamp is invalid
    var zero_ts = valid;
    zero_ts.fetched_at_us = 0;
    try testing.expect(!zero_ts.isValid());
}

test "ArbOpportunity validation" {
    const buy_bbo = BboUpdate{
        .exchange = .binance,
        .pair = .{ .base = .BTC, .quote = .USDC },
        .bid = .{ .price = 82000.0, .size = 0.5 },
        .ask = .{ .price = 82010.0, .size = 0.3 },
        .fetched_at_us = 1000,
    };
    const sell_bbo = BboUpdate{
        .exchange = .bybit,
        .pair = .{ .base = .BTC, .quote = .USDC },
        .bid = .{ .price = 82200.0, .size = 0.2 },
        .ask = .{ .price = 82210.0, .size = 0.1 },
        .fetched_at_us = 1001,
    };
    const opp = ArbOpportunity{
        .buy_exchange = .binance,
        .sell_exchange = .bybit,
        .pair = .{ .base = .BTC, .quote = .USDC },
        .profit_pct = 0.23,
        .notional_usd = 12000.0,
        .buy_bbo = buy_bbo,
        .sell_bbo = sell_bbo,
        .detected_at_us = 1002,
    };
    try testing.expect(opp.isValid());

    // same exchange is invalid
    var same_exch = opp;
    same_exch.sell_exchange = .binance;
    try testing.expect(!same_exch.isValid());
}

test "RiskMetrics defaults are valid" {
    const rm = RiskMetrics{};
    try testing.expect(rm.isValid());
}

test "profitPct helper" {
    // Normal case: (101 - 100) / 100 * 100 = 1.0
    try testing.expectApproxEqRel(1.0, types.profitPct(101.0, 100.0).?, 1e-9);

    // Negative spread
    const neg = types.profitPct(99.0, 100.0).?;
    try testing.expect(neg < 0.0);

    // Zero buy_ask
    try testing.expect(types.profitPct(101.0, 0.0) == null);

    // NaN input
    try testing.expect(types.profitPct(math.nan(f64), 100.0) == null);
}

test "cappedNotional helper" {
    // min(0.3, 0.2) * 82000 = 16400, capped at 15000
    try testing.expectApproxEqRel(15000.0, types.cappedNotional(0.3, 0.2, 82000.0, 15000.0).?, 1e-9);

    // No cap needed: min(0.1, 0.2) * 100 = 10, cap 20
    try testing.expectApproxEqRel(10.0, types.cappedNotional(0.1, 0.2, 100.0, 20.0).?, 1e-9);

    // Invalid inputs
    try testing.expect(types.cappedNotional(0.0, 0.2, 100.0, 1000.0) == null);
    try testing.expect(types.cappedNotional(0.1, -1.0, 100.0, 1000.0) == null);
    try testing.expect(types.cappedNotional(0.1, 0.2, 0.0, 1000.0) == null);
}

test "PairSet add and duplicate detection" {
    var set = PairSet{};
    try set.add(.{ .base = .BTC, .quote = .USDC });
    try set.add(.{ .base = .ETH, .quote = .USDC });
    try testing.expectEqual(@as(usize, 2), set.len);

    // Duplicate
    try testing.expectError(error.Duplicate, set.add(.{ .base = .BTC, .quote = .USDC }));

    // Fill to capacity
    var full = PairSet{};
    var i: usize = 0;
    const bases = [_]BaseAsset{ .BTC, .ETH, .SOL, .XRP, .DOGE };
    const quotes = [_]QuoteAsset{ .USDC, .USDT };
    outer: for (bases) |b| {
        for (quotes) |q| {
            if (i >= MAX_PAIRS) break :outer;
            try full.add(.{ .base = b, .quote = q });
            i += 1;
        }
    }
    while (full.len < MAX_PAIRS) {
        break;
    }
}
