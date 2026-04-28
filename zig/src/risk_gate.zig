//! Mandatory risk gate — every order must pass through validateOrder before submission.
//! Checks are evaluated in deterministic order; first failure short-circuits.
const std = @import("std");
const log = @import("logger.zig");
const db = @import("db.zig");
const ipc = @import("ipc.zig");
const ipc_types = @import("ipc_types.zig");

pub const RiskConfig = struct {
    max_position_usd: f64 = 500.0,
    max_portfolio_exposure_usd: f64 = 5000.0,
    max_daily_drawdown_usd: f64 = 200.0,
    /// Hard upper bound (safety cap). The *effective* max open orders is
    /// derived from the latest balance snapshot via dynamicMaxOpenOrders().
    /// This static value is only used as a fallback ceiling and when no
    /// balance data is available.
    max_open_orders: u32 = 200,
    allow_duplicate_positions: bool = false,
    /// Fraction of the user's USDC balance the bot is allowed to commit to
    /// open orders at any given time.
    max_balance_commitment_ratio: f64 = 0.70,
    balance_snapshot_max_age_seconds: i64 = 600,
    /// Nominal per-order notional in USD used to compute dynamicMaxOpenOrders
    /// from balance. Intentionally small (matches default lp/news order size
    /// of $5–$10) so the dynamic cap scales sensibly with account size.
    nominal_order_notional_usd: f64 = 5.0,
};

/// Compute the effective max open orders from the user's USDC balance.
/// Formula: floor(balance * commitment_ratio / nominal_order_notional).
///
/// - If `balance` is null (no snapshot yet), returns `static_cap` so the
///   engine can still operate from a cold start.
/// - The result is clamped to `[1, static_cap]` so a dust balance never
///   blocks the bot from any orders, and the static cap acts as a hard
///   safety ceiling.
pub fn dynamicMaxOpenOrders(
    balance: ?f64,
    commitment_ratio: f64,
    nominal_order_notional_usd: f64,
    static_cap: u32,
) u32 {
    const bal = balance orelse return static_cap;
    if (bal <= 0 or commitment_ratio <= 0 or nominal_order_notional_usd <= 0) return static_cap;
    const raw = (bal * commitment_ratio) / nominal_order_notional_usd;
    if (!std.math.isFinite(raw) or raw < 1.0) return 1;
    if (raw >= @as(f64, @floatFromInt(static_cap))) return static_cap;
    return @intFromFloat(@floor(raw));
}

pub const OrderRequest = struct {
    market_id: []const u8,
    side: []const u8, // "buy" or "sell"
    size: []const u8, // decimal string
    price: []const u8, // decimal string
    order_type: []const u8,
    client_order_id: []const u8,
};

pub const RejectionReason = enum {
    invalid_input,
    db_error,
    max_position_exceeded,
    max_portfolio_exposure_exceeded,
    max_daily_drawdown_exceeded,
    max_open_orders_exceeded,
    duplicate_position,
    balance_commitment_exceeded,
};

pub const ValidationResult = union(enum) {
    pass: void,
    reject: Rejection,
};

pub const Rejection = struct {
    reason: RejectionReason,
    check_name: []const u8,
    limit_value: f64,
    actual_value: f64,
};

/// Validate an order against all risk checks. Returns pass or structured rejection.
/// On rejection, persists a risk_events row and logs the rejection.
pub fn validateOrder(request: OrderRequest, database: *db.DB, config: RiskConfig) ValidationResult {
    // Parse order notional
    const size = std.fmt.parseFloat(f64, request.size) catch {
        const rejection = Rejection{
            .reason = .invalid_input,
            .check_name = "invalid_size",
            .limit_value = 0.0,
            .actual_value = 0.0,
        };
        persistRejection(database, request, rejection);
        return .{ .reject = rejection };
    };
    const price = std.fmt.parseFloat(f64, request.price) catch {
        const rejection = Rejection{
            .reason = .invalid_input,
            .check_name = "invalid_price",
            .limit_value = 0.0,
            .actual_value = 0.0,
        };
        persistRejection(database, request, rejection);
        return .{ .reject = rejection };
    };
    const notional = size * price;

    // Check 1: Max position size
    if (notional > config.max_position_usd) {
        const rejection = Rejection{
            .reason = .max_position_exceeded,
            .check_name = "max_position_usd",
            .limit_value = config.max_position_usd,
            .actual_value = notional,
        };
        persistRejection(database, request, rejection);
        return .{ .reject = rejection };
    }

    // Check 2: Max portfolio exposure
    const current_exposure = database.queryOpenExposureUsd() catch {
        const rejection = Rejection{
            .reason = .db_error,
            .check_name = "db_query_open_exposure_failed",
            .limit_value = 0.0,
            .actual_value = 0.0,
        };
        persistRejection(database, request, rejection);
        return .{ .reject = rejection };
    };
    if (current_exposure + notional > config.max_portfolio_exposure_usd) {
        const rejection = Rejection{
            .reason = .max_portfolio_exposure_exceeded,
            .check_name = "max_portfolio_exposure_usd",
            .limit_value = config.max_portfolio_exposure_usd,
            .actual_value = current_exposure + notional,
        };
        persistRejection(database, request, rejection);
        return .{ .reject = rejection };
    }

    // Check 2b: Balance commitment ratio (only when balance snapshots are available)
    const balance_opt = database.queryLatestUsdcBalance(config.balance_snapshot_max_age_seconds) catch {
        const rejection = Rejection{
            .reason = .db_error,
            .check_name = "db_query_latest_usdc_balance_failed",
            .limit_value = 0.0,
            .actual_value = 0.0,
        };
        persistRejection(database, request, rejection);
        return .{ .reject = rejection };
    };
    if (balance_opt) |usdc_balance| {
        if (usdc_balance <= 0) {
            const rejection = Rejection{
                .reason = .invalid_input, // or add a new enum value if desired
                .check_name = "invalid_balance_snapshot",
                .limit_value = 0.0,
                .actual_value = usdc_balance,
            };
            persistRejection(database, request, rejection);
            return .{ .reject = rejection };
        }
        const balance_limit = usdc_balance * config.max_balance_commitment_ratio;
        if (current_exposure + notional > balance_limit) {
            const rejection = Rejection{
                .reason = .balance_commitment_exceeded,
                .check_name = "max_balance_commitment_ratio",
                .limit_value = balance_limit,
                .actual_value = current_exposure + notional,
            };
            persistRejection(database, request, rejection);
            return .{ .reject = rejection };
        }
    }

    // Check 3: Max daily drawdown
    const daily_loss = database.queryTodaysRealizedAndUnrealizedLoss() catch {
        const rejection = Rejection{
            .reason = .db_error,
            .check_name = "db_query_daily_loss_failed",
            .limit_value = 0.0,
            .actual_value = 0.0,
        };
        persistRejection(database, request, rejection);
        return .{ .reject = rejection };
    };
    if (daily_loss < 0 and @abs(daily_loss) >= config.max_daily_drawdown_usd) {
        const rejection = Rejection{
            .reason = .max_daily_drawdown_exceeded,
            .check_name = "max_daily_drawdown_usd",
            .limit_value = config.max_daily_drawdown_usd,
            .actual_value = @abs(daily_loss),
        };
        persistRejection(database, request, rejection);
        return .{ .reject = rejection };
    }

    // Check 4: Max open orders (balance-derived; falls back to static cap
    // when no balance snapshot is available so the engine still works on
    // cold start and in unit tests).
    const open_orders = database.queryOpenOrderCount() catch {
        const rejection = Rejection{
            .reason = .db_error,
            .check_name = "db_query_open_orders_failed",
            .limit_value = 0.0,
            .actual_value = 0.0,
        };
        persistRejection(database, request, rejection);
        return .{ .reject = rejection };
    };
    const effective_max_orders = dynamicMaxOpenOrders(
        balance_opt,
        config.max_balance_commitment_ratio,
        config.nominal_order_notional_usd,
        config.max_open_orders,
    );
    if (open_orders >= effective_max_orders) {
        const rejection = Rejection{
            .reason = .max_open_orders_exceeded,
            .check_name = "max_open_orders",
            .limit_value = @floatFromInt(effective_max_orders),
            .actual_value = @floatFromInt(open_orders),
        };
        persistRejection(database, request, rejection);
        return .{ .reject = rejection };
    }

    // Validate side and map buy/sell to long/short for position lookup.
    const position_side = if (std.mem.eql(u8, request.side, "buy"))
        "long"
    else if (std.mem.eql(u8, request.side, "sell"))
        "short"
    else {
        const rejection = Rejection{
            .reason = .invalid_input,
            .check_name = "invalid_side",
            .limit_value = 0.0,
            .actual_value = 0.0,
        };
        persistRejection(database, request, rejection);
        return .{ .reject = rejection };
    };

    // Check 5: Duplicate position guard
    if (!config.allow_duplicate_positions) {
        const has_position = database.queryPositionByMarketDirection(request.market_id, position_side) catch {
            const rejection = Rejection{
                .reason = .db_error,
                .check_name = "db_query_position_direction_failed",
                .limit_value = 0.0,
                .actual_value = 0.0,
            };
            persistRejection(database, request, rejection);
            return .{ .reject = rejection };
        };
        if (has_position) {
            const rejection = Rejection{
                .reason = .duplicate_position,
                .check_name = "duplicate_position_guard",
                .limit_value = 0.0,
                .actual_value = 1.0,
            };
            persistRejection(database, request, rejection);
            return .{ .reject = rejection };
        }
    }

    log.info("risk", "order passed all risk checks: market={s} side={s} notional={d:.2}", .{
        request.market_id, request.side, notional,
    });

    return .{ .pass = {} };
}

/// Format a rejection reason as a human-readable string.
pub fn rejectionReasonName(reason: RejectionReason) []const u8 {
    return switch (reason) {
        .invalid_input => "InvalidInput",
        .db_error => "DbError",
        .max_position_exceeded => "MaxPositionExceeded",
        .max_portfolio_exposure_exceeded => "MaxPortfolioExposureExceeded",
        .max_daily_drawdown_exceeded => "MaxDailyDrawdownExceeded",
        .max_open_orders_exceeded => "MaxOpenOrdersExceeded",
        .duplicate_position => "DuplicatePosition",
        .balance_commitment_exceeded => "BalanceCommitmentExceeded",
    };
}

fn persistRejection(database: *db.DB, request: OrderRequest, rejection: Rejection) void {
    const reason_name = rejectionReasonName(rejection.reason);

    log.warn("risk", "order REJECTED: check={s} limit={d:.2} actual={d:.2} market={s} side={s}", .{
        rejection.check_name,
        rejection.limit_value,
        rejection.actual_value,
        request.market_id,
        request.side,
    });

    // Format float values as strings for DB storage
    var limit_buf: [32]u8 = undefined;
    const limit_str = std.fmt.bufPrint(&limit_buf, "{d:.2}", .{rejection.limit_value}) catch "0";
    var actual_buf: [32]u8 = undefined;
    const actual_str = std.fmt.bufPrint(&actual_buf, "{d:.2}", .{rejection.actual_value}) catch "0";

    database.recordRiskRejection(
        request.client_order_id,
        request.market_id,
        rejection.check_name,
        reason_name,
        limit_str,
        actual_str,
    ) catch |e| {
        log.err("risk", "failed to persist risk rejection: {any}", .{e});
    };

    // Publish risk rejection event
    var evt_buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&evt_buf);
    const evt_payload_obj = .{
        .order_id = request.client_order_id,
        .market_id = request.market_id,
        .side = request.side,
        .check_name = rejection.check_name,
        .reason = reason_name,
        .limit_value = limit_str,
        .actual_value = actual_str,
    };
    const evt_payload = std.json.Stringify.valueAlloc(fba.allocator(), evt_payload_obj, .{}) catch |e| {
        log.err(
            "risk",
            "failed to serialize risk rejection event: err={s} order_id={s} market_id={s} side={s} check={s} reason={s}",
            .{ @errorName(e), request.client_order_id, request.market_id, request.side, rejection.check_name, reason_name },
        );
        return;
    };
    defer fba.allocator().free(evt_payload);
    ipc.publishEvent(ipc_types.T.event_risk_rejection, evt_payload);
}
