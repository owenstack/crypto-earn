//! Strategy engine — news repricing and liquidity provision signal generation.
const std = @import("std");
const log = @import("logger.zig");

pub const StrategyName = enum { news_repricing, liquidity_provision };

pub const SignalDirection = enum { buy, sell };

pub const Signal = struct {
    strategy: StrategyName,
    market_id: [68]u8,
    market_id_len: usize,
    direction: SignalDirection,
    price: f64,
    size: f64,
    confidence: f64,
    timestamp: i64,
    best_bid: f64,
    best_ask: f64,
};

pub const StrategyConfig = struct {
    // News repricing
    news_delta_threshold: f64 = 0.06,
    news_confidence_min: f64 = 0.40,

    /// News order notional as fraction of USDC balance. Interpreted as
    /// dollars-of-collateral, then divided by quote price to derive the
    /// share count submitted to the CLOB.
    news_order_size_pct: f64 = 0.12,
    /// Dollar notional fallback when balance is unknown (cold start).
    news_order_fallback_usd: f64 = 1.20,

    // Liquidity provision
    lp_min_spread: f64 = 0.06,
    lp_exit_spread: f64 = 0.03,

    /// LP TOTAL pair notional as fraction of USDC balance (covers BOTH legs
    /// combined). Interpreted as dollars-of-collateral, then split per leg
    /// and divided by leg price to derive shares.
    lp_order_size_pct: f64 = 0.07,
    /// Dollar notional fallback (per-pair-total) when balance is unknown.
    lp_order_fallback_usd: f64 = 0.70,
};

/// Polymarket CLOB share floor. Orders below this are dust-rejected.
pub const MIN_ORDER_SHARES: f64 = 5.0;
/// Polymarket CLOB notional floor (USD). Orders smaller than this are dust.
pub const MIN_ORDER_NOTIONAL_USD: f64 = 1.0;

/// Resolve a strategy order size (in shares) from a balance-scaled DOLLAR
/// fraction at a given quote price. Replaces the legacy share-only sizing,
/// which ignored price and over-committed at low prices.
///
/// Semantics:
///   target_usd = balance > 0 ? balance * pct : fallback_usd
///   notional   = max(target_usd, MIN_ORDER_NOTIONAL_USD)
///   shares     = max(notional / price, MIN_ORDER_SHARES)
pub fn resolveOrderSize(balance: f64, pct: f64, price: f64, fallback_usd: f64) f64 {
    const px = std.math.clamp(price, 0.01, 0.99);
    const target_usd = if (balance <= 0) fallback_usd else balance * pct;
    const notional_usd = @max(target_usd, MIN_ORDER_NOTIONAL_USD);
    return @max(notional_usd / px, MIN_ORDER_SHARES);
}

pub const StrategyStats = struct {
    signals_emitted: u64 = 0,
    orders_accepted: u64 = 0,
    orders_rejected: u64 = 0,
    cancels: u64 = 0,
    realized_pnl_estimate: f64 = 0.0,
    active_order_overflow_count: u64 = 0,
};

const MAX_ACTIVE_ORDERS = 64;
const MAX_INVENTORY_MARKETS = 64;

pub const MarketInventory = struct {
    market_id: [68]u8,
    market_id_len: usize,
    net_shares: f64,
    cost_basis: f64,
};

pub const ActiveOrder = struct {
    order_id: [68]u8,
    order_id_len: usize,
    market_id: [68]u8,
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
    paused: std.atomic.Value(bool),
    state_mu: std.Thread.Mutex,
    news_stats: StrategyStats,
    lp_stats: StrategyStats,
    active_orders: [MAX_ACTIVE_ORDERS]?ActiveOrder,
    active_order_count: usize,
    market_inventory: [MAX_INVENTORY_MARKETS]?MarketInventory,
    inventory_count: usize,
    lp_cooldown_markets: [MAX_INVENTORY_MARKETS][68]u8,
    lp_cooldown_lens: [MAX_INVENTORY_MARKETS]usize,
    lp_cooldown_ts: [MAX_INVENTORY_MARKETS]i64,
    lp_cooldown_count: usize,
    lp_max_position_usd: f64,

    pub fn init(config: StrategyConfig) StrategyEngine {
        return .{
            .config = config,
            .news_enabled = std.atomic.Value(bool).init(false),
            .lp_enabled = std.atomic.Value(bool).init(false),
            .paused = std.atomic.Value(bool).init(false),
            .state_mu = .{},
            .news_stats = .{},
            .lp_stats = .{},
            .active_orders = [_]?ActiveOrder{null} ** MAX_ACTIVE_ORDERS,
            .active_order_count = 0,
            .market_inventory = [_]?MarketInventory{null} ** MAX_INVENTORY_MARKETS,
            .inventory_count = 0,
            .lp_cooldown_markets = [_][68]u8{[_]u8{0} ** 68} ** MAX_INVENTORY_MARKETS,
            .lp_cooldown_lens = [_]usize{0} ** MAX_INVENTORY_MARKETS,
            .lp_cooldown_ts = [_]i64{0} ** MAX_INVENTORY_MARKETS,
            .lp_cooldown_count = 0,
            .lp_max_position_usd = 50.0,
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
    /// `balance` is the current USDC balance — used to scale order size.
    pub fn evaluateNewsRepricing(
        self: *StrategyEngine,
        market_id: []const u8,
        external_prob: f64,
        market_mid: f64,
        balance: f64,
    ) ?Signal {
        if (self.paused.load(.seq_cst)) return null;
        // enable check should live at worker level
        const delta = @abs(external_prob - market_mid);
        if (delta < self.config.news_delta_threshold) return null;

        const confidence = @min(1.0, delta / 0.2);
        if (confidence < self.config.news_confidence_min) return null;

        const direction: SignalDirection = if (external_prob > market_mid) .buy else .sell;

        self.state_mu.lock();
        defer self.state_mu.unlock();
        self.news_stats.signals_emitted += 1;

        var mid: [68]u8 = undefined;
        const mid_len = @min(market_id.len, 68);
        @memcpy(mid[0..mid_len], market_id[0..mid_len]);

        log.info("strategy", "news signal: market={s} dir={s} delta={d:.4} conf={d:.4}", .{
            market_id,
            @tagName(direction),
            delta,
            confidence,
        });

        const order_size = resolveOrderSize(
            balance,
            self.config.news_order_size_pct,
            external_prob,
            self.config.news_order_fallback_usd,
        );

        return Signal{
            .strategy = .news_repricing,
            .market_id = mid,
            .market_id_len = mid_len,
            .direction = direction,
            .price = external_prob,
            .size = order_size,
            .confidence = confidence,
            .timestamp = std.time.timestamp(),
            .best_bid = 0.0,
            .best_ask = 0.0,
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
        balance: f64,
    ) LpResult {
        if (self.paused.load(.seq_cst)) return .{ .signals = undefined, .count = 0 };
        const spread = best_ask - best_bid;
        if (spread < self.config.lp_min_spread) return .{ .signals = undefined, .count = 0 };

        // Check per-market inventory limit and current inventory. With the
        // current token-resolution path, we can only quote a paired LP bid+ask
        // when we already own enough inventory to safely back the sell leg.
        const mid_price = (best_bid + best_ask) / 2.0;
        var inventory_shares: f64 = 0.0;
        {
            self.state_mu.lock();
            defer self.state_mu.unlock();
            for (self.market_inventory[0..self.inventory_count]) |slot| {
                if (slot) |inv| {
                    if (std.mem.eql(u8, inv.market_id[0..inv.market_id_len], market_id)) {
                        inventory_shares = inv.net_shares;
                        const exposure = @abs(inv.net_shares) * mid_price;
                        if (exposure >= self.lp_max_position_usd) {
                            log.info("strategy", "LP signal blocked: inventory limit reached for {s} (exposure={d:.2} >= limit={d:.2})", .{
                                market_id, exposure, self.lp_max_position_usd,
                            });
                            return .{ .signals = undefined, .count = 0 };
                        }
                        break;
                    }
                }
            }
        }

        const bid_price = best_bid + spread * 0.25;
        const ask_price = best_ask - spread * 0.25;
        const confidence = @min(1.0, spread / 0.1);

        var mid: [68]u8 = undefined;
        const mid_len = @min(market_id.len, 68);
        @memcpy(mid[0..mid_len], market_id[0..mid_len]);

        self.state_mu.lock();
        defer self.state_mu.unlock();

        log.info("strategy", "lp signals: market={s} bid={d:.4} ask={d:.4} spread={d:.4}", .{
            market_id,
            bid_price,
            ask_price,
            spread,
        });

        // Each leg gets half the configured pair notional, so the pair-total
        // matches lp_order_size_pct of balance instead of doubling it.
        const per_leg_pct = self.config.lp_order_size_pct * 0.5;
        const per_leg_fallback_usd = self.config.lp_order_fallback_usd * 0.5;

        const buy_size = resolveOrderSize(balance, per_leg_pct, bid_price, per_leg_fallback_usd);
        const ask_leg_size = resolveOrderSize(balance, per_leg_pct, ask_price, per_leg_fallback_usd);
        const ts = std.time.timestamp();

        // LP must never emit a naked sell. If we do not already own enough
        // inventory to back the ask leg, skip this market entirely rather than
        // place an orphan buy that cannot be paired.
        if (inventory_shares < MIN_ORDER_SHARES) {
            log.info("strategy", "LP skipped: insufficient inventory for paired quote on {s} (inventory={d:.4})", .{
                market_id,
                inventory_shares,
            });
            return .{ .signals = undefined, .count = 0 };
        }

        const sell_size = @min(ask_leg_size, inventory_shares);
        if (sell_size < MIN_ORDER_SHARES) {
            log.info("strategy", "LP skipped: sell leg below minimum size on {s} (size={d:.4})", .{
                market_id,
                sell_size,
            });
            return .{ .signals = undefined, .count = 0 };
        }

        self.lp_stats.signals_emitted += 2;
        return .{
            .signals = .{
                Signal{
                    .strategy = .liquidity_provision,
                    .market_id = mid,
                    .market_id_len = mid_len,
                    .direction = .buy,
                    .price = bid_price,
                    .size = buy_size,
                    .confidence = confidence,
                    .timestamp = ts,
                    .best_bid = best_bid,
                    .best_ask = best_ask,
                },
                Signal{
                    .strategy = .liquidity_provision,
                    .market_id = mid,
                    .market_id_len = mid_len,
                    .direction = .sell,
                    .price = ask_price,
                    .size = sell_size,
                    .confidence = confidence,
                    .timestamp = ts,
                    .best_bid = best_bid,
                    .best_ask = best_ask,
                },
            },
            .count = 2,
        };
    }

    /// Check if a market is in LP cooldown. If not, mark it as cooling down.
    /// Returns true if the market is currently in cooldown (signal should be suppressed).
    pub fn checkLpCooldown(self: *StrategyEngine, market_id: []const u8, cooldown_seconds: i64) bool {
        const now = std.time.timestamp();
        self.state_mu.lock();
        defer self.state_mu.unlock();

        // Check existing cooldowns
        for (0..self.lp_cooldown_count) |i| {
            if (std.mem.eql(u8, self.lp_cooldown_markets[i][0..self.lp_cooldown_lens[i]], market_id)) {
                if (now - self.lp_cooldown_ts[i] < cooldown_seconds) {
                    return true; // still in cooldown
                }
                // Cooldown expired, update timestamp
                self.lp_cooldown_ts[i] = now;
                return false;
            }
        }

        // Not found, need to add or replace an entry
        if (self.lp_cooldown_count < MAX_INVENTORY_MARKETS) {
            // There is space, add new entry
            const mid_len = @min(market_id.len, 68);
            @memcpy(self.lp_cooldown_markets[self.lp_cooldown_count][0..mid_len], market_id[0..mid_len]);
            self.lp_cooldown_lens[self.lp_cooldown_count] = mid_len;
            self.lp_cooldown_ts[self.lp_cooldown_count] = now;
            self.lp_cooldown_count += 1;
            return false;
        } else {
            // At capacity: scan for expired entry
            var expired_index: ?usize = null;
            for (0..MAX_INVENTORY_MARKETS) |i| {
                if (now - self.lp_cooldown_ts[i] >= cooldown_seconds) {
                    expired_index = i;
                    break;
                }
            }
            var victim_index: usize = 0;
            if (expired_index) |idx| {
                victim_index = idx;
            } else {
                // No expired entry, evict the oldest (smallest timestamp)
                var min_ts = self.lp_cooldown_ts[0];
                victim_index = 0;
                for (1..MAX_INVENTORY_MARKETS) |i| {
                    if (self.lp_cooldown_ts[i] < min_ts) {
                        min_ts = self.lp_cooldown_ts[i];
                        victim_index = i;
                    }
                }
            }
            // Overwrite victim slot
            const mid_len = @min(market_id.len, 68);
            @memcpy(self.lp_cooldown_markets[victim_index][0..mid_len], market_id[0..mid_len]);
            self.lp_cooldown_lens[victim_index] = mid_len;
            self.lp_cooldown_ts[victim_index] = now;
            // Do NOT increment lp_cooldown_count (reused slot)
            return false;
        }
    }

    /// Track an order placed by a strategy (for cancel-on-collapse and LP pair lifecycle).
    pub fn trackOrder(
        self: *StrategyEngine,
        order_id: []const u8,
        market_id: []const u8,
        strategy: StrategyName,
        direction: SignalDirection,
        signal_price: f64,
    ) bool {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        // Find first empty slot
        for (&self.active_orders) |*slot| {
            if (slot.* == null) {
                var oid: [68]u8 = undefined;
                const oid_len = @min(order_id.len, 68);
                @memcpy(oid[0..oid_len], order_id[0..oid_len]);

                var mid: [68]u8 = undefined;
                const mid_len = @min(market_id.len, 68);
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
                return true;
            }
        }

        switch (strategy) {
            .news_repricing => self.news_stats.active_order_overflow_count += 1,
            .liquidity_provision => self.lp_stats.active_order_overflow_count += 1,
        }
        log.warn("strategy", "cannot track order: active_orders full ({d})", .{MAX_ACTIVE_ORDERS});
        return false;
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
        order_ids: [MAX_ACTIVE_ORDERS][68]u8,
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

    /// Update per-market inventory on fill.
    /// direction: .buy increments net_shares, .sell decrements.
    pub fn updateInventory(self: *StrategyEngine, market_id: []const u8, direction: SignalDirection, fill_size: f64) void {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        const delta: f64 = if (direction == .buy) fill_size else -fill_size;

        // Find existing entry first
        for (self.market_inventory[0..self.inventory_count]) |*slot| {
            if (slot.*) |*inv| {
                if (std.mem.eql(u8, inv.market_id[0..inv.market_id_len], market_id)) {
                    inv.net_shares += delta;
                    log.info("strategy", "inventory updated: {s} net_shares={d:.4}", .{ market_id, inv.net_shares });
                    return;
                }
            }
        }

        // Not found, create new entry
        if (self.inventory_count >= MAX_INVENTORY_MARKETS) {
            log.warn("strategy", "cannot create inventory entry: capacity full ({d})", .{MAX_INVENTORY_MARKETS});
            return;
        }
        var mid: [68]u8 = undefined;
        const mid_len = @min(market_id.len, 68);
        @memcpy(mid[0..mid_len], market_id[0..mid_len]);

        self.market_inventory[self.inventory_count] = MarketInventory{
            .market_id = mid,
            .market_id_len = mid_len,
            .net_shares = delta,
            .cost_basis = 0.0,
        };
        self.inventory_count += 1;
        log.info("strategy", "inventory created: {s} net_shares={d:.4}", .{ market_id, delta });
    }

    /// Get a snapshot of inventory for IPC.
    pub fn getInventorySnapshot(self: *StrategyEngine, buf: []u8) ![]const u8 {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();
        try writer.writeAll("{\"markets\":[");

        var first = true;
        for (self.market_inventory[0..self.inventory_count]) |slot| {
            if (slot) |inv| {
                if (!first) try writer.writeAll(",");
                first = false;
                var esc_buf: [140]u8 = undefined;
                const esc = escapeJsonString(inv.market_id[0..inv.market_id_len], &esc_buf) catch inv.market_id[0..inv.market_id_len];
                try writer.print("{{\"market_id\":\"{s}\",\"net_shares\":{d:.4},\"cost_basis\":{d:.4}}}", .{
                    esc,
                    inv.net_shares,
                    inv.cost_basis,
                });
            }
        }
        try writer.writeAll("],\"lp_max_position_usd\":");
        try writer.print("{d:.2}", .{self.lp_max_position_usd});
        try writer.writeAll("}");
        return fbs.getWritten();
    }

    /// Find the index of a tracked order by order_id (for linkPair after placement).
    pub fn findOrderIndex(self: *StrategyEngine, order_id: []const u8) ?usize {
        self.state_mu.lock();
        defer self.state_mu.unlock();

        for (self.active_orders, 0..) |slot, idx| {
            if (slot) |order| {
                if (std.mem.eql(u8, order.order_id[0..order.order_id_len], order_id)) {
                    return idx;
                }
            }
        }
        return null;
    }
};

fn escapeJsonString(src: []const u8, buf: []u8) ![]const u8 {
    var i: usize = 0;
    var j: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        switch (c) {
            '"' => {
                buf[j] = '\\';
                j += 1;
                buf[j] = '"';
                j += 1;
            },
            '\\' => {
                buf[j] = '\\';
                j += 1;
                buf[j] = '\\';
                j += 1;
            },
            0...0x1F => {
                // Control chars as \\u00XX
                if (j + 6 > buf.len) return error.BufferTooSmall;
                std.mem.copyForwards(u8, buf[j .. j + 2], "\\u");
                buf[j + 2] = '0';
                buf[j + 3] = '0';
                buf[j + 4] = "0123456789abcdef"[(c >> 4) & 0xF];
                buf[j + 5] = "0123456789abcdef"[c & 0xF];
                j += 6;
            },
            else => {
                buf[j] = c;
                j += 1;
            },
        }
        if (j >= buf.len) return error.BufferTooSmall;
    }
    return buf[0..j];
}
