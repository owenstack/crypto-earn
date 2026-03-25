//! Unit tests for TOML config parsing, validation, and env overrides.

const std = @import("std");
const testing = std.testing;
const cex = @import("cex_zig");
const config = cex.config;
const Config = config.Config;
const ConfigError = config.ConfigError;
const TomlParser = config.TomlParser;

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
    const cfg = try parser.parseConfig(valid_toml);

    try testing.expectEqual(@as(u32, 1), cfg.schema_version);
    try testing.expectEqual(@as(u32, 500), cfg.poll_interval_ms);
    try testing.expectEqual(@as(u32, 300), cfg.request_timeout_ms);
    try testing.expectEqual(@as(u32, 2000), cfg.backoff_initial_ms);
    try testing.expectEqual(@as(u32, 128), cfg.bbo_channel_capacity);
    try testing.expectApproxEqRel(0.15, cfg.min_profit_pct, 1e-9);
    try testing.expectApproxEqRel(30000.0, cfg.max_notional_usd, 1e-9);
    try testing.expectApproxEqRel(20000.0, cfg.max_exposure_per_trade, 1e-9);
    try testing.expectApproxEqRel(3.0, cfg.max_drawdown_pct, 1e-9);
    try testing.expectApproxEqRel(0.08, cfg.max_volatility, 1e-9);
    try testing.expectEqual(@as(u32, 10), cfg.risk_update_interval_s);
    try testing.expectEqual(@as(u16, 8080), cfg.metrics_port);
    try testing.expectEqual(@as(u32, 15), cfg.health_stale_threshold_s);
    try testing.expectEqual(@as(usize, 2), cfg.pairs.len);
    try testing.expect(cfg.telegram_bot_token != null);
    try testing.expect(cfg.telegram_chat_id != null);

    // Validation should pass
    try cfg.validate();
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
    const cfg = try parser.parseConfig(no_pairs_toml);
    try testing.expectError(ConfigError.MissingRequiredField, cfg.validate());
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
    const cfg = try parser.parseConfig(bad_drawdown);
    try testing.expectError(ConfigError.InvalidValue, cfg.validate());
}

test "zero poll_interval_ms fails validation" {
    const parser = TomlParser.init(testing.allocator);
    const bad_poll =
        \\[fetcher]
        \\poll_interval_ms = 0
        \\[pairs]
        \\1 = "BTC/USDC"
    ;
    const cfg = try parser.parseConfig(bad_poll);
    try testing.expectError(ConfigError.InvalidValue, cfg.validate());
}

test "env override precedence" {
    var cfg = Config{};
    cfg.telegram_bot_token = "from-file";

    config.applyEnvOverrides(&cfg);
    try testing.expectEqualStrings("from-file", cfg.telegram_bot_token.?);
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
    const cfg = try parser.parseConfig(commented_toml);
    try cfg.validate();
    try testing.expectEqual(@as(u32, 1), cfg.schema_version);
}

test "default config with pairs is valid" {
    var cfg = Config{};
    try cfg.pairs.add(.{ .base = .BTC, .quote = .USDC });
    try cfg.validate();
}

test "invalid pair string returns error" {
    const parser = TomlParser.init(testing.allocator);
    const bad_pair_toml =
        \\[pairs]
        \\1 = "INVALID/PAIR"
    ;
    try testing.expectError(ConfigError.ParseError, parser.parseConfig(bad_pair_toml));
}
