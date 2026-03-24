const std = @import("std");

pub fn BoundedChannel(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const SendResult = enum {
            ok,
            dropped,
            closed,
        };

        buffer: [capacity]T = undefined,
        head: usize = 0,
        count: usize = 0,
        mutex: std.Thread.Mutex = .{},
        not_empty: std.Thread.Condition = .{},
        is_closed: bool = false,

        pub fn init() Self {
            return .{};
        }

        pub fn send(self: *Self, item: T) SendResult {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed) return .closed;

            if (self.count == capacity) {
                // Drop oldest: advance head
                self.buffer[self.head] = item;
                self.head = (self.head + 1) % capacity;
                // count stays at capacity
                self.not_empty.signal();
                return .dropped;
            }

            const tail = (self.head + self.count) % capacity;
            self.buffer[tail] = item;
            self.count += 1;
            self.not_empty.signal();
            return .ok;
        }

        pub fn receive(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count == 0) {
                if (self.is_closed) return null;
                self.not_empty.wait(&self.mutex);
            }

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            return item;
        }

        pub fn tryReceive(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count == 0) return null;

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            return item;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.is_closed = true;
            self.not_empty.broadcast();
        }
    };
}

// --- Tests ---

test "fifo order" {
    var ch = BoundedChannel(u32, 4).init();
    _ = ch.send(1);
    _ = ch.send(2);
    _ = ch.send(3);

    try std.testing.expectEqual(@as(u32, 1), ch.receive().?);
    try std.testing.expectEqual(@as(u32, 2), ch.receive().?);
    try std.testing.expectEqual(@as(u32, 3), ch.receive().?);
}

test "full capacity drop oldest" {
    var ch = BoundedChannel(u32, 3).init();
    try std.testing.expectEqual(.ok, ch.send(1));
    try std.testing.expectEqual(.ok, ch.send(2));
    try std.testing.expectEqual(.ok, ch.send(3));
    // Buffer full: [1, 2, 3]. Sending 4 should drop 1.
    try std.testing.expectEqual(.dropped, ch.send(4));
    // Now buffer should be [2, 3, 4].
    try std.testing.expectEqual(@as(u32, 2), ch.receive().?);
    try std.testing.expectEqual(@as(u32, 3), ch.receive().?);
    try std.testing.expectEqual(@as(u32, 4), ch.receive().?);
}

test "empty tryReceive returns null" {
    var ch = BoundedChannel(u32, 4).init();
    try std.testing.expectEqual(@as(?u32, null), ch.tryReceive());
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
        try std.testing.expectEqual(.ok, ch.send(@as(i32, @intCast(i))));
    }

    for (0..count) |i| {
        try std.testing.expectEqual(@as(i32, @intCast(i)), ch.receive().?);
    }

    // Channel should be empty now
    try std.testing.expectEqual(@as(?i32, null), ch.tryReceive());
}
