//! Strategy engine — news repricing and liquidity provision signal generation.
const std = @import("std");
const log = @import("logger.zig");

pub const StrategyName = enum { news_repricing, liquidity_provision };

pub const SignalDirection = enum { buy, sell };

pub const Signal = struct {
    strategy: StrategyName,
    market_id: [64]u8,
    market_id_len: usize,
    direction: SignalDirection,
    price: f64,
    size: f64,
    confidence: f64,
    timestamp: i64,
};

pub const StrategyConfig = struct {
    // News repricing
    news_delta_threshold: f64 = 0.05,
    news_confidence_min: f64 = 0.3,
    news_order_size: f64 = 10.0,
    // Liquidity provision
    lp_min_spread: f64 = 0.04,
    lp_exit_spread: f64 = 0.02,
    lp_order_size: f64 = 5.0,
};

pub const StrategyStats = struct {
    signals_emitted: u64 = 0,
    orders_accepted: u64 = 0,
    orders_rejected: u64 = 0,
    cancels: u64 = 0,
    realized_pnl_estimate: f64 = 0.0,
};

const MAX_ACTIVE_ORDERS = 64;

pub const ActiveOrder = struct {
    order_id: [64]u8,
    order_id_len: usize,
    market_id: [64]u8,
    market_id_len: usize,
    strategy: StrategyName,
    direction: SignalDirection,
    pair_index: ?usize,
    signal_price: f64,
};

pub const StrategyEngine = struct {
    config: StrategyConfig,
    news_enabled: std.atomic.Value(bool),
    lp_enabled: std.atomic.Value(bool),
    state_mu: std.Thread.Mutex,
    news_stats: StrategyStats,
    lp_stats: StrategyStats,
    active_orders: [MAX_ACTIVE_ORDERS]?ActiveOrder,
    active_order_count: usize,

    pub fn init(config: StrategyConfig) StrategyEngine {
        return .{
            .config = config,
            .news_enabled = std.atomic.Value(bool).init(false),
            .lp_enabled = std.atomic.Value(bool).init(false),
            .state_mu = .{},
            .news_stats = .{},
            .lp_stats = .{},
            .active_orders = [_]?ActiveOrder{null} ** MAX_ACTIVE_ORDERS,
            .active_order_count = 0,
        };
    }

    pub fn enableStrategy(self: *StrategyEngine, name: StrategyName) void {
        switch (name) {
            .news_repricing => self.news_enabled.store(true, .seq_cst),
            .liquidity_provision => self.lp_enabled.store(true, .seq_cst),
        }
        log.info("strategy", "enabled strategy: {s}", .{@tagName(name)});
    }

    pub fn disableStrategy(self: *StrategyEngine, name: StrategyName) void {
        switch (name) {
            .news_repricing => self.news_enabled.store(false, .seq_cst),
            .liquidity_provision => self.lp_enabled.store(false, .seq_cst),
        }
        log.info("strategy", "disabled strategy: {s}", .{@tagName(name)});
    }

    pub fn isEnabled(self: *StrategyEngine, name: StrategyName) bool {
        return switch (name) {
            .news_repricing => self.news_enabled.load(.seq_cst),
            .liquidity_provision => self.lp_enabled.load(.seq_cst),
        };
    }

    /// News repricing evaluator: compare external_prob vs market_mid.
    /// Returns a signal if delta exceeds threshold and confidence passes.
    pub fn evaluateNewsRepricing(
        self: *StrategyEngine,
        market_id: []const u8,
        external_prob: f64,
        market_mid: f64,
    ) ?Signal {
        // enable check should live at worker level
        const delta = @abs(external_prob - market_mid);
        if (delta < self.config.news_delta_threshold) return null;

        const confidence = @min(1.0, delta / 0.2);
        if (confidence < self.config.news_confidence_min) return null;

        const direction: SignalDirection = if (external_prob > market_mid) .buy else .sell;

        self.state_mu.lock();
        defer self.state_mu.unlock();
        self.news_stats.signals_emitted += 1;

        var mid: [64]u8 = undefined;
        const mid_len = @min(market_id.len, 64);
        @memcpy(mid[0..mid_len], market_id[0..mid_len]);

        log.info("strategy", "news signal: market={s} dir={s} delta={d:.4} conf={d:.4}", .{
            market_id,
            @tagName(direction),
            delta,
            confidence,
        });

        return Signal{
            .strategy = .news_repricing,
            .market_id = mid,
            .market_id_len = mid_len,
            .direction = direction,
            .price = external_prob,
            .size = self.config.news_order_size,
            .confidence = confidence,
            .timestamp = std.time.timestamp(),
        };
    }

    pub const LpResult = struct {
        signals: [2]Signal,
        count: usize,
    };

    pub fn evaluateLiquidityProvision(
        self: *StrategyEngine,
        market_id: []const u8,
        best_bid: f64,
        best_ask: f64,
    ) LpResult {
        const spread = best_ask - best_bid;
        if (spread < self.config.lp_min_spread) return .{ .signals = undefined, .count = 0 };

        const bid_price = best_bid + spread * 0.25;
        const ask_price = best_ask - spread * 0.25;
        const confidence = @min(1.0, spread / 0.1);

        var mid: [64]u8 = undefined;
        const mid_len = @min(market_id.len, 64);
        @memcpy(mid[0..mid_len], market_id[0..mid_len]);

        self.state_mu.lock();
        defer self.state_mu.unlock();
        self.lp_stats.signals_emitted += 2;

        log.info("strategy", "lp signals: market={s} bid={d:.4} ask={d:.4} spread={d:.4}", .{
            market_id,
            bid_price,
            ask_price,
            spread,
        });

        return .{
            .signals = .{
                Signal{
                    .strategy = .liquidity_provision,
                    .market_id = mid,
                    .market_id_len = mid_len,
                    .direction = .buy,
                    .price = bid_price,
                    .size = self.config.lp_order_size,
                    .confidence = confidence,
                    .timestamp = std.time.timestamp(),
                },
                Signal{
                    .strategy = .liquidity_provision,
                    .market_id = mid,
                    .market_id_len = mid_len,
                    .direction = .sell,
                    .price = ask_price,
                    .size = self.config.lp_order_size,
                    .confidence = confidence,
                    .timestamp = std.time.timestamp(),
                },
            },
            .count = 2,
        };
    }

    /// Track an order placed by a strategy (for cancel-on-collapse and LP pair lifecycle).
    pub fn trackOrder(
        self: *StrategyEngine,
        order_id: []const u8,
        market_id: []const u8,
        strategy: StrategyName,
        direction: SignalDirection,
        signal_price: f64,
    ) void {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        // Find first empty slot
        for (&self.active_orders) |*slot| {
            if (slot.* == null) {
                var oid: [64]u8 = undefined;
                const oid_len = @min(order_id.len, 64);
                @memcpy(oid[0..oid_len], order_id[0..oid_len]);

                var mid: [64]u8 = undefined;
                const mid_len = @min(market_id.len, 64);
                @memcpy(mid[0..mid_len], market_id[0..mid_len]);

                slot.* = ActiveOrder{
                    .order_id = oid,
                    .order_id_len = oid_len,
                    .market_id = mid,
                    .market_id_len = mid_len,
                    .strategy = strategy,
                    .direction = direction,
                    .pair_index = null,
                    .signal_price = signal_price,
                };
                self.active_order_count += 1;
                log.info("strategy", "tracking order: {s} strategy={s}", .{
                    order_id,
                    @tagName(strategy),
                });
                return;
            }
        }
        log.warn("strategy", "cannot track order: active_orders full ({d})", .{MAX_ACTIVE_ORDERS});
    }

    /// Link two LP orders as a pair.
    pub fn linkPair(self: *StrategyEngine, idx_a: usize, idx_b: usize) void {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        if (idx_a >= MAX_ACTIVE_ORDERS or idx_b >= MAX_ACTIVE_ORDERS) return;
        if (self.active_orders[idx_a]) |*a| {
            a.pair_index = idx_b;
        }
        if (self.active_orders[idx_b]) |*b| {
            b.pair_index = idx_a;
        }
    }

    /// Remove a tracked order (after cancel or fill).
    pub fn untrackOrder(self: *StrategyEngine, order_id: []const u8) void {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        for (&self.active_orders, 0..) |*slot, idx| {
            if (slot.*) |order| {
                if (std.mem.eql(u8, order.order_id[0..order.order_id_len], order_id)) {
                    if (order.pair_index) |pair_idx| {
                        if (pair_idx < self.active_orders.len) {
                            if (self.active_orders[pair_idx]) |*paired| {
                                if (paired.pair_index) |back_idx| {
                                    if (back_idx == idx) {
                                        paired.pair_index = null;
                                    }
                                }
                            }
                        }
                    }

                    slot.* = null;
                    if (self.active_order_count > 0) self.active_order_count -= 1;
                    log.info("strategy", "untracked order: {s}", .{order_id});
                    return;
                }
            }
        }
    }

    pub const CollapsedResult = struct {
        order_ids: [MAX_ACTIVE_ORDERS][64]u8,
        order_id_lens: [MAX_ACTIVE_ORDERS]usize,
        count: usize,
    };

    /// Find tracked orders for a market + strategy that should be cancelled
    /// because the edge has collapsed (delta below threshold).
    pub fn findCollapsedEdgeOrders(
        self: *StrategyEngine,
        market_id: []const u8,
        current_delta: f64,
    ) CollapsedResult {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        var result: CollapsedResult = .{
            .order_ids = undefined,
            .order_id_lens = [_]usize{0} ** MAX_ACTIVE_ORDERS,
            .count = 0,
        };

        if (@abs(current_delta) >= self.config.news_delta_threshold) return result;

        for (self.active_orders) |slot| {
            if (slot) |order| {
                if (order.strategy == .news_repricing and
                    std.mem.eql(u8, order.market_id[0..order.market_id_len], market_id))
                {
                    result.order_ids[result.count] = order.order_id;
                    result.order_id_lens[result.count] = order.order_id_len;
                    result.count += 1;
                }
            }
        }
        return result;
    }

    /// Find the paired order for a filled LP order (to cancel it).
    pub fn findPairedOrder(self: *StrategyEngine, order_id: []const u8) ?[]const u8 {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        for (self.active_orders) |slot| {
            if (slot) |order| {
                if (std.mem.eql(u8, order.order_id[0..order.order_id_len], order_id)) {
                    if (order.pair_index) |pair_idx| {
                        if (pair_idx < MAX_ACTIVE_ORDERS) {
                            if (self.active_orders[pair_idx]) |paired| {
                                return paired.order_id[0..paired.order_id_len];
                            }
                        }
                    }
                    return null;
                }
            }
        }
        return null;
    }

    /// Check if LP spread has narrowed below exit threshold.
    pub fn shouldCancelLpPair(self: *StrategyEngine, best_bid: f64, best_ask: f64) bool {
        const spread = best_ask - best_bid;
        return spread < self.config.lp_exit_spread;
    }

    /// Get stats snapshot for a strategy.
    pub fn getStats(self: *StrategyEngine, name: StrategyName) StrategyStats {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        return switch (name) {
            .news_repricing => self.news_stats,
            .liquidity_provision => self.lp_stats,
        };
    }

    pub fn incrementOrdersAccepted(self: *StrategyEngine, name: StrategyName) void {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        switch (name) {
            .news_repricing => self.news_stats.orders_accepted += 1,
            .liquidity_provision => self.lp_stats.orders_accepted += 1,
        }
    }

    pub fn incrementOrdersRejected(self: *StrategyEngine, name: StrategyName) void {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        switch (name) {
            .news_repricing => self.news_stats.orders_rejected += 1,
            .liquidity_provision => self.lp_stats.orders_rejected += 1,
        }
    }

    pub fn incrementCancels(self: *StrategyEngine, name: StrategyName) void {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        switch (name) {
            .news_repricing => self.news_stats.cancels += 1,
            .liquidity_provision => self.lp_stats.cancels += 1,
        }
    }
};
