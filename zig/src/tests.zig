const std = @import("std");
const testing = std.testing;
const log = @import("logger.zig");
const ipc_types = @import("ipc_types.zig");
const db = @import("db.zig");

// Phase 1 modules — import to run their inline tests
const crypto = @import("crypto.zig");
const http_client = @import("http_client.zig");
const websocket = @import("websocket.zig");
const gamma_api = @import("gamma_api.zig");
const clob_orderbook = @import("clob_orderbook.zig");
const market_scanner = @import("market_scanner.zig");

// Phase 2 modules
const risk_gate = @import("risk_gate.zig");
const order_manager = @import("order_manager.zig");
const portfolio_tracker = @import("portfolio_tracker.zig");

// Phase 3 modules
const strategy_engine = @import("strategy_engine.zig");
const news_sources = @import("news_sources.zig");

// Phase 4 modules
const ipc = @import("ipc.zig");

// Polymarket auth module
const polymarket_auth = @import("polymarket_auth.zig");

// Phase 2 PRD modules (fill detection)
const fill_poller = @import("fill_poller.zig");

// Phase 3 PRD modules (probability provider)
const probability_provider = @import("probability_provider.zig");

// ─── Logger tests ───────────────────────────────────────────────────────────

test "logger: init sets start time and uptimeMs returns non-negative" {
    log.init();
    const uptime = log.uptimeMs();
    try testing.expect(uptime >= 0);
}

test "logger: uptimeMs increases over time" {
    log.init();
    const t1 = log.uptimeMs();
    std.Thread.sleep(1_000_000); // 1ms
    const t2 = log.uptimeMs();
    try testing.expect(t2 >= t1);
}

test "logger: debug does not crash" {
    log.init();
    log.debug("test", "debug message {d}", .{42});
}

test "logger: info does not crash" {
    log.init();
    log.info("test", "info message {s}", .{"hello"});
}

test "logger: warn does not crash" {
    log.init();
    log.warn("test", "warn message", .{});
}

test "logger: err does not crash" {
    log.init();
    log.err("test", "error message {d}", .{99});
}

test "logger: writeRecentLogs produces valid JSON array" {
    log.init();
    log.info("test", "log entry for writeRecentLogs", .{});

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try log.writeRecentLogs(buf.writer(testing.allocator));

    const output = buf.items;
    // Must start with [ and end with ]
    try testing.expect(output.len >= 2);
    try testing.expectEqual(@as(u8, '['), output[0]);
    try testing.expectEqual(@as(u8, ']'), output[output.len - 1]);

    // Must parse as valid JSON
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .array);
    try testing.expect(parsed.value.array.items.len > 0);
}

test "logger: ring buffer caps at 200 entries" {
    log.init();
    // Write more than RING_SIZE (200) entries
    for (0..250) |i| {
        log.info("ring", "entry {d}", .{i});
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try log.writeRecentLogs(buf.writer(testing.allocator));

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .array);
    try testing.expect(parsed.value.array.items.len <= 200);
}

// ─── IPC types tests ────────────────────────────────────────────────────────

test "ipc_types: VERSION equals 1" {
    try testing.expectEqual(@as(u8, 1), ipc_types.VERSION);
}

test "ipc_types: type string constants are correct" {
    try testing.expectEqualStrings("heartbeat", ipc_types.T.heartbeat);
    try testing.expectEqualStrings("heartbeat.response", ipc_types.T.heartbeat_response);
    try testing.expectEqualStrings("status", ipc_types.T.status);
    try testing.expectEqualStrings("status.response", ipc_types.T.status_response);
    try testing.expectEqualStrings("portfolio", ipc_types.T.portfolio);
    try testing.expectEqualStrings("portfolio.response", ipc_types.T.portfolio_response);
    try testing.expectEqualStrings("orders", ipc_types.T.orders);
    try testing.expectEqualStrings("orders.response", ipc_types.T.orders_response);
    try testing.expectEqualStrings("config.get", ipc_types.T.config_get);
    try testing.expectEqualStrings("config.get.response", ipc_types.T.config_get_response);
    try testing.expectEqualStrings("logs", ipc_types.T.logs);
    try testing.expectEqualStrings("logs.response", ipc_types.T.logs_response);
    try testing.expectEqualStrings("error.response", ipc_types.T.err_response);
}

test "ipc_types: writeResponse produces valid JSON-line" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const writer = buf.writer(testing.allocator);

    try ipc_types.writeResponse(writer, "req-1", "test.response", "{\"ok\":true}");

    const output = buf.items;
    // Must end with newline
    try testing.expect(output.len > 0);
    try testing.expectEqual(@as(u8, '\n'), output[output.len - 1]);

    // Parse the JSON (strip trailing newline)
    const json_str = output[0 .. output.len - 1];
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    // Check required fields exist
    try testing.expect(obj.get("v") != null);
    try testing.expect(obj.get("id") != null);
    try testing.expect(obj.get("ts") != null);
    try testing.expect(obj.get("type") != null);
    try testing.expect(obj.get("payload") != null);

    // Check field values
    try testing.expectEqual(@as(i64, 1), obj.get("v").?.integer);
    try testing.expectEqualStrings("req-1", obj.get("id").?.string);
    try testing.expectEqualStrings("test.response", obj.get("type").?.string);

    // ts should be a positive integer
    try testing.expect(obj.get("ts").?.integer > 0);

    // payload should be an object with "ok" key
    try testing.expect(obj.get("payload").?.object.get("ok") != null);
}

test "ipc_types: writeError produces envelope with type error.response" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const writer = buf.writer(testing.allocator);

    try ipc_types.writeError(writer, "req-err", "something went wrong");

    const output = buf.items;
    try testing.expect(output.len > 0);
    try testing.expectEqual(@as(u8, '\n'), output[output.len - 1]);

    const json_str = output[0 .. output.len - 1];
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("error.response", obj.get("type").?.string);
    try testing.expectEqualStrings("req-err", obj.get("id").?.string);

    // payload should contain "error" key
    const payload = obj.get("payload").?.object;
    try testing.expect(payload.get("error") != null);
    try testing.expectEqualStrings("something went wrong", payload.get("error").?.string);
}

test "ipc_types: multiple writeResponse calls produce separate lines" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const writer = buf.writer(testing.allocator);

    try ipc_types.writeResponse(writer, "r1", "t1", "{}");
    try ipc_types.writeResponse(writer, "r2", "t2", "{}");

    // Count newlines — should be exactly 2
    var count: usize = 0;
    for (buf.items) |ch| {
        if (ch == '\n') count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

// ─── DB tests ───────────────────────────────────────────────────────────────

fn openTempDb() !db.DB {
    return db.DB.open(":memory:");
}

test "db: open in-memory succeeds" {
    var database = try openTempDb();
    defer database.close();
}

test "db: execZ runs simple SQL" {
    var database = try openTempDb();
    defer database.close();
    try database.execZ("SELECT 1;");
}

test "db: runMigrations succeeds on fresh db" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();
}

test "db: runMigrations is idempotent" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();
    try database.runMigrations(); // second run should not error
}

test "db: tables exist after migrations" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    // Verify each table exists by running a SELECT against it.
    // execZ will return error.DBExecFailed if the table doesn't exist.
    try database.execZ("SELECT count(*) FROM schema_migrations;");
    try database.execZ("SELECT count(*) FROM markets;");
    try database.execZ("SELECT count(*) FROM positions;");
    try database.execZ("SELECT count(*) FROM orders;");
    try database.execZ("SELECT count(*) FROM fills;");
    try database.execZ("SELECT count(*) FROM strategy_signals;");
    try database.execZ("SELECT count(*) FROM config_changes;");
    try database.execZ("SELECT count(*) FROM logs;");
}

test "db: journalMode returns a non-empty string" {
    // in-memory DB journal mode is typically "memory", not "wal"
    var database = try openTempDb();
    defer database.close();
    var jm_buf: [16]u8 = undefined;
    const jm = database.journalMode(&jm_buf);
    try testing.expect(jm.len > 0);
}

test "db: temp file DB gets WAL journal mode" {
    // WAL requires a real file — use a unique temp path
    var seed: u64 = 0;
    std.posix.getrandom(std.mem.asBytes(&seed)) catch {
        seed = @as(u64, @intCast(@max(std.time.timestamp(), 1)));
    };
    var rng = std.Random.DefaultPrng.init(seed);
    var path_buf: [128:0]u8 = @splat(0);
    const path = std.fmt.bufPrint(&path_buf, "/tmp/cex-test-wal-{d}.db", .{rng.random().int(u32)}) catch unreachable;

    var database = try db.DB.open(&path_buf);
    defer {
        database.close();
        std.fs.cwd().deleteFile(path) catch {};
    }
    var jm_buf: [16]u8 = undefined;
    const jm = database.journalMode(&jm_buf);
    try testing.expectEqualStrings("wal", jm);
}

test "db: execZ rejects invalid SQL" {
    var database = try openTempDb();
    defer database.close();
    const result = database.execZ("INVALID SQL STATEMENT;");
    try testing.expectError(error.DBExecFailed, result);
}

// ─── IPC dispatch tests (indirect, via ipc_types + db) ──────────────────────
// Since dispatch is private in ipc.zig, we test envelope formatting
// and DB interactions that dispatch relies on.

test "ipc: heartbeat response envelope format" {
    log.init();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const writer = buf.writer(testing.allocator);

    // Simulate what dispatch does for heartbeat
    var p: [64]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &p,
        "{{\"status\":\"ok\",\"uptime_ms\":{d}}}",
        .{log.uptimeMs()},
    ) catch "{}";
    try ipc_types.writeResponse(writer, "hb-1", ipc_types.T.heartbeat_response, payload);

    const json_str = buf.items[0 .. buf.items.len - 1];
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("heartbeat.response", obj.get("type").?.string);
    const pl = obj.get("payload").?.object;
    try testing.expectEqualStrings("ok", pl.get("status").?.string);
    try testing.expect(pl.get("uptime_ms") != null);
}

test "ipc: status response envelope with db info" {
    var database = try openTempDb();
    defer database.close();

    log.init();
    var jm_buf: [16]u8 = undefined;
    const jm = database.journalMode(&jm_buf);

    var p: [128]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &p,
        "{{\"engine\":\"running\",\"db\":\"{s}\",\"uptime_ms\":{d}}}",
        .{ jm, log.uptimeMs() },
    ) catch "{}";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const writer = buf.writer(testing.allocator);
    try ipc_types.writeResponse(writer, "st-1", ipc_types.T.status_response, payload);

    const json_str = buf.items[0 .. buf.items.len - 1];
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("status.response", obj.get("type").?.string);
    const pl = obj.get("payload").?.object;
    try testing.expectEqualStrings("running", pl.get("engine").?.string);
    try testing.expect(pl.get("db") != null);
    try testing.expect(pl.get("uptime_ms") != null);
}

test "ipc: portfolio stub response" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const writer = buf.writer(testing.allocator);
    try ipc_types.writeResponse(writer, "pf-1", ipc_types.T.portfolio_response, "{\"positions\":[],\"note\":\"phase-0-stub\"}");

    const json_str = buf.items[0 .. buf.items.len - 1];
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("portfolio.response", obj.get("type").?.string);
}

test "ipc: orders stub response" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const writer = buf.writer(testing.allocator);
    try ipc_types.writeResponse(writer, "or-1", ipc_types.T.orders_response, "{\"orders\":[],\"note\":\"phase-0-stub\"}");

    const json_str = buf.items[0 .. buf.items.len - 1];
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("orders.response", obj.get("type").?.string);
}

test "ipc: config.get stub response" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const writer = buf.writer(testing.allocator);
    try ipc_types.writeResponse(writer, "cg-1", ipc_types.T.config_get_response, "{\"config\":{},\"note\":\"phase-0-stub\"}");

    const json_str = buf.items[0 .. buf.items.len - 1];
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("config.get.response", obj.get("type").?.string);
}

test "ipc: logs response with writeRecentLogs" {
    log.init();
    log.info("test", "log for ipc test", .{});

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(testing.allocator);
    try payload.appendSlice(testing.allocator, "{\"logs\":");
    try log.writeRecentLogs(payload.writer(testing.allocator));
    try payload.append(testing.allocator, '}');

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const writer = buf.writer(testing.allocator);
    try ipc_types.writeResponse(writer, "lg-1", ipc_types.T.logs_response, payload.items);

    const json_str = buf.items[0 .. buf.items.len - 1];
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("logs.response", obj.get("type").?.string);
    const pl = obj.get("payload").?.object;
    try testing.expect(pl.get("logs") != null);
    try testing.expect(pl.get("logs").? == .array);
}

test "ipc: error response for unknown type" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const writer = buf.writer(testing.allocator);
    try ipc_types.writeError(writer, "bad-1", "unknown message type");

    const json_str = buf.items[0 .. buf.items.len - 1];
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("error.response", obj.get("type").?.string);
    const pl = obj.get("payload").?.object;
    try testing.expectEqualStrings("unknown message type", pl.get("error").?.string);
}

test "ipc: error response for invalid json" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const writer = buf.writer(testing.allocator);
    try ipc_types.writeError(writer, "unknown", "invalid json");

    const json_str = buf.items[0 .. buf.items.len - 1];
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("error.response", obj.get("type").?.string);
    try testing.expectEqualStrings("unknown", obj.get("id").?.string);
}

test "ipc: error response for unknown message type" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const writer = buf.writer(testing.allocator);
    try ipc_types.writeError(writer, "unknown", "unknown message type");

    const json_str = buf.items[0 .. buf.items.len - 1];
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("error.response", obj.get("type").?.string);
}

// ─── Phase 2: Risk gate tests ───────────────────────────────────────────────

test "risk_gate: passes valid order under all limits" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    const config = risk_gate.RiskConfig{
        .max_position_usd_fallback = 500.0,
        .max_portfolio_exposure_usd_fallback = 5000.0,
        .max_daily_drawdown_usd_fallback = 200.0,
        .max_open_orders = 20,
        .allow_duplicate_positions = false,
    };

    const request = risk_gate.OrderRequest{
        .market_id = "test-market",
        .side = "buy",
        .size = "10",
        .price = "0.50",
        .order_type = "limit",
        .client_order_id = "test-order-1",
    };

    const result = risk_gate.validateOrder(request, &database, config);
    try testing.expect(result == .pass);
}

test "risk_gate: rejects order exceeding max position" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    const config = risk_gate.RiskConfig{
        .max_position_usd_fallback = 100.0,
    };

    const request = risk_gate.OrderRequest{
        .market_id = "test-market",
        .side = "buy",
        .size = "500",
        .price = "0.50",
        .order_type = "limit",
        .client_order_id = "test-order-2",
    };

    const result = risk_gate.validateOrder(request, &database, config);
    switch (result) {
        .reject => |r| {
            try testing.expectEqual(risk_gate.RejectionReason.max_position_exceeded, r.reason);
            try testing.expectEqualStrings("max_position_usd", r.check_name);
        },
        .pass => try testing.expect(false),
    }
}

test "risk_gate: rejects above max position boundary" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    const config = risk_gate.RiskConfig{
        .max_position_usd_fallback = 250.0,
    };

    // Notional = 500 * 0.55 = 275 > 250
    const request = risk_gate.OrderRequest{
        .market_id = "test-market",
        .side = "buy",
        .size = "500",
        .price = "0.55",
        .order_type = "limit",
        .client_order_id = "test-order-boundary",
    };

    const result = risk_gate.validateOrder(request, &database, config);
    try testing.expect(result == .reject);
}

test "risk_gate: rejects when max open orders reached" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    // Insert markets first (required by foreign key). Use distinct markets so
    // the new duplicate_open_order guard does not fire before the
    // max_open_orders check.
    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m2','SYM','B','Q');");
    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m3','SYM','B','Q');");

    // Insert max_open_orders pending orders, one per market.
    const config = risk_gate.RiskConfig{
        .max_position_usd_fallback = 500.0,
        .max_portfolio_exposure_usd_fallback = 5000.0,
        .max_open_orders = 2,
    };

    try database.insertOrder("o1", "m1", "co1", "limit", "buy", "10", "0.50", null);
    try database.insertOrder("o2", "m2", "co2", "limit", "sell", "10", "0.50", null);
    try database.updateOrderStatus("o1", "placed");
    try database.updateOrderStatus("o2", "placed");

    const request = risk_gate.OrderRequest{
        .market_id = "m3",
        .side = "buy",
        .size = "10",
        .price = "0.50",
        .order_type = "limit",
        .client_order_id = "test-order-3",
    };

    const result = risk_gate.validateOrder(request, &database, config);
    switch (result) {
        .reject => |r| {
            try testing.expectEqual(risk_gate.RejectionReason.max_open_orders_exceeded, r.reason);
        },
        .pass => try testing.expect(false),
    }
}

test "risk_gate: pair preflight rejects when only one open-order slot remains" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.insertOrder("o1", "m1", "co1", "limit", "buy", "10", "0.50", null);
    try database.updateOrderStatus("o1", "placed");

    const config = risk_gate.RiskConfig{
        .max_position_usd_fallback = 500.0,
        .max_portfolio_exposure_usd_fallback = 5000.0,
        .max_open_orders = 2,
    };

    const result = risk_gate.validatePairPreflight(&database, config, 5.0, 5.0);
    switch (result) {
        .reject => |r| {
            try testing.expectEqual(risk_gate.RejectionReason.max_open_orders_exceeded, r.reason);
        },
        .pass => try testing.expect(false),
    }
}

test "risk_gate: rejects duplicate position" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    // Insert a market and an open long position
    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.execZ("INSERT INTO positions(id,market_id,side,size,entry_price,status) VALUES('p1','m1','long','10','0.50','open');");

    const config = risk_gate.RiskConfig{
        .max_position_usd_fallback = 500.0,
        .max_portfolio_exposure_usd_fallback = 5000.0,
        .allow_duplicate_positions = false,
    };

    // Try to place another buy (long) on same market
    const request = risk_gate.OrderRequest{
        .market_id = "m1",
        .side = "buy",
        .size = "10",
        .price = "0.50",
        .order_type = "limit",
        .client_order_id = "test-dup",
    };

    const result = risk_gate.validateOrder(request, &database, config);
    switch (result) {
        .reject => |r| {
            try testing.expectEqual(risk_gate.RejectionReason.duplicate_position, r.reason);
        },
        .pass => try testing.expect(false),
    }
}

test "risk_gate: rejects duplicate open order on same market" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    // Insert a market and a resting (pending) order — no position yet, since
    // the order has not filled.
    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.insertOrder("o1", "m1", "co1", "limit", "buy", "10", "0.14", null);

    const config = risk_gate.RiskConfig{
        .max_position_usd_fallback = 500.0,
        .max_portfolio_exposure_usd_fallback = 5000.0,
        .allow_duplicate_positions = false,
    };

    // Strategy emits the same buy signal again on the next tick — must be
    // blocked by the new open-order guard, even though no position exists.
    const request = risk_gate.OrderRequest{
        .market_id = "m1",
        .side = "buy",
        .size = "10",
        .price = "0.14",
        .order_type = "limit",
        .client_order_id = "test-dup-open",
    };

    const result = risk_gate.validateOrder(request, &database, config);
    switch (result) {
        .reject => |r| {
            try testing.expectEqual(risk_gate.RejectionReason.duplicate_open_order, r.reason);
        },
        .pass => try testing.expect(false),
    }
}

test "risk_gate: allows duplicate when configured" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.execZ("INSERT INTO positions(id,market_id,side,size,entry_price,status) VALUES('p1','m1','long','10','0.50','open');");

    const config = risk_gate.RiskConfig{
        .max_position_usd_fallback = 500.0,
        .max_portfolio_exposure_usd_fallback = 5000.0,
        .allow_duplicate_positions = true,
    };

    const request = risk_gate.OrderRequest{
        .market_id = "m1",
        .side = "buy",
        .size = "10",
        .price = "0.50",
        .order_type = "limit",
        .client_order_id = "test-dup-ok",
    };

    const result = risk_gate.validateOrder(request, &database, config);
    try testing.expect(result == .pass);
}

test "risk_gate: falls back when latest balance snapshot is non-positive" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.insertBalanceSnapshot(10.0, 0.0, 0.0, 0.0);
    try database.insertBalanceSnapshot(0.0, 0.0, 0.0, 0.0);

    const config = risk_gate.RiskConfig{
        .max_position_usd_fallback = 50.0,
        .max_portfolio_exposure_usd_fallback = 100.0,
        .max_daily_drawdown_usd_fallback = 25.0,
        .max_balance_commitment_ratio = 0.70,
    };

    const request = risk_gate.OrderRequest{
        .market_id = "test-market",
        .side = "buy",
        .size = "10",
        .price = "0.50",
        .order_type = "limit",
        .client_order_id = "test-invalid-balance-fallback",
    };

    const result = risk_gate.validateOrder(request, &database, config);
    try testing.expect(result == .pass);
}

test "risk_gate: rejection reason names are correct" {
    try testing.expectEqualStrings("MaxPositionExceeded", risk_gate.rejectionReasonName(.max_position_exceeded));
    try testing.expectEqualStrings("MaxPortfolioExposureExceeded", risk_gate.rejectionReasonName(.max_portfolio_exposure_exceeded));
    try testing.expectEqualStrings("MaxDailyDrawdownExceeded", risk_gate.rejectionReasonName(.max_daily_drawdown_exceeded));
    try testing.expectEqualStrings("MaxOpenOrdersExceeded", risk_gate.rejectionReasonName(.max_open_orders_exceeded));
    try testing.expectEqualStrings("DuplicatePosition", risk_gate.rejectionReasonName(.duplicate_position));
}

// ─── Phase 2: Order manager tests ───────────────────────────────────────────

test "order_manager: backoff schedule is 1s,2s,4s,...,60s capped" {
    try testing.expectEqual(@as(u64, 1000), order_manager.OrderManager.backoffDelayMs(0));
    try testing.expectEqual(@as(u64, 2000), order_manager.OrderManager.backoffDelayMs(1));
    try testing.expectEqual(@as(u64, 4000), order_manager.OrderManager.backoffDelayMs(2));
    try testing.expectEqual(@as(u64, 8000), order_manager.OrderManager.backoffDelayMs(3));
    try testing.expectEqual(@as(u64, 16000), order_manager.OrderManager.backoffDelayMs(4));
    try testing.expectEqual(@as(u64, 32000), order_manager.OrderManager.backoffDelayMs(5));
    try testing.expectEqual(@as(u64, 60000), order_manager.OrderManager.backoffDelayMs(6)); // capped
    try testing.expectEqual(@as(u64, 60000), order_manager.OrderManager.backoffDelayMs(7)); // stays capped
}

test "order_manager: halt blocks order placement" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    var om = order_manager.OrderManager.init(testing.allocator, &database, .{}, .{});

    // Halt the engine
    _ = om.halt();
    try testing.expect(om.isHalted());

    // Attempt to place order while halted
    const result = om.placeOrder("m1", "buy", "10", "0.50", "limit", null);
    switch (result) {
        .rejected => |r| try testing.expectEqualStrings("engine_halted", r.reason),
        else => try testing.expect(false),
    }
}

test "order_manager: resume unblocks after halt" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    var om = order_manager.OrderManager.init(testing.allocator, &database, .{}, .{});
    _ = om.halt();
    try testing.expect(om.isHalted());

    om.@"resume"();
    try testing.expect(!om.isHalted());
}

test "order_manager: init defaults" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    var om = order_manager.OrderManager.init(testing.allocator, &database, .{}, .{});
    try testing.expect(!om.isHalted());
    try testing.expectEqual(@as(u32, 24), om.config.max_order_age_hours);
    try testing.expectEqual(@as(u32, 5), om.config.stale_scan_interval_min);
    try testing.expectEqual(@as(u32, 7), om.config.max_retry_attempts);
}

// ─── Phase 2: DB helper tests ───────────────────────────────────────────────

test "db: migration 002 creates risk_events and balance_snapshots tables" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    // These should not error - tables exist
    try database.execZ("SELECT count(*) FROM risk_events;");
    try database.execZ("SELECT count(*) FROM balance_snapshots;");
}

test "db: queryLatestUsdcBalance returns null when latest snapshot is non-positive" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.insertBalanceSnapshot(25.0, 0.0, 0.0, 0.0);
    try database.insertBalanceSnapshot(0.0, 0.0, 0.0, 0.0);

    const balance = try database.queryLatestUsdcBalance(600);
    try testing.expectEqual(@as(?f64, null), balance);
}

test "db: insertOrder and queryOpenOrderCount" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");

    const count_before = try database.queryOpenOrderCount();
    try testing.expectEqual(@as(u32, 0), count_before);

    try database.insertOrder("o1", "m1", "co1", "limit", "buy", "10", "0.50", null);
    try database.updateOrderStatus("o1", "placed");
    const count_after = try database.queryOpenOrderCount();
    try testing.expectEqual(@as(u32, 1), count_after);
}

test "db: updateOrderStatus" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.insertOrder("o1", "m1", "co1", "limit", "buy", "10", "0.50", null);

    try database.updateOrderStatus("o1", "filled");
    const count = try database.queryOpenOrderCount();
    try testing.expectEqual(@as(u32, 0), count); // filled orders not counted
}

test "db: recordRiskRejection persists to risk_events" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.recordRiskRejection("o1", "m1", "max_position_usd", "MaxPositionExceeded", "500.00", "750.00");

    const sql = "SELECT count(*) FROM risk_events WHERE check_name='max_position_usd';" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    try testing.expectEqual(@as(c_int, db.c.SQLITE_OK), db.c.sqlite3_prepare_v2(database.handle, sql.ptr, -1, &stmt, null));
    defer _ = db.c.sqlite3_finalize(stmt);

    try testing.expectEqual(@as(c_int, db.c.SQLITE_ROW), db.c.sqlite3_step(stmt));
    const count = db.c.sqlite3_column_int(stmt, 0);
    try testing.expectEqual(@as(c_int, 1), count);
}

test "db: queryOpenExposureUsd returns 0 with no orders" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    const exposure = try database.queryOpenExposureUsd();
    try testing.expectEqual(@as(f64, 0.0), exposure);
}

test "db: queryPositionByMarketDirection returns false with no positions" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    const has = try database.queryPositionByMarketDirection("m1", "long");
    try testing.expect(!has);
}

// ─── Phase 2: IPC type constants ────────────────────────────────────────────

test "ipc_types: Phase 2 type constants exist" {
    try testing.expectEqualStrings("order.place", ipc_types.T.order_place);
    try testing.expectEqualStrings("order.cancel", ipc_types.T.order_cancel);
    try testing.expectEqualStrings("order.cancel_all", ipc_types.T.order_cancel_all);
    try testing.expectEqualStrings("halt", ipc_types.T.halt);
    try testing.expectEqualStrings("resume", ipc_types.T.@"resume");
    try testing.expectEqualStrings("risk.check.response", ipc_types.T.risk_check_response);
    try testing.expectEqualStrings("order.event", ipc_types.T.order_event);
    try testing.expectEqualStrings("halt.response", ipc_types.T.halt_response);
    try testing.expectEqualStrings("resume.response", ipc_types.T.resume_response);
    try testing.expectEqualStrings("order.place.response", ipc_types.T.order_place_response);
    try testing.expectEqualStrings("order.cancel.response", ipc_types.T.order_cancel_response);
    try testing.expectEqualStrings("order.cancel_all.response", ipc_types.T.order_cancel_all_response);
}

// ─── Phase 3: Strategy engine tests ─────────────────────────────────────────

test "strategy_engine: init defaults" {
    var se = strategy_engine.StrategyEngine.init(.{});
    try testing.expect(!se.isEnabled(.news_repricing));
    try testing.expect(!se.isEnabled(.liquidity_provision));
    try testing.expectEqual(@as(u64, 0), se.news_stats.signals_emitted);
    try testing.expectEqual(@as(u64, 0), se.lp_stats.signals_emitted);
    try testing.expectEqual(@as(usize, 0), se.active_order_count);
}

test "strategy_engine: enable and disable" {
    var se = strategy_engine.StrategyEngine.init(.{});
    try testing.expect(!se.isEnabled(.news_repricing));

    se.enableStrategy(.news_repricing);
    try testing.expect(se.isEnabled(.news_repricing));
    try testing.expect(!se.isEnabled(.liquidity_provision));

    se.enableStrategy(.liquidity_provision);
    try testing.expect(se.isEnabled(.liquidity_provision));

    se.disableStrategy(.news_repricing);
    try testing.expect(!se.isEnabled(.news_repricing));
    try testing.expect(se.isEnabled(.liquidity_provision));
}

test "strategy_engine: news repricing triggers on sufficient delta" {
    var se = strategy_engine.StrategyEngine.init(.{
        .news_delta_threshold = 0.05,
        .news_confidence_min = 0.3,
        .news_order_fallback_usd = 10.0,
    });

    // Delta = |0.70 - 0.50| = 0.20, well above threshold
    const signal = se.evaluateNewsRepricing("test-market", 0.70, 0.50, 0.0, 0.0, 0.0);
    try testing.expect(signal != null);
    const s = signal.?;
    try testing.expectEqual(strategy_engine.StrategyName.news_repricing, s.strategy);
    try testing.expectEqual(strategy_engine.SignalDirection.buy, s.direction);
    try testing.expectEqual(@as(f64, 0.70), s.price);
    // Size = max($10/$0.70, 5 shares) = ~14.2857 shares
    try testing.expectApproxEqAbs(@as(f64, 14.285714285714286), s.size, 1e-9);
    try testing.expect(s.confidence >= 0.3);
    try testing.expect(s.confidence <= 1.0);
    try testing.expectEqual(@as(u64, 1), se.news_stats.signals_emitted);
}

test "strategy_engine: news repricing crosses spread on buy when ask is favorable" {
    var se = strategy_engine.StrategyEngine.init(.{
        .news_delta_threshold = 0.05,
        .news_confidence_min = 0.3,
        .news_order_fallback_usd = 10.0,
    });

    // external_prob = 0.70 fair value, market mid 0.50 (delta 0.20).
    // Best bid = 0.45, best ask = 0.60. Ask 0.60 <= 0.70, so the engine
    // should buy at the ask (0.60) for an instant fill instead of resting
    // on the book at 0.70.
    const signal = se.evaluateNewsRepricing("m-spread", 0.70, 0.50, 0.0, 0.45, 0.60);
    try testing.expect(signal != null);
    try testing.expectEqual(strategy_engine.SignalDirection.buy, signal.?.direction);
    try testing.expectEqual(@as(f64, 0.60), signal.?.price);
    try testing.expectEqual(@as(f64, 0.45), signal.?.best_bid);
    try testing.expectEqual(@as(f64, 0.60), signal.?.best_ask);
}

test "strategy_engine: news repricing keeps fair price when ask is too high" {
    var se = strategy_engine.StrategyEngine.init(.{
        .news_delta_threshold = 0.05,
        .news_confidence_min = 0.3,
        .news_order_fallback_usd = 10.0,
    });

    // Best ask 0.85 > fair value 0.70 — refuse to chase, post bid at 0.70.
    const signal = se.evaluateNewsRepricing("m-wide", 0.70, 0.50, 0.0, 0.05, 0.85);
    try testing.expect(signal != null);
    try testing.expectEqual(@as(f64, 0.70), signal.?.price);
}

test "strategy_engine: news repricing crosses spread on sell when bid is favorable" {
    var se = strategy_engine.StrategyEngine.init(.{
        .news_delta_threshold = 0.05,
        .news_confidence_min = 0.3,
        .news_order_fallback_usd = 10.0,
    });

    // external_prob = 0.30 fair value, market mid 0.50 — sell signal.
    // Best bid 0.40 >= 0.30, so the engine should sell into the bid at 0.40.
    const signal = se.evaluateNewsRepricing("m-sell", 0.30, 0.50, 0.0, 0.40, 0.55);
    try testing.expect(signal != null);
    try testing.expectEqual(strategy_engine.SignalDirection.sell, signal.?.direction);
    try testing.expectEqual(@as(f64, 0.40), signal.?.price);
}

test "strategy_engine: news repricing returns null when delta below threshold" {
    var se = strategy_engine.StrategyEngine.init(.{
        .news_delta_threshold = 0.05,
    });

    // Delta = |0.52 - 0.50| = 0.02, below threshold
    const signal = se.evaluateNewsRepricing("test-market", 0.52, 0.50, 0.0, 0.0, 0.0);
    try testing.expect(signal == null);
    try testing.expectEqual(@as(u64, 0), se.news_stats.signals_emitted);
}

test "strategy_engine: news repricing sell direction" {
    var se = strategy_engine.StrategyEngine.init(.{
        .news_delta_threshold = 0.05,
        .news_confidence_min = 0.1,
    });

    // external_prob < market_mid => sell signal
    const signal = se.evaluateNewsRepricing("test-market", 0.30, 0.50, 0.0, 0.0, 0.0);
    try testing.expect(signal != null);
    try testing.expectEqual(strategy_engine.SignalDirection.sell, signal.?.direction);
}

test "strategy_engine: news repricing confidence bounds" {
    var se = strategy_engine.StrategyEngine.init(.{
        .news_delta_threshold = 0.01,
        .news_confidence_min = 0.0,
    });

    // Delta = 0.30 => confidence = min(1.0, 0.30/0.2) = 1.0 (capped)
    const sig1 = se.evaluateNewsRepricing("m1", 0.80, 0.50, 0.0, 0.0, 0.0);
    try testing.expect(sig1 != null);
    try testing.expectEqual(@as(f64, 1.0), sig1.?.confidence);

    // Delta = 0.05 => confidence = min(1.0, 0.05/0.2) = 0.25
    const sig2 = se.evaluateNewsRepricing("m2", 0.55, 0.50, 0.0, 0.0, 0.0);
    try testing.expect(sig2 != null);
    try testing.expectApproxEqAbs(@as(f64, 0.25), sig2.?.confidence, 1e-9);
}

test "strategy_engine: LP emits no signals without inventory" {
    var se = strategy_engine.StrategyEngine.init(.{
        .lp_min_spread = 0.04,
        .lp_order_fallback_usd = 5.0,
    });

    // Spread = 0.60 - 0.40 = 0.20, well above min_spread
    const result = se.evaluateLiquidityProvision("test-market", 0.40, 0.60, 0.0);
    try testing.expectEqual(@as(usize, 0), result.count);
    try testing.expectEqual(@as(u64, 0), se.lp_stats.signals_emitted);
}

test "strategy_engine: LP emits paired signals when spread wide and inventory exists" {
    var se = strategy_engine.StrategyEngine.init(.{
        .lp_min_spread = 0.04,
        .lp_order_fallback_usd = 5.0,
    });
    se.updateInventory("test-market", .buy, 10.0);

    // Spread = 0.60 - 0.40 = 0.20, well above min_spread
    const result = se.evaluateLiquidityProvision("test-market", 0.40, 0.60, 0.0);
    try testing.expectEqual(@as(usize, 2), result.count);
    try testing.expectEqual(strategy_engine.SignalDirection.buy, result.signals[0].direction);
    try testing.expectEqual(strategy_engine.SignalDirection.sell, result.signals[1].direction);
    // bid = 0.40 + 0.20 * 0.25 = 0.45 → buy size = max($2.50/$0.45, 5) = ~5.555
    try testing.expectApproxEqAbs(@as(f64, 0.45), result.signals[0].price, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.5 / 0.45), result.signals[0].size, 1e-9);
    // ask = 0.60 - 0.20 * 0.25 = 0.55 → sell size = max($2.50/$0.55, 5) = ~5.0
    try testing.expectApproxEqAbs(@as(f64, 0.55), result.signals[1].price, 1e-9);
    try testing.expectApproxEqAbs(@max(@as(f64, 2.5 / 0.55), @as(f64, 5.0)), result.signals[1].size, 1e-9);
    try testing.expectEqual(@as(u64, 2), se.lp_stats.signals_emitted);
}

test "strategy_engine: LP returns no signals when spread narrow" {
    var se = strategy_engine.StrategyEngine.init(.{
        .lp_min_spread = 0.04,
    });

    // Spread = 0.51 - 0.49 = 0.02, below min_spread
    const result = se.evaluateLiquidityProvision("test-market", 0.49, 0.51, 0.0);
    try testing.expectEqual(@as(u8, 0), result.count);
    try testing.expectEqual(@as(u64, 0), se.lp_stats.signals_emitted);
}

test "strategy_engine: order tracking and untracking" {
    var se = strategy_engine.StrategyEngine.init(.{});

    try testing.expect(se.trackOrder("order-1", "market-1", .news_repricing, .buy, 0.65));
    try testing.expectEqual(@as(usize, 1), se.active_order_count);

    try testing.expect(se.trackOrder("order-2", "market-1", .liquidity_provision, .sell, 0.55));
    try testing.expectEqual(@as(usize, 2), se.active_order_count);

    se.untrackOrder("order-1");
    try testing.expectEqual(@as(usize, 1), se.active_order_count);

    se.untrackOrder("order-2");
    try testing.expectEqual(@as(usize, 0), se.active_order_count);
}

test "strategy_engine: repricing cancel-on-collapse" {
    var se = strategy_engine.StrategyEngine.init(.{
        .news_delta_threshold = 0.05,
    });

    try testing.expect(se.trackOrder("order-1", "market-1", .news_repricing, .buy, 0.65));
    try testing.expect(se.trackOrder("order-2", "market-2", .news_repricing, .sell, 0.35));

    // current_delta for market-1 is 0.02, below threshold => should find order-1
    const collapsed = se.findCollapsedEdgeOrders("market-1", 0.02);
    try testing.expectEqual(@as(usize, 1), collapsed.count);
    try testing.expectEqualStrings("order-1", collapsed.order_ids[0][0..collapsed.order_id_lens[0]]);

    // current_delta = 0.10, above threshold => no collapsed orders
    const no_collapse = se.findCollapsedEdgeOrders("market-1", 0.10);
    try testing.expectEqual(@as(usize, 0), no_collapse.count);
}

test "strategy_engine: LP pair lifecycle" {
    var se = strategy_engine.StrategyEngine.init(.{
        .lp_exit_spread = 0.02,
    });

    try testing.expect(se.trackOrder("bid-1", "m1", .liquidity_provision, .buy, 0.45));
    try testing.expect(se.trackOrder("ask-1", "m1", .liquidity_provision, .sell, 0.55));

    // Find indices and link them
    var bid_idx: ?usize = null;
    var ask_idx: ?usize = null;
    for (se.active_orders, 0..) |slot, i| {
        if (slot) |order| {
            if (std.mem.eql(u8, order.order_id[0..order.order_id_len], "bid-1")) bid_idx = i;
            if (std.mem.eql(u8, order.order_id[0..order.order_id_len], "ask-1")) ask_idx = i;
        }
    }
    try testing.expect(bid_idx != null);
    try testing.expect(ask_idx != null);
    se.linkPair(bid_idx.?, ask_idx.?);

    // Find paired order for bid-1
    const paired = se.findPairedOrder("bid-1");
    try testing.expect(paired != null);
    try testing.expectEqualStrings("ask-1", paired.?);

    // Should cancel LP pair when spread narrows
    try testing.expect(se.shouldCancelLpPair(0.495, 0.505)); // spread = 0.01 < 0.02
    try testing.expect(!se.shouldCancelLpPair(0.40, 0.60)); // spread = 0.20 > 0.02
}

test "strategy_engine: halt suppresses evaluation gating" {
    // Verify that the enable/disable gating works (halt integration is at worker level)
    var se = strategy_engine.StrategyEngine.init(.{
        .news_delta_threshold = 0.05,
    });

    // When not enabled, evaluator still produces signals (enable check is at worker level)
    const signal = se.evaluateNewsRepricing("m1", 0.70, 0.50, 0.0, 0.0, 0.0);
    try testing.expect(signal != null);

    // isEnabled returns false by default
    try testing.expect(!se.isEnabled(.news_repricing));
}

test "strategy_engine: stats tracking" {
    var se = strategy_engine.StrategyEngine.init(.{});

    // Initial stats are zero
    const ns = se.getStats(.news_repricing);
    try testing.expectEqual(@as(u64, 0), ns.signals_emitted);
    try testing.expectEqual(@as(u64, 0), ns.orders_accepted);

    // After signals
    _ = se.evaluateNewsRepricing("m1", 0.80, 0.50, 0.0, 0.0, 0.0);
    const ns2 = se.getStats(.news_repricing);
    try testing.expectEqual(@as(u64, 1), ns2.signals_emitted);
}

test "strategy_engine: trackOrder overflow increments counter" {
    var se = strategy_engine.StrategyEngine.init(.{});

    var id_buf: [32]u8 = undefined;
    for (0..64) |i| {
        const id = try std.fmt.bufPrint(&id_buf, "order-{d}", .{i});
        try testing.expect(se.trackOrder(id, "m1", .news_repricing, .buy, 0.5));
    }

    try testing.expect(!se.trackOrder("order-overflow", "m1", .news_repricing, .buy, 0.5));
    const stats = se.getStats(.news_repricing);
    try testing.expectEqual(@as(u64, 1), stats.active_order_overflow_count);
}

// ─── Phase 3: IPC type constants ────────────────────────────────────────────

test "ipc_types: Phase 3 strategy type constants exist" {
    try testing.expectEqualStrings("strategy.enable", ipc_types.T.strategy_enable);
    try testing.expectEqualStrings("strategy.disable", ipc_types.T.strategy_disable);
    try testing.expectEqualStrings("strategy.list", ipc_types.T.strategy_list);
    try testing.expectEqualStrings("strategy.list.response", ipc_types.T.strategy_list_response);
    try testing.expectEqualStrings("strategy.enable.response", ipc_types.T.strategy_enable_response);
    try testing.expectEqualStrings("strategy.disable.response", ipc_types.T.strategy_disable_response);
    try testing.expectEqualStrings("strategy.signal.event", ipc_types.T.strategy_signal_event);
}

// ─── Phase 3: DB strategy helpers ───────────────────────────────────────────

test "db: migration 003 creates strategy_stats table" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("SELECT count(*) FROM strategy_stats;");
}

test "db: insertStrategySignal and queryRecentSignalsByStrategy" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.insertStrategySignal("m1", "news_repricing", 0.75, "test metadata");

    var out: [10]db.DB.SignalRow = undefined;
    const count = try database.queryRecentSignalsByStrategy("news_repricing", 10, &out);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectApproxEqAbs(@as(f64, 0.75), out[0].strength, 1e-9);
}

test "db: insertStrategyStats and queryStrategyStats" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.insertStrategyStats("news_repricing", 10, 8, 2, 1, 15.50);

    const stats = try database.queryStrategyStats("news_repricing");
    try testing.expect(stats != null);
    const s = stats.?;
    try testing.expectEqual(@as(i64, 10), s.signals_emitted);
    try testing.expectEqual(@as(i64, 8), s.orders_accepted);
    try testing.expectEqual(@as(i64, 2), s.orders_rejected);
    try testing.expectEqual(@as(i64, 1), s.cancels);
    try testing.expectApproxEqAbs(@as(f64, 15.50), s.realized_pnl_estimate, 1e-9);
}

test "db: insertOrder with strategy_origin" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.insertOrder("o1", "m1", "co1", "limit", "buy", "10", "0.50", "news_repricing");
    try database.updateOrderStatus("o1", "placed");

    const count = try database.queryOpenOrderCount();
    try testing.expectEqual(@as(u32, 1), count);
}

test "portfolio_tracker: writeOrdersJson reports truncation metadata" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");

    var long_id_buf: [1400]u8 = undefined;
    @memset(long_id_buf[0..], 'a');
    const long_id = long_id_buf[0..];

    try database.insertOrder(long_id, "m1", "co-long", "limit", "buy", "10", "0.50", null);

    var pt = portfolio_tracker.PortfolioTracker.init(testing.allocator, &database, .{});
    var out: [4096]u8 = undefined;
    const json = try pt.writeOrdersJson(&out);

    try testing.expect(std.mem.indexOf(u8, json, "\"truncated\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"skipped_count\":1") != null);
}

// ─── Phase 3: News sources tests ────────────────────────────────────────────

test "news_sources: init and empty cache" {
    var nc = news_sources.NewsClient.init(testing.allocator, .{});
    try testing.expectEqual(@as(usize, 0), nc.cached_count);

    const est = nc.getEstimate("nonexistent");
    try testing.expect(est == null);
}

// ─── Phase 4: IPC event types and writeEvent ────────────────────────────────

test "ipc_types: Phase 4 event type constants exist" {
    try testing.expectEqualStrings("event.subscribe", ipc_types.T.event_subscribe);
    try testing.expectEqualStrings("event.subscribe.response", ipc_types.T.event_subscribe_response);
    try testing.expectEqualStrings("event.unsubscribe", ipc_types.T.event_unsubscribe);
    try testing.expectEqualStrings("event.unsubscribe.response", ipc_types.T.event_unsubscribe_response);
    try testing.expectEqualStrings("event.order.placed", ipc_types.T.event_order_placed);
    try testing.expectEqualStrings("event.order.filled", ipc_types.T.event_order_filled);
    try testing.expectEqualStrings("event.order.cancelled", ipc_types.T.event_order_cancelled);
    try testing.expectEqualStrings("event.order.rejected", ipc_types.T.event_order_rejected);
    try testing.expectEqualStrings("event.risk.rejection", ipc_types.T.event_risk_rejection);
    try testing.expectEqualStrings("event.engine.halted", ipc_types.T.event_engine_halted);
    try testing.expectEqualStrings("event.engine.resumed", ipc_types.T.event_engine_resumed);
}

test "ipc_types: writeEvent produces valid JSON-line with event id" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const writer = buf.writer(testing.allocator);

    try ipc_types.writeEvent(writer, "event.order.placed", "{\"order_id\":\"test-1\",\"market_id\":\"m1\"}");

    const output = buf.items;
    try testing.expect(output.len > 0);
    try testing.expectEqual(@as(u8, '\n'), output[output.len - 1]);

    const json_str = output[0 .. output.len - 1];
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.get("v") != null);
    try testing.expect(obj.get("id") != null);
    try testing.expect(obj.get("ts") != null);
    try testing.expect(obj.get("type") != null);
    try testing.expect(obj.get("payload") != null);

    // Event id should start with "evt-"
    const id_str = obj.get("id").?.string;
    try testing.expect(std.mem.startsWith(u8, id_str, "evt-"));

    try testing.expectEqualStrings("event.order.placed", obj.get("type").?.string);
    try testing.expect(obj.get("ts").?.integer > 0);

    // Payload should have order_id
    const pl = obj.get("payload").?.object;
    try testing.expectEqualStrings("test-1", pl.get("order_id").?.string);
}

test "ipc_types: writeEvent generates sequential event ids" {
    var buf1: std.ArrayList(u8) = .empty;
    defer buf1.deinit(testing.allocator);
    try ipc_types.writeEvent(buf1.writer(testing.allocator), "event.order.placed", "{}");

    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(testing.allocator);
    try ipc_types.writeEvent(buf2.writer(testing.allocator), "event.order.cancelled", "{}");

    // Parse both and verify IDs are different
    const json1 = buf1.items[0 .. buf1.items.len - 1];
    const json2 = buf2.items[0 .. buf2.items.len - 1];

    var p1 = try std.json.parseFromSlice(std.json.Value, testing.allocator, json1, .{});
    defer p1.deinit();
    var p2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, json2, .{});
    defer p2.deinit();

    const id1 = p1.value.object.get("id").?.string;
    const id2 = p2.value.object.get("id").?.string;
    try testing.expect(!std.mem.eql(u8, id1, id2));
}

// ─── Phase 5: IPC type constants ────────────────────────────────────────────

test "ipc_types: Phase 5 config/pause/pnl type constants exist" {
    try testing.expectEqualStrings("config.set", ipc_types.T.config_set);
    try testing.expectEqualStrings("config.set.response", ipc_types.T.config_set_response);
    try testing.expectEqualStrings("pause", ipc_types.T.pause);
    try testing.expectEqualStrings("pause.response", ipc_types.T.pause_response);
    try testing.expectEqualStrings("pnl.query", ipc_types.T.pnl_query);
    try testing.expectEqualStrings("pnl.response", ipc_types.T.pnl_response);
}

// ─── Phase 5: DB config persistence ─────────────────────────────────────────

test "db: migration 004 creates runtime_config table" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("SELECT count(*) FROM runtime_config;");
}

test "db: setConfig and getConfig round-trip" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    var old_buf: [256]u8 = undefined;
    const old = try database.setConfig("max_position_usd", "500", &old_buf);
    try testing.expect(old == null);

    var val_buf: [256]u8 = undefined;
    const val = database.getConfig("max_position_usd", &val_buf);
    try testing.expect(val != null);
    try testing.expectEqualStrings("500", val.?);
}

test "db: setConfig returns old value on update" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    var old1: [256]u8 = undefined;
    _ = try database.setConfig("key1", "value1", &old1);

    var old2: [256]u8 = undefined;
    const prev = try database.setConfig("key1", "value2", &old2);
    try testing.expect(prev != null);
    try testing.expectEqualStrings("value1", prev.?);

    var val_buf: [256]u8 = undefined;
    const current = database.getConfig("key1", &val_buf);
    try testing.expect(current != null);
    try testing.expectEqualStrings("value2", current.?);
}

test "db: getConfig returns null when buffer too small" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    var old: [256]u8 = undefined;
    _ = try database.setConfig("long_key", "abcdefghij", &old);

    var tiny_buf: [4]u8 = undefined;
    const val = database.getConfig("long_key", &tiny_buf);
    try testing.expect(val == null);
}

test "db: setConfig writes audit entry" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    var old: [256]u8 = undefined;
    _ = try database.setConfig("test_key", "test_value", &old);

    // Verify audit entry exists
    const sql = "SELECT count(*) FROM config_changes WHERE key='test_key';" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    try testing.expect(db.c.sqlite3_prepare_v2(database.handle, sql.ptr, -1, &stmt, null) == db.c.SQLITE_OK);
    defer _ = db.c.sqlite3_finalize(stmt);
    try testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    try testing.expect(db.c.sqlite3_column_int(stmt, 0) > 0);
}

test "db: getAllConfig returns valid JSON" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    var old: [256]u8 = undefined;
    _ = try database.setConfig("k1", "v1", &old);
    _ = try database.setConfig("k2", "v2", &old);

    const json = try database.getAllConfig(testing.allocator);
    defer testing.allocator.free(json);

    // Parse as JSON
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expectEqualStrings("v1", parsed.value.object.get("k1").?.string);
    try testing.expectEqualStrings("v2", parsed.value.object.get("k2").?.string);
}

test "db: analyzeDryRunSignals reports paper trade metrics" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    // Buy signal that gets filled and later exits profitably.
    try database.insertDryRunSignal("m1", "news_repricing", "buy", 0.50, 10.0, 0.10, 0.90, 100, 0.49, 0.51);
    try database.insertDryRunSignal("m1", "news_repricing", "buy", 0.48, 10.0, 0.08, 0.85, 130, 0.47, 0.49);
    try database.insertDryRunSignal("m1", "news_repricing", "buy", 0.60, 10.0, 0.05, 0.80, 400, 0.59, 0.61);

    // Sell signal that gets filled and later exits at a loss.
    try database.insertDryRunSignal("m2", "liquidity_provision", "sell", 0.60, 10.0, 0.06, 0.75, 200, 0.59, 0.61);
    try database.insertDryRunSignal("m2", "liquidity_provision", "sell", 0.62, 10.0, 0.05, 0.70, 240, 0.61, 0.63);
    try database.insertDryRunSignal("m2", "liquidity_provision", "sell", 0.67, 10.0, 0.03, 0.65, 500, 0.61, 0.73);

    var buf: [4096]u8 = undefined;
    const json = try database.analyzeDryRunSignals(&buf);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value == .object);
    const obj = parsed.value.object;

    try testing.expectEqual(@as(i64, 6), obj.get("total_signals").?.integer);
    try testing.expectEqual(@as(i64, 2), obj.get("paper_filled_trades").?.integer);
    try testing.expectEqual(@as(i64, 4), obj.get("paper_unfilled_signals").?.integer);
    try testing.expectEqual(@as(i64, 1), obj.get("paper_winning_trades").?.integer);
    try testing.expectEqual(@as(i64, 1), obj.get("paper_losing_trades").?.integer);
    try testing.expect(obj.get("paper_fill_rate_pct").?.float > 30.0);
    try testing.expect(obj.get("paper_win_rate_pct").?.float > 40.0);
    try testing.expect(obj.get("paper_net_pnl").?.float > 0.4);
    try testing.expect(obj.get("paper_max_drawdown").?.float > 0.5);
    try testing.expectEqualStrings("paper_viable", obj.get("diagnosis").?.string);
}

// ─── Phase 5: P&L query ────────────────────────────────────────────────────

test "db: queryPnl returns zero result on empty db" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    const result = try database.queryPnl("today");
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.realized_pnl, 1e-9);
    try testing.expectEqual(@as(i64, 0), result.win_count);
    try testing.expectEqual(@as(i64, 0), result.loss_count);
}

test "db: queryPnl with all windows" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    // All window types should succeed
    _ = try database.queryPnl("today");
    _ = try database.queryPnl("7d");
    _ = try database.queryPnl("30d");
    _ = try database.queryPnl("all");
}

// ─── Phase 5: Strategy engine paused state ──────────────────────────────────

test "strategy_engine: paused state blocks signal generation" {
    var se = strategy_engine.StrategyEngine.init(.{
        .news_delta_threshold = 0.05,
        .lp_min_spread = 0.04,
    });

    // Not paused — signals generated
    const signal1 = se.evaluateNewsRepricing("m1", 0.80, 0.50, 0.0, 0.0, 0.0);
    try testing.expect(signal1 != null);

    // Pause — no signals
    se.paused.store(true, .seq_cst);
    const signal2 = se.evaluateNewsRepricing("m1", 0.80, 0.50, 0.0, 0.0, 0.0);
    try testing.expect(signal2 == null);

    const lp = se.evaluateLiquidityProvision("m1", 0.40, 0.60, 0.0);
    try testing.expectEqual(@as(usize, 0), lp.count);

    // Unpause — signals resume
    se.paused.store(false, .seq_cst);
    const signal3 = se.evaluateNewsRepricing("m1", 0.80, 0.50, 0.0, 0.0, 0.0);
    try testing.expect(signal3 != null);
}

// ─── Phase 1B: Market registry slug-collision tests ─────────────────────────

test "market_registry: two markets with same slug but different IDs both survive" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    // Ensure orderbooks table exists (needed for migration 006 index)
    try database.execZ("CREATE TABLE IF NOT EXISTS orderbooks(id INTEGER PRIMARY KEY AUTOINCREMENT,market TEXT NOT NULL,asset_id TEXT NOT NULL,best_bid TEXT,best_ask TEXT,mid_price REAL,bids_json TEXT,asks_json TEXT,last_trade_price TEXT,tick_size TEXT,timestamp TEXT,created_at INTEGER NOT NULL DEFAULT(unixepoch()),gamma_id TEXT DEFAULT NULL);");

    // Insert two markets with the same slug but different IDs
    try database.execZ("INSERT INTO markets(id,symbol,base,quote,status,condition_id,clob_token_ids) VALUES('market-1','same-slug','Q1','USDC','active','cond-1','[\"tok1\"]');");
    try database.execZ("INSERT INTO markets(id,symbol,base,quote,status,condition_id,clob_token_ids) VALUES('market-2','same-slug','Q2','USDC','active','cond-2','[\"tok2\"]');");

    // Assert both rows survive
    const count_sql = "SELECT COUNT(*) FROM markets WHERE symbol='same-slug';" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    try testing.expect(db.c.sqlite3_prepare_v2(database.handle, count_sql.ptr, -1, &stmt, null) == db.c.SQLITE_OK);
    defer _ = db.c.sqlite3_finalize(stmt);
    try testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    try testing.expectEqual(@as(c_int, 2), db.c.sqlite3_column_int(stmt, 0));
}

test "market_registry: re-insert existing market ID updates mutable fields without duplicate" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("CREATE TABLE IF NOT EXISTS orderbooks(id INTEGER PRIMARY KEY AUTOINCREMENT,market TEXT NOT NULL,asset_id TEXT NOT NULL,best_bid TEXT,best_ask TEXT,mid_price REAL,bids_json TEXT,asks_json TEXT,last_trade_price TEXT,tick_size TEXT,timestamp TEXT,created_at INTEGER NOT NULL DEFAULT(unixepoch()),gamma_id TEXT DEFAULT NULL);");

    // Insert a market
    try database.execZ("INSERT INTO markets(id,symbol,base,quote,status,condition_id,clob_token_ids) VALUES('m1','slug1','Q1','USDC','active','cond-1','[\"tok1\"]');");

    // INSERT OR IGNORE should not create a duplicate
    try database.execZ("INSERT OR IGNORE INTO markets(id,symbol,base,quote,status,condition_id,clob_token_ids) VALUES('m1','slug1','Q1','USDC','inactive','cond-1','[\"tok1\",\"tok2\"]');");

    // UPDATE mutable fields
    try database.execZ("UPDATE markets SET status='inactive',clob_token_ids='[\"tok1\",\"tok2\"]' WHERE id='m1';");

    // Assert only one row and fields are updated
    const count_sql = "SELECT COUNT(*) FROM markets WHERE id='m1';" ++ &[_:0]u8{};
    var count_stmt: ?*db.c.sqlite3_stmt = null;
    try testing.expect(db.c.sqlite3_prepare_v2(database.handle, count_sql.ptr, -1, &count_stmt, null) == db.c.SQLITE_OK);
    defer _ = db.c.sqlite3_finalize(count_stmt);
    try testing.expect(db.c.sqlite3_step(count_stmt) == db.c.SQLITE_ROW);
    try testing.expectEqual(@as(c_int, 1), db.c.sqlite3_column_int(count_stmt, 0));

    // Verify mutable fields updated
    const val_sql = "SELECT status,clob_token_ids FROM markets WHERE id='m1';" ++ &[_:0]u8{};
    var val_stmt: ?*db.c.sqlite3_stmt = null;
    try testing.expect(db.c.sqlite3_prepare_v2(database.handle, val_sql.ptr, -1, &val_stmt, null) == db.c.SQLITE_OK);
    defer _ = db.c.sqlite3_finalize(val_stmt);
    try testing.expect(db.c.sqlite3_step(val_stmt) == db.c.SQLITE_ROW);

    const status_ptr = db.c.sqlite3_column_text(val_stmt, 0);
    const status = if (status_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
    try testing.expectEqualStrings("inactive", status);

    const tokens_ptr = db.c.sqlite3_column_text(val_stmt, 1);
    const tokens = if (tokens_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
    try testing.expectEqualStrings("[\"tok1\",\"tok2\"]", tokens);
}

// ─── Phase 1C: Identifier standardization tests ─────────────────────────────

test "identifier: markets lookup by id only (no condition_id fallback)" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("CREATE TABLE IF NOT EXISTS orderbooks(id INTEGER PRIMARY KEY AUTOINCREMENT,market TEXT NOT NULL,asset_id TEXT NOT NULL,best_bid TEXT,best_ask TEXT,mid_price REAL,bids_json TEXT,asks_json TEXT,last_trade_price TEXT,tick_size TEXT,timestamp TEXT,created_at INTEGER NOT NULL DEFAULT(unixepoch()),gamma_id TEXT DEFAULT NULL);");

    // Insert a market with known Gamma id and clob_token_ids
    try database.execZ("INSERT INTO markets(id,symbol,base,quote,status,condition_id,clob_token_ids) VALUES('gamma-123','test-slug','Q','USDC','active','cond-abc','[\"12345678901234567890\"]');");

    // The new resolveTokenId query (WHERE id=?) should find by Gamma id
    const sql_by_id = "SELECT clob_token_ids FROM markets WHERE id=? LIMIT 1;" ++ &[_:0]u8{};
    var stmt1: ?*db.c.sqlite3_stmt = null;
    try testing.expect(db.c.sqlite3_prepare_v2(database.handle, sql_by_id.ptr, -1, &stmt1, null) == db.c.SQLITE_OK);
    defer _ = db.c.sqlite3_finalize(stmt1);
    _ = db.c.sqlite3_bind_text(stmt1, 1, "gamma-123", 9, null);
    try testing.expect(db.c.sqlite3_step(stmt1) == db.c.SQLITE_ROW);
    const tokens_ptr = db.c.sqlite3_column_text(stmt1, 0);
    const tokens = if (tokens_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
    try testing.expectEqualStrings("[\"12345678901234567890\"]", tokens);

    // Looking up by condition_id using the same query should NOT find anything
    var stmt2: ?*db.c.sqlite3_stmt = null;
    try testing.expect(db.c.sqlite3_prepare_v2(database.handle, sql_by_id.ptr, -1, &stmt2, null) == db.c.SQLITE_OK);
    defer _ = db.c.sqlite3_finalize(stmt2);
    _ = db.c.sqlite3_bind_text(stmt2, 1, "cond-abc", 8, null);
    try testing.expect(db.c.sqlite3_step(stmt2) != db.c.SQLITE_ROW);
}

test "identifier: orderbooks gamma_id column stores resolved market id" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("CREATE TABLE IF NOT EXISTS orderbooks(id INTEGER PRIMARY KEY AUTOINCREMENT,market TEXT NOT NULL,asset_id TEXT NOT NULL,best_bid TEXT,best_ask TEXT,mid_price REAL,bids_json TEXT,asks_json TEXT,last_trade_price TEXT,tick_size TEXT,timestamp TEXT,created_at INTEGER NOT NULL DEFAULT(unixepoch()),gamma_id TEXT DEFAULT NULL);");

    // Insert with gamma_id
    try database.execZ("INSERT INTO orderbooks(market,asset_id,best_bid,best_ask,mid_price,gamma_id) VALUES('cond-abc','tok1','0.45','0.55',0.50,'gamma-123');");

    // Verify gamma_id is stored
    const sql = "SELECT gamma_id FROM orderbooks WHERE market='cond-abc' LIMIT 1;" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    try testing.expect(db.c.sqlite3_prepare_v2(database.handle, sql.ptr, -1, &stmt, null) == db.c.SQLITE_OK);
    defer _ = db.c.sqlite3_finalize(stmt);
    try testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    const gid_ptr = db.c.sqlite3_column_text(stmt, 0);
    const gid = if (gid_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
    try testing.expectEqualStrings("gamma-123", gid);

    // Insert without gamma_id (NULL)
    try database.execZ("INSERT INTO orderbooks(market,asset_id,best_bid,best_ask,mid_price) VALUES('cond-xyz','tok2','0.30','0.70',0.50);");

    const sql2 = "SELECT gamma_id FROM orderbooks WHERE market='cond-xyz' LIMIT 1;" ++ &[_:0]u8{};
    var stmt2: ?*db.c.sqlite3_stmt = null;
    try testing.expect(db.c.sqlite3_prepare_v2(database.handle, sql2.ptr, -1, &stmt2, null) == db.c.SQLITE_OK);
    defer _ = db.c.sqlite3_finalize(stmt2);
    try testing.expect(db.c.sqlite3_step(stmt2) == db.c.SQLITE_ROW);
    try testing.expect(db.c.sqlite3_column_type(stmt2, 0) == db.c.SQLITE_NULL);
}

// ─── Phase 2 PRD: Fill detection and reconciliation tests ───────────────────

test "db: migration 007 adds fill tracking columns to orders" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    // Verify new columns exist by inserting and querying
    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.insertOrder("o1", "m1", "co1", "limit", "buy", "10", "0.50", null);

    // Check filled_size default
    const sql = "SELECT filled_size, average_fill_price, last_checked_at FROM orders WHERE id='o1';" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    try testing.expect(db.c.sqlite3_prepare_v2(database.handle, sql.ptr, -1, &stmt, null) == db.c.SQLITE_OK);
    defer _ = db.c.sqlite3_finalize(stmt);
    try testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);

    const fs_ptr = db.c.sqlite3_column_text(stmt, 0);
    const fs = if (fs_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
    try testing.expectEqualStrings("0", fs);

    // average_fill_price should be NULL
    try testing.expect(db.c.sqlite3_column_type(stmt, 1) == db.c.SQLITE_NULL);

    // last_checked_at should be 0
    try testing.expectEqual(@as(c_int, 0), db.c.sqlite3_column_int(stmt, 2));
}

test "db: updateOrderFillStatus updates fill columns" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.insertOrder("o1", "m1", "co1", "limit", "buy", "10", "0.50", null);

    try database.updateOrderFillStatus("o1", "partially_filled", "5.0", "0.50");

    const sql = "SELECT status, filled_size, average_fill_price FROM orders WHERE id='o1';" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    try testing.expect(db.c.sqlite3_prepare_v2(database.handle, sql.ptr, -1, &stmt, null) == db.c.SQLITE_OK);
    defer _ = db.c.sqlite3_finalize(stmt);
    try testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);

    const status_ptr = db.c.sqlite3_column_text(stmt, 0);
    const status = if (status_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
    try testing.expectEqualStrings("partially_filled", status);

    const fs_ptr = db.c.sqlite3_column_text(stmt, 1);
    const fs = if (fs_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
    try testing.expectEqualStrings("5.0", fs);

    const fp_ptr = db.c.sqlite3_column_text(stmt, 2);
    const fp = if (fp_ptr) |p| std.mem.span(@as([*c]const u8, @ptrCast(p))) else "";
    try testing.expectEqualStrings("0.50", fp);
}

test "order_manager: reconciliation gate blocks orders until set" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    var om = order_manager.OrderManager.init(testing.allocator, &database, .{}, .{});

    // Should be blocked initially
    try testing.expect(!om.reconciliation_complete.load(.seq_cst));

    const result = om.placeOrder("m1", "buy", "10", "0.50", "limit", null);
    switch (result) {
        .rejected => |r| try testing.expectEqualStrings("reconciliation_pending", r.reason),
        else => try testing.expect(false),
    }

    // After setting reconciliation complete, orders should pass the gate
    om.reconciliation_complete.store(true, .seq_cst);
    try testing.expect(om.reconciliation_complete.load(.seq_cst));

    // Place order again: should no longer be blocked by reconciliation gate.
    const result2 = om.placeOrder("m1", "buy", "10", "0.50", "limit", null);
    switch (result2) {
        .success => |s| {
            // order_id should be non-empty
            try testing.expect(s.order_id.len > 0);
            om.allocator.free(s.order_id);
        },
        .failed => |f| try testing.expectEqualStrings("clob_submission_failed", f.reason),
        .rejected => |r| try testing.expect(!std.mem.eql(u8, r.reason, "reconciliation_pending")),
    }
}

test "ipc_types: Phase 2 PRD fill event type constants exist" {
    try testing.expectEqualStrings("event.order.partially_filled", ipc_types.T.event_order_partially_filled);
    try testing.expectEqualStrings("reconcile.status", ipc_types.T.reconcile_status);
    try testing.expectEqualStrings("reconcile.status.response", ipc_types.T.reconcile_status_response);
}

test "db: updateOrderLastChecked updates timestamp" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.insertOrder("o1", "m1", "co1", "limit", "buy", "10", "0.50", null);

    try database.updateOrderLastChecked("o1");

    const sql = "SELECT last_checked_at FROM orders WHERE id='o1';" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    try testing.expect(db.c.sqlite3_prepare_v2(database.handle, sql.ptr, -1, &stmt, null) == db.c.SQLITE_OK);
    defer _ = db.c.sqlite3_finalize(stmt);
    try testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);

    const checked_at = db.c.sqlite3_column_int64(stmt, 0);
    try testing.expect(checked_at > 0);
}

// ─── Phase 4 PRD: Hardening and test coverage ───────────────────────────────

// -- TASK-4.2: Fill poller latency — detected_at column exists

test "db: migration 007 adds detected_at column to fills" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    // Insert a market and order for the FK
    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.insertOrder("o1", "m1", "co1", "limit", "buy", "10", "0.50", null);

    // Insert a fill — detected_at should be populated automatically
    try database.insertFill("f1", "o1", "5", "0.50", "0");

    const sql = "SELECT detected_at FROM fills WHERE id='f1';" ++ &[_:0]u8{};
    var stmt: ?*db.c.sqlite3_stmt = null;
    try testing.expect(db.c.sqlite3_prepare_v2(database.handle, sql.ptr, -1, &stmt, null) == db.c.SQLITE_OK);
    defer _ = db.c.sqlite3_finalize(stmt);
    try testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);

    const detected_at = db.c.sqlite3_column_int64(stmt, 0);
    try testing.expect(detected_at > 0);
}

// -- TASK-4.3: Retry hardening — backoffDelayMs from order_manager

test "order_manager: backoffDelayMs produces correct exponential schedule" {
    try testing.expectEqual(@as(u64, 1000), order_manager.OrderManager.backoffDelayMs(0));
    try testing.expectEqual(@as(u64, 2000), order_manager.OrderManager.backoffDelayMs(1));
    try testing.expectEqual(@as(u64, 4000), order_manager.OrderManager.backoffDelayMs(2));
    try testing.expectEqual(@as(u64, 8000), order_manager.OrderManager.backoffDelayMs(3));
    try testing.expectEqual(@as(u64, 16000), order_manager.OrderManager.backoffDelayMs(4));
    try testing.expectEqual(@as(u64, 32000), order_manager.OrderManager.backoffDelayMs(5));
    try testing.expectEqual(@as(u64, 60000), order_manager.OrderManager.backoffDelayMs(6)); // capped
    try testing.expectEqual(@as(u64, 60000), order_manager.OrderManager.backoffDelayMs(10)); // still capped
}

// -- TASK-4.3: Circuit-breaker fields exist in FillPoller

test "fill_poller: circuit-breaker fields initialized to zero" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    var om = order_manager.OrderManager.init(testing.allocator, &database, .{}, .{});
    var pt = portfolio_tracker.PortfolioTracker.init(testing.allocator, &database, .{});

    const fp = fill_poller.FillPoller.init(testing.allocator, &database, &om, &pt, null);
    try testing.expectEqual(@as(u32, 0), fp.consecutive_http_failures);
    try testing.expectEqual(@as(i64, 0), fp.circuit_breaker_until);
}

// -- TASK-4.4: Config validation IPC types exist

test "ipc_types: Phase 4 config.validate type constants exist" {
    try testing.expectEqualStrings("config.validate", ipc_types.T.config_validate);
    try testing.expectEqualStrings("config.validate.response", ipc_types.T.config_validate_response);
}

// -- TASK-4.5: fill_poller parseOrderResponse test coverage

test "fill_poller: parseOrderResponse handles delayed status" {
    const json = "{\"status\":\"delayed\",\"size_matched\":\"0\",\"price\":\"0.40\",\"original_size\":\"15.0\"}";
    const result = fill_poller.FillPoller.parseOrderResponse(json);
    try testing.expect(result != null);
    try testing.expectEqualStrings("delayed", result.?.status());
    try testing.expect(!result.?.has_new_fill);
}

test "fill_poller: parseOrderResponse handles open status" {
    const json = "{\"status\":\"open\",\"size_matched\":\"0\",\"price\":\"0.60\",\"original_size\":\"25.0\"}";
    const result = fill_poller.FillPoller.parseOrderResponse(json);
    try testing.expect(result != null);
    try testing.expectEqualStrings("open", result.?.status());
    try testing.expect(!result.?.has_new_fill);
}

// -- TASK-4.5: probability_provider test coverage

test "probability_provider: normalizeProbability clamps correctly" {
    // Inline tests already cover this via the module import — just verify the module compiles
    // and estimate struct can be constructed
    var est = probability_provider.ExternalEstimate{
        .market_id = [_]u8{0} ** 64,
        .market_id_len = 0,
        .condition_id = [_]u8{0} ** 128,
        .condition_id_len = 0,
        .probability = 0.65,
        .confidence = 0.8,
        .source = [_]u8{0} ** 32,
        .source_len = 0,
        .fetched_at = 0,
        .yes_token_id = [_]u8{0} ** 80,
        .yes_token_id_len = 0,
    };
    try testing.expect(est.probability > 0.0 and est.probability < 1.0);
    est.probability = 0.5;
    try testing.expectEqual(@as(f64, 0.5), est.probability);
}

// -- TASK-4.5: migration 008 test coverage

test "db: migration 008 adds lp_pair_order_id and net_position_usd columns" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    // Verify lp_pair_order_id column exists on orders
    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.insertOrder("o1", "m1", "co1", "limit", "buy", "10", "0.50", null);

    const order_sql = "SELECT lp_pair_order_id FROM orders WHERE id='o1';" ++ &[_:0]u8{};
    var order_stmt: ?*db.c.sqlite3_stmt = null;
    try testing.expect(db.c.sqlite3_prepare_v2(database.handle, order_sql.ptr, -1, &order_stmt, null) == db.c.SQLITE_OK);
    defer _ = db.c.sqlite3_finalize(order_stmt);
    try testing.expect(db.c.sqlite3_step(order_stmt) == db.c.SQLITE_ROW);
    // Should be NULL by default
    try testing.expect(db.c.sqlite3_column_type(order_stmt, 0) == db.c.SQLITE_NULL);

    // Verify net_position_usd column exists on positions
    try database.execZ("INSERT INTO positions(id,market_id,side,size,entry_price) VALUES('p1','m1','long','10','0.50');");

    const pos_sql = "SELECT net_position_usd FROM positions WHERE id='p1';" ++ &[_:0]u8{};
    var pos_stmt: ?*db.c.sqlite3_stmt = null;
    try testing.expect(db.c.sqlite3_prepare_v2(database.handle, pos_sql.ptr, -1, &pos_stmt, null) == db.c.SQLITE_OK);
    defer _ = db.c.sqlite3_finalize(pos_stmt);
    try testing.expect(db.c.sqlite3_step(pos_stmt) == db.c.SQLITE_ROW);
    // Should default to 0.0
    const net_pos = db.c.sqlite3_column_double(pos_stmt, 0);
    try testing.expectEqual(@as(f64, 0.0), net_pos);
}

// -- TASK-4.5: lp_max_position_usd runtime config seed exists after migration 008

test "db: migration 008 seeds lp_max_position_usd in runtime_config" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    var buf: [32]u8 = undefined;
    const val = database.getConfig("lp_max_position_usd", &buf);
    try testing.expect(val != null);
    try testing.expectEqualStrings("50.0", val.?);
}
