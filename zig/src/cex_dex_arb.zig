//! Phase 6: Binance ↔ Hyperliquid taker arbitrage strategy.
//!
//! Pure logic only. The owning worker (engine) is responsible for plumbing
//! mid prices from `binance_prices` / `hl_orderbook` into `evaluate()`,
//! routing the returned `ArbSignal` through the existing order pipeline,
//! and feeding round-trip P&L back via `recordTradeResult()` so the
//! circuit-breaker state machine can disable the strategy after a streak
//! of losses.
//!
//! Decisions:
//!   * Arb takers are allowed to open new directional positions; we do not
//!     constrain them to reduce-only here.
//!   * The signal is emitted only after the absolute delta has stayed in
//!     the same direction for `confirm_window_ticks` consecutive evaluator
//!     calls. This filters single-tick spikes from noisy mids.
//!   * The breaker disables the strategy for `cooldown_seconds` after the
//!     loss streak hits `loss_streak_disable`. While disabled, `evaluate`
//!     returns `null` and the streak is reset on re-enable.
const std = @import("std");
const log = @import("logger.zig");

pub const ArbDirection = enum {
    /// HL mid > Binance mid → HL is overpriced. Sell HL (short), buy CEX.
    short_hl_long_cex,
    /// HL mid < Binance mid → HL is underpriced. Buy HL (long), sell CEX.
    long_hl_short_cex,
};
pub const ArbConfig = struct {
    /// Minimum absolute |delta_bps| required for a candidate signal. This
    /// default leaves room above two taker fees plus a small slippage/latency
    /// buffer before the strategy emits a candidate.
    delta_threshold_bps: f64 = 20.0,
    /// Number of consecutive evaluator ticks the delta must stay above
    /// the threshold (in the same direction) before a signal fires.
    confirm_window_ticks: u32 = 3,
    /// Loss-streak count at which the strategy auto-disables.
    loss_streak_disable: u32 = 5,
    /// Cooldown (seconds) after the breaker trips before signals resume.
    cooldown_seconds: i64 = 300,
    /// Per-trade USD notional submitted through the order pipeline.
    order_size_usd: f64 = 12.0,

    pub fn validate(self: ArbConfig) !void {
        if (self.delta_threshold_bps < 0 or !std.math.isFinite(self.delta_threshold_bps))
            return error.InvalidDeltaThreshold;
        if (self.confirm_window_ticks == 0)
            return error.InvalidConfirmWindow;
        if (self.cooldown_seconds < 0)
            return error.InvalidCooldown;
        if (self.order_size_usd <= 0 or !std.math.isFinite(self.order_size_usd))
            return error.InvalidOrderSize;
    }
};


pub const ArbSignal = struct {
    asset: []const u8,
    direction: ArbDirection,
    delta_bps: f64,
    binance_mid: f64,
    hl_mid: f64,
    size_usd: f64,
    timestamp: i64,
};

/// Compute the signed delta in basis points between the HL mid and the
/// Binance mid. `(hl - binance) / binance * 10_000`. Positive values mean
/// HL is trading rich versus Binance.
pub fn computeDeltaBps(binance_mid: f64, hl_mid: f64) f64 {
    if (binance_mid <= 0 or !std.math.isFinite(binance_mid)) return 0.0;
    if (hl_mid <= 0 or !std.math.isFinite(hl_mid)) return 0.0;
    return ((hl_mid - binance_mid) / binance_mid) * 10_000.0;
}

pub const ArbState = struct {
    config: ArbConfig,
    confirm_streak: u32 = 0,
    confirm_direction: ?ArbDirection = null,
    loss_streak: u32 = 0,
    /// Unix-seconds timestamp at which the breaker re-enables the
    /// strategy. `0` = breaker not tripped.
    disabled_until: i64 = 0,

    pub fn init(config: ArbConfig) ArbState {
        return .{ .config = config };
    }

    pub fn isDisabled(self: *const ArbState, now: i64) bool {
        return now < self.disabled_until;
    }

    /// Run one evaluator tick. Returns a signal only when:
    ///   * the breaker is not currently active,
    ///   * both mids are finite and positive,
    ///   * |delta_bps| has stayed at or above `delta_threshold_bps` in the
    ///     same direction for `confirm_window_ticks` consecutive ticks.
    /// On any failed precondition the in-progress confirmation streak is
    /// reset so a single noisy tick cannot pre-load the next signal.
    pub fn evaluate(
        self: *ArbState,
        asset: []const u8,
        binance_mid: f64,
        hl_mid: f64,
        now: i64,
    ) ?ArbSignal {
        if (self.isDisabled(now)) return null;

        if (binance_mid <= 0 or hl_mid <= 0 or
            !std.math.isFinite(binance_mid) or !std.math.isFinite(hl_mid))
        {
            self.confirm_streak = 0;
            self.confirm_direction = null;
            return null;
        }

        const delta_bps = computeDeltaBps(binance_mid, hl_mid);
        if (@abs(delta_bps) < self.config.delta_threshold_bps) {
            self.confirm_streak = 0;
            self.confirm_direction = null;
            return null;
        }

        const direction: ArbDirection = if (delta_bps > 0)
            .short_hl_long_cex
        else
            .long_hl_short_cex;

        if (self.confirm_direction) |prev| {
            if (prev == direction) {
                self.confirm_streak += 1;
            } else {
                self.confirm_streak = 1;
                self.confirm_direction = direction;
            }
        } else {
            self.confirm_streak = 1;
            self.confirm_direction = direction;
        }

        if (self.confirm_streak < self.config.confirm_window_ticks) return null;

        log.info("arb", "signal {s} delta={d:.2}bps binance={d:.4} hl={d:.4}", .{
            asset, delta_bps, binance_mid, hl_mid,
        });

        // Reset the streak so a long-running deviation emits at most one
        // signal per confirm window. The owning worker is expected to
        // submit the order, then call `recordTradeResult` once the
        // round-trip closes.
        self.confirm_streak = 0;
        self.confirm_direction = null;

        return ArbSignal{
            .asset = asset,
            .direction = direction,
            .delta_bps = delta_bps,
            .binance_mid = binance_mid,
            .hl_mid = hl_mid,
            .size_usd = self.config.order_size_usd,
            .timestamp = now,
        };
    }

    /// Feed a closed round-trip P&L back into the breaker. Negative pnl
    /// increments the loss streak; once the streak hits the configured
    /// disable threshold the breaker trips and `evaluate` returns null
    /// until `now >= disabled_until`. A non-negative pnl resets the
    /// streak.
    pub fn recordTradeResult(self: *ArbState, pnl: f64, now: i64) void {
        if (pnl < 0) {
            self.loss_streak += 1;
            if (self.loss_streak >= self.config.loss_streak_disable) {
                self.disabled_until = now + self.config.cooldown_seconds;
                log.warn("arb", "circuit breaker tripped: {d} consecutive losses; disabled until ts={d}", .{
                    self.loss_streak, self.disabled_until,
                });
                self.loss_streak = 0;
            }
        } else {
            if (self.loss_streak > 0) {
                log.info("arb", "loss streak cleared by pnl={d:.4}", .{pnl});
            }
            self.loss_streak = 0;
        }
    }

    /// Manual breaker reset (used by control plane / tests).
    pub fn reenable(self: *ArbState) void {
        self.disabled_until = 0;
        self.loss_streak = 0;
        self.confirm_streak = 0;
        self.confirm_direction = null;
    }
};

/// Thread-safe owner for ArbState. The strategy worker evaluates signals,
/// while fill ingestion can report realized P&L from another thread.
pub const ArbRuntime = struct {
    mu: std.Thread.Mutex = .{},
    state: ArbState,

    pub fn init(config: ArbConfig) ArbRuntime {
        return .{ .state = ArbState.init(config) };
    }

    pub fn evaluate(
        self: *ArbRuntime,
        asset: []const u8,
        binance_mid: f64,
        hl_mid: f64,
        now: i64,
    ) ?ArbSignal {
        self.mu.lock();
        defer self.mu.unlock();
        return self.state.evaluate(asset, binance_mid, hl_mid, now);
    }

    pub fn recordTradeResult(self: *ArbRuntime, pnl: f64, now: i64) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.state.recordTradeResult(pnl, now);
    }

    pub fn reenable(self: *ArbRuntime) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.state.reenable();
    }
};
