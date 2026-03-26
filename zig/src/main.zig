const std = @import("std");
const log = @import("logger.zig");
const db = @import("db.zig");
const ipc = @import("ipc.zig");
const scanner = @import("market_scanner.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.init();
    log.info("engine", "starting cex-engine", .{});

    // Read config from environment
    const db_path = std.posix.getenv("DB_PATH") orelse "./data/cex.db";
    const socket_path = std.posix.getenv("IPC_SOCKET") orelse "/tmp/cex-engine.sock";

    // Ensure data directory exists
    std.fs.cwd().makeDir("data") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    // Allocate null-terminated DB path
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);

    log.info("engine", "opening db: {s}", .{db_path});
    var database = try db.DB.open(db_path_z);
    defer database.close();

    try database.runMigrations();
    log.info("engine", "db ready", .{});

    // Spawn market scanner thread
    var scan = scanner.Scanner.init(allocator, &database, .{});
    const scanner_thread = try std.Thread.spawn(.{}, scanner.Scanner.run, .{&scan});
    defer {
        scan.stop();
        scanner_thread.join();
        scan.deinit();
    }
    log.info("engine", "market scanner started", .{});

    // Start IPC server (blocks)
    try ipc.serve(allocator, socket_path, &database);
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
