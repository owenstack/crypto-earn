//! Polymarket CLOB authentication: L1 EIP-712 signing, L2 HMAC, order signing,
//! API credential bootstrapping.
const std = @import("std");
const log = @import("logger.zig");
const crypto = @import("crypto.zig");
const http = @import("http_client.zig");

const c = @cImport({
    @cInclude("secp256k1.h");
    @cInclude("secp256k1_recovery.h");
});

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const CHAIN_ID: u64 = 137;
pub const CTF_EXCHANGE: [20]u8 = parseAddr("E111180000d2663C0091e4f400237545B87B996B");
pub const NEG_RISK_CTF_EXCHANGE: [20]u8 = parseAddr("e2222d279d744050d28e00520010520000310F59");
pub const COLLATERAL_DECIMALS: u64 = 6;

const CLOB_API_BASE = "https://clob.polymarket.com";
const ORDER_V2_TYPE_STRING = "Order(uint256 salt,address maker,address signer,uint256 tokenId,uint256 makerAmount,uint256 takerAmount,uint8 side,uint8 signatureType,uint256 timestamp,bytes32 metadata,bytes32 builder)";
const TYPED_DATA_SIGN_TYPE_STRING = "TypedDataSign(Order contents,string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)" ++ ORDER_V2_TYPE_STRING;

// ---------------------------------------------------------------------------
// Address derivation
// ---------------------------------------------------------------------------

/// Derive the Ethereum address (last 20 bytes of keccak256 of uncompressed pubkey)
/// from a 32-byte secp256k1 private key.
pub fn deriveAddress(private_key: [32]u8) ![20]u8 {
    const ctx = c.secp256k1_context_create(c.SECP256K1_CONTEXT_NONE) orelse
        return error.Secp256k1ContextFailed;
    defer c.secp256k1_context_destroy(ctx);

    var pubkey: c.secp256k1_pubkey = undefined;
    if (c.secp256k1_ec_pubkey_create(ctx, &pubkey, &private_key) != 1)
        return error.Secp256k1PubkeyFailed;

    var serialized: [65]u8 = undefined;
    var out_len: usize = 65;
    if (c.secp256k1_ec_pubkey_serialize(ctx, &serialized, &out_len, &pubkey, c.SECP256K1_EC_UNCOMPRESSED) != 1)
        return error.Secp256k1SerializeFailed;

    // Hash bytes 1..65 (skip the 0x04 prefix)
    const hash = crypto.Keccak256.hash(serialized[1..65]);
    return hash[12..32].*;
}

// ---------------------------------------------------------------------------
// L1 ClobAuth EIP-712 signing
// ---------------------------------------------------------------------------

/// Build the EIP-712 digest for ClobAuth (L1 authentication).
pub fn buildClobAuthDigest(address: [20]u8, timestamp: []const u8, nonce: u64) [32]u8 {
    // Domain separator
    const domain_type_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash("EIP712Domain(string name,string version,uint256 chainId)");
    };
    const name_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash("ClobAuthDomain");
    };
    const version_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash("1");
    };

    var domain_data: [4 * 32]u8 = undefined;
    @memcpy(domain_data[0..32], &domain_type_hash);
    @memcpy(domain_data[32..64], &name_hash);
    @memcpy(domain_data[64..96], &version_hash);
    writeU256(domain_data[96..128], CHAIN_ID);

    const domain_separator = crypto.Keccak256.hash(&domain_data);

    // Struct hash
    const type_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash("ClobAuth(address address,string timestamp,uint256 nonce,string message)");
    };
    const message_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash("This message attests that I control the given wallet");
    };

    const timestamp_hash = crypto.Keccak256.hash(timestamp);

    var struct_data: [5 * 32]u8 = undefined;
    @memcpy(struct_data[0..32], &type_hash);

    // address left-padded to 32 bytes (12 zero bytes + 20 address bytes)
    @memset(struct_data[32..44], 0);
    @memcpy(struct_data[44..64], &address);

    @memcpy(struct_data[64..96], &timestamp_hash);
    writeU256(struct_data[96..128], nonce);
    @memcpy(struct_data[128..160], &message_hash);

    const struct_hash = crypto.Keccak256.hash(&struct_data);

    // Final digest: keccak256("\x19\x01" ++ domainSep ++ structHash)
    var envelope: [2 + 32 + 32]u8 = undefined;
    envelope[0] = 0x19;
    envelope[1] = 0x01;
    @memcpy(envelope[2..34], &domain_separator);
    @memcpy(envelope[34..66], &struct_hash);

    return crypto.Keccak256.hash(&envelope);
}

// ---------------------------------------------------------------------------
// L2 HMAC-SHA256 signing
// ---------------------------------------------------------------------------

pub const HmacResult = struct {
    buf: [128]u8,
    len: usize,

    pub fn slice(self: *const HmacResult) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Build an HMAC-SHA256 signature for L2 API requests.
/// `secret` is a base64url-encoded key. Message = timestamp ++ method ++ path ++ body.
pub fn buildHmacSignature(
    secret: []const u8,
    timestamp: []const u8,
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
) !HmacResult {
    // Normalize base64url -> standard base64
    var secret_norm: [256]u8 = undefined;
    if (secret.len > secret_norm.len) return error.SecretTooLong;
    @memcpy(secret_norm[0..secret.len], secret);
    for (secret_norm[0..secret.len]) |*ch| {
        if (ch.* == '-') ch.* = '+' else if (ch.* == '_') ch.* = '/';
    }

    // Decode base64
    var key_buf: [192]u8 = undefined;
    const key_len = std.base64.standard.Decoder.calcSizeForSlice(secret_norm[0..secret.len]) catch
        return error.InvalidBase64;
    if (key_len > key_buf.len) return error.SecretTooLong;
    std.base64.standard.Decoder.decode(&key_buf, secret_norm[0..secret.len]) catch
        return error.InvalidBase64;

    // Build message
    var msg_buf: [2048]u8 = undefined;
    var msg_len: usize = 0;
    const body_len: usize = if (body) |b| b.len else 0;
    const required_len = timestamp.len + method.len + path.len + body_len;
    if (required_len > msg_buf.len) return error.MessageTooLong;
    @memcpy(msg_buf[msg_len .. msg_len + timestamp.len], timestamp);
    msg_len += timestamp.len;
    @memcpy(msg_buf[msg_len .. msg_len + method.len], method);
    msg_len += method.len;
    @memcpy(msg_buf[msg_len .. msg_len + path.len], path);
    msg_len += path.len;
    if (body) |b| {
        @memcpy(msg_buf[msg_len .. msg_len + b.len], b);
        msg_len += b.len;
    }

    // HMAC-SHA256
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, msg_buf[0..msg_len], key_buf[0..key_len]);

    // Encode as base64, then convert to base64url
    var result: HmacResult = .{ .buf = undefined, .len = 0 };
    const encoded = std.base64.standard.Encoder.encode(&result.buf, &mac);
    result.len = encoded.len;

    // Replace + -> -, / -> _
    for (result.buf[0..result.len]) |*ch| {
        if (ch.* == '+') ch.* = '-' else if (ch.* == '/') ch.* = '_';
    }

    return result;
}

// ---------------------------------------------------------------------------
// CTF Exchange Order EIP-712 signing
// ---------------------------------------------------------------------------

pub const CtfOrder = struct {
    salt: u256,
    maker: [20]u8,
    signer: [20]u8,
    token_id: u256,
    maker_amount: u256,
    taker_amount: u256,
    side: u8,
    signature_type: u8,
    timestamp: u256,
    metadata: [32]u8,
    builder: [32]u8,
};

/// Build the EIP-712 digest for a CTF Exchange order.
pub fn buildOrderDigest(order: CtfOrder, chain_id: u64, exchange_addr: [20]u8) [32]u8 {
    // Domain separator (includes verifyingContract)
    const domain_type_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    };
    const name_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash("Polymarket CTF Exchange");
    };
    const version_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash("2");
    };

    var domain_data: [5 * 32]u8 = undefined;
    @memcpy(domain_data[0..32], &domain_type_hash);
    @memcpy(domain_data[32..64], &name_hash);
    @memcpy(domain_data[64..96], &version_hash);
    writeU256(domain_data[96..128], chain_id);
    // address left-padded to 32 bytes
    @memset(domain_data[128..140], 0);
    @memcpy(domain_data[140..160], &exchange_addr);

    const domain_separator = crypto.Keccak256.hash(&domain_data);

    // CLOB V2 order type hash
    const order_type_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash("Order(uint256 salt,address maker,address signer,uint256 tokenId,uint256 makerAmount,uint256 takerAmount,uint8 side,uint8 signatureType,uint256 timestamp,bytes32 metadata,bytes32 builder)");
    };

    // Struct hash: 12 fields (type_hash + 11 fields)
    var struct_data: [12 * 32]u8 = undefined;
    @memcpy(struct_data[0..32], &order_type_hash);
    writeU256_wide(struct_data[32..64], order.salt);
    writeAddrPadded(struct_data[64..96], order.maker);
    writeAddrPadded(struct_data[96..128], order.signer);
    writeU256_wide(struct_data[128..160], order.token_id);
    writeU256_wide(struct_data[160..192], order.maker_amount);
    writeU256_wide(struct_data[192..224], order.taker_amount);
    writeU256(struct_data[224..256], order.side);
    writeU256(struct_data[256..288], order.signature_type);
    writeU256_wide(struct_data[288..320], order.timestamp);
    @memcpy(struct_data[320..352], &order.metadata);
    @memcpy(struct_data[352..384], &order.builder);

    const struct_hash = crypto.Keccak256.hash(&struct_data);

    // Final digest
    var envelope: [2 + 32 + 32]u8 = undefined;
    envelope[0] = 0x19;
    envelope[1] = 0x01;
    @memcpy(envelope[2..34], &domain_separator);
    @memcpy(envelope[34..66], &struct_hash);

    return crypto.Keccak256.hash(&envelope);
}

// ---------------------------------------------------------------------------
// Signature formatting
// ---------------------------------------------------------------------------

/// Format an ECDSA signature as 0x-prefixed hex string (r ++ s ++ v) = 132 chars.
pub fn formatSignature(sig: crypto.Signature) [132]u8 {
    var out: [132]u8 = undefined;
    out[0] = '0';
    out[1] = 'x';

    var raw: [65]u8 = undefined;
    @memcpy(raw[0..32], &sig.r);
    @memcpy(raw[32..64], &sig.s);
    raw[64] = sig.v;

    const charset = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        out[2 + i * 2] = charset[b >> 4];
        out[2 + i * 2 + 1] = charset[b & 0x0f];
    }
    return out;
}

/// Format an Ethereum address using EIP-55 checksum casing.
pub fn formatAddressEip55(addr: [20]u8) [42]u8 {
    var lower_hex: [40]u8 = undefined;
    const charset = "0123456789abcdef";
    for (addr, 0..) |b, i| {
        lower_hex[i * 2] = charset[b >> 4];
        lower_hex[i * 2 + 1] = charset[b & 0x0f];
    }

    const digest = crypto.Keccak256.hash(&lower_hex);

    var out: [42]u8 = undefined;
    out[0] = '0';
    out[1] = 'x';
    for (lower_hex, 0..) |ch, i| {
        if (ch >= 'a' and ch <= 'f') {
            const hash_byte = digest[i / 2];
            const nibble: u8 = if ((i & 1) == 0) (hash_byte >> 4) & 0x0f else hash_byte & 0x0f;
            out[2 + i] = if (nibble >= 8) std.ascii.toUpper(ch) else ch;
        } else {
            out[2 + i] = ch;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Order amount helpers
// ---------------------------------------------------------------------------

pub const OrderAmounts = struct {
    maker_amount: u64,
    taker_amount: u64,
};

/// Compute maker/taker amounts in 1e6 (USDC) units from price and size.
/// BUY:  makerAmount = size * price, takerAmount = size
/// SELL: makerAmount = size, takerAmount = size * price
pub fn computeOrderAmounts(side: u8, price_f: f64, size_f: f64) !OrderAmounts {
    const scale: f64 = 1e6;
    if (side != 0 and side != 1)
        return error.InvalidInput;
    if (!std.math.isFinite(price_f) or !std.math.isFinite(size_f))
        return error.InvalidInput;
    if (std.math.isNan(price_f) or std.math.isNan(size_f))
        return error.InvalidInput;
    if (price_f < 0 or size_f < 0)
        return error.InvalidInput;

    var maker_f: f64 = undefined;
    var taker_f: f64 = undefined;
    if (side == 0) {
        // BUY
        maker_f = size_f * price_f * scale;
        taker_f = size_f * scale;
    } else {
        // SELL
        maker_f = size_f * scale;
        taker_f = size_f * price_f * scale;
    }
    const maker_rounded = @round(maker_f);
    const taker_rounded = @round(taker_f);
    const u64_max_f: f64 = @floatFromInt(std.math.maxInt(u64));
    if (maker_rounded < 0 or maker_rounded > u64_max_f)
        return error.InvalidInput;
    if (taker_rounded < 0 or taker_rounded > u64_max_f)
        return error.InvalidInput;
    return OrderAmounts{
        .maker_amount = @intFromFloat(maker_rounded),
        .taker_amount = @intFromFloat(taker_rounded),
    };
}

// ---------------------------------------------------------------------------
// USDC balance fetch (L2 GET /balance-allowance)
// ---------------------------------------------------------------------------

/// Fetch the current USDC (collateral) balance for the Polymarket account
/// address that actually holds funds. In proxy / Safe setups this may differ
/// from the signing key address. Returns the balance in whole USDC units
/// (i.e. raw 1e6 units divided by 1e6). The HMAC signs only the path
/// "/balance-allowance" (without the query string), matching py-clob-client
/// behaviour.
pub fn fetchUsdcBalance(
    allocator: std.mem.Allocator,
    creds: ApiCredentials,
    auth_address: [20]u8,
    signature_type: u8,
) !f64 {
    // Path used in the HMAC signature (no query string).
    const sign_path = "/balance-allowance";

    // Path with query string actually sent to the server.
    var path_q_buf: [128]u8 = undefined;
    const path_with_query = std.fmt.bufPrint(
        &path_q_buf,
        "/balance-allowance?asset_type=COLLATERAL&signature_type={d}",
        .{signature_type},
    ) catch return error.FormatFailed;

    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ CLOB_API_BASE, path_with_query }) catch
        return error.FormatFailed;

    var ts_buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch
        return error.FormatFailed;

    const hmac = try buildHmacSignature(
        creds.secret[0..creds.secret_len],
        ts,
        "GET",
        sign_path,
        null,
    );

    const addr_hex = formatAddressEip55(auth_address);

    var client = http.HttpClient.init(allocator);
    defer client.deinit();

    var response = client.getWithHeaders(url, &.{
        .{ .name = "POLY_ADDRESS", .value = &addr_hex },
        .{ .name = "POLY_SIGNATURE", .value = hmac.slice() },
        .{ .name = "POLY_TIMESTAMP", .value = ts },
        .{ .name = "POLY_API_KEY", .value = creds.api_key[0..creds.api_key_len] },
        .{ .name = "POLY_PASSPHRASE", .value = creds.passphrase[0..creds.passphrase_len] },
    }) catch |e| {
        log.err("poly_auth", "balance-allowance request failed: {s}", .{@errorName(e)});
        return error.RequestFailed;
    };
    defer response.deinit();

    if (response.status.class() != .success) {
        log.err("poly_auth", "balance-allowance status {d}: {s}", .{
            @intFromEnum(response.status),
            response.body[0..@min(response.body.len, 256)],
        });
        return error.RequestFailed;
    }

    return parseBalanceResponse(response.body);
}

/// Parse {"balance":"<raw_1e6>",...} into whole USDC units.
pub fn parseBalanceResponse(body: []const u8) !f64 {
    var parse_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&parse_buf);
    const alloc = fba.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return error.ParseFailed;

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.ParseFailed,
    };

    const bal_v = obj.get("balance") orelse return error.ParseFailed;
    const bal_str = switch (bal_v) {
        .string => |s| s,
        else => return error.ParseFailed,
    };

    const raw = std.fmt.parseFloat(f64, bal_str) catch return error.ParseFailed;
    return raw / 1_000_000.0;
}

// ---------------------------------------------------------------------------
// API credential bootstrapping
// ---------------------------------------------------------------------------

pub const ApiCredentials = struct {
    api_key: [64]u8,
    api_key_len: usize,
    secret: [128]u8,
    secret_len: usize,
    passphrase: [64]u8,
    passphrase_len: usize,
};

pub fn parseSignatureType(value: []const u8) !u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "EOA") or std.mem.eql(u8, trimmed, "0")) return 0;
    if (std.ascii.eqlIgnoreCase(trimmed, "POLY_PROXY") or
        std.ascii.eqlIgnoreCase(trimmed, "POLYPROXY") or
        std.ascii.eqlIgnoreCase(trimmed, "PROXY") or
        std.mem.eql(u8, trimmed, "1")) return 1;
    if (std.ascii.eqlIgnoreCase(trimmed, "GNOSIS_SAFE") or
        std.ascii.eqlIgnoreCase(trimmed, "GNOSIS") or
        std.ascii.eqlIgnoreCase(trimmed, "SAFE") or
        std.mem.eql(u8, trimmed, "2")) return 2;
    if (std.ascii.eqlIgnoreCase(trimmed, "POLY_1271") or
        std.ascii.eqlIgnoreCase(trimmed, "1271") or
        std.ascii.eqlIgnoreCase(trimmed, "DEPOSIT_WALLET") or
        std.ascii.eqlIgnoreCase(trimmed, "DEPOSIT") or
        std.mem.eql(u8, trimmed, "3")) return 3;
    return error.InvalidSignatureType;
}

pub fn signatureTypeName(signature_type: u8) []const u8 {
    return switch (signature_type) {
        0 => "EOA",
        1 => "POLY_PROXY",
        2 => "GNOSIS_SAFE",
        3 => "POLY_1271",
        else => "EOA",
    };
}

pub fn buildPoly1271OrderSignature(
    order: CtfOrder,
    chain_id: u64,
    exchange_addr: [20]u8,
    private_key: [32]u8,
) ![]u8 {
    const app_domain_separator = computeExchangeDomainSeparator(chain_id, exchange_addr);
    const contents_hash = computeOrderContentsHash(order);

    const solady_type_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash(TYPED_DATA_SIGN_TYPE_STRING);
    };
    const deposit_wallet_name_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash("DepositWallet");
    };
    const deposit_wallet_version_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash("1");
    };
    const zero_bytes32 = [_]u8{0} ** 32;

    var typed_sign_data: [7 * 32]u8 = undefined;
    @memcpy(typed_sign_data[0..32], &solady_type_hash);
    @memcpy(typed_sign_data[32..64], &contents_hash);
    @memcpy(typed_sign_data[64..96], &deposit_wallet_name_hash);
    @memcpy(typed_sign_data[96..128], &deposit_wallet_version_hash);
    writeU256(typed_sign_data[128..160], chain_id);
    writeAddrPadded(typed_sign_data[160..192], order.signer);
    @memcpy(typed_sign_data[192..224], &zero_bytes32);
    const typed_sign_struct_hash = crypto.Keccak256.hash(&typed_sign_data);

    var envelope: [2 + 32 + 32]u8 = undefined;
    envelope[0] = 0x19;
    envelope[1] = 0x01;
    @memcpy(envelope[2..34], &app_domain_separator);
    @memcpy(envelope[34..66], &typed_sign_struct_hash);
    const digest = crypto.Keccak256.hash(&envelope);

    const inner_sig = try crypto.signEip712(digest, private_key);
    const inner_sig_hex = formatSignature(inner_sig);
    const order_type_hex_len = ORDER_V2_TYPE_STRING.len * 2;

    const total_len = 2 + 130 + 64 + 64 + order_type_hex_len + 4;
    var out = try std.heap.page_allocator.alloc(u8, total_len);
    out[0] = '0';
    out[1] = 'x';

    @memcpy(out[2..132], inner_sig_hex[2..132]);

    var domain_hex_buf: [64]u8 = undefined;
    _ = bytesToHexInto(&app_domain_separator, &domain_hex_buf);
    @memcpy(out[132..196], &domain_hex_buf);

    var contents_hex_buf: [64]u8 = undefined;
    _ = bytesToHexInto(&contents_hash, &contents_hex_buf);
    @memcpy(out[196..260], &contents_hex_buf);

    _ = bytesToHexInto(ORDER_V2_TYPE_STRING, out[260 .. 260 + order_type_hex_len]);

    const type_len_u16: u16 = @intCast(ORDER_V2_TYPE_STRING.len);
    var type_len_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &type_len_bytes, type_len_u16, .big);
    _ = bytesToHexInto(&type_len_bytes, out[260 + order_type_hex_len .. total_len]);

    return out;
}

pub fn parseAddress(value: []const u8) ![20]u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const hex = if (trimmed.len >= 2 and trimmed[0] == '0' and (trimmed[1] == 'x' or trimmed[1] == 'X'))
        trimmed[2..]
    else
        trimmed;
    if (hex.len != 40) return error.InvalidAddress;

    var out: [20]u8 = undefined;
    for (0..20) |i| {
        out[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return error.InvalidAddress;
    }
    return out;
}

/// Bootstrap API credentials via the same create-or-derive flow used by the
/// official CLOB clients. Try POST /auth/api-key first, then fall back to
/// GET /auth/derive-api-key if creation does not produce usable creds.
pub fn bootstrapApiCredentials(
    allocator: std.mem.Allocator,
    private_key: [32]u8,
    address: [20]u8,
) !ApiCredentials {
    // Build L1 auth headers
    var ts_buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch
        return error.FormatFailed;

    const nonce: u64 = 0;
    const digest = buildClobAuthDigest(address, ts, nonce);
    const sig = try crypto.signEip712(digest, private_key);
    const sig_hex = formatSignature(sig);

    const addr_hex = formatAddressEip55(address);

    var nonce_buf: [32]u8 = undefined;
    const nonce_str = std.fmt.bufPrint(&nonce_buf, "{d}", .{nonce}) catch
        return error.FormatFailed;

    const auth_headers = [_]std.http.Header{
        .{ .name = "POLY_ADDRESS", .value = addr_hex[0..] },
        .{ .name = "POLY_SIGNATURE", .value = sig_hex[0..] },
        .{ .name = "POLY_TIMESTAMP", .value = ts },
        .{ .name = "POLY_NONCE", .value = nonce_str },
    };

    // Match the official client bootstrap sequence: create first, then derive.
    const derive_url = CLOB_API_BASE ++ "/auth/derive-api-key";
    const create_url = CLOB_API_BASE ++ "/auth/api-key";

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const result = tryAuthRequest(allocator, &client, .POST, create_url, "", &auth_headers) catch |e| blk: {
        log.info("poly_auth", "create-api-key failed ({s}), trying GET derive", .{@errorName(e)});
        break :blk tryAuthRequest(allocator, &client, .GET, derive_url, null, &auth_headers) catch |e2| {
            log.err("poly_auth", "GET /auth/derive-api-key also failed: {s}", .{@errorName(e2)});
            return e2;
        };
    };
    defer allocator.free(result);

    return parseApiCredentials(result);
}

fn tryAuthRequest(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    headers: []const std.http.Header,
) ![]const u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;

    var all_headers: [8]std.http.Header = undefined;
    var hdr_count: usize = 0;
    for (headers) |h| {
        all_headers[hdr_count] = h;
        hdr_count += 1;
    }
    all_headers[hdr_count] = .{ .name = "Accept-Encoding", .value = "identity" };
    hdr_count += 1;
    if (payload != null) {
        all_headers[hdr_count] = .{ .name = "Content-Type", .value = "application/json" };
        hdr_count += 1;
    }

    var body_writer = std.Io.Writer.Allocating.init(allocator);
    errdefer body_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = method,
        .payload = payload,
        .response_writer = &body_writer.writer,
        .extra_headers = all_headers[0..hdr_count],
    }) catch {
        return error.RequestFailed;
    };

    const status_class = result.status.class();
    if (status_class == .client_error or status_class == .server_error) {
        const err_body = body_writer.toOwnedSlice() catch "";
        defer if (err_body.len > 0) allocator.free(err_body);
        log.err("poly_auth", "auth request {d}: {s}", .{ @intFromEnum(result.status), err_body });
        return if (status_class == .client_error) error.ClientError else error.ServerError;
    }

    return body_writer.toOwnedSlice() catch error.RequestFailed;
}

fn parseApiCredentials(body: []const u8) !ApiCredentials {
    var creds: ApiCredentials = .{
        .api_key = undefined,
        .api_key_len = 0,
        .secret = undefined,
        .secret_len = 0,
        .passphrase = undefined,
        .passphrase_len = 0,
    };

    // Use a stack allocator for JSON parsing
    var parse_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&parse_buf);
    const alloc = fba.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return error.ParseFailed;

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.ParseFailed,
    };

    if (obj.get("apiKey")) |v| {
        if (v == .string) {
            if (v.string.len > creds.api_key.len) return error.FieldTooLong;
            @memcpy(creds.api_key[0..v.string.len], v.string);
            creds.api_key_len = v.string.len;
        }
    }
    if (obj.get("secret")) |v| {
        if (v == .string) {
            if (v.string.len > creds.secret.len) return error.FieldTooLong;
            @memcpy(creds.secret[0..v.string.len], v.string);
            creds.secret_len = v.string.len;
        }
    }
    if (obj.get("passphrase")) |v| {
        if (v == .string) {
            if (v.string.len > creds.passphrase.len) return error.FieldTooLong;
            @memcpy(creds.passphrase[0..v.string.len], v.string);
            creds.passphrase_len = v.string.len;
        }
    }

    if (creds.api_key_len == 0 or creds.secret_len == 0 or creds.passphrase_len == 0)
        return error.ParseFailed;

    return creds;
}

// ---------------------------------------------------------------------------
// ABI encoding helpers
// ---------------------------------------------------------------------------

/// Write a u64 as a big-endian 32-byte word.
fn writeU256(buf: *[32]u8, value: u64) void {
    @memset(buf[0..24], 0);
    std.mem.writeInt(u64, buf[24..32], value, .big);
}

/// Write a u256 as a big-endian 32-byte word.
fn writeU256_wide(buf: *[32]u8, value: u256) void {
    std.mem.writeInt(u256, buf, value, .big);
}

/// Write an address left-padded to 32 bytes.
fn writeAddrPadded(buf: *[32]u8, addr: [20]u8) void {
    @memset(buf[0..12], 0);
    @memcpy(buf[12..32], &addr);
}

fn computeExchangeDomainSeparator(chain_id: u64, exchange_addr: [20]u8) [32]u8 {
    const domain_type_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    };
    const name_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash("Polymarket CTF Exchange");
    };
    const version_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash("2");
    };

    var domain_data: [5 * 32]u8 = undefined;
    @memcpy(domain_data[0..32], &domain_type_hash);
    @memcpy(domain_data[32..64], &name_hash);
    @memcpy(domain_data[64..96], &version_hash);
    writeU256(domain_data[96..128], chain_id);
    writeAddrPadded(domain_data[128..160], exchange_addr);
    return crypto.Keccak256.hash(&domain_data);
}

fn computeOrderContentsHash(order: CtfOrder) [32]u8 {
    const order_type_hash = comptime blk: {
        @setEvalBranchQuota(100000);
        break :blk crypto.Keccak256.hash(ORDER_V2_TYPE_STRING);
    };

    var struct_data: [12 * 32]u8 = undefined;
    @memcpy(struct_data[0..32], &order_type_hash);
    writeU256_wide(struct_data[32..64], order.salt);
    writeAddrPadded(struct_data[64..96], order.maker);
    writeAddrPadded(struct_data[96..128], order.signer);
    writeU256_wide(struct_data[128..160], order.token_id);
    writeU256_wide(struct_data[160..192], order.maker_amount);
    writeU256_wide(struct_data[192..224], order.taker_amount);
    writeU256(struct_data[224..256], order.side);
    writeU256(struct_data[256..288], order.signature_type);
    writeU256_wide(struct_data[288..320], order.timestamp);
    @memcpy(struct_data[320..352], &order.metadata);
    @memcpy(struct_data[352..384], &order.builder);
    return crypto.Keccak256.hash(&struct_data);
}

fn bytesToHexInto(bytes: []const u8, out: []u8) []const u8 {
    std.debug.assert(out.len >= bytes.len * 2);
    const charset = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = charset[b >> 4];
        out[i * 2 + 1] = charset[b & 0x0f];
    }
    return out[0 .. bytes.len * 2];
}

/// Parse a 40-char hex string into a 20-byte address at comptime.
fn parseAddr(comptime hex: *const [40]u8) [20]u8 {
    var out: [20]u8 = undefined;
    for (0..20) |i| {
        out[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch unreachable;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "deriveAddress: produces valid 20-byte address" {
    // Well-known test private key
    const privkey = hexToBytes("4c0883a69102937d6231471b5dbb6204fe512961708279f0b4a1c3e3e1f3e3e0");
    const addr = try deriveAddress(privkey);
    // Must be non-zero
    const zero20 = [_]u8{0} ** 20;
    try testing.expect(!std.mem.eql(u8, &addr, &zero20));
    // Must be deterministic
    const addr2 = try deriveAddress(privkey);
    try testing.expectEqualSlices(u8, &addr, &addr2);
}

test "buildClobAuthDigest: produces 32-byte digest" {
    const addr = hexToBytes("2c7536e3605d9c16a7a3d7b1898e529396a65c23");
    const digest = buildClobAuthDigest(addr, "1234567890", 0);
    const zero32 = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &digest, &zero32));
}

test "buildHmacSignature: roundtrip" {
    // base64url of "supersecret" = "c3VwZXJzZWNyZXQ="
    const result = try buildHmacSignature("c3VwZXJzZWNyZXQ=", "1234567890", "GET", "/test", null);
    try testing.expect(result.len > 0);
    // Verify no standard base64 chars leak through
    for (result.buf[0..result.len]) |ch| {
        try testing.expect(ch != '+');
        try testing.expect(ch != '/');
    }
}

test "computeOrderAmounts: BUY" {
    const amounts = try computeOrderAmounts(0, 0.50, 10.0);
    try testing.expectEqual(@as(u64, 5_000_000), amounts.maker_amount);
    try testing.expectEqual(@as(u64, 10_000_000), amounts.taker_amount);
}

test "computeOrderAmounts: SELL" {
    const amounts = try computeOrderAmounts(1, 0.50, 10.0);
    try testing.expectEqual(@as(u64, 10_000_000), amounts.maker_amount);
    try testing.expectEqual(@as(u64, 5_000_000), amounts.taker_amount);
}

test "computeOrderAmounts: invalid side" {
    try testing.expectError(error.InvalidInput, computeOrderAmounts(2, 0.5, 10.0));
}
test "computeOrderAmounts: negative price" {
    try testing.expectError(error.InvalidInput, computeOrderAmounts(0, -1.0, 10.0));
}
test "computeOrderAmounts: negative size" {
    try testing.expectError(error.InvalidInput, computeOrderAmounts(1, 0.5, -10.0));
}
test "computeOrderAmounts: nan" {
    try testing.expectError(error.InvalidInput, computeOrderAmounts(0, std.math.nan(f64), 10.0));
    try testing.expectError(error.InvalidInput, computeOrderAmounts(0, 0.5, std.math.nan(f64)));
}
test "computeOrderAmounts: inf" {
    try testing.expectError(error.InvalidInput, computeOrderAmounts(0, std.math.inf(f64), 10.0));
    try testing.expectError(error.InvalidInput, computeOrderAmounts(0, 0.5, std.math.inf(f64)));
}
test "computeOrderAmounts: overflow" {
    // Use a value that will overflow u64 after scaling
    try testing.expectError(error.InvalidInput, computeOrderAmounts(0, 1e20, 1e20));
}

test "formatSignature: produces 0x-prefixed 130-char hex" {
    const sig = crypto.Signature{
        .r = [_]u8{0xaa} ** 32,
        .s = [_]u8{0xbb} ** 32,
        .v = 27,
    };
    const hex = formatSignature(sig);
    try testing.expectEqualStrings("0x", hex[0..2]);
    try testing.expectEqual(@as(usize, 132), hex.len);
    // v=27 = 0x1b at the end
    try testing.expectEqualStrings("1b", hex[130..132]);
}

test "parseAddr: constant addresses" {
    // Verify the constant addresses parse without error
    try testing.expectEqual(@as(u8, 0xE1), CTF_EXCHANGE[0]);
    try testing.expectEqual(@as(u8, 0xe2), NEG_RISK_CTF_EXCHANGE[0]);
}

test "buildOrderDigest: produces 32-byte digest" {
    const order = CtfOrder{
        .salt = 123456,
        .maker = [_]u8{0x01} ** 20,
        .signer = [_]u8{0x02} ** 20,
        .token_id = 999,
        .maker_amount = 1_000_000,
        .taker_amount = 2_000_000,
        .side = 0,
        .signature_type = 0,
        .timestamp = 1_713_398_400_000,
        .metadata = [_]u8{0} ** 32,
        .builder = [_]u8{0} ** 32,
    };
    const digest = buildOrderDigest(order, CHAIN_ID, CTF_EXCHANGE);
    const zero32 = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &digest, &zero32));
}

test "buildOrderDigest/signature: matches official V2 EOA reference" {
    const private_key = hexToBytes("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
    const signer = try parseAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const exchange = try parseAddress("0xE111180000d2663C0091e4f400237545B87B996B");

    const order = CtfOrder{
        .salt = 479249096354,
        .maker = signer,
        .signer = signer,
        .token_id = 1234,
        .maker_amount = 100000000,
        .taker_amount = 50000000,
        .side = 0,
        .signature_type = 0,
        .timestamp = 1710000000000,
        .metadata = [_]u8{0} ** 32,
        .builder = [_]u8{0} ** 32,
    };

    const digest = buildOrderDigest(order, 80002, exchange);
    var digest_hex_buf: [64]u8 = undefined;
    const digest_hex = bytesToHexTest(&digest, &digest_hex_buf);
    try testing.expectEqualStrings(
        "962c97b18bea292cc94b9479272aa74fb59a905e84a621a40eb339131e9fb6ba",
        digest_hex,
    );

    const sig = try crypto.signEip712(digest, private_key);
    const sig_hex = formatSignature(sig);
    try testing.expectEqualStrings(
        "0x518472f1b081f6bd713d638bb11d1bf0720ed577e93c52eb00ec9f5f325f7d510c65cbfdfe9130de2602185f4a500863d777d8b838cb28abc75ecc1b5330315d1c",
        sig_hex[0..],
    );
}

test "parseApiCredentials: valid JSON" {
    const body =
        \\{"apiKey":"key123","secret":"sec456","passphrase":"pass789"}
    ;
    const creds = try parseApiCredentials(body);
    try testing.expectEqual(@as(usize, 6), creds.api_key_len);
    try testing.expectEqualStrings("key123", creds.api_key[0..creds.api_key_len]);
    try testing.expectEqualStrings("sec456", creds.secret[0..creds.secret_len]);
    try testing.expectEqualStrings("pass789", creds.passphrase[0..creds.passphrase_len]);
}

test "parseApiCredentials: missing field" {
    const body =
        \\{"apiKey":"key123","secret":"sec456"}
    ;
    try testing.expectError(error.ParseFailed, parseApiCredentials(body));
}

test "parseBalanceResponse: parses raw 1e6 USDC string" {
    const body =
        \\{"asset_address":"0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174","balance":"12345670","allowance":"99999","asset_type":"COLLATERAL"}
    ;
    const bal = try parseBalanceResponse(body);
    try testing.expectApproxEqAbs(@as(f64, 12.34567), bal, 1e-9);
}

test "parseBalanceResponse: zero balance" {
    const body = "{\"balance\":\"0\"}";
    const bal = try parseBalanceResponse(body);
    try testing.expectEqual(@as(f64, 0.0), bal);
}

test "parseBalanceResponse: missing balance field" {
    const body = "{\"allowance\":\"100\"}";
    try testing.expectError(error.ParseFailed, parseBalanceResponse(body));
}

test "parseSignatureType: accepts ids and names" {
    try testing.expectEqual(@as(u8, 0), try parseSignatureType("0"));
    try testing.expectEqual(@as(u8, 0), try parseSignatureType("EOA"));
    try testing.expectEqual(@as(u8, 1), try parseSignatureType("POLY_PROXY"));
    try testing.expectEqual(@as(u8, 1), try parseSignatureType("proxy"));
    try testing.expectEqual(@as(u8, 2), try parseSignatureType("GNOSIS_SAFE"));
    try testing.expectEqual(@as(u8, 2), try parseSignatureType("safe"));
    try testing.expectEqual(@as(u8, 3), try parseSignatureType("3"));
    try testing.expectEqual(@as(u8, 3), try parseSignatureType("POLY_1271"));
    try testing.expectEqual(@as(u8, 3), try parseSignatureType("deposit_wallet"));
    try testing.expectError(error.InvalidSignatureType, parseSignatureType("4"));
}

test "signatureTypeName: renders API enum names" {
    try testing.expectEqualStrings("EOA", signatureTypeName(0));
    try testing.expectEqualStrings("POLY_PROXY", signatureTypeName(1));
    try testing.expectEqualStrings("GNOSIS_SAFE", signatureTypeName(2));
    try testing.expectEqualStrings("POLY_1271", signatureTypeName(3));
}

test "parseAddress: accepts 0x and plain hex" {
    const expected = hexToBytes("2c7536e3605d9c16a7a3d7b1898e529396a65c23");
    const a = try parseAddress("0x2c7536e3605d9c16a7a3d7b1898e529396a65c23");
    const b = try parseAddress("2c7536e3605d9c16a7a3d7b1898e529396a65c23");
    try testing.expectEqualSlices(u8, &expected, &a);
    try testing.expectEqualSlices(u8, &expected, &b);
    try testing.expectError(error.InvalidAddress, parseAddress("0x1234"));
}

// Test helpers

fn hexToBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    for (0..out.len) |i| {
        out[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch unreachable;
    }
    return out;
}

fn bytesToHexTest(bytes: []const u8, buf: []u8) []const u8 {
    const charset = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        buf[i * 2] = charset[b >> 4];
        buf[i * 2 + 1] = charset[b & 0x0f];
    }
    return buf[0 .. bytes.len * 2];
}
