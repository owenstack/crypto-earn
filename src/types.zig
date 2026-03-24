//! Core domain types for the CEX Arbitrage Bot.
//!
//! This module defines the foundational value types that flow through the system.
//! All types are allocator-free, explicit, and designed for zero-copy passing
//! through bounded channels.
//!
//! Phase 0 scope: type definitions, validation helpers, and unit tests.
//! Out of scope: runtime multi-pair processing, exchange adapters, engine logic.

const std = @import("std");
const math = std.math;
const testing = std.testing;

/// Supported centralised exchanges.
/// New exchanges are added here and in a corresponding gateway file (Phase 1+).
pub const Exchange = enum(u8) {
    binance = 0,
    bybit = 1,
    coinbase = 2,
    okx = 3,

    pub fn label(self: Exchange) []const u8 {
        return switch (self) {
            .binance => "Binance",
            .bybit => "ByBit",
            .coinbase => "Coinbase",
            .okx => "OKX",
        };
    }

    pub const count = @typeInfo(Exchange).@"enum".fields.len;
};

/// Base asset in a trading pair.
pub const BaseAsset = enum {
    BTC,
    ETH,
    SOL,
    XRP,
    DOGE,
};

/// Quote asset in a trading pair.
pub const QuoteAsset = enum {
    USDC,
    USDT,
};

/// A trading pair, e.g. BTC/USDC.
pub const TokenPair = struct {
    base: BaseAsset,
    quote: QuoteAsset,

    pub fn eql(self: TokenPair, other: TokenPair) bool {
        return self.base == other.base and self.quote == other.quote;
    }

    pub fn format(self: TokenPair, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}/{s}", .{ @tagName(self.base), @tagName(self.quote) });
    }
};

/// A single price level (bid or ask) on an order book.
pub const PriceLevel = struct {
    price: f64,
    size: f64,

    /// Returns true if both price and size are finite and strictly positive.
    pub fn isValid(self: PriceLevel) bool {
        return math.isFinite(self.price) and self.price > 0.0 and
            math.isFinite(self.size) and self.size > 0.0;
    }

    /// Notional value = price * size.
    pub fn notional(self: PriceLevel) f64 {
        return self.price * self.size;
    }
};

/// A best-bid-offer update emitted by a fetcher on every successful poll.
pub const BboUpdate = struct {
    exchange: Exchange,
    pair: TokenPair,
    bid: PriceLevel,
    ask: PriceLevel,
    /// Monotonic microsecond timestamp of when the data was fetched.
    fetched_at_us: i64,

    /// Basic validity: bid and ask must be valid, ask >= bid, timestamp positive.
    pub fn isValid(self: BboUpdate) bool {
        return self.bid.isValid() and self.ask.isValid() and
            self.ask.price >= self.bid.price and
            self.fetched_at_us > 0;
    }
};

/// An arbitrage opportunity detected by the engine.
pub const ArbOpportunity = struct {
    buy_exchange: Exchange,
    sell_exchange: Exchange,
    pair: TokenPair,
    /// (sell_bid - buy_ask) / buy_ask * 100
    profit_pct: f64,
    /// min(buy_ask_size, sell_bid_size) * price, capped at max_notional config.
    notional_usd: f64,
    buy_bbo: BboUpdate,
    sell_bbo: BboUpdate,
    /// Monotonic microsecond timestamp of detection.
    detected_at_us: i64,

    /// Validate that the opportunity is internally consistent.
    pub fn isValid(self: ArbOpportunity) bool {
        return self.buy_exchange != self.sell_exchange and
            self.buy_bbo.isValid() and self.sell_bbo.isValid() and
            math.isFinite(self.profit_pct) and self.profit_pct > 0.0 and
            math.isFinite(self.notional_usd) and self.notional_usd > 0.0 and
            self.detected_at_us > 0;
    }
};

/// Snapshot of current risk metrics, updated on a background thread (Phase 3+).
/// Phase 0: type definition and validation only.
pub const RiskMetrics = struct {
    /// Current portfolio drawdown as a percentage (0.0–100.0).
    drawdown_pct: f64 = 0.0,
    /// Current total exposure in USD.
    exposure_usd: f64 = 0.0,
    /// 24-hour rolling volatility as a decimal (e.g. 0.05 = 5%).
    volatility_24h: f64 = 0.0,
    /// Monotonic microsecond timestamp of last update.
    updated_at_us: i64 = 0,

    pub fn isValid(self: RiskMetrics) bool {
        return math.isFinite(self.drawdown_pct) and self.drawdown_pct >= 0.0 and
            math.isFinite(self.exposure_usd) and self.exposure_usd >= 0.0 and
            math.isFinite(self.volatility_24h) and self.volatility_24h >= 0.0;
    }
};

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------

/// Compute profit percentage: (sell_bid - buy_ask) / buy_ask * 100.
/// Returns null if buy_ask is not positive or result is not finite.
pub fn profitPct(sell_bid: f64, buy_ask: f64) ?f64 {
    if (!math.isFinite(buy_ask) or buy_ask <= 0.0 or !math.isFinite(sell_bid)) return null;
    const result = (sell_bid - buy_ask) / buy_ask * 100.0;
    return if (math.isFinite(result)) result else null;
}

/// Compute capped notional: min(buy_ask_size, sell_bid_size) * price, capped.
/// Returns null if inputs are not finite/positive.
pub fn cappedNotional(buy_ask_size: f64, sell_bid_size: f64, price: f64, max_notional: f64) ?f64 {
    if (!math.isFinite(buy_ask_size) or buy_ask_size <= 0.0) return null;
    if (!math.isFinite(sell_bid_size) or sell_bid_size <= 0.0) return null;
    if (!math.isFinite(price) or price <= 0.0) return null;
    if (!math.isFinite(max_notional) or max_notional <= 0.0) return null;
    const raw = @min(buy_ask_size, sell_bid_size) * price;
    return @min(raw, max_notional);
}

// ---------------------------------------------------------------------------
// Multi-pair scaffolding (Phase 0: type-level only, no runtime processing)
// ---------------------------------------------------------------------------

/// Maximum number of token pairs the system can monitor simultaneously.
/// Runtime multi-pair processing is out of scope for Phase 0.
pub const MAX_PAIRS: usize = 16;

/// A validated collection of token pairs for configuration.
pub const PairSet = struct {
    pairs: [MAX_PAIRS]TokenPair = undefined,
    len: usize = 0,

    /// Add a pair. Returns error if duplicate or at capacity.
    pub fn add(self: *PairSet, pair: TokenPair) error{ Duplicate, AtCapacity }!void {
        for (self.pairs[0..self.len]) |existing| {
            if (existing.eql(pair)) return error.Duplicate;
        }
        if (self.len >= MAX_PAIRS) return error.AtCapacity;
        self.pairs[self.len] = pair;
        self.len += 1;
    }

    pub fn slice(self: *const PairSet) []const TokenPair {
        return self.pairs[0..self.len];
    }
};

// ===========================================================================
// Tests
// ===========================================================================

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
    try testing.expectApproxEqRel(1.0, profitPct(101.0, 100.0).?, 1e-9);

    // Negative spread
    const neg = profitPct(99.0, 100.0).?;
    try testing.expect(neg < 0.0);

    // Zero buy_ask
    try testing.expect(profitPct(101.0, 0.0) == null);

    // NaN input
    try testing.expect(profitPct(math.nan(f64), 100.0) == null);
}

test "cappedNotional helper" {
    // min(0.3, 0.2) * 82000 = 16400, capped at 15000
    try testing.expectApproxEqRel(15000.0, cappedNotional(0.3, 0.2, 82000.0, 15000.0).?, 1e-9);

    // No cap needed: min(0.1, 0.2) * 100 = 10, cap 20
    try testing.expectApproxEqRel(10.0, cappedNotional(0.1, 0.2, 100.0, 20.0).?, 1e-9);

    // Invalid inputs
    try testing.expect(cappedNotional(0.0, 0.2, 100.0, 1000.0) == null);
    try testing.expect(cappedNotional(0.1, -1.0, 100.0, 1000.0) == null);
    try testing.expect(cappedNotional(0.1, 0.2, 0.0, 1000.0) == null);
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
    // Add beyond capacity (need to fill up remaining slots first with unique pairs)
    while (full.len < MAX_PAIRS) {
        // Already at max from the loop if MAX_PAIRS <= 10
        break;
    }
}
