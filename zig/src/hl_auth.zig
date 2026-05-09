//! Hyperliquid auth/signing helpers.
//!
//! Responsibilities:
//!   - parse the operator's API-wallet private key from hex
//!   - derive the corresponding 20-byte Ethereum address (secp256k1 → keccak256)
//!   - format addresses in EIP-55 mixed-case checksum form
//!   - assemble the EIP-712 domain separator for the configured network
//!   - compute the action digest used for signing the HL `/exchange` payload
//!   - wrap `crypto.signEip712` and produce JSON-ready r/s/v hex strings
//!
//! Phase 2 scope: domain values and chainId are fully configurable via env so
//! we can match either the L1-actions phantom-agent layout or a future
//! verifying-contract once the operator confirms the live values.

const std = @import("std");
const crypto = @import("crypto.zig");

const c = @cImport({
    @cInclude("secp256k1.h");
});

pub const Network = enum { testnet, mainnet };

pub const CHAIN_ID_TESTNET: u64 = 998;
pub const CHAIN_ID_MAINNET: u64 = 999;

pub const ParseError = error{
    InvalidLength,
    InvalidHex,
    Secp256k1Error,
};

/// Parse a 32-byte private key from hex (with or without `0x` prefix).
/// Refuses any input shorter or longer than 64 hex chars after stripping the
/// optional prefix. Never logs the input.
pub fn parsePrivateKeyHex(input: []const u8) ParseError![32]u8 {
    var s = input;
    if (s.len >= 2 and (std.mem.eql(u8, s[0..2], "0x") or std.mem.eql(u8, s[0..2], "0X"))) {
        s = s[2..];
    }
    if (s.len != 64) return error.InvalidLength;

    var out: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        out[i] = std.fmt.parseInt(u8, s[i * 2 .. i * 2 + 2], 16) catch return error.InvalidHex;
    }
    return out;
}

/// Parse a 20-byte address from hex (with or without `0x` prefix).
pub fn parseAddressHex(input: []const u8) ParseError![20]u8 {
    var s = input;
    if (s.len >= 2 and (std.mem.eql(u8, s[0..2], "0x") or std.mem.eql(u8, s[0..2], "0X"))) {
        s = s[2..];
    }
    if (s.len != 40) return error.InvalidLength;

    var out: [20]u8 = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        out[i] = std.fmt.parseInt(u8, s[i * 2 .. i * 2 + 2], 16) catch return error.InvalidHex;
    }
    return out;
}

/// Derive the 20-byte Ethereum address from a 32-byte secp256k1 private key.
/// Address = last 20 bytes of keccak256(uncompressed_pubkey[1..]).
pub fn derivePublicAddress(private_key: [32]u8) ParseError![20]u8 {
    const ctx = c.secp256k1_context_create(c.SECP256K1_CONTEXT_SIGN) orelse
        return error.Secp256k1Error;
    defer c.secp256k1_context_destroy(ctx);

    var pub_internal: c.secp256k1_pubkey = undefined;
    if (c.secp256k1_ec_pubkey_create(ctx, &pub_internal, &private_key) != 1) {
        return error.Secp256k1Error;
    }

    var serialized: [65]u8 = undefined;
    var serialized_len: usize = 65;
    if (c.secp256k1_ec_pubkey_serialize(
        ctx,
        &serialized,
        &serialized_len,
        &pub_internal,
        c.SECP256K1_EC_UNCOMPRESSED,
    ) != 1) {
        return error.Secp256k1Error;
    }

    // Skip the 0x04 prefix; hash the 64-byte XY portion.
    const digest = crypto.Keccak256.hash(serialized[1..65]);
    var addr: [20]u8 = undefined;
    @memcpy(&addr, digest[12..32]);
    return addr;
}

/// Format a 20-byte address as a 42-char EIP-55 mixed-case checksum string
/// (with the `0x` prefix). The buffer is heap-free and stack-returned.
pub fn formatAddressEip55(addr: [20]u8) [42]u8 {
    const lowercase = "0123456789abcdef";
    var hex_only: [40]u8 = undefined;
    for (addr, 0..) |b, i| {
        hex_only[i * 2] = lowercase[b >> 4];
        hex_only[i * 2 + 1] = lowercase[b & 0x0f];
    }

    const hash = crypto.Keccak256.hash(&hex_only);

    var out: [42]u8 = undefined;
    out[0] = '0';
    out[1] = 'x';
    for (hex_only, 0..) |ch, i| {
        // Each hex char is upper-cased if the corresponding 4-bit nibble of
        // the hash is >= 8. Hash nibbles: byte i/2, low nibble if i%2 == 1.
        const nibble: u8 = if (i & 1 == 0) hash[i >> 1] >> 4 else hash[i >> 1] & 0x0f;
        if (ch >= 'a' and ch <= 'f' and nibble >= 8) {
            out[i + 2] = ch - ('a' - 'A');
        } else {
            out[i + 2] = ch;
        }
    }
    return out;
}

/// Compute the EIP-712 domain separator:
///   keccak256(
///     keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)") ||
///     keccak256(name) ||
///     keccak256(version) ||
///     uint256_be(chainId) ||
///     left_pad32(verifyingContract)
///   )
pub fn buildDomainSeparator(
    name: []const u8,
    version: []const u8,
    chain_id: u64,
    verifying_contract: [20]u8,
) [32]u8 {
    const type_hash = crypto.Keccak256.hash(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
    );
    const name_hash = crypto.Keccak256.hash(name);
    const version_hash = crypto.Keccak256.hash(version);

    var chain_id_be: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(u64, chain_id_be[24..32], chain_id, .big);

    var verifier_padded: [32]u8 = [_]u8{0} ** 32;
    @memcpy(verifier_padded[12..32], &verifying_contract);

    var h = crypto.Keccak256.init();
    h.update(&type_hash);
    h.update(&name_hash);
    h.update(&version_hash);
    h.update(&chain_id_be);
    h.update(&verifier_padded);
    return h.final();
}

/// Type hash for the phantom Agent struct used by HL L1 actions:
///   Agent(string source,bytes32 connectionId)
const AGENT_TYPE_HASH: [32]u8 = blk: {
    @setEvalBranchQuota(10000);
    break :blk crypto.Keccak256.hash("Agent(string source,bytes32 connectionId)");
};

/// Build the action digest the operator signs.
///
/// connection_id = keccak256(action_msgpack || nonce_be8 || vault_or_zero(20) || source_byte)
/// Following the HL convention, `source` is "a" for mainnet ("\x00" tag),
/// "b" for testnet. Caller passes the resolved string.
///
/// EIP-712 digest = keccak256(0x1901 || domain_separator || keccak256(AGENT_TYPE_HASH || keccak256(source) || connection_id))
pub fn buildActionDigest(
    action_msgpack: []const u8,
    nonce: u64,
    vault: ?[20]u8,
    source: []const u8,
    domain_separator: [32]u8,
) [32]u8 {
    // connectionId = keccak256(msgpack || nonce_be8 || vault_byte_layout)
    var nonce_be: [8]u8 = undefined;
    std.mem.writeInt(u64, &nonce_be, nonce, .big);

    var ch = crypto.Keccak256.init();
    ch.update(action_msgpack);
    ch.update(&nonce_be);
    if (vault) |v| {
        // 0x01 prefix indicates "vault present", per HL convention.
        ch.update(&[_]u8{0x01});
        ch.update(&v);
    } else {
        // 0x00 prefix indicates no vault.
        ch.update(&[_]u8{0x00});
    }
    const connection_id = ch.final();

    // struct hash for Agent(source, connectionId)
    const source_hash = crypto.Keccak256.hash(source);
    var sh = crypto.Keccak256.init();
    sh.update(&AGENT_TYPE_HASH);
    sh.update(&source_hash);
    sh.update(&connection_id);
    const struct_hash = sh.final();

    // EIP-712 digest = keccak256(0x1901 || domain || struct_hash)
    var dh = crypto.Keccak256.init();
    dh.update(&[_]u8{ 0x19, 0x01 });
    dh.update(&domain_separator);
    dh.update(&struct_hash);
    return dh.final();
}

pub const SignedAction = struct {
    r_hex: [66]u8, // "0x" + 64 hex
    s_hex: [66]u8,
    v: u8,

    pub fn rSlice(self: *const SignedAction) []const u8 {
        return self.r_hex[0..];
    }
    pub fn sSlice(self: *const SignedAction) []const u8 {
        return self.s_hex[0..];
    }
};

pub const SignError = error{
    Secp256k1ContextFailed,
    Secp256k1SignFailed,
};

fn bytesToHex0x(bytes: [32]u8) [66]u8 {
    const charset = "0123456789abcdef";
    var out: [66]u8 = undefined;
    out[0] = '0';
    out[1] = 'x';
    for (bytes, 0..) |b, i| {
        out[2 + i * 2] = charset[b >> 4];
        out[2 + i * 2 + 1] = charset[b & 0x0f];
    }
    return out;
}

/// Sign a precomputed digest and return the JSON-ready signature.
pub fn signDigest(digest: [32]u8, private_key: [32]u8) SignError!SignedAction {
    const sig = crypto.signEip712(digest, private_key) catch |e| switch (e) {
        error.Secp256k1ContextFailed => return error.Secp256k1ContextFailed,
        error.Secp256k1SignFailed => return error.Secp256k1SignFailed,
    };
    return .{
        .r_hex = bytesToHex0x(sig.r),
        .s_hex = bytesToHex0x(sig.s),
        .v = sig.v,
    };
}

/// Resolve the runtime chainId from network + optional override.
pub fn resolveChainId(network: Network, override: ?u64) u64 {
    if (override) |c_id| return c_id;
    return switch (network) {
        .testnet => CHAIN_ID_TESTNET,
        .mainnet => CHAIN_ID_MAINNET,
    };
}

/// Resolve the source string passed into the phantom Agent struct.
pub fn resolveSource(network: Network) []const u8 {
    return switch (network) {
        .mainnet => "a",
        .testnet => "b",
    };
}

pub fn parseNetwork(s: []const u8) ParseError!Network {
    if (std.mem.eql(u8, s, "testnet")) return .testnet;
    if (std.mem.eql(u8, s, "mainnet")) return .mainnet;
    return error.InvalidLength; // reuse: unrecognised value
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "hl_auth: parsePrivateKeyHex accepts 0x and bare hex" {
    const hex = "4c0883a69102937d6231471b5dbb6204fe512961708279f0b4a1c3e3e1f3e3e0";
    const without_prefix = try parsePrivateKeyHex(hex);
    const with_prefix = try parsePrivateKeyHex("0x" ++ hex);
    try testing.expectEqualSlices(u8, &without_prefix, &with_prefix);
}

test "hl_auth: parsePrivateKeyHex rejects bad length" {
    try testing.expectError(error.InvalidLength, parsePrivateKeyHex("abcd"));
    try testing.expectError(error.InvalidLength, parsePrivateKeyHex("0x" ++ "ab" ** 31));
}

test "hl_auth: parsePrivateKeyHex rejects bad hex" {
    try testing.expectError(error.InvalidHex, parsePrivateKeyHex("zz" ** 32));
}

test "hl_auth: derivePublicAddress matches well-known vector" {
    // priv 0xc85ef7d79691fe79573b1a7064c19c1a9819ebdbd1faaab1a8ec92344438aaf4
    // → addr 0xcd2a3d9f938e13cd947ec05abc7fe734df8dd826
    const priv = try parsePrivateKeyHex("c85ef7d79691fe79573b1a7064c19c1a9819ebdbd1faaab1a8ec92344438aaf4");
    const addr = try derivePublicAddress(priv);
    var expected: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, "cd2a3d9f938e13cd947ec05abc7fe734df8dd826") catch unreachable;
    try testing.expectEqualSlices(u8, &expected, &addr);
}

test "hl_auth: formatAddressEip55 known checksum" {
    var addr: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&addr, "5aaeb6053f3e94c9b9a09f33669435e7ef1beaed");
    const out = formatAddressEip55(addr);
    try testing.expectEqualStrings("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", &out);
}

test "hl_auth: buildDomainSeparator is deterministic" {
    const verifier = [_]u8{0} ** 20;
    const a = buildDomainSeparator("Exchange", "1", 999, verifier);
    const b = buildDomainSeparator("Exchange", "1", 999, verifier);
    try testing.expectEqualSlices(u8, &a, &b);
    // Different chainId → different digest.
    const c_diff = buildDomainSeparator("Exchange", "1", 998, verifier);
    try testing.expect(!std.mem.eql(u8, &a, &c_diff));
}

test "hl_auth: buildActionDigest changes with nonce" {
    const verifier = [_]u8{0} ** 20;
    const ds = buildDomainSeparator("Exchange", "1", 999, verifier);
    const action = [_]u8{ 0x80 }; // empty msgpack map
    const a = buildActionDigest(&action, 1, null, "a", ds);
    const b = buildActionDigest(&action, 2, null, "a", ds);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "hl_auth: signDigest produces 27/28 v" {
    const priv = try parsePrivateKeyHex("4c0883a69102937d6231471b5dbb6204fe512961708279f0b4a1c3e3e1f3e3e0");
    var digest: [32]u8 = undefined;
    @memset(&digest, 0xab);
    const signed = try signDigest(digest, priv);
    try testing.expect(signed.v == 27 or signed.v == 28);
    // r/s hex strings have 0x prefix and 64 hex chars.
    try testing.expectEqualSlices(u8, "0x", signed.r_hex[0..2]);
    try testing.expectEqual(@as(usize, 66), signed.r_hex.len);
}

test "hl_auth: resolveChainId honours override and defaults" {
    try testing.expectEqual(@as(u64, 998), resolveChainId(.testnet, null));
    try testing.expectEqual(@as(u64, 999), resolveChainId(.mainnet, null));
    try testing.expectEqual(@as(u64, 12345), resolveChainId(.mainnet, 12345));
}
