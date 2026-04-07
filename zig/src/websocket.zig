//! WebSocket client with auto-reconnect and subscription management.
//! Connects to Polymarket CLOB WebSocket for real-time orderbook feeds.
const std = @import("std");
const log = @import("logger.zig");
const ws_lib = @import("websocket");

pub const WS_HOST = "ws-subscriptions-clob.polymarket.com";
pub const WS_PATH = "/ws/market";

pub const EventType = enum {
    book,
    price_change,
    last_trade_price,
    tick_size_change,
    best_bid_ask,
    new_market,
    market_resolved,
    unknown,
};

pub const PriceUpdate = struct {
    asset_id: []const u8,
    market: []const u8,
    best_bid: []const u8,
    best_ask: []const u8,
    timestamp: []const u8,
    event_type: []const u8,
};

pub const WebSocketState = enum {
    disconnected,
    connecting,
    connected,
};

/// Callback type for price updates.
pub const PriceCallback = *const fn (update: PriceUpdate) void;

pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    state: WebSocketState,
    subscriptions: std.ArrayList([]const u8),
    reconnect_delay_ms: u64,
    max_reconnect_delay_ms: u64,
    callback: ?PriceCallback,
    should_stop: std.atomic.Value(bool),
    mu: std.Thread.Mutex,
    live_client: ?*ws_lib.Client,

    const INITIAL_RECONNECT_MS: u64 = 1_000;
    const MAX_RECONNECT_MS: u64 = 30_000;

    pub fn init(allocator: std.mem.Allocator) WebSocketClient {
        return .{
            .allocator = allocator,
            .state = .disconnected,
            .subscriptions = .empty,
            .reconnect_delay_ms = INITIAL_RECONNECT_MS,
            .max_reconnect_delay_ms = MAX_RECONNECT_MS,
            .callback = null,
            .should_stop = std.atomic.Value(bool).init(false),
            .mu = .{},
            .live_client = null,
        };
    }

    pub fn stop(self: *WebSocketClient) void {
        self.should_stop.store(true, .seq_cst);
    }

    pub fn deinit(self: *WebSocketClient) void {
        for (self.subscriptions.items) |sub| {
            self.allocator.free(sub);
        }
        self.subscriptions.deinit(self.allocator);
    }

    pub fn setCallback(self: *WebSocketClient, cb: PriceCallback) void {
        self.callback = cb;
    }

    /// Add a subscription for an asset_id. Thread-safe.
    /// If a live connection exists, sends a dynamic subscribe message immediately.
    pub fn subscribe(self: *WebSocketClient, asset_id: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();

        // Avoid duplicate subscriptions
        for (self.subscriptions.items) |existing| {
            if (std.mem.eql(u8, existing, asset_id)) return;
        }
        const copy = try self.allocator.dupe(u8, asset_id);
        try self.subscriptions.append(self.allocator, copy);
        log.info("ws", "subscribed to {s}", .{asset_id[0..@min(asset_id.len, 20)]});

        // If connected, send a dynamic subscribe for this single asset
        if (self.live_client) |client| {
            var dyn_buf: [4096]u8 = undefined;
            const dyn_msg = buildDynamicSubscribe(&dyn_buf, asset_id) catch return;
            var mut_buf: [4096]u8 = undefined;
            const len = dyn_msg.len;
            @memcpy(mut_buf[0..len], dyn_msg);
            client.write(mut_buf[0..len]) catch |e| {
                log.err("ws", "failed to send dynamic subscribe: {s}", .{@errorName(e)});
            };
        }
    }

    /// Build the subscription JSON message for all tracked asset_ids.
    /// Caller must hold `mu` when called from multi-threaded context.
    pub fn buildSubscriptionMessage(self: *WebSocketClient, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();
        try writer.writeAll("{\"assets_ids\":[");
        for (self.subscriptions.items, 0..) |sub, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{sub});
        }
        try writer.writeAll("],\"type\":\"market\",\"custom_feature_enabled\":true}");
        return fbs.getWritten();
    }

    /// Build a dynamic subscribe message for a single asset_id.
    fn buildDynamicSubscribe(buf: []u8, asset_id: []const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();
        try writer.print("{{\"assets_ids\":[\"{s}\"],\"operation\":\"subscribe\",\"custom_feature_enabled\":true}}", .{asset_id});
        return fbs.getWritten();
    }

    /// Connect and run the WebSocket read loop. Blocks.
    /// On disconnect, reconnects with exponential backoff (1s -> 30s).
    /// Call from a dedicated thread.
    pub fn connectAndRun(self: *WebSocketClient) void {
        while (!self.should_stop.load(.seq_cst)) {
            self.state = .connecting;
            log.info("ws", "connecting to Polymarket CLOB WebSocket...", .{});

            self.runConnection() catch |e| {
                log.err("ws", "connection error: {s}", .{@errorName(e)});
            };

            if (self.should_stop.load(.seq_cst)) break;

            self.state = .disconnected;
            log.warn("ws", "disconnected, reconnecting in {d}ms", .{self.reconnect_delay_ms});
            std.Thread.sleep(self.reconnect_delay_ms * std.time.ns_per_ms);
            self.reconnect_delay_ms = @min(self.reconnect_delay_ms * 2, self.max_reconnect_delay_ms);
        }
        self.state = .disconnected;
    }

    fn runConnection(self: *WebSocketClient) !void {
        var client = try ws_lib.Client.init(self.allocator, .{
            .host = WS_HOST,
            .port = 443,
            .tls = true,
            .max_size = 8 * 1024 * 1024,
        });
        defer client.deinit();

        try client.handshake(WS_PATH, .{
            .timeout_ms = 10_000,
            .headers = "Host: " ++ WS_HOST ++ "\r\n",
        });

        self.state = .connected;
        self.resetBackoff();

        // Register live client so subscribe() can send dynamic messages
        self.mu.lock();
        self.live_client = &client;
        const sub_count = self.subscriptions.items.len;
        self.mu.unlock();

        defer {
            self.mu.lock();
            self.live_client = null;
            self.mu.unlock();
        }

        log.info("ws", "connected, sending subscriptions ({d} assets)", .{sub_count});

        // Send initial subscription for all tracked assets
        if (sub_count > 0) {
            var sub_buf: [65536]u8 = undefined;
            self.mu.lock();
            const sub_msg = self.buildSubscriptionMessage(&sub_buf) catch |e| {
                self.mu.unlock();
                log.err("ws", "failed to build subscription message: {s}", .{@errorName(e)});
                return e;
            };
            // Copy before releasing lock since sub_msg points into sub_buf (safe, but be explicit)
            var mut_buf: [65536]u8 = undefined;
            const len = sub_msg.len;
            @memcpy(mut_buf[0..len], sub_msg);
            self.mu.unlock();

            client.write(mut_buf[0..len]) catch |e| {
                log.err("ws", "failed to send subscription: {s}", .{@errorName(e)});
                return e;
            };
            log.info("ws", "subscription message sent", .{});
        }

        // Read loop with periodic PING heartbeats (Polymarket requires PING every 10s)
        try client.readTimeout(5_000); // 5s read timeout so we can interleave PINGs
        var last_ping_ns: i128 = std.time.nanoTimestamp();
        const ping_interval_ns: i128 = 8 * std.time.ns_per_s; // Send PING every 8s (server expects <10s)

        while (!self.should_stop.load(.seq_cst)) {
            // Send PING if interval elapsed
            const now_ns = std.time.nanoTimestamp();
            if (now_ns - last_ping_ns >= ping_interval_ns) {
                var ping_buf = [_]u8{ 'P', 'I', 'N', 'G' };
                client.write(&ping_buf) catch |e| {
                    log.err("ws", "failed to send PING: {s}", .{@errorName(e)});
                    return e;
                };
                last_ping_ns = now_ns;
            }

            // Try to read a message (returns null on timeout)
            const message = client.read() catch |err| switch (err) {
                error.Closed => return,
                else => return err,
            } orelse continue;

            defer client.done(message);

            switch (message.type) {
                .text, .binary => {
                    self.handleMessage(message.data);
                },
                .close => return,
                .ping, .pong => {},
            }
        }
    }

    /// Parse incoming WebSocket message and invoke callback.
    fn handleMessage(self: *WebSocketClient, data: []const u8) void {
        // Skip PONG heartbeat responses (text "PONG" from Polymarket)
        if (data.len == 4 and std.mem.eql(u8, data, "PONG")) return;
        // Skip empty arrays (server sends "[]" on subscription ack)
        if (data.len <= 2 and std.mem.eql(u8, data[0..@min(data.len, 2)], "[]")) return;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
            log.warn("ws", "failed to parse WS message", .{});
            return;
        };
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return,
        };

        const event_type_str = if (root.get("event_type")) |v| switch (v) {
            .string => |s| s,
            else => "unknown",
        } else "unknown";

        const event = parseEventType(event_type_str);

        switch (event) {
            .book => handleBookEvent(self, root),
            .price_change => handlePriceChangeEvent(self, root),
            .last_trade_price => handleLastTradeEvent(self, root),
            .best_bid_ask => handleBestBidAskEvent(self, root),
            .tick_size_change => handleTickSizeChangeEvent(self, root),
            .unknown, .new_market, .market_resolved => {},
        }
    }

    /// Reset reconnect delay on successful connection.
    fn resetBackoff(self: *WebSocketClient) void {
        self.reconnect_delay_ms = INITIAL_RECONNECT_MS;
    }
};

fn parseEventType(s: []const u8) EventType {
    if (std.mem.eql(u8, s, "book")) return .book;
    if (std.mem.eql(u8, s, "price_change")) return .price_change;
    if (std.mem.eql(u8, s, "last_trade_price")) return .last_trade_price;
    if (std.mem.eql(u8, s, "tick_size_change")) return .tick_size_change;
    if (std.mem.eql(u8, s, "best_bid_ask")) return .best_bid_ask;
    if (std.mem.eql(u8, s, "new_market")) return .new_market;
    if (std.mem.eql(u8, s, "market_resolved")) return .market_resolved;
    return .unknown;
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    return if (obj.get(key)) |v| switch (v) {
        .string => |s| s,
        else => "",
    } else "";
}

fn handleBookEvent(self: *WebSocketClient, root: std.json.ObjectMap) void {
    // Full orderbook snapshot: has bids[], asks[], market, asset_id, timestamp
    const asset_id = jsonStr(root, "asset_id");
    const market = jsonStr(root, "market");
    const timestamp = jsonStr(root, "timestamp");

    // Extract best bid/ask from the bids/asks arrays
    var best_bid: []const u8 = "0";
    var best_ask: []const u8 = "0";

    if (root.get("bids")) |bids_val| {
        if (bids_val == .array and bids_val.array.items.len > 0) {
            if (bids_val.array.items[0] == .object) {
                best_bid = jsonStr(bids_val.array.items[0].object, "price");
            }
        }
    }
    if (root.get("asks")) |asks_val| {
        if (asks_val == .array and asks_val.array.items.len > 0) {
            if (asks_val.array.items[0] == .object) {
                best_ask = jsonStr(asks_val.array.items[0].object, "price");
            }
        }
    }

    if (self.callback) |cb| {
        cb(.{
            .asset_id = asset_id,
            .market = market,
            .best_bid = best_bid,
            .best_ask = best_ask,
            .timestamp = timestamp,
            .event_type = "book",
        });
    }
}

fn handlePriceChangeEvent(self: *WebSocketClient, root: std.json.ObjectMap) void {
    const market = jsonStr(root, "market");
    const timestamp = jsonStr(root, "timestamp");

    // price_change events: asset_id, best_bid, best_ask are inside each price_changes[] entry
    if (root.get("price_changes")) |changes_val| {
        if (changes_val == .array) {
            for (changes_val.array.items) |change| {
                if (change == .object) {
                    const change_asset_id = jsonStr(change.object, "asset_id");
                    const best_bid = jsonStr(change.object, "best_bid");
                    const best_ask = jsonStr(change.object, "best_ask");

                    if (self.callback) |cb| {
                        cb(.{
                            .asset_id = change_asset_id,
                            .market = market,
                            .best_bid = best_bid,
                            .best_ask = best_ask,
                            .timestamp = timestamp,
                            .event_type = "price_change",
                        });
                    }
                }
            }
        }
    }
}

fn handleLastTradeEvent(self: *WebSocketClient, root: std.json.ObjectMap) void {
    const asset_id = jsonStr(root, "asset_id");
    const market = jsonStr(root, "market");
    const price = jsonStr(root, "price");
    const timestamp = jsonStr(root, "timestamp");

    if (self.callback) |cb| {
        cb(.{
            .asset_id = asset_id,
            .market = market,
            .best_bid = price,
            .best_ask = price,
            .timestamp = timestamp,
            .event_type = "last_trade_price",
        });
    }
}

fn handleBestBidAskEvent(self: *WebSocketClient, root: std.json.ObjectMap) void {
    const asset_id = jsonStr(root, "asset_id");
    const market = jsonStr(root, "market");
    const best_bid = jsonStr(root, "best_bid");
    const best_ask = jsonStr(root, "best_ask");
    const timestamp = jsonStr(root, "timestamp");

    if (self.callback) |cb| {
        cb(.{
            .asset_id = asset_id,
            .market = market,
            .best_bid = best_bid,
            .best_ask = best_ask,
            .timestamp = timestamp,
            .event_type = "best_bid_ask",
        });
    }
}

fn handleTickSizeChangeEvent(_: *WebSocketClient, root: std.json.ObjectMap) void {
    const asset_id = jsonStr(root, "asset_id");
    const old = jsonStr(root, "old_tick_size");
    const new = jsonStr(root, "new_tick_size");
    log.warn("ws", "tick_size_change for {s}: {s} -> {s}", .{
        asset_id[0..@min(asset_id.len, 20)],
        old,
        new,
    });
}

test "websocket: init and deinit" {
    var ws_client = WebSocketClient.init(std.testing.allocator);
    defer ws_client.deinit();
    try std.testing.expectEqual(WebSocketState.disconnected, ws_client.state);
}

test "websocket: subscribe adds to list" {
    var ws_client = WebSocketClient.init(std.testing.allocator);
    defer ws_client.deinit();
    try ws_client.subscribe("test-asset-id-123");
    try std.testing.expectEqual(@as(usize, 1), ws_client.subscriptions.items.len);
}

test "websocket: subscribe deduplicates" {
    var ws_client = WebSocketClient.init(std.testing.allocator);
    defer ws_client.deinit();
    try ws_client.subscribe("asset1");
    try ws_client.subscribe("asset1");
    try std.testing.expectEqual(@as(usize, 1), ws_client.subscriptions.items.len);
}

test "websocket: buildSubscriptionMessage" {
    var ws_client = WebSocketClient.init(std.testing.allocator);
    defer ws_client.deinit();
    try ws_client.subscribe("asset1");
    try ws_client.subscribe("asset2");
    var buf: [4096]u8 = undefined;
    const msg = try ws_client.buildSubscriptionMessage(&buf);
    var parsed_msg = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, msg, .{});
    defer parsed_msg.deinit();
    try std.testing.expect(parsed_msg.value == .object);
    // Verify custom_feature_enabled is present and true
    const cfe = parsed_msg.value.object.get("custom_feature_enabled").?;
    try std.testing.expect(cfe == .bool);
    try std.testing.expect(cfe.bool == true);
}

test "websocket: exponential backoff constants" {
    var ws_client = WebSocketClient.init(std.testing.allocator);
    defer ws_client.deinit();
    try std.testing.expectEqual(@as(u64, 1_000), ws_client.reconnect_delay_ms);
    try std.testing.expectEqual(@as(u64, 30_000), ws_client.max_reconnect_delay_ms);
}

test "websocket: parseEventType" {
    try std.testing.expectEqual(EventType.book, parseEventType("book"));
    try std.testing.expectEqual(EventType.price_change, parseEventType("price_change"));
    try std.testing.expectEqual(EventType.best_bid_ask, parseEventType("best_bid_ask"));
    try std.testing.expectEqual(EventType.unknown, parseEventType("garbage"));
}
