//! CEX Arbitrage Bot — Library
//!
//! Public API. Consumers import `cex_zig` to access:
//! - `types`   — domain value types (Exchange, TokenPair, BboUpdate, etc.)
//! - `channel` — bounded channel primitive for inter-thread communication
//! - `log`     — structured JSON logger
//! - `config`  — TOML config parsing, env overrides, and validation
//! - `http`    — shared HTTP client wrapper
//! - `gateway` — exchange gateway adapters (Binance, ByBit, Coinbase, OKX)
//! - `engine`  — arbitrage detection engine (BboStateTable, ArbEngine)

const std = @import("std");

pub const types = @import("types.zig");
pub const channel = @import("channel.zig");
pub const log = @import("log.zig");
pub const config = @import("config.zig");
pub const http = @import("http.zig");
pub const gateway = @import("gateway.zig");
pub const engine = @import("engine.zig");


