//! Arbitrage detection engine.
//!
//! Maintains a thread-safe BBO state table per token pair and evaluates
//! N*(N-1) exchange-pair spreads to find the highest-profit arbitrage
//! opportunity that exceeds a configurable minimum threshold.

const std = @import("std");
const types = @import("types.zig");

const Exchange = types.Exchange;
const TokenPair = types.TokenPair;
const BboUpdate = types.BboUpdate;
const ArbOpportunity = types.ArbOpportunity;
const PriceLevel = types.PriceLevel;

/// Thread-safe BBO state table for a single token pair.
/// Stores the latest BBO snapshot per exchange, protected by a mutex.
pub const BboStateTable = struct {
    pair: TokenPair,
    slots: [Exchange.count]?BboUpdate,
    mutex: std.Thread.Mutex,

    pub fn init(pair: TokenPair) BboStateTable {
        return .{
            .pair = pair,
            .slots = .{null} ** Exchange.count,
            .mutex = .{},
        };
    }

    /// Store a BBO update for its exchange slot.
    /// The update must be valid and match this table's pair.
    pub fn update(self: *BboStateTable, bbo: BboUpdate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.slots[@intFromEnum(bbo.exchange)] = bbo;
    }

    /// Retrieve the current BBO for a given exchange, or null.
    pub fn get(self: *BboStateTable, exchange: Exchange) ?BboUpdate {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.slots[@intFromEnum(exchange)];
    }

    /// Snapshot of all exchange slots.
    pub fn getAll(self: *BboStateTable) [Exchange.count]?BboUpdate {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.slots;
    }
};

/// Spread evaluation engine.
/// Ingests BBO updates, maintains state, and detects cross-exchange arbitrage.
pub const ArbEngine = struct {
    state: BboStateTable,
    min_profit_pct: f64,
    max_notional_usd: f64,

    pub fn init(pair: TokenPair, min_profit_pct: f64, max_notional_usd: f64) ArbEngine {
        return .{
            .state = BboStateTable.init(pair),
            .min_profit_pct = min_profit_pct,
            .max_notional_usd = max_notional_usd,
        };
    }

    /// Ingest a BBO update and evaluate all spreads.
    /// Returns the best opportunity above the profit threshold, or null.
    /// Rejects invalid BBOs without updating state.
    pub fn processBboUpdate(self: *ArbEngine, bbo: BboUpdate) ?ArbOpportunity {
        if (!bbo.isValid()) return null;
        self.state.update(bbo);
        return self.evaluateAllPairs();
    }

    /// Evaluate all N*(N-1) directed exchange pairs for arbitrage.
    /// Returns the opportunity with the highest profit_pct, or null if
    /// none exceeds min_profit_pct.
    pub fn evaluateAllPairs(self: *ArbEngine) ?ArbOpportunity {
        const snapshot = self.state.getAll();
        var best: ?ArbOpportunity = null;

        for (0..Exchange.count) |buy_idx| {
            const buy_bbo = snapshot[buy_idx] orelse continue;
            for (0..Exchange.count) |sell_idx| {
                if (buy_idx == sell_idx) continue;
                const sell_bbo = snapshot[sell_idx] orelse continue;

                const sell_bid = sell_bbo.bid.price;
                const buy_ask = buy_bbo.ask.price;

                const pct = types.profitPct(sell_bid, buy_ask) orelse continue;
                if (pct < self.min_profit_pct) continue;

                const notional = types.cappedNotional(
                    buy_bbo.ask.size,
                    sell_bbo.bid.size,
                    buy_ask,
                    self.max_notional_usd,
                ) orelse continue;

                const now_us: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_us));

                const candidate = ArbOpportunity{
                    .buy_exchange = @enumFromInt(buy_idx),
                    .sell_exchange = @enumFromInt(sell_idx),
                    .pair = self.state.pair,
                    .profit_pct = pct,
                    .notional_usd = notional,
                    .buy_bbo = buy_bbo,
                    .sell_bbo = sell_bbo,
                    .detected_at_us = now_us,
                };

                if (best) |b| {
                    if (pct > b.profit_pct) best = candidate;
                } else {
                    best = candidate;
                }
            }
        }
        return best;
    }
};


