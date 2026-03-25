//! Mock BBO data fixtures for deterministic testing.
//!
//! All timestamps and prices are fixed constants — no randomness or real network calls.

const types = @import("cex_zig").types;

/// Standard BTC/USDC pair used across fixtures.
pub const btc_usdc = types.TokenPair{ .base = .BTC, .quote = .USDC };

/// Standard ETH/USDT pair for multi-pair isolation tests.
pub const eth_usdt = types.TokenPair{ .base = .ETH, .quote = .USDT };

/// Base timestamp for all fixtures (microseconds).
pub const base_ts: i64 = 1_000_000;

// ---------------------------------------------------------------------------
// Scenario 1: Valid spread — Binance ask < ByBit bid (0.19% profit)
// ---------------------------------------------------------------------------

pub const binance_btc = types.BboUpdate{
    .exchange = .binance,
    .pair = btc_usdc,
    .bid = .{ .price = 82_440.0, .size = 0.50 },
    .ask = .{ .price = 82_450.0, .size = 0.30 },
    .fetched_at_us = base_ts,
};

pub const bybit_btc = types.BboUpdate{
    .exchange = .bybit,
    .pair = btc_usdc,
    .bid = .{ .price = 82_610.0, .size = 0.20 },
    .ask = .{ .price = 82_620.0, .size = 0.15 },
    .fetched_at_us = base_ts + 1,
};

// Expected: buy on Binance (ask 82450), sell on ByBit (bid 82610)
// profit_pct = (82610 - 82450) / 82450 * 100 ≈ 0.1940%

// ---------------------------------------------------------------------------
// Scenario 2: No spread — all asks >= all bids
// ---------------------------------------------------------------------------

pub const coinbase_btc_no_spread = types.BboUpdate{
    .exchange = .coinbase,
    .pair = btc_usdc,
    .bid = .{ .price = 82_445.0, .size = 0.40 },
    .ask = .{ .price = 82_455.0, .size = 0.25 },
    .fetched_at_us = base_ts + 2,
};

pub const okx_btc_no_spread = types.BboUpdate{
    .exchange = .okx,
    .pair = btc_usdc,
    .bid = .{ .price = 82_448.0, .size = 0.35 },
    .ask = .{ .price = 82_452.0, .size = 0.20 },
    .fetched_at_us = base_ts + 3,
};

// ---------------------------------------------------------------------------
// Scenario 3: Spread below threshold (0.01% — below typical 0.1% min)
// ---------------------------------------------------------------------------

pub const binance_btc_tiny_spread = types.BboUpdate{
    .exchange = .binance,
    .pair = btc_usdc,
    .bid = .{ .price = 82_449.0, .size = 0.50 },
    .ask = .{ .price = 82_450.0, .size = 0.30 },
    .fetched_at_us = base_ts + 4,
};

pub const bybit_btc_tiny_spread = types.BboUpdate{
    .exchange = .bybit,
    .pair = btc_usdc,
    .bid = .{ .price = 82_458.0, .size = 0.20 },
    .ask = .{ .price = 82_460.0, .size = 0.15 },
    .fetched_at_us = base_ts + 5,
};

// profit_pct = (82458 - 82450) / 82450 * 100 ≈ 0.0097%

// ---------------------------------------------------------------------------
// Scenario 4: Multiple spreads — engine should pick the best
// ---------------------------------------------------------------------------

pub const coinbase_btc_good_spread = types.BboUpdate{
    .exchange = .coinbase,
    .pair = btc_usdc,
    .bid = .{ .price = 82_700.0, .size = 0.10 },
    .ask = .{ .price = 82_710.0, .size = 0.08 },
    .fetched_at_us = base_ts + 6,
};

// With binance_btc (ask 82450) and coinbase_btc_good_spread (bid 82700):
// profit_pct = (82700 - 82450) / 82450 * 100 ≈ 0.3032%
// This should be the best opportunity when bybit_btc is also present.

// ---------------------------------------------------------------------------
// Scenario 5: Different pair (ETH/USDT) for multi-pair isolation
// ---------------------------------------------------------------------------

pub const binance_eth = types.BboUpdate{
    .exchange = .binance,
    .pair = eth_usdt,
    .bid = .{ .price = 3_200.0, .size = 2.0 },
    .ask = .{ .price = 3_201.0, .size = 1.5 },
    .fetched_at_us = base_ts + 10,
};

pub const bybit_eth = types.BboUpdate{
    .exchange = .bybit,
    .pair = eth_usdt,
    .bid = .{ .price = 3_210.0, .size = 1.0 },
    .ask = .{ .price = 3_211.0, .size = 0.8 },
    .fetched_at_us = base_ts + 11,
};

// ---------------------------------------------------------------------------
// Adapter test fixtures (JSON response bodies)
// ---------------------------------------------------------------------------

pub const coinbase_valid_json =
    \\{"trade_id":123456,"price":"82455.00","size":"0.15","time":"2026-03-24T14:32:07.411Z","bid":"82450.00","ask":"82460.00","volume":"1234.56"}
;

pub const coinbase_missing_bid_json =
    \\{"trade_id":123456,"price":"82455.00","size":"0.15","ask":"82460.00","volume":"1234.56"}
;

pub const coinbase_zero_size_json =
    \\{"trade_id":123456,"price":"82455.00","size":"0.0","time":"2026-03-24T14:32:07.411Z","bid":"82450.00","ask":"82460.00","volume":"1234.56"}
;

pub const coinbase_bid_gt_ask_json =
    \\{"trade_id":123456,"price":"82455.00","size":"0.15","time":"2026-03-24T14:32:07.411Z","bid":"82470.00","ask":"82460.00","volume":"1234.56"}
;

pub const okx_valid_json =
    \\{"code":"0","msg":"","data":[{"instId":"BTC-USDC","bidPx":"82450.00","askPx":"82460.00","bidSz":"0.15","askSz":"0.10","last":"82455.00","ts":"1711289527411"}]}
;

pub const okx_nonzero_code_json =
    \\{"code":"50011","msg":"Rate limit exceeded","data":[]}
;

pub const okx_empty_data_json =
    \\{"code":"0","msg":"","data":[]}
;

pub const okx_zero_size_json =
    \\{"code":"0","msg":"","data":[{"instId":"BTC-USDC","bidPx":"82450.00","askPx":"82460.00","bidSz":"0.0","askSz":"0.10","last":"82455.00","ts":"1711289527411"}]}
;

pub const okx_bid_gt_ask_json =
    \\{"code":"0","msg":"","data":[{"instId":"BTC-USDC","bidPx":"82470.00","askPx":"82460.00","bidSz":"0.15","askSz":"0.10","last":"82455.00","ts":"1711289527411"}]}
;
