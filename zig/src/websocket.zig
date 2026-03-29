//! WebSocket client with auto-reconnect and subscription management.
//! Connects to Polymarket CLOB WebSocket for real-time price feeds.
const std = @import("std");
const log = @import("logger.zig");

pub const WS_ENDPOINT = "wss://ws-subscriptions-clob.polymarket.com/ws/market";

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

    /// Request the poll/connect loop to stop.
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

    /// Connect and run the WebSocket read loop. Blocks.
    /// On disconnect, reconnects with exponential backoff (250ms -> 30s).
    /// This should be called from a dedicated thread.
    pub fn connectAndRun(self: *WebSocketClient) void {
        while (!self.should_stop.load(.seq_cst)) {
            self.state = .connecting;
            log.info("ws", "connecting to CLOB WebSocket...", .{});

            self.runConnection() catch |e| {
                log.err("ws", "connection error: {}", .{e});
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
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const uri = try std.Uri.parse(WS_ENDPOINT);
        try self.performUpgrade(&client, uri);

        // Successful upgrade path: transition state first, then reset backoff.
        self.state = .connected;
        self.resetBackoff();

        // Stub: actual WebSocket read/serve loop will be filled in once we
        // validate the std.http.Client WebSocket API surface.
    }

    fn performUpgrade(self: *WebSocketClient, client: *std.http.Client, uri: std.Uri) !void {
        _ = self;
        _ = client;
        _ = uri;
        return error.NotImplemented;
    }

    /// Poll-based fallback: fetch orderbook snapshots via REST and invoke callback.
    /// This is used until native WebSocket support is added.
    /// Blocks — call from a dedicated thread.
    pub fn pollAndNotify(self: *WebSocketClient, poll_interval_ms: u64) void {
        const http_mod = @import("http_client.zig");
        const clob = @import("clob_orderbook.zig");

        self.state = .connected;
        log.info("ws", "starting REST poll fallback ({d}ms interval, {d} subscriptions)", .{ poll_interval_ms, self.subscriptions.items.len });

        var client = http_mod.HttpClient.init(self.allocator);
        defer client.deinit();

        while (!self.should_stop.load(.seq_cst)) {
            for (self.subscriptions.items) |asset_id| {
                if (self.should_stop.load(.seq_cst)) break;

                var ob = clob.fetchOrderbook(self.allocator, &client, asset_id) catch |e| {
                    log.warn("ws", "poll fetch failed for {s}: {s}", .{ asset_id[0..@min(asset_id.len, 16)], @errorName(e) });
                    continue;
                };
                defer ob.deinit(self.allocator);

                if (self.callback) |cb| {
                    var ts_buf: [32]u8 = undefined;
                    const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch "0";
                    cb(.{
                        .asset_id = asset_id,
                        .market = ob.market,
                        .best_bid = ob.best_bid,
                        .best_ask = ob.best_ask,
                        .timestamp = ts_str,
                        .event_type = "price_update",
                    });
                }
            }

            if (self.should_stop.load(.seq_cst)) break;

            std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
        }

        self.state = .disconnected;
        log.info("ws", "REST poll fallback stopped", .{});
    }

    /// Reset reconnect delay on successful connection.
    fn resetBackoff(self: *WebSocketClient) void {
        self.reconnect_delay_ms = INITIAL_RECONNECT_MS;
    }
};

test "websocket: init and deinit" {
    var ws = WebSocketClient.init(std.testing.allocator);
    defer ws.deinit();
    try std.testing.expectEqual(WebSocketState.disconnected, ws.state);
}

test "websocket: subscribe adds to list" {
    var ws = WebSocketClient.init(std.testing.allocator);
    defer ws.deinit();
    try ws.subscribe("test-asset-id-123");
    try std.testing.expectEqual(@as(usize, 1), ws.subscriptions.items.len);
}

test "websocket: buildSubscriptionMessage" {
    var ws = WebSocketClient.init(std.testing.allocator);
    defer ws.deinit();
    try ws.subscribe("asset1");
    try ws.subscribe("asset2");
    var buf: [4096]u8 = undefined;
    const msg = try ws.buildSubscriptionMessage(&buf);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "websocket: exponential backoff constants" {
    var ws = WebSocketClient.init(std.testing.allocator);
    defer ws.deinit();
    try std.testing.expectEqual(@as(u64, 250), ws.reconnect_delay_ms);
    try std.testing.expectEqual(@as(u64, 30_000), ws.max_reconnect_delay_ms);
}
