//! CLOB order book fetcher and SQLite storage.
const std = @import("std");
const log = @import("logger.zig");
const http = @import("http_client.zig");
const db = @import("db.zig");

const c = @cImport(@cInclude("sqlite3.h"));

pub const CLOB_API_BASE = "https://clob.polymarket.com";

pub const OrderLevel = struct {
    price: []const u8,
    size: []const u8,
};

pub const OrderBook = struct {
    market: []const u8,
    asset_id: []const u8,
    timestamp: []const u8,
    best_bid: []const u8,
    best_ask: []const u8,
    mid_price: f64,
    bids_json: []const u8,
    asks_json: []const u8,
    last_trade_price: []const u8,
    tick_size: []const u8,

    pub fn deinit(self: *OrderBook, allocator: std.mem.Allocator) void {
        allocator.free(self.market);
        allocator.free(self.asset_id);
        allocator.free(self.timestamp);
        allocator.free(self.best_bid);
        allocator.free(self.best_ask);
        allocator.free(self.bids_json);
        allocator.free(self.asks_json);
        allocator.free(self.last_trade_price);
        allocator.free(self.tick_size);
    }
};

/// Fetch order book from CLOB API for a given token_id.
pub fn fetchOrderbook(allocator: std.mem.Allocator, client: *http.HttpClient, token_id: []const u8) !OrderBook {
    const url = try std.fmt.allocPrint(allocator, CLOB_API_BASE ++ "/book?token_id={s}", .{token_id});
    defer allocator.free(url);

    var resp = client.get(url) catch |e| {
        log.err("clob", "fetchOrderbook failed: {s}", .{@errorName(e)});
        return error.RequestFailed;
    };
    defer resp.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{}) catch {
        log.err("clob", "failed to parse order book JSON", .{});
        return error.ParseFailed;
    };
    defer parsed.deinit();
    const root = parsed.value.object;

    const market = try allocator.dupe(u8, root.get("market").?.string);
    errdefer allocator.free(market);
    const asset_id = try allocator.dupe(u8, root.get("asset_id").?.string);
    errdefer allocator.free(asset_id);
    const timestamp = try allocator.dupe(u8, root.get("timestamp").?.string);
    errdefer allocator.free(timestamp);
    const last_trade_price = try allocator.dupe(u8, root.get("last_trade_price").?.string);
    errdefer allocator.free(last_trade_price);
    const tick_size = try allocator.dupe(u8, root.get("tick_size").?.string);
    errdefer allocator.free(tick_size);

    const bids = root.get("bids").?.array;
    const asks = root.get("asks").?.array;

    const best_bid = if (bids.items.len > 0)
        try allocator.dupe(u8, bids.items[0].object.get("price").?.string)
    else
        try allocator.dupe(u8, "0");
    errdefer allocator.free(best_bid);

    const best_ask = if (asks.items.len > 0)
        try allocator.dupe(u8, asks.items[0].object.get("price").?.string)
    else
        try allocator.dupe(u8, "0");
    errdefer allocator.free(best_ask);

    const bid_f = std.fmt.parseFloat(f64, best_bid) catch 0.0;
    const ask_f = std.fmt.parseFloat(f64, best_ask) catch 0.0;
    const mid_price = (bid_f + ask_f) / 2.0;

    const bids_json = try stringifyArray(allocator, resp.body, "bids");
    errdefer allocator.free(bids_json);
    const asks_json = try stringifyArray(allocator, resp.body, "asks");
    errdefer allocator.free(asks_json);

    return .{
        .market = market,
        .asset_id = asset_id,
        .timestamp = timestamp,
        .best_bid = best_bid,
        .best_ask = best_ask,
        .mid_price = mid_price,
        .bids_json = bids_json,
        .asks_json = asks_json,
        .last_trade_price = last_trade_price,
        .tick_size = tick_size,
    };
}

/// Extract a top-level JSON array field as a raw string from the response body.
fn stringifyArray(allocator: std.mem.Allocator, body: []const u8, key: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.ParseFailed;
    defer parsed.deinit();
    const arr = parsed.value.object.get(key) orelse return error.ParseFailed;
    return std.json.Stringify.valueAlloc(allocator, arr, .{}) catch error.ParseFailed;
}

/// Persist an order book snapshot to SQLite.
pub fn saveSnapshot(database: *db.DB, book: *const OrderBook) !void {
    const insert_sql =
        "INSERT INTO orderbooks(market,asset_id,best_bid,best_ask,mid_price,bids_json,asks_json,last_trade_price,tick_size,timestamp) " ++
        "VALUES(?,?,?,?,?,?,?,?,?,?);" ++ &[_:0]u8{};

    var stmt: ?*c.sqlite3_stmt = null;
    const rc_prepare = c.sqlite3_prepare_v2(database.handle, insert_sql.ptr, -1, &stmt, null);
    if (rc_prepare != c.SQLITE_OK) {
        log.err("clob", "failed to prepare orderbook INSERT: rc={d}", .{rc_prepare});
        return error.DBExecFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    if (c.sqlite3_bind_text(stmt, 1, book.market.ptr, @intCast(book.market.len), null) != c.SQLITE_OK or
        c.sqlite3_bind_text(stmt, 2, book.asset_id.ptr, @intCast(book.asset_id.len), null) != c.SQLITE_OK or
        c.sqlite3_bind_text(stmt, 3, book.best_bid.ptr, @intCast(book.best_bid.len), null) != c.SQLITE_OK or
        c.sqlite3_bind_text(stmt, 4, book.best_ask.ptr, @intCast(book.best_ask.len), null) != c.SQLITE_OK or
        c.sqlite3_bind_double(stmt, 5, book.mid_price) != c.SQLITE_OK or
        c.sqlite3_bind_text(stmt, 6, book.bids_json.ptr, @intCast(book.bids_json.len), null) != c.SQLITE_OK or
        c.sqlite3_bind_text(stmt, 7, book.asks_json.ptr, @intCast(book.asks_json.len), null) != c.SQLITE_OK or
        c.sqlite3_bind_text(stmt, 8, book.last_trade_price.ptr, @intCast(book.last_trade_price.len), null) != c.SQLITE_OK or
        c.sqlite3_bind_text(stmt, 9, book.tick_size.ptr, @intCast(book.tick_size.len), null) != c.SQLITE_OK or
        c.sqlite3_bind_text(stmt, 10, book.timestamp.ptr, @intCast(book.timestamp.len), null) != c.SQLITE_OK)
    {
        log.err("clob", "failed to bind orderbook INSERT parameters", .{});
        return error.DBExecFailed;
    }

    const rc_step = c.sqlite3_step(stmt);
    if (rc_step != c.SQLITE_DONE) {
        log.err("clob", "failed to execute orderbook INSERT: rc={d}", .{rc_step});
        return error.DBExecFailed;
    }
}

/// SQL to create the orderbooks table (called from db migrations or inline).
pub const CREATE_ORDERBOOKS_TABLE =
    \\CREATE TABLE IF NOT EXISTS orderbooks(
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  market TEXT NOT NULL,
    \\  asset_id TEXT NOT NULL,
    \\  best_bid TEXT,
    \\  best_ask TEXT,
    \\  mid_price REAL,
    \\  bids_json TEXT,
    \\  asks_json TEXT,
    \\  last_trade_price TEXT,
    \\  tick_size TEXT,
    \\  timestamp TEXT,
    \\  created_at INTEGER NOT NULL DEFAULT(unixepoch()),
    \\  gamma_id TEXT DEFAULT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_orderbooks_asset ON orderbooks(asset_id);
    \\CREATE INDEX IF NOT EXISTS idx_orderbooks_created ON orderbooks(created_at DESC);
;

test "clob_orderbook: CREATE_ORDERBOOKS_TABLE is valid" {
    const sqlite = @cImport(@cInclude("sqlite3.h"));
    var handle: ?*sqlite.sqlite3 = null;
    const rc_open = sqlite.sqlite3_open(":memory:", &handle);
    try std.testing.expectEqual(sqlite.SQLITE_OK, rc_open);
    defer _ = sqlite.sqlite3_close(handle);

    var errmsg: ?[*:0]u8 = null;
    const rc_exec = sqlite.sqlite3_exec(handle.?, (CREATE_ORDERBOOKS_TABLE ++ &[_:0]u8{}).ptr, null, null, @ptrCast(&errmsg));
    if (errmsg) |m| {
        std.debug.print("SQL error: {s}\n", .{m});
        sqlite.sqlite3_free(m);
    }
    try std.testing.expectEqual(sqlite.SQLITE_OK, rc_exec);
}

test "clob_orderbook: mid_price calculation" {
    const bid = std.fmt.parseFloat(f64, "0.45") catch unreachable;
    const ask = std.fmt.parseFloat(f64, "0.46") catch unreachable;
    const mid = (bid + ask) / 2.0;
    try std.testing.expectApproxEqAbs(@as(f64, 0.455), mid, 1e-12);
}
