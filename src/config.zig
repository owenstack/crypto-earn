//! Configuration module for the CEX Arbitrage Bot.
//!
//! Handles TOML-based config parsing, environment variable overrides for secrets,
//! and startup validation with descriptive failure outcomes.
//!
//! Phase 0 scope: config types, TOML parsing, env override, validation.
//! Out of scope: hot-reload (SIGHUP), --dry-run flag runtime behavior.

const std = @import("std");
const types = @import("types.zig");
const testing = std.testing;

/// Config schema version for forward compatibility.
pub const SCHEMA_VERSION: u32 = 1;

pub const ConfigError = error{
    MissingRequiredField,
    InvalidValue,
    ParseError,
    FileNotFound,
    IoError,
};

/// Top-level bot configuration.
pub const Config = struct {
    schema_version: u32 = SCHEMA_VERSION,

    // -- General --
    poll_interval_ms: u32 = 1000,
    request_timeout_ms: u32 = 500,
    backoff_initial_ms: u32 = 1000,
    backoff_max_ms: u32 = 30000,
    bbo_channel_capacity: u32 = 256,
    alert_channel_capacity: u32 = 64,

    // -- Trading --
    min_profit_pct: f64 = 0.1,
    max_notional_usd: f64 = 50000.0,

    // -- Risk --
    max_exposure_per_trade: f64 = 25000.0,
    max_drawdown_pct: f64 = 5.0,
    max_volatility: f64 = 0.10,
    risk_update_interval_s: u32 = 5,

    // -- Logging --
    log_level: []const u8 = "INFO",

    // -- Pairs (first pair required, rest optional) --
    pairs: types.PairSet = .{},

    // -- Secrets (overridable via env vars) --
    telegram_bot_token: ?[]const u8 = null,
    telegram_chat_id: ?[]const u8 = null,

    // -- Observability --
    metrics_port: u16 = 9090,
    health_stale_threshold_s: u32 = 10,

    // -- Dry run --
    dry_run: bool = false,

    pub fn validate(self: *const Config) ConfigError!void {
        if (self.schema_version != SCHEMA_VERSION) return ConfigError.InvalidValue;
        if (self.poll_interval_ms == 0) return ConfigError.InvalidValue;
        if (self.request_timeout_ms == 0) return ConfigError.InvalidValue;
        if (self.bbo_channel_capacity == 0) return ConfigError.InvalidValue;
        if (self.alert_channel_capacity == 0) return ConfigError.InvalidValue;
        if (!std.math.isFinite(self.min_profit_pct) or self.min_profit_pct <= 0.0) return ConfigError.InvalidValue;
        if (!std.math.isFinite(self.max_notional_usd) or self.max_notional_usd <= 0.0) return ConfigError.InvalidValue;
        if (!std.math.isFinite(self.max_exposure_per_trade) or self.max_exposure_per_trade <= 0.0) return ConfigError.InvalidValue;
        if (!std.math.isFinite(self.max_drawdown_pct) or self.max_drawdown_pct <= 0.0 or self.max_drawdown_pct > 100.0) return ConfigError.InvalidValue;
        if (!std.math.isFinite(self.max_volatility) or self.max_volatility <= 0.0) return ConfigError.InvalidValue;
        if (self.risk_update_interval_s == 0) return ConfigError.InvalidValue;
        if (self.pairs.len == 0) return ConfigError.MissingRequiredField;
    }
};

// ---------------------------------------------------------------------------
// Minimal TOML parser (supports the subset needed for config)
// ---------------------------------------------------------------------------

/// A minimal TOML parser supporting:
/// - key = "string"
/// - key = integer
/// - key = float
/// - key = true/false
/// - [section] headers (dotted keys)
/// - # comments
/// - Ignores unknown keys.
pub const TomlParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TomlParser {
        return .{ .allocator = allocator };
    }

    pub fn parseConfig(self: *const TomlParser, source: []const u8) ConfigError!Config {
        var config = Config{};
        var current_section: []const u8 = "";

        var line_iter = std.mem.splitScalar(u8, source, '\n');
        while (line_iter.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            // Section header
            if (line[0] == '[') {
                const end = std.mem.indexOfScalar(u8, line, ']') orelse return ConfigError.ParseError;
                current_section = std.mem.trim(u8, line[1..end], " \t");
                continue;
            }

            // Key = value
            const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse return ConfigError.ParseError;
            const key = std.mem.trim(u8, line[0..eq_pos], " \t");
            const raw_val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

            // Strip inline comments (not inside strings)
            const val = stripInlineComment(raw_val);

            self.applyField(&config, current_section, key, val) catch return ConfigError.ParseError;
        }

        return config;
    }

    fn stripInlineComment(val: []const u8) []const u8 {
        if (val.len > 0 and val[0] == '"') {
            // Find closing quote
            var i: usize = 1;
            while (i < val.len) : (i += 1) {
                if (val[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (val[i] == '"') return val[0 .. i + 1];
            }
            return val;
        }
        // For non-string values, strip at #
        if (std.mem.indexOfScalar(u8, val, '#')) |pos| {
            return std.mem.trim(u8, val[0..pos], " \t");
        }
        return val;
    }

    fn applyField(self: *const TomlParser, config: *Config, section: []const u8, key: []const u8, val: []const u8) !void {
        _ = self;
        if (std.mem.eql(u8, section, "")) {
            // Top-level keys
            if (std.mem.eql(u8, key, "schema_version")) {
                config.schema_version = try parseUint(u32, val);
            } else if (std.mem.eql(u8, key, "log_level")) {
                config.log_level = try parseString(val);
            } else if (std.mem.eql(u8, key, "dry_run")) {
                config.dry_run = try parseBool(val);
            }
        } else if (std.mem.eql(u8, section, "fetcher")) {
            if (std.mem.eql(u8, key, "poll_interval_ms")) {
                config.poll_interval_ms = try parseUint(u32, val);
            } else if (std.mem.eql(u8, key, "request_timeout_ms")) {
                config.request_timeout_ms = try parseUint(u32, val);
            } else if (std.mem.eql(u8, key, "backoff_initial_ms")) {
                config.backoff_initial_ms = try parseUint(u32, val);
            } else if (std.mem.eql(u8, key, "backoff_max_ms")) {
                config.backoff_max_ms = try parseUint(u32, val);
            }
        } else if (std.mem.eql(u8, section, "channel")) {
            if (std.mem.eql(u8, key, "bbo_capacity")) {
                config.bbo_channel_capacity = try parseUint(u32, val);
            } else if (std.mem.eql(u8, key, "alert_capacity")) {
                config.alert_channel_capacity = try parseUint(u32, val);
            }
        } else if (std.mem.eql(u8, section, "trading")) {
            if (std.mem.eql(u8, key, "min_profit_pct")) {
                config.min_profit_pct = try parseFloat(val);
            } else if (std.mem.eql(u8, key, "max_notional_usd")) {
                config.max_notional_usd = try parseFloat(val);
            }
        } else if (std.mem.eql(u8, section, "risk")) {
            if (std.mem.eql(u8, key, "max_exposure_per_trade")) {
                config.max_exposure_per_trade = try parseFloat(val);
            } else if (std.mem.eql(u8, key, "max_drawdown_pct")) {
                config.max_drawdown_pct = try parseFloat(val);
            } else if (std.mem.eql(u8, key, "max_volatility")) {
                config.max_volatility = try parseFloat(val);
            } else if (std.mem.eql(u8, key, "update_interval_s")) {
                config.risk_update_interval_s = try parseUint(u32, val);
            }
        } else if (std.mem.eql(u8, section, "notify")) {
            if (std.mem.eql(u8, key, "bot_token")) {
                config.telegram_bot_token = try parseString(val);
            } else if (std.mem.eql(u8, key, "chat_id")) {
                config.telegram_chat_id = try parseString(val);
            }
        } else if (std.mem.eql(u8, section, "observability")) {
            if (std.mem.eql(u8, key, "metrics_port")) {
                config.metrics_port = try parseUint(u16, val);
            } else if (std.mem.eql(u8, key, "health_stale_threshold_s")) {
                config.health_stale_threshold_s = try parseUint(u32, val);
            }
        } else if (std.mem.eql(u8, section, "pairs")) {
            // pairs.1 = "BTC/USDC" etc.
            const pair = try parsePairString(val);
            config.pairs.add(pair) catch return error.Overflow;
        }
    }

    fn parseUint(comptime T: type, val: []const u8) !T {
        return std.fmt.parseInt(T, val, 10) catch return error.Overflow;
    }

    fn parseFloat(val: []const u8) !f64 {
        return std.fmt.parseFloat(f64, val) catch return error.Overflow;
    }

    fn parseBool(val: []const u8) !bool {
        if (std.mem.eql(u8, val, "true")) return true;
        if (std.mem.eql(u8, val, "false")) return false;
        return error.Overflow;
    }

    fn parseString(val: []const u8) ![]const u8 {
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            return val[1 .. val.len - 1];
        }
        return val;
    }

    fn parsePairString(val: []const u8) !types.TokenPair {
        const s = try parseString(val);
        const slash = std.mem.indexOfScalar(u8, s, '/') orelse return error.Overflow;
        const base_str = s[0..slash];
        const quote_str = s[slash + 1 ..];

        const base = std.meta.stringToEnum(types.BaseAsset, base_str) orelse return error.Overflow;
        const quote = std.meta.stringToEnum(types.QuoteAsset, quote_str) orelse return error.Overflow;

        return .{ .base = base, .quote = quote };
    }
};

// ---------------------------------------------------------------------------
// Environment variable overrides
// ---------------------------------------------------------------------------

/// Apply environment variable overrides for secret fields.
/// CEX_TELEGRAM_BOT_TOKEN and CEX_TELEGRAM_CHAT_ID override config file values.
pub fn applyEnvOverrides(config: *Config) void {
    if (std.posix.getenv("CEX_TELEGRAM_BOT_TOKEN")) |v| {
        config.telegram_bot_token = v;
    }
    if (std.posix.getenv("CEX_TELEGRAM_CHAT_ID")) |v| {
        config.telegram_chat_id = v;
    }
    if (std.posix.getenv("CEX_LOG_LEVEL")) |v| {
        config.log_level = v;
    }
    if (std.posix.getenv("CEX_DRY_RUN")) |v| {
        if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) {
            config.dry_run = true;
        }
    }
}

/// Load config from a TOML file, apply env overrides, and validate.
pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = std.fs.cwd().openFile(path, .{}) catch return ConfigError.FileNotFound;
    defer file.close();

    var buf: [16384]u8 = undefined;
    const len = file.readAll(&buf) catch return ConfigError.IoError;
    const source = buf[0..len];

    const parser = TomlParser.init(allocator);
    var config = try parser.parseConfig(source);
    applyEnvOverrides(&config);
    try config.validate();
    return config;
}

// ===========================================================================
// Tests
// ===========================================================================

const valid_toml =
    \\schema_version = 1
    \\log_level = "INFO"
    \\
    \\[fetcher]
    \\poll_interval_ms = 500
    \\request_timeout_ms = 300
    \\backoff_initial_ms = 2000
    \\backoff_max_ms = 60000
    \\
    \\[channel]
    \\bbo_capacity = 128
    \\alert_capacity = 32
    \\
    \\[trading]
    \\min_profit_pct = 0.15
    \\max_notional_usd = 30000.0
    \\
    \\[risk]
    \\max_exposure_per_trade = 20000.0
    \\max_drawdown_pct = 3.0
    \\max_volatility = 0.08
    \\update_interval_s = 10
    \\
    \\[notify]
    \\bot_token = "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"
    \\chat_id = "-1001234567890"
    \\
    \\[observability]
    \\metrics_port = 8080
    \\health_stale_threshold_s = 15
    \\
    \\[pairs]
    \\1 = "BTC/USDC"
    \\2 = "ETH/USDT"
;

test "valid TOML file parses correctly" {
    const parser = TomlParser.init(testing.allocator);
    const config = try parser.parseConfig(valid_toml);

    try testing.expectEqual(@as(u32, 1), config.schema_version);
    try testing.expectEqual(@as(u32, 500), config.poll_interval_ms);
    try testing.expectEqual(@as(u32, 300), config.request_timeout_ms);
    try testing.expectEqual(@as(u32, 2000), config.backoff_initial_ms);
    try testing.expectEqual(@as(u32, 128), config.bbo_channel_capacity);
    try testing.expectApproxEqRel(0.15, config.min_profit_pct, 1e-9);
    try testing.expectApproxEqRel(30000.0, config.max_notional_usd, 1e-9);
    try testing.expectApproxEqRel(20000.0, config.max_exposure_per_trade, 1e-9);
    try testing.expectApproxEqRel(3.0, config.max_drawdown_pct, 1e-9);
    try testing.expectApproxEqRel(0.08, config.max_volatility, 1e-9);
    try testing.expectEqual(@as(u32, 10), config.risk_update_interval_s);
    try testing.expectEqual(@as(u16, 8080), config.metrics_port);
    try testing.expectEqual(@as(u32, 15), config.health_stale_threshold_s);
    try testing.expectEqual(@as(usize, 2), config.pairs.len);
    try testing.expect(config.telegram_bot_token != null);
    try testing.expect(config.telegram_chat_id != null);

    // Validation should pass
    try config.validate();
}

test "invalid TOML syntax returns ParseError" {
    const parser = TomlParser.init(testing.allocator);
    const bad_toml = "this is not valid toml at all";
    try testing.expectError(ConfigError.ParseError, parser.parseConfig(bad_toml));
}

test "missing required pairs field fails validation" {
    const parser = TomlParser.init(testing.allocator);
    const no_pairs_toml =
        \\schema_version = 1
        \\[trading]
        \\min_profit_pct = 0.1
    ;
    const config = try parser.parseConfig(no_pairs_toml);
    try testing.expectError(ConfigError.MissingRequiredField, config.validate());
}

test "out-of-range values fail validation" {
    const parser = TomlParser.init(testing.allocator);

    // drawdown > 100%
    const bad_drawdown =
        \\[risk]
        \\max_drawdown_pct = 150.0
        \\[pairs]
        \\1 = "BTC/USDC"
    ;
    const config = try parser.parseConfig(bad_drawdown);
    try testing.expectError(ConfigError.InvalidValue, config.validate());
}

test "zero poll_interval_ms fails validation" {
    const parser = TomlParser.init(testing.allocator);
    const bad_poll =
        \\[fetcher]
        \\poll_interval_ms = 0
        \\[pairs]
        \\1 = "BTC/USDC"
    ;
    const config = try parser.parseConfig(bad_poll);
    try testing.expectError(ConfigError.InvalidValue, config.validate());
}

test "env override precedence" {
    // We can't easily set env vars in Zig tests in a portable way,
    // but we can test the applyEnvOverrides function manually.
    var config = Config{};
    config.telegram_bot_token = "from-file";

    // applyEnvOverrides reads real env vars; since CEX_TELEGRAM_BOT_TOKEN
    // is not set, the config value should remain unchanged.
    applyEnvOverrides(&config);
    try testing.expectEqualStrings("from-file", config.telegram_bot_token.?);
}

test "comments and blank lines are ignored" {
    const parser = TomlParser.init(testing.allocator);
    const commented_toml =
        \\# This is a comment
        \\schema_version = 1
        \\
        \\# Another comment
        \\[pairs]
        \\1 = "BTC/USDC"
    ;
    const config = try parser.parseConfig(commented_toml);
    try config.validate();
    try testing.expectEqual(@as(u32, 1), config.schema_version);
}

test "default config with pairs is valid" {
    var config = Config{};
    try config.pairs.add(.{ .base = .BTC, .quote = .USDC });
    try config.validate();
}

test "invalid pair string returns error" {
    const parser = TomlParser.init(testing.allocator);
    const bad_pair_toml =
        \\[pairs]
        \\1 = "INVALID/PAIR"
    ;
    try testing.expectError(ConfigError.ParseError, parser.parseConfig(bad_pair_toml));
}
