const std = @import("std");
const testing = std.testing;
const log = @import("logger.zig");
const ipc_types = @import("ipc_types.zig");
const db = @import("db.zig");

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
    var rng = std.rand.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        std.os.getrandom(std.mem.asBytes(&seed)) catch break :blk 0;
        break :blk seed;
    });
    const random = rng.random();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/cex-test-wal-{d}.db", .{random.int(u32)});

    var database = try db.DB.open(path);
    defer {
        database.close();
        std.fs.cwd().deleteFile(path) catch {};
        // Also clean up WAL/SHM files
        std.fs.cwd().deleteFile(path ++ "-wal") catch {};
        std.fs.cwd().deleteFile(path ++ "-shm") catch {};
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
