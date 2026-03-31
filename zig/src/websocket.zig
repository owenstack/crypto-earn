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

    const INITIAL_RECONNECT_MS: u64 = 250;
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

    /// Add a subscription for an asset_id. Will be sent when connected.
    pub fn subscribe(self: *WebSocketClient, asset_id: []const u8) !void {
        // Avoid duplicate subscriptions
        for (self.subscriptions.items) |existing| {
            if (std.mem.eql(u8, existing, asset_id)) return;
        }
        const copy = try self.allocator.dupe(u8, asset_id);
        try self.subscriptions.append(self.allocator, copy);
        log.info("ws", "subscribed to {s}", .{asset_id[0..@min(asset_id.len, 20)]});
    }

    /// Build the subscription JSON message for all tracked asset_ids.
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
        try writer.print("{{\"assets_ids\":[\"{s}\"],\"operation\":\"subscribe\"}}", .{asset_id});
        return fbs.getWritten();
    }

    /// Connect and run the WebSocket read loop. Blocks.
    /// On disconnect, reconnects with exponential backoff (250ms -> 30s).
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
        });
        defer client.deinit();

        try client.handshake(WS_PATH, .{
            .timeout_ms = 10_000,
            .headers = "Host: " ++ WS_HOST ++ "\r\n",
        });

        self.state = .connected;
        self.resetBackoff();
        log.info("ws", "connected, sending subscriptions ({d} assets)", .{self.subscriptions.items.len});

        // Send initial subscription for all tracked assets
        if (self.subscriptions.items.len > 0) {
            var sub_buf: [65536]u8 = undefined;
            const sub_msg = self.buildSubscriptionMessage(&sub_buf) catch |e| {
                log.err("ws", "failed to build subscription message: {s}", .{@errorName(e)});
                return e;
            };
            // websocket.zig client.write takes []u8 (mutable for masking)
            var mut_buf: [65536]u8 = undefined;
            const len = sub_msg.len;
            @memcpy(mut_buf[0..len], sub_msg);
            client.write(mut_buf[0..len]) catch |e| {
                log.err("ws", "failed to send subscription: {s}", .{@errorName(e)});
                return e;
            };
            log.info("ws", "subscription message sent", .{});
        }

        // Read loop — blocks until disconnect or error
        var handler = Handler{ .ws_client = self };
        try client.readLoop(&handler);
    }

    /// Parse incoming WebSocket message and invoke callback.
    fn handleMessage(self: *WebSocketClient, data: []const u8) void {
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

/// Handler for incoming WebSocket messages from the karlseguin/websocket.zig read loop.
const Handler = struct {
    ws_client: *WebSocketClient,

    pub fn serverMessage(self: *Handler, data: []u8) !void {
        self.ws_client.handleMessage(data);
    }

    pub fn close(_: *Handler) void {}
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
    const asset_id = jsonStr(root, "asset_id");
    const market = jsonStr(root, "market");
    const timestamp = jsonStr(root, "timestamp");

    // price_change events include price_changes[] with best_bid, best_ask
    if (root.get("changes")) |changes_val| {
        if (changes_val == .array) {
            for (changes_val.array.items) |change| {
                if (change == .object) {
                    const best_bid = jsonStr(change.object, "best_bid");
                    const best_ask = jsonStr(change.object, "best_ask");

                    if (self.callback) |cb| {
                        // Use JSON timestamp if present, else heap-allocate
                        var ts_heap: ?[]u8 = null;
                        const ts_final = if (timestamp.len > 0) timestamp else blk: {
                            var ts_buf: [32]u8 = undefined;
                            const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch "0";
                            ts_heap = self.allocator.dupe(u8, ts_str) catch null;
                            break :blk if (ts_heap) |h| h else "0";
                        };
                        cb(.{
                            .asset_id = asset_id,
                            .market = market,
                            .best_bid = best_bid,
                            .best_ask = best_ask,
                            .timestamp = ts_final,
                            .event_type = "price_change",
                        });
                        if (ts_heap) |h| self.allocator.free(h);
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
        var ts_heap: ?[]u8 = null;
        const ts_final = if (timestamp.len > 0) timestamp else blk: {
            var ts_buf: [32]u8 = undefined;
            const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch "0";
            ts_heap = self.allocator.dupe(u8, ts_str) catch null;
            break :blk if (ts_heap) |h| h else "0";
        };
        cb(.{
            .asset_id = asset_id,
            .market = market,
            .best_bid = price,
            .best_ask = price,
            .timestamp = ts_final,
            .event_type = "last_trade_price",
        });
        if (ts_heap) |h| self.allocator.free(h);
    }
}

fn handleBestBidAskEvent(self: *WebSocketClient, root: std.json.ObjectMap) void {
    const asset_id = jsonStr(root, "asset_id");
    const market = jsonStr(root, "market");
    const best_bid = jsonStr(root, "best_bid");
    const best_ask = jsonStr(root, "best_ask");
    const timestamp = jsonStr(root, "timestamp");

    if (self.callback) |cb| {
        var ts_heap: ?[]u8 = null;
        const ts_final = if (timestamp.len > 0) timestamp else blk: {
            var ts_buf: [32]u8 = undefined;
            const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch "0";
            ts_heap = self.allocator.dupe(u8, ts_str) catch null;
            break :blk if (ts_heap) |h| h else "0";
        };
        cb(.{
            .asset_id = asset_id,
            .market = market,
            .best_bid = best_bid,
            .best_ask = best_ask,
            .timestamp = ts_final,
            .event_type = "best_bid_ask",
        });
        if (ts_heap) |h| self.allocator.free(h);
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
    try std.testing.expectEqual(@as(u64, 250), ws_client.reconnect_delay_ms);
    try std.testing.expectEqual(@as(u64, 30_000), ws_client.max_reconnect_delay_ms);
}

test "websocket: parseEventType" {
    try std.testing.expectEqual(EventType.book, parseEventType("book"));
    try std.testing.expectEqual(EventType.price_change, parseEventType("price_change"));
    try std.testing.expectEqual(EventType.best_bid_ask, parseEventType("best_bid_ask"));
    try std.testing.expectEqual(EventType.unknown, parseEventType("garbage"));
}
