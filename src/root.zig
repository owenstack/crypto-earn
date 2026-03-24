//! CEX Arbitrage Bot — Foundation Library
//!
//! Phase 0 public API. Consumers import `cex_zig` to access:
//! - `types`  — domain value types (Exchange, TokenPair, BboUpdate, etc.)
//! - `channel` — bounded channel primitive for inter-thread communication
//! - `log`    — structured JSON logger
//! - `config` — TOML config parsing, env overrides, and validation
//!
//! Out of scope (Phase 1+): exchange gateways, arb engine, risk gate,
//! notifier pipeline, metrics/health endpoints, signal lifecycle.

const std = @import("std");

pub const types = @import("types.zig");
pub const channel = @import("channel.zig");
pub const log = @import("log.zig");
pub const config = @import("config.zig");

test {
    // Pull in all module tests so `zig build test` runs them.
    _ = @import("types.zig");
    _ = @import("channel.zig");
    _ = @import("log.zig");
    _ = @import("config.zig");
}
