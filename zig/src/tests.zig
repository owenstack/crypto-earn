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
        .max_position_usd = 500.0,
        .max_portfolio_exposure_usd = 5000.0,
        .max_daily_drawdown_usd = 200.0,
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
        .max_position_usd = 100.0,
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
        .max_position_usd = 250.0,
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

    // Insert a market first (required by foreign key)
    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");

    // Insert max_open_orders pending orders
    const config = risk_gate.RiskConfig{
        .max_open_orders = 2,
    };

    try database.insertOrder("o1", "m1", "co1", "limit", "buy", "10", "0.50");
    try database.insertOrder("o2", "m1", "co2", "limit", "sell", "10", "0.50");

    const request = risk_gate.OrderRequest{
        .market_id = "m1",
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

test "risk_gate: rejects duplicate position" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    // Insert a market and an open long position
    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.execZ("INSERT INTO positions(id,market_id,side,size,entry_price,status) VALUES('p1','m1','long','10','0.50','open');");

    const config = risk_gate.RiskConfig{
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

test "risk_gate: allows duplicate when configured" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.execZ("INSERT INTO positions(id,market_id,side,size,entry_price,status) VALUES('p1','m1','long','10','0.50','open');");

    const config = risk_gate.RiskConfig{
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
    const result = om.placeOrder("m1", "buy", "10", "0.50", "limit");
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

test "db: insertOrder and queryOpenOrderCount" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");

    const count_before = try database.queryOpenOrderCount();
    try testing.expectEqual(@as(u32, 0), count_before);

    try database.insertOrder("o1", "m1", "co1", "limit", "buy", "10", "0.50");
    const count_after = try database.queryOpenOrderCount();
    try testing.expectEqual(@as(u32, 1), count_after);
}

test "db: updateOrderStatus" {
    var database = try openTempDb();
    defer database.close();
    try database.runMigrations();

    try database.execZ("INSERT INTO markets(id,symbol,base,quote) VALUES('m1','SYM','B','Q');");
    try database.insertOrder("o1", "m1", "co1", "limit", "buy", "10", "0.50");

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
