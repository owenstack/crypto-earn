//! Integration tests for the arbitrage engine using mock data fixtures.
//!
//! Tests cover: state table behaviour, spread detection, threshold rejection,
//! best-opportunity selection, and multi-pair isolation.

const std = @import("std");
const testing = std.testing;
const cex = @import("cex_zig");
const engine = cex.engine;
const types = cex.types;
const mock = @import("mock_data.zig");

fn makeBbo(exchange: types.Exchange, bid_price: f64, ask_price: f64) types.BboUpdate {
    return .{
        .exchange = exchange,
        .pair = .{ .base = .BTC, .quote = .USDC },
        .bid = .{ .price = bid_price, .size = 1.0 },
        .ask = .{ .price = ask_price, .size = 1.0 },
        .fetched_at_us = 1000,
    };
}

// ---------------------------------------------------------------------------
// State table integration tests
// ---------------------------------------------------------------------------

test "state table: fixture BBOs update correctly" {
    var table = engine.BboStateTable.init(mock.btc_usdc);

    table.update(mock.binance_btc);
    table.update(mock.bybit_btc);

    const bin = table.get(.binance).?;
    try testing.expectApproxEqRel(@as(f64, 82_450.0), bin.ask.price, 1e-9);

    const byb = table.get(.bybit).?;
    try testing.expectApproxEqRel(@as(f64, 82_610.0), byb.bid.price, 1e-9);

    try testing.expect(table.get(.coinbase) == null);
    try testing.expect(table.get(.okx) == null);
}

test "state table: overwrite preserves latest data" {
    var table = engine.BboStateTable.init(mock.btc_usdc);

    table.update(mock.binance_btc);
    table.update(mock.binance_btc_tiny_spread);

    const bin = table.get(.binance).?;
    try testing.expectApproxEqRel(@as(f64, 82_450.0), bin.ask.price, 1e-9);
}

// ---------------------------------------------------------------------------
// Spread detection with fixtures
// ---------------------------------------------------------------------------

test "spread detection: Binance/ByBit fixture produces valid opportunity" {
    var eng = engine.ArbEngine.init(mock.btc_usdc, 0.1, 100_000.0);

    _ = eng.processBboUpdate(mock.binance_btc);
    const result = eng.processBboUpdate(mock.bybit_btc);

    try testing.expect(result != null);
    const opp = result.?;
    try testing.expectEqual(types.Exchange.binance, opp.buy_exchange);
    try testing.expectEqual(types.Exchange.bybit, opp.sell_exchange);
    // Expected: (82610 - 82450) / 82450 * 100 ≈ 0.1940%
    try testing.expect(opp.profit_pct > 0.19);
    try testing.expect(opp.profit_pct < 0.20);
    try testing.expect(opp.isValid());
}

test "threshold rejection: tiny spread below 0.1% min returns null" {
    var eng = engine.ArbEngine.init(mock.btc_usdc, 0.1, 100_000.0);

    _ = eng.processBboUpdate(mock.binance_btc_tiny_spread);
    const result = eng.processBboUpdate(mock.bybit_btc_tiny_spread);

    try testing.expect(result == null);
}

test "no spread: exchanges with overlapping books return null" {
    var eng = engine.ArbEngine.init(mock.btc_usdc, 0.01, 100_000.0);

    _ = eng.processBboUpdate(mock.coinbase_btc_no_spread);
    const result = eng.processBboUpdate(mock.okx_btc_no_spread);

    try testing.expect(result == null);
}

// ---------------------------------------------------------------------------
// Best-opportunity selection
// ---------------------------------------------------------------------------

test "best opportunity: Coinbase spread wins over ByBit" {
    var eng = engine.ArbEngine.init(mock.btc_usdc, 0.01, 100_000.0);

    _ = eng.processBboUpdate(mock.binance_btc);
    _ = eng.processBboUpdate(mock.bybit_btc);
    const result = eng.processBboUpdate(mock.coinbase_btc_good_spread);

    try testing.expect(result != null);
    const opp = result.?;
    // Coinbase bid 82700 vs Binance ask 82450 → ~0.303%
    // ByBit bid 82610 vs Binance ask 82450 → ~0.194%
    try testing.expectEqual(types.Exchange.binance, opp.buy_exchange);
    try testing.expectEqual(types.Exchange.coinbase, opp.sell_exchange);
    try testing.expect(opp.profit_pct > 0.30);
}

// ---------------------------------------------------------------------------
// Multi-pair isolation
// ---------------------------------------------------------------------------

test "multi-pair isolation: ETH engine unaffected by BTC data" {
    var btc_eng = engine.ArbEngine.init(mock.btc_usdc, 0.1, 100_000.0);
    var eth_eng = engine.ArbEngine.init(mock.eth_usdt, 0.1, 50_000.0);

    // Feed BTC data to BTC engine
    _ = btc_eng.processBboUpdate(mock.binance_btc);
    _ = btc_eng.processBboUpdate(mock.bybit_btc);

    // ETH engine should have no data
    try testing.expect(eth_eng.state.get(.binance) == null);
    try testing.expect(eth_eng.state.get(.bybit) == null);

    // Feed ETH data to ETH engine
    _ = eth_eng.processBboUpdate(mock.binance_eth);
    const result = eth_eng.processBboUpdate(mock.bybit_eth);

    try testing.expect(result != null);
    const opp = result.?;
    try testing.expect(opp.pair.eql(mock.eth_usdt));
}

// ---------------------------------------------------------------------------
// Channel integration
// ---------------------------------------------------------------------------

test "engine consumes from bounded channel" {
    const BboChannel = cex.channel.BoundedChannel(types.BboUpdate, 256);
    var ch = BboChannel.init();

    _ = ch.send(mock.binance_btc);
    _ = ch.send(mock.bybit_btc);

    var eng = engine.ArbEngine.init(mock.btc_usdc, 0.1, 100_000.0);
    var last_opp: ?types.ArbOpportunity = null;

    while (ch.tryReceive()) |bbo| {
        if (eng.processBboUpdate(bbo)) |opp| {
            last_opp = opp;
        }
    }

    try testing.expect(last_opp != null);
    try testing.expect(last_opp.?.profit_pct > 0.19);
}

// ---------------------------------------------------------------------------
// Unit tests (using makeBbo helper)
// ---------------------------------------------------------------------------

test "state table: unit update and retrieve" {
    var table = engine.BboStateTable.init(.{ .base = .BTC, .quote = .USDC });
    const bbo = makeBbo(.binance, 82000.0, 82010.0);
    table.update(bbo);

    const got = table.get(.binance).?;
    try testing.expectEqual(types.Exchange.binance, got.exchange);
    try testing.expectApproxEqRel(82000.0, got.bid.price, 1e-9);
    try testing.expectApproxEqRel(82010.0, got.ask.price, 1e-9);
}

test "state table: unit overwrite with newer data" {
    var table = engine.BboStateTable.init(.{ .base = .BTC, .quote = .USDC });
    table.update(makeBbo(.bybit, 81000.0, 81010.0));
    table.update(makeBbo(.bybit, 82000.0, 82010.0));

    const got = table.get(.bybit).?;
    try testing.expectApproxEqRel(82000.0, got.bid.price, 1e-9);
}

test "state table: unit get returns null for empty slot" {
    var table = engine.BboStateTable.init(.{ .base = .BTC, .quote = .USDC });
    try testing.expect(table.get(.coinbase) == null);
}

test "unit spread detection: valid spread produces ArbOpportunity" {
    var eng = engine.ArbEngine.init(.{ .base = .BTC, .quote = .USDC }, 0.01, 100_000.0);

    _ = eng.processBboUpdate(makeBbo(.binance, 81990.0, 82000.0));
    const result = eng.processBboUpdate(makeBbo(.bybit, 82100.0, 82110.0));

    try testing.expect(result != null);
    const opp = result.?;
    try testing.expectEqual(types.Exchange.binance, opp.buy_exchange);
    try testing.expectEqual(types.Exchange.bybit, opp.sell_exchange);
    try testing.expect(opp.profit_pct > 0.1);
    try testing.expect(opp.isValid());
}

test "unit threshold rejection: spread below min_profit_pct returns null" {
    var eng = engine.ArbEngine.init(.{ .base = .BTC, .quote = .USDC }, 1.0, 100_000.0);
    _ = eng.processBboUpdate(makeBbo(.binance, 81990.0, 82000.0));
    const result = eng.processBboUpdate(makeBbo(.bybit, 82010.0, 82020.0));

    try testing.expect(result == null);
}

test "unit no spread: ask >= bid across all pairs returns null" {
    var eng = engine.ArbEngine.init(.{ .base = .BTC, .quote = .USDC }, 0.01, 100_000.0);
    _ = eng.processBboUpdate(makeBbo(.binance, 82000.0, 82010.0));
    const result = eng.processBboUpdate(makeBbo(.bybit, 82000.0, 82010.0));

    try testing.expect(result == null);
}

test "unit best opportunity: highest profit returned among multiple" {
    var eng = engine.ArbEngine.init(.{ .base = .BTC, .quote = .USDC }, 0.01, 100_000.0);

    _ = eng.processBboUpdate(makeBbo(.binance, 81990.0, 82000.0));
    _ = eng.processBboUpdate(makeBbo(.bybit, 82050.0, 82060.0));
    const result = eng.processBboUpdate(makeBbo(.coinbase, 82200.0, 82210.0));

    try testing.expect(result != null);
    const opp = result.?;
    try testing.expectEqual(types.Exchange.binance, opp.buy_exchange);
    try testing.expectEqual(types.Exchange.coinbase, opp.sell_exchange);
    try testing.expect(opp.profit_pct > 0.2);
}

test "unit multi-exchange: 3+ exchanges, correct best pair selected" {
    var eng = engine.ArbEngine.init(.{ .base = .BTC, .quote = .USDC }, 0.01, 100_000.0);

    _ = eng.processBboUpdate(makeBbo(.okx, 81900.0, 81950.0));
    _ = eng.processBboUpdate(makeBbo(.binance, 82000.0, 82010.0));
    _ = eng.processBboUpdate(makeBbo(.bybit, 82300.0, 82310.0));
    const result = eng.processBboUpdate(makeBbo(.coinbase, 82100.0, 82110.0));

    try testing.expect(result != null);
    const opp = result.?;
    try testing.expectEqual(types.Exchange.okx, opp.buy_exchange);
    try testing.expectEqual(types.Exchange.bybit, opp.sell_exchange);
    try testing.expect(opp.profit_pct > 0.4);
}

test "unit single exchange data: only one exchange has data returns null" {
    var eng = engine.ArbEngine.init(.{ .base = .BTC, .quote = .USDC }, 0.01, 100_000.0);
    const result = eng.processBboUpdate(makeBbo(.binance, 82000.0, 82010.0));

    try testing.expect(result == null);
}

test "unit invalid BBO rejected" {
    var eng = engine.ArbEngine.init(.{ .base = .BTC, .quote = .USDC }, 0.01, 100_000.0);

    const invalid = types.BboUpdate{
        .exchange = .binance,
        .pair = .{ .base = .BTC, .quote = .USDC },
        .bid = .{ .price = 82010.0, .size = 1.0 },
        .ask = .{ .price = 82000.0, .size = 1.0 },
        .fetched_at_us = 1000,
    };
    const result = eng.processBboUpdate(invalid);
    try testing.expect(result == null);

    try testing.expect(eng.state.get(.binance) == null);
}
