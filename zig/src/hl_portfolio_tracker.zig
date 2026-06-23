//! Phase 5 — Hyperliquid portfolio tracker.
//!
//! Polls `POST /info {"type":"clearinghouseState","user":...}` and exposes
//! an in-memory snapshot (equity, margin used, positions, funding accrual).
//! Only the parsing + snapshot serialization layer is implemented here; the
//! polling thread + REST plumbing are wired in `main.zig` so this module is
//! testable without a live HL connection.
//!
//! All numeric fields in the HL response are JSON strings (e.g. "12345.67").
//! Parsing is allocation-free and tolerant of missing/malformed fields —
//! callers receive defaults (0.0) rather than errors so a transient parse
//! failure doesn't tear down the engine.

const std = @import("std");
const log = @import("logger.zig");
const db_mod = @import("db.zig");
const c = db_mod.c;
const http = @import("http_client.zig");

pub const MAX_POSITIONS = 64;
pub const MAX_FUNDING_RATES = 64;

pub const HlPosition = struct {
    coin: [16]u8,
    coin_len: usize,
    /// Signed size (positive = long, negative = short).
    szi: f64,
    entry_px: f64,
    /// Latest mark price (deduced from l2Book mid; populated externally).
    mark_price: f64,
    unreal_pnl: f64,
    funding_accrued: f64,
    leverage: i32,

    pub fn name(self: *const HlPosition) []const u8 {
        return self.coin[0..self.coin_len];
    }

    pub fn side(self: *const HlPosition) []const u8 {
        return if (self.szi >= 0) "long" else "short";
    }

    pub fn absSize(self: *const HlPosition) f64 {
        return if (self.szi < 0) -self.szi else self.szi;
    }
};

pub const HlSnapshot = struct {
    /// Total account value (HL `marginSummary.accountValue`).
    equity: f64,
    /// Margin currently in use across all positions.
    margin_used: f64,
    /// Sum of `unrealizedPnl` across positions.
    unrealized_pnl: f64,
    /// Sum of `funding_accrued` across positions.
    funding_accrued: f64,
    /// Count of populated entries in `positions`.
    position_count: usize,
    positions: [MAX_POSITIONS]HlPosition,
    /// `unixepoch()` when this snapshot was last refreshed; 0 means stale.
    snapshot_ts: i64,

    pub fn marginUsedPct(self: *const HlSnapshot) f64 {
        if (self.equity <= 0.0) return 0.0;
        return (self.margin_used / self.equity) * 100.0;
    }
};

pub const FundingRate = struct {
    asset: [16]u8,
    asset_len: usize,
    rate: f64,
    next_payment_ts: i64,

    pub fn name(self: *const FundingRate) []const u8 {
        return self.asset[0..self.asset_len];
    }
};

/// In-memory portfolio tracker holding the latest HL snapshot. Thread-safe
/// for read-mostly workloads via a single mutex around the whole snapshot
/// (snapshots are tiny and copied on read).
pub const HlPortfolioTracker = struct {
    allocator: std.mem.Allocator,
    database: *db_mod.DB,
    snapshot: HlSnapshot,
    funding_rates: [MAX_FUNDING_RATES]FundingRate,
    funding_count: usize,
    mutex: std.Thread.Mutex,
    should_stop: std.atomic.Value(bool),
    /// True when consecutive polls have failed and the strategy should pause.
    stale: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, database: *db_mod.DB) HlPortfolioTracker {
        return .{
            .allocator = allocator,
            .database = database,
            .snapshot = emptySnapshot(),
            .funding_rates = undefined,
            .funding_count = 0,
            .mutex = .{},
            .should_stop = std.atomic.Value(bool).init(false),
            .stale = std.atomic.Value(bool).init(false),
        };
    }

    pub fn stop(self: *HlPortfolioTracker) void {
        self.should_stop.store(true, .seq_cst);
    }

    /// Replace the in-memory snapshot atomically (under the mutex).
    pub fn updateSnapshot(self: *HlPortfolioTracker, snap: HlSnapshot) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.snapshot = snap;
        self.snapshot.snapshot_ts = std.time.timestamp();
        self.stale.store(false, .seq_cst);
    }

    /// Return a copy of the current snapshot (read-mostly, holds the mutex).
    pub fn getSnapshot(self: *HlPortfolioTracker) HlSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.snapshot;
    }

    pub fn isStale(self: *HlPortfolioTracker) bool {
        return self.stale.load(.seq_cst);
    }

    pub fn markStale(self: *HlPortfolioTracker) void {
        self.stale.store(true, .seq_cst);
    }

    pub fn getAccountEquity(self: *HlPortfolioTracker) f64 {
        return self.getSnapshot().equity;
    }

    pub fn getMarginUsedPercent(self: *HlPortfolioTracker) f64 {
        const snap = self.getSnapshot();
        return snap.marginUsedPct();
    }

    pub fn getFundingRate(self: *HlPortfolioTracker, asset: []const u8) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.funding_rates[0..self.funding_count]) |fr| {
            if (std.mem.eql(u8, fr.name(), asset)) return fr.rate;
        }
        return 0.0;
    }

    pub fn setFundingRates(
        self: *HlPortfolioTracker,
        rates: []const FundingRate,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(rates.len, self.funding_rates.len);
        for (rates[0..n], 0..) |r, i| self.funding_rates[i] = r;
        self.funding_count = n;
    }

    /// Persist the current equity/margin to balance_snapshots so historical
    /// reports + the legacy /portfolio handler can read it.
    pub fn persistEquity(self: *HlPortfolioTracker) void {
        const snap = self.getSnapshot();
        // Reuse balance_snapshots: usdc_balance ← equity, total_exposure ←
        // margin_used. This keeps the table compatible with the Phase 2
        // reader while exposing HL margin semantics.
        self.database.insertBalanceSnapshot(
            snap.equity,
            snap.margin_used,
            snap.unrealized_pnl,
            0.0,
        ) catch |e| {
            log.warn("hl_portfolio", "persistEquity failed: {s}", .{@errorName(e)});
        };
    }

    /// Fetch `clearinghouseState` once, update the in-memory snapshot, and
    /// persist the equity row for historical/risk consumers.
    pub fn fetchAndApplySnapshot(
        self: *HlPortfolioTracker,
        api_base: []const u8,
        user: []const u8,
    ) !void {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/info", .{api_base}) catch return error.HttpFailed;

        var body_buf: [128]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"type\":\"clearinghouseState\",\"user\":\"{s}\"}}",
            .{user},
        ) catch return error.HttpFailed;

        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        var response = client.postJson(url, body) catch |e| {
            log.warn("hl_portfolio", "clearinghouseState http failed: {s}", .{@errorName(e)});
            return error.HttpFailed;
        };
        defer response.deinit();

        if (response.status.class() != .success) {
            log.warn("hl_portfolio", "clearinghouseState status={d}", .{@intFromEnum(response.status)});
            return error.HttpFailed;
        }

        var snap = parseClearinghouseState(response.body) orelse return error.InvalidJson;
        snap.snapshot_ts = std.time.timestamp();
        self.updateSnapshot(snap);
        self.persistEquity();
    }

    /// Fetch funding rates once and persist them for `funding.snapshot`.
    pub fn fetchAndPersistFundingRates(
        self: *HlPortfolioTracker,
        api_base: []const u8,
    ) !void {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/info", .{api_base}) catch return error.HttpFailed;

        var client = http.HttpClient.init(self.allocator);
        defer client.deinit();

        var response = client.postJson(url, "{\"type\":\"predictedFundings\"}") catch |e| {
            log.warn("hl_portfolio", "predictedFundings http failed: {s}", .{@errorName(e)});
            return error.HttpFailed;
        };
        defer response.deinit();

        if (response.status.class() != .success) {
            log.warn("hl_portfolio", "predictedFundings status={d}", .{@intFromEnum(response.status)});
            return error.HttpFailed;
        }

        var rates_buf: [MAX_FUNDING_RATES]FundingRate = undefined;
        const n = parseFundingRates(response.body, &rates_buf);
        if (n == 0) return;
        self.setFundingRates(rates_buf[0..n]);
        try persistFundingRates(self.database, rates_buf[0..n]);
    }

    /// Serialize the current snapshot as JSON for the IPC `portfolio.response`.
    /// Format matches the Phase 5 plan:
    ///   {"equity":..,"margin_used_pct":..,"funding_accrued":..,
    ///    "positions":[{"asset":..,"side":..,"size":..,"entry_price":..,
    ///                  "mark_price":..,"unrealized_pnl":..,
    ///                  "funding_accrued":..}, ...]}
    pub fn writeSnapshotJson(self: *HlPortfolioTracker, buf: []u8) ![]const u8 {
        const snap = self.getSnapshot();
        return writeSnapshotJsonInner(snap, buf);
    }
};

const FetchError = error{
    HttpFailed,
    InvalidJson,
};

fn emptySnapshot() HlSnapshot {
    return .{
        .equity = 0.0,
        .margin_used = 0.0,
        .unrealized_pnl = 0.0,
        .funding_accrued = 0.0,
        .position_count = 0,
        .positions = undefined,
        .snapshot_ts = 0,
    };
}

/// Escape `src` for use inside a JSON string value (`"` → `\"`, `\` → `\\`,
/// U+0000–U+001F → `\u00XX`; other UTF-8 bytes pass through unchanged).
fn escapeJsonString(src: []const u8, buf: []u8) ![]const u8 {
    var i: usize = 0;
    var j: usize = 0;
    while (i < src.len) : (i += 1) {
        const byte = src[i];
        switch (byte) {
            '"' => {
                buf[j] = '\\';
                j += 1;
                buf[j] = '"';
                j += 1;
            },
            '\\' => {
                buf[j] = '\\';
                j += 1;
                buf[j] = '\\';
                j += 1;
            },
            0...0x1F => {
                if (j + 6 > buf.len) return error.BufferTooSmall;
                std.mem.copyForwards(u8, buf[j .. j + 2], "\\u");
                buf[j + 2] = '0';
                buf[j + 3] = '0';
                buf[j + 4] = "0123456789abcdef"[(byte >> 4) & 0xF];
                buf[j + 5] = "0123456789abcdef"[byte & 0xF];
                j += 6;
            },
            else => {
                buf[j] = byte;
                j += 1;
            },
        }
        if (j >= buf.len) return error.BufferTooSmall;
    }
    return buf[0..j];
}

/// Pure-functional snapshot serializer (testable without a tracker instance).
pub fn writeSnapshotJsonInner(snap: HlSnapshot, buf: []u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.print(
        "{{\"equity\":{d:.6},\"margin_used\":{d:.6},\"margin_used_pct\":{d:.4},\"unrealized_pnl\":{d:.6},\"funding_accrued\":{d:.6},\"snapshot_ts\":{d},\"positions\":[",
        .{
            snap.equity,
            snap.margin_used,
            snap.marginUsedPct(),
            snap.unrealized_pnl,
            snap.funding_accrued,
            snap.snapshot_ts,
        },
    );
    var first = true;
    for (snap.positions[0..snap.position_count]) |pos| {
        if (!first) try w.writeAll(",");
        first = false;
        var esc_asset_buf: [16 * 6]u8 = undefined;
        var esc_side_buf: [8 * 6]u8 = undefined;
        const asset_esc = try escapeJsonString(pos.name(), &esc_asset_buf);
        const side_esc = try escapeJsonString(pos.side(), &esc_side_buf);
        try w.print(
            "{{\"asset\":\"{s}\",\"side\":\"{s}\",\"size\":{d:.10},\"entry_price\":{d:.6},\"mark_price\":{d:.6},\"unrealized_pnl\":{d:.6},\"funding_accrued\":{d:.6},\"leverage\":{d}}}",
            .{
                asset_esc,
                side_esc,
                pos.absSize(),
                pos.entry_px,
                pos.mark_price,
                pos.unreal_pnl,
                pos.funding_accrued,
                pos.leverage,
            },
        );
    }
    try w.writeAll("]}");
    return fbs.getWritten();
}

/// Parse the HL `clearinghouseState` response body. Returns a snapshot
/// containing equity, margin, and per-asset positions. Numeric fields are
/// stored as JSON strings on the wire so we use a tolerant scalar extractor.
///
/// Expected envelope (abbreviated):
///   {
///     "marginSummary":{"accountValue":"10000.0","totalMarginUsed":"500.0",...},
///     "assetPositions":[
///       {"position":{"coin":"BTC","szi":"0.05","entryPx":"45000",
///                    "unrealizedPnl":"5","leverage":{"value":3}}},
///       ...
///     ]
///   }
pub fn parseClearinghouseState(body: []const u8) ?HlSnapshot {
    var snap = emptySnapshot();

    // Margin summary.
    if (std.mem.indexOf(u8, body, "\"marginSummary\"")) |ms_idx| {
        const slice = body[ms_idx..];
        if (extractFloatField(slice, "accountValue")) |v| snap.equity = v;
        if (extractFloatField(slice, "totalMarginUsed")) |v| snap.margin_used = v;
    } else {
        // No margin summary at all — treat as malformed.
        return null;
    }

    // Asset positions.
    const ap_key = "\"assetPositions\"";
    if (std.mem.indexOf(u8, body, ap_key)) |ap_idx| {
        var i = ap_idx + ap_key.len;
        while (i < body.len and body[i] != '[') : (i += 1) {}
        if (i < body.len) {
            i += 1;
            while (i < body.len and snap.position_count < snap.positions.len) {
                while (i < body.len and (body[i] == ' ' or body[i] == ',' or body[i] == '\n' or body[i] == '\r' or body[i] == '\t')) : (i += 1) {}
                if (i >= body.len or body[i] == ']') break;
                if (body[i] != '{') {
                    i += 1;
                    continue;
                }

                // Find the matching '}' at depth 0 for the outer
                // assetPosition wrapper (which nests "position":{...}).
                var depth: i32 = 0;
                var end: usize = i;
                while (end < body.len) : (end += 1) {
                    if (body[end] == '{') depth += 1;
                    if (body[end] == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                if (end >= body.len) break;
                const obj = body[i .. end + 1];

                if (parsePositionObject(obj)) |pos| {
                    snap.positions[snap.position_count] = pos;
                    snap.position_count += 1;
                    snap.unrealized_pnl += pos.unreal_pnl;
                    snap.funding_accrued += pos.funding_accrued;
                }
                i = end + 1;
            }
        }
    }

    return snap;
}

fn parsePositionObject(obj: []const u8) ?HlPosition {
    var p = HlPosition{
        .coin = [_]u8{0} ** 16,
        .coin_len = 0,
        .szi = 0.0,
        .entry_px = 0.0,
        .mark_price = 0.0,
        .unreal_pnl = 0.0,
        .funding_accrued = 0.0,
        .leverage = 1,
    };

    if (extractStringField(obj, "coin")) |s| {
        p.coin_len = copyJsonStringDecoded(&p.coin, s);
    }
    if (extractFloatField(obj, "szi")) |v| p.szi = v;
    if (extractFloatField(obj, "entryPx")) |v| p.entry_px = v;
    if (extractFloatField(obj, "unrealizedPnl")) |v| p.unreal_pnl = v;
    // Funding accrued (HL reports cumulative funding under "cumFunding" or
    // "funding" depending on SDK version).
    if (extractFloatField(obj, "cumFunding")) |v| {
        p.funding_accrued = v;
    } else if (extractFloatField(obj, "funding")) |v| {
        p.funding_accrued = v;
    }
    // Leverage: nested `"leverage":{"value":3,...}`. Look up by the inner key.
    if (extractIntField(obj, "value")) |v| p.leverage = @intCast(v);

    if (p.coin_len == 0) return null;
    return p;
}

/// Copy a JSON string payload into `dest`, decoding the small escape subset
/// that can appear in HL symbols. In particular, `\\\"` decodes to
/// `\"` (a literal backslash followed by a quote).
fn copyJsonStringDecoded(dest: []u8, src: []const u8) usize {
    var i: usize = 0;
    var j: usize = 0;
    while (i < src.len and j < dest.len) {
        if (src[i] == '\\' and i + 2 < src.len and src[i + 1] == '\\' and src[i + 2] == '"') {
            if (j + 2 > dest.len) break;
            dest[j] = '\\';
            dest[j + 1] = '"';
            j += 2;
            i += 3;
            continue;
        }
        if (src[i] == '\\' and i + 1 < src.len) {
            const next = src[i + 1];
            switch (next) {
                '"', '\\', '/' => {
                    dest[j] = next;
                    j += 1;
                    i += 2;
                    continue;
                },
                else => {},
            }
        }
        dest[j] = src[i];
        j += 1;
        i += 1;
    }
    return j;
}

/// Extract a numeric field stored as either a string ("123.45") or a raw
/// number (123.45). Returns null if missing or unparseable.
fn extractFloatField(obj: []const u8, key: []const u8) ?f64 {
    const raw = extractRawValue(obj, key) orelse return null;
    return std.fmt.parseFloat(f64, raw) catch null;
}

fn extractIntField(obj: []const u8, key: []const u8) ?i64 {
    const raw = extractRawValue(obj, key) orelse return null;
    return std.fmt.parseInt(i64, raw, 10) catch null;
}

fn extractStringField(obj: []const u8, key: []const u8) ?[]const u8 {
    return extractRawValue(obj, key);
}

/// Locate `"key":` and return the following scalar value (string contents
/// without quotes, or numeric token).
fn extractRawValue(obj: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + key.len + 3 < obj.len) : (i += 1) {
        if (obj[i] != '"') continue;
        if (i + 1 + key.len + 1 >= obj.len) continue;
        if (!std.mem.eql(u8, obj[i + 1 .. i + 1 + key.len], key)) continue;
        if (obj[i + 1 + key.len] != '"') continue;

        var j = i + 1 + key.len + 1;
        while (j < obj.len and (obj[j] == ':' or obj[j] == ' ')) : (j += 1) {}
        if (j >= obj.len) return null;

        if (obj[j] == '"') {
            const start = j + 1;
            var end = start;
            while (end < obj.len) {
                if (obj[end] != '"') {
                    end += 1;
                    continue;
                }
                // Only treat `"` as the closing delimiter if it is not escaped
                // by an odd count of consecutive `\` immediately before it.
                var bs: usize = 0;
                var k = end;
                while (k > start and obj[k - 1] == '\\') : (k -= 1) {
                    bs += 1;
                }
                if (bs % 2 == 0) break;
                end += 1;
            }
            if (end >= obj.len) return null;
            return obj[start..end];
        }

        const start = j;
        var end = start;
        while (end < obj.len and obj[end] != ',' and obj[end] != '}' and obj[end] != ' ' and obj[end] != ']') : (end += 1) {}
        return obj[start..end];
    }
    return null;
}

/// Parse an HL `predictedFundings` response body. The endpoint returns a
/// nested array, one entry per coin, each pairing the coin name with a list
/// of per-venue predicted funding objects:
///   [["BTC",[["BinPerp",{"fundingRate":"0.0001","nextFundingTime":...}],
///            ["HlPerp",{"fundingRate":"0.0000125","nextFundingTime":...}],
///            ...]],
///    ["ETH",[...]], ...]
/// We extract the Hyperliquid venue ("HlPerp") rate for each coin, since that
/// is the funding the engine pays/receives on HL positions. Coins without an
/// HlPerp entry are skipped.
pub fn parseFundingRates(body: []const u8, out: []FundingRate) usize {
    const venue_marker = "\"HlPerp\"";
    var n: usize = 0;
    var i: usize = 0;
    // Find first '[' (outer array open).
    while (i < body.len and body[i] != '[') : (i += 1) {}
    if (i >= body.len) return 0;
    i += 1;

    while (i < body.len and n < out.len) {
        while (i < body.len and (body[i] == ' ' or body[i] == ',' or body[i] == '\n' or body[i] == '\r' or body[i] == '\t')) : (i += 1) {}
        if (i >= body.len or body[i] == ']') break;
        // Each coin entry is itself an array: ["COIN",[...]].
        if (body[i] != '[') {
            i += 1;
            continue;
        }
        // Capture the full coin entry by bracket depth.
        var depth: i32 = 0;
        var end: usize = i;
        while (end < body.len) : (end += 1) {
            if (body[end] == '[') depth += 1;
            if (body[end] == ']') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (end >= body.len) break;
        const entry = body[i .. end + 1];
        i = end + 1;

        // Coin name: first quoted string in the entry.
        const coin = firstQuotedString(entry) orelse continue;

        // Locate the HlPerp venue object inside this entry.
        const venue_pos = std.mem.indexOf(u8, entry, venue_marker) orelse continue;
        var oi = venue_pos + venue_marker.len;
        while (oi < entry.len and entry[oi] != '{') : (oi += 1) {}
        if (oi >= entry.len) continue;
        var od: i32 = 0;
        var oe = oi;
        while (oe < entry.len) : (oe += 1) {
            if (entry[oe] == '{') od += 1;
            if (entry[oe] == '}') {
                od -= 1;
                if (od == 0) break;
            }
        }
        if (oe >= entry.len) continue;
        const obj = entry[oi .. oe + 1];

        var fr = FundingRate{
            .asset = [_]u8{0} ** 16,
            .asset_len = 0,
            .rate = 0.0,
            .next_payment_ts = 0,
        };
        const m = @min(coin.len, fr.asset.len);
        @memcpy(fr.asset[0..m], coin[0..m]);
        fr.asset_len = m;
        if (extractFloatField(obj, "fundingRate")) |v| fr.rate = v;
        if (extractIntField(obj, "nextFundingTime")) |v| fr.next_payment_ts = v;
        if (fr.asset_len > 0) {
            out[n] = fr;
            n += 1;
        }
    }
    return n;
}

/// Return the contents of the first double-quoted string in `s`, without the
/// surrounding quotes. Assumes no escaped quotes in coin names (HL coin
/// symbols are plain alphanumerics).
fn firstQuotedString(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] != '"') : (i += 1) {}
    if (i >= s.len) return null;
    const start = i + 1;
    var end = start;
    while (end < s.len and s[end] != '"') : (end += 1) {}
    if (end >= s.len) return null;
    return s[start..end];
}

/// Persist a slice of funding rates into the funding_snapshots table.
pub fn persistFundingRates(database: *db_mod.DB, rates: []const FundingRate) !void {
    const sql = "INSERT INTO funding_snapshots(asset, rate, next_payment_ts) VALUES(?,?,?);" ++ &[_:0]u8{};
    for (rates) |fr| {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(database.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) continue;
        defer _ = c.sqlite3_finalize(stmt);
        const name_slice = fr.asset[0..fr.asset_len];
        _ = c.sqlite3_bind_text(stmt, 1, name_slice.ptr, @intCast(name_slice.len), null);
        _ = c.sqlite3_bind_double(stmt, 2, fr.rate);
        _ = c.sqlite3_bind_int64(stmt, 3, fr.next_payment_ts);
        _ = c.sqlite3_step(stmt);
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "hl_portfolio_tracker: parseClearinghouseState extracts equity + margin" {
    const json =
        \\{"marginSummary":{"accountValue":"10500.50","totalMarginUsed":"4750.25"},
        \\ "assetPositions":[]}
    ;
    const snap = parseClearinghouseState(json) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectApproxEqAbs(@as(f64, 10500.50), snap.equity, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 4750.25), snap.margin_used, 1e-6);
    try std.testing.expectEqual(@as(usize, 0), snap.position_count);
}

test "hl_portfolio_tracker: parseClearinghouseState parses long position" {
    const json =
        \\{"marginSummary":{"accountValue":"10000","totalMarginUsed":"500"},
        \\ "assetPositions":[
        \\   {"position":{"coin":"BTC","szi":"0.05","entryPx":"45000","unrealizedPnl":"5","leverage":{"value":3}}}
        \\ ]}
    ;
    const snap = parseClearinghouseState(json) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(usize, 1), snap.position_count);
    const p = snap.positions[0];
    try std.testing.expectEqualStrings("BTC", p.name());
    try std.testing.expectEqualStrings("long", p.side());
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), p.absSize(), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 45000.0), p.entry_px, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), p.unreal_pnl, 1e-6);
    try std.testing.expectEqual(@as(i32, 3), p.leverage);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), snap.unrealized_pnl, 1e-6);
}

test "hl_portfolio_tracker: parseClearinghouseState parses short position" {
    const json =
        \\{"marginSummary":{"accountValue":"10000","totalMarginUsed":"500"},
        \\ "assetPositions":[
        \\   {"position":{"coin":"ETH","szi":"-1.5","entryPx":"3000","unrealizedPnl":"-50","leverage":{"value":2}}}
        \\ ]}
    ;
    const snap = parseClearinghouseState(json) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(usize, 1), snap.position_count);
    const p = snap.positions[0];
    try std.testing.expectEqualStrings("short", p.side());
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), p.absSize(), 1e-9);
}

test "hl_portfolio_tracker: parsePositionObject respects escaped quote in coin" {
    const json =
        \\{"position":{"coin":"A\\\"B","szi":"0.5","entryPx":"1","unrealizedPnl":"0","leverage":{"value":2}}}
    ;
    const pos = parsePositionObject(json) orelse {
        try std.testing.expect(false);
        return;
    };
    const expected = [_]u8{ 'A', '\\', '"', 'B' };
    try std.testing.expectEqualStrings(&expected, pos.name());
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), pos.absSize(), 1e-9);
}

test "hl_portfolio_tracker: parseClearinghouseState returns null on malformed" {
    try std.testing.expect(parseClearinghouseState("{}") == null);
}

test "hl_portfolio_tracker: marginUsedPct" {
    var snap = emptySnapshot();
    snap.equity = 1000.0;
    snap.margin_used = 250.0;
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), snap.marginUsedPct(), 1e-9);

    snap.equity = 0.0;
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), snap.marginUsedPct(), 1e-9);
}

test "hl_portfolio_tracker: writeSnapshotJsonInner emits required fields" {
    var snap = emptySnapshot();
    snap.equity = 10500.50;
    snap.margin_used = 4750.25;
    snap.unrealized_pnl = 12.5;
    snap.funding_accrued = -5.0;
    snap.snapshot_ts = 1_700_000_000;
    snap.position_count = 1;
    var pos = HlPosition{
        .coin = [_]u8{0} ** 16,
        .coin_len = 0,
        .szi = 0.05,
        .entry_px = 45000.0,
        .mark_price = 45100.0,
        .unreal_pnl = 5.0,
        .funding_accrued = 0.0,
        .leverage = 3,
    };
    @memcpy(pos.coin[0..3], "BTC");
    pos.coin_len = 3;
    snap.positions[0] = pos;

    var buf: [1024]u8 = undefined;
    const json = try writeSnapshotJsonInner(snap, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"equity\":10500.500000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"margin_used_pct\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"asset\":\"BTC\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"side\":\"long\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mark_price\":45100") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"funding_accrued\":-5") != null);
    // Must NOT contain the legacy USDC balance field.
    try std.testing.expect(std.mem.indexOf(u8, json, "usdc_balance") == null);
}

test "hl_portfolio_tracker: writeSnapshotJsonInner escapes asset JSON special chars" {
    var snap = emptySnapshot();
    snap.snapshot_ts = 1;
    snap.position_count = 1;
    var pos = HlPosition{
        .coin = [_]u8{0} ** 16,
        .coin_len = 0,
        .szi = 0.05,
        .entry_px = 1.0,
        .mark_price = 1.0,
        .unreal_pnl = 0.0,
        .funding_accrued = 0.0,
        .leverage = 1,
    };
    @memcpy(pos.coin[0..6], "\"\\\nBTC");
    pos.coin_len = 6;
    snap.positions[0] = pos;

    var buf: [2048]u8 = undefined;
    const json = try writeSnapshotJsonInner(snap, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\u000a") != null);
}

test "hl_portfolio_tracker: parseFundingRates extracts HlPerp rates" {
    // Mirrors the real `predictedFundings` shape: per-coin, per-venue tuples.
    // Only the HlPerp venue should be extracted.
    const json =
        \\[["BTC",[["BinPerp",{"fundingRate":"-0.00002098","nextFundingTime":1782086400000,"fundingIntervalHours":4}],
        \\         ["HlPerp",{"fundingRate":"0.0001","nextFundingTime":1700000000000,"fundingIntervalHours":1}],
        \\         ["BybitPerp",{"fundingRate":"0.00005","nextFundingTime":1782086400000,"fundingIntervalHours":4}]]],
        \\ ["ETH",[["HlPerp",{"fundingRate":"0.00005","nextFundingTime":1700000003600,"fundingIntervalHours":1}]]],
        \\ ["NOHL",[["BinPerp",{"fundingRate":"0.0002","nextFundingTime":1782086400000,"fundingIntervalHours":4}]]]]
    ;
    var out: [4]FundingRate = undefined;
    const n = parseFundingRates(json, &out);
    // NOHL has no HlPerp entry → skipped.
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("BTC", out[0].name());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0001), out[0].rate, 1e-12);
    try std.testing.expectEqual(@as(i64, 1700000000000), out[0].next_payment_ts);
    try std.testing.expectEqualStrings("ETH", out[1].name());
    try std.testing.expectApproxEqAbs(@as(f64, 0.00005), out[1].rate, 1e-12);
}

test "hl_portfolio_tracker: tracker getFundingRate after setFundingRates" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    var tracker = HlPortfolioTracker.init(std.testing.allocator, &database);
    var rates: [2]FundingRate = undefined;
    rates[0] = .{ .asset = [_]u8{0} ** 16, .asset_len = 3, .rate = 0.0001, .next_payment_ts = 1 };
    @memcpy(rates[0].asset[0..3], "BTC");
    rates[1] = .{ .asset = [_]u8{0} ** 16, .asset_len = 3, .rate = 0.00005, .next_payment_ts = 2 };
    @memcpy(rates[1].asset[0..3], "ETH");
    tracker.setFundingRates(&rates);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0001), tracker.getFundingRate("BTC"), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), tracker.getFundingRate("UNKNOWN"), 1e-12);
}

test "hl_portfolio_tracker: persistFundingRates writes rows" {
    var database = try db_mod.DB.open(":memory:");
    defer database.close();
    try database.runMigrations();

    var rates: [1]FundingRate = undefined;
    rates[0] = .{ .asset = [_]u8{0} ** 16, .asset_len = 3, .rate = 0.0001, .next_payment_ts = 1 };
    @memcpy(rates[0].asset[0..3], "BTC");

    try persistFundingRates(&database, &rates);

    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(
        database.handle,
        "SELECT COUNT(*) FROM funding_snapshots WHERE asset='BTC';",
        -1,
        &stmt,
        null,
    ));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(stmt, 0));
}
