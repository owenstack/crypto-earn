//! Unit tests for the bounded channel.

const std = @import("std");
const testing = std.testing;
const cex = @import("cex_zig");
const BoundedChannel = cex.channel.BoundedChannel;

test "fifo order" {
    var ch = BoundedChannel(u32, 4).init();
    _ = ch.send(1);
    _ = ch.send(2);
    _ = ch.send(3);

    try testing.expectEqual(@as(u32, 1), ch.receive().?);
    try testing.expectEqual(@as(u32, 2), ch.receive().?);
    try testing.expectEqual(@as(u32, 3), ch.receive().?);
}

test "full capacity drop oldest" {
    var ch = BoundedChannel(u32, 3).init();
    try testing.expectEqual(.ok, ch.send(1));
    try testing.expectEqual(.ok, ch.send(2));
    try testing.expectEqual(.ok, ch.send(3));
    // Buffer full: [1, 2, 3]. Sending 4 should drop 1.
    try testing.expectEqual(.dropped, ch.send(4));
    // Now buffer should be [2, 3, 4].
    try testing.expectEqual(@as(u32, 2), ch.receive().?);
    try testing.expectEqual(@as(u32, 3), ch.receive().?);
    try testing.expectEqual(@as(u32, 4), ch.receive().?);
}

test "empty tryReceive returns null" {
    var ch = BoundedChannel(u32, 4).init();
    try testing.expectEqual(@as(?u32, null), ch.tryReceive());
}

test "close wakes blocked receivers" {
    var ch = BoundedChannel(u32, 4).init();

    const handle = try std.Thread.spawn(.{}, struct {
        fn run(channel: *BoundedChannel(u32, 4)) void {
            // This will block until close() is called
            const val = channel.receive();
            std.debug.assert(val == null);
        }
    }.run, .{&ch});

    // Give the thread time to block on receive
    std.Thread.sleep(10 * std.time.ns_per_ms);
    ch.close();
    handle.join();
}

test "multiple items enqueue dequeue" {
    var ch = BoundedChannel(i32, 8).init();
    const count = 8;

    for (0..count) |i| {
        try testing.expectEqual(.ok, ch.send(@as(i32, @intCast(i))));
    }

    for (0..count) |i| {
        try testing.expectEqual(@as(i32, @intCast(i)), ch.receive().?);
    }

    // Channel should be empty now
    try testing.expectEqual(@as(?i32, null), ch.tryReceive());
}
