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


