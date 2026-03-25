//! Gateway contract and exchange adapters.
//!
//! Each adapter exposes a struct with:
//!   `fn init(allocator, timeout_ms) Adapter`
//!   `fn deinit(*Adapter) void`
//!   `fn fetchBbo(*Adapter, TokenPair) GatewayError!BboUpdate`
//!
//! Phase 1 scope: Binance and ByBit adapters.

const std = @import("std");
const types = @import("types.zig");
const http_mod = @import("http.zig");

/// Errors returned by gateway adapters.
pub const GatewayError = error{
    HttpFailure,
    ParseFailure,
    ValidationFailure,
};

pub const binance = @import("gateway/binance.zig");
pub const bybit = @import("gateway/bybit.zig");
pub const coinbase = @import("gateway/coinbase.zig");
pub const okx = @import("gateway/okx.zig");


