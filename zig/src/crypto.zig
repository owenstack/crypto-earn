//! Keccak-256 hash and secp256k1 ECDSA signing for EIP-712.
const std = @import("std");

const c = @cImport({
    @cInclude("secp256k1.h");
    @cInclude("secp256k1_recovery.h");
});

// --- Keccak-256 (pure Zig) ---

/// Keccak-256 hasher (Ethereum variant: 0x01 padding, NOT SHA-3 0x06).
/// Rate = 1088 bits (136 bytes), capacity = 512 bits, output = 256 bits.
pub const Keccak256 = struct {
    state: [25]u64,
    buf: [rate]u8,
    buf_len: usize,

    const rate = 136;

    pub fn init() Keccak256 {
        return .{
            .state = [_]u64{0} ** 25,
            .buf = [_]u8{0} ** rate,
            .buf_len = 0,
        };
    }

    pub fn update(self: *Keccak256, data: []const u8) void {
        var off: usize = 0;
        var remaining = data.len;

        // Fill partial buffer first
        if (self.buf_len > 0) {
            const space = rate - self.buf_len;
            if (remaining < space) {
                @memcpy(self.buf[self.buf_len .. self.buf_len + remaining], data);
                self.buf_len += remaining;
                return;
            }
            @memcpy(self.buf[self.buf_len..rate], data[0..space]);
            self.absorb(&self.buf);
            self.buf_len = 0;
            off = space;
            remaining -= space;
        }

        // Absorb full blocks
        while (remaining >= rate) {
            self.absorb(data[off..][0..rate]);
            off += rate;
            remaining -= rate;
        }

        // Buffer remainder
        if (remaining > 0) {
            @memcpy(self.buf[0..remaining], data[off .. off + remaining]);
            self.buf_len = remaining;
        }
    }

    pub fn final(self: *Keccak256) [32]u8 {
        // Keccak padding (NOT SHA-3): pad byte = 0x01
        @memset(self.buf[self.buf_len..rate], 0);
        self.buf[self.buf_len] = 0x01;
        self.buf[rate - 1] |= 0x80;
        self.absorb(&self.buf);

        // Squeeze 32 bytes from state
        var out: [32]u8 = undefined;
        for (0..4) |i| {
            std.mem.writeInt(u64, out[i * 8 ..][0..8], self.state[i], .little);
        }
        return out;
    }

    /// Convenience one-shot hash.
    pub fn hash(data: []const u8) [32]u8 {
        var h = Keccak256.init();
        h.update(data);
        return h.final();
    }

    fn absorb(self: *Keccak256, block: *const [rate]u8) void {
        for (0..rate / 8) |i| {
            self.state[i] ^= std.mem.readInt(u64, block[i * 8 ..][0..8], .little);
        }
        keccakF1600(&self.state);
    }
};

// --- Keccak-f[1600] permutation ---

const rc: [24]u64 = .{
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
};

const rot_offsets: [25]u6 = .{
    0,  1, 62, 28, 27,
    36, 44,  6, 55, 20,
    3, 10, 43, 25, 39,
    41, 45, 15, 21,  8,
    18,  2, 61, 56, 14,
};

fn keccakF1600(state: *[25]u64) void {
    var a = state.*;

    for (rc) |round_const| {
        // θ (theta)
        var col: [5]u64 = undefined;
        for (0..5) |x| {
            col[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20];
        }
        for (0..5) |x| {
            const d = col[(x + 4) % 5] ^ std.math.rotl(u64, col[(x + 1) % 5], 1);
            for (0..5) |y| {
                a[x + 5 * y] ^= d;
            }
        }

        // ρ (rho) + π (pi)
        var b: [25]u64 = undefined;
        for (0..25) |i| {
            const x = i % 5;
            const y = i / 5;
            const dest = y + 5 * ((2 * x + 3 * y) % 5);
            b[dest] = std.math.rotl(u64, a[i], @as(u64, rot_offsets[i]));
        }

        // χ (chi)
        for (0..5) |y| {
            const base = 5 * y;
            for (0..5) |x| {
                a[base + x] = b[base + x] ^ (~b[base + (x + 1) % 5] & b[base + (x + 2) % 5]);
            }
        }

        // ι (iota)
        a[0] ^= round_const;
    }

    state.* = a;
}

// --- EIP-712 Signing ---

pub const Signature = struct {
    r: [32]u8,
    s: [32]u8,
    v: u8, // 27 or 28
};

/// Sign a 32-byte EIP-712 digest with a 32-byte private key.
/// Returns the (r, s, v) signature compatible with Ethereum ecrecover.
pub fn signEip712(digest: [32]u8, private_key: [32]u8) !Signature {
    const ctx = c.secp256k1_context_create(c.SECP256K1_CONTEXT_NONE) orelse
        return error.Secp256k1ContextFailed;
    defer c.secp256k1_context_destroy(ctx);

    var sig: c.secp256k1_ecdsa_recoverable_signature = undefined;
    if (c.secp256k1_ecdsa_sign_recoverable(ctx, &sig, &digest, &private_key, null, null) != 1)
        return error.Secp256k1SignFailed;

    var compact: [64]u8 = undefined;
    var recid: c_int = 0;
    _ = c.secp256k1_ecdsa_recoverable_signature_serialize_compact(ctx, &compact, &recid, &sig);

    return Signature{
        .r = compact[0..32].*,
        .s = compact[32..64].*,
        .v = @intCast(@as(c_uint, @bitCast(recid)) + 27),
    };
}

// --- Tests ---

const testing = std.testing;

fn hexToBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    for (0..out.len) |i| {
        out[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch unreachable;
    }
    return out;
}

fn bytesToHex(bytes: []const u8, buf: []u8) []const u8 {
    const charset = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        buf[i * 2] = charset[b >> 4];
        buf[i * 2 + 1] = charset[b & 0x0f];
    }
    return buf[0 .. bytes.len * 2];
}

test "keccak256: empty string" {
    const digest = Keccak256.hash("");
    var buf: [64]u8 = undefined;
    const hex = bytesToHex(&digest, &buf);
    try testing.expectEqualStrings("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", hex);
}

test "keccak256: hello world" {
    // keccak256("hello world") — well-known Ethereum test vector
    const digest = Keccak256.hash("hello world");
    var buf: [64]u8 = undefined;
    const hex = bytesToHex(&digest, &buf);
    try testing.expectEqualStrings("47173285a8d7341e5e972fc677286384f802f8ef42a5ec5f03bbfa254cb01fad", hex);
}

test "signEip712: produces valid signature struct" {
    // Deterministic test key (do NOT use in production)
    const privkey = hexToBytes("4c0883a69102937d6231471b5dbb6204fe512961708279f0b4a1c3e3e1f3e3e0");
    const digest = hexToBytes("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    const sig = try signEip712(digest, privkey);

    // v must be 27 or 28
    try testing.expect(sig.v == 27 or sig.v == 28);
    // r and s must be non-zero
    const zero32 = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &sig.r, &zero32));
    try testing.expect(!std.mem.eql(u8, &sig.s, &zero32));
}
