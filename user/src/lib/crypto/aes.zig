//! AES-128 / AES-256 block encryption (FIPS 197 §5.1/§5.3, the forward
//! cipher) plus the key expansion. Freestanding, caller-buffered, no
//! allocation.
//!
//! TLS 1.3 needs AES for `TLS_AES_128_GCM_SHA256` and
//! `TLS_AES_256_GCM_SHA384` (RFC 8446 §9.1); both suite names are mandatory
//! to implement, and AES-GCM uses only the forward cipher (CTR mode plus
//! GHASH), so decryption is deliberately **not** implemented here. That gap
//! is stated rather than silently missing — `gcm.zig` also needs only the
//! forward direction, so nothing in the TLS 1.3 client requires it.
//!
//! The S-box is derived at comptime from the GF(2^8) multiplicative inverse
//! and the FIPS 197 affine transform rather than being transcribed as 256
//! literals, so it cannot contain a copy error; the FIPS 197 known-answer
//! tests in `aes_gcm_vectors.zig` are what pin it.
//!
//! Known limitation (stated, not hidden): this is a table-based AES, so the
//! S-box lookups are not cache-timing constant-time. That is the same class
//! of limit ADR 0023 D3 already declares for this library (no side-channel
//! hardening); it is not a regression introduced here.

const std = @import("std");

pub const block_len = 16;

/// Multiply by 2 in GF(2^8) modulo the AES polynomial x^8+x^4+x^3+x+1.
fn xtime(x: u8) u8 {
    const t: u16 = @as(u16, x) << 1;
    return if (t & 0x100 != 0) @as(u8, @truncate(t)) ^ 0x1b else @as(u8, @truncate(t));
}

/// Multiply in GF(2^8) modulo the AES polynomial.
fn gfMul(a: u8, b: u8) u8 {
    var result: u8 = 0;
    var x: u8 = a;
    var y: u8 = b;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if (y & 1 != 0) result ^= x;
        x = xtime(x);
        y >>= 1;
    }
    return result;
}

/// Rotate an 8-bit value left by n bits (using a 16-bit intermediate so the
/// shift cannot silently drop bits).
fn rotl8(x: u8, comptime n: u3) u8 {
    const t: u16 = @as(u16, x) << n;
    return @truncate(t | (t >> 8));
}

/// FIPS 197 §5.1.1 S-box, derived at comptime from the GF(2^8) inverse via a
/// discrete-log table (3 is a primitive element of GF(2^8) modulo the AES
/// polynomial). Derived rather than transcribed so a copy slip is
/// impossible; the FIPS 197 known-answer vectors are what pin it.
const sbox = blk: {
    @setEvalBranchQuota(40000);
    var exp: [256]u8 = undefined;
    var log: [256]u8 = undefined;
    var x: u8 = 1;
    for (0..255) |i| {
        exp[i] = x;
        log[x] = @intCast(i);
        x = gfMul(x, 3);
    }
    exp[255] = exp[0];
    var s: [256]u8 = undefined;
    for (0..256) |i| {
        const a: u8 = @intCast(i);
        const inv: u8 = if (a == 0) 0 else exp[255 - @as(usize, log[a])];
        s[i] = inv ^ rotl8(inv, 1) ^ rotl8(inv, 2) ^ rotl8(inv, 3) ^ rotl8(inv, 4) ^ 0x63;
    }
    break :blk s;
};

pub const Aes = struct {
    /// Expanded key schedule; 60 words is the AES-256 maximum.
    words: [60]u32 = undefined,
    rounds: u8 = 0,

    pub fn init128(key: *const [16]u8) Aes {
        return expand(key, 4, 10);
    }

    pub fn init256(key: *const [32]u8) Aes {
        return expand(key, 8, 14);
    }

    fn expand(key: []const u8, nk: usize, nr: u8) Aes {
        var self: Aes = .{ .rounds = nr };
        const total = 4 * (@as(usize, nr) + 1);
        for (0..nk) |i| self.words[i] = std.mem.readInt(u32, key[i * 4 ..][0..4], .big);
        var rcon: u8 = 1;
        var i: usize = nk;
        while (i < total) : (i += 1) {
            var t = self.words[i - 1];
            if (i % nk == 0) {
                t = subWord(std.math.rotl(u32, t, 8)) ^ (@as(u32, rcon) << 24);
                rcon = xtime(rcon);
            } else if (nk > 6 and i % nk == 4) {
                t = subWord(t);
            }
            self.words[i] = self.words[i - nk] ^ t;
        }
        return self;
    }

    /// Encrypt one 16-byte block (FIPS 197 §5.1, `Cipher`).
    pub fn encryptBlock(self: *const Aes, input: *const [16]u8, out: *[16]u8) void {
        var s: [16]u8 = input.*;
        addRoundKey(&s, self.words[0..4]);
        var r: usize = 1;
        while (r < self.rounds) : (r += 1) {
            subBytes(&s);
            shiftRows(&s);
            mixColumns(&s);
            addRoundKey(&s, self.words[r * 4 ..][0..4]);
        }
        subBytes(&s);
        shiftRows(&s);
        addRoundKey(&s, self.words[@as(usize, self.rounds) * 4 ..][0..4]);
        out.* = s;
    }
};

fn subWord(w: u32) u32 {
    return (@as(u32, sbox[@as(u8, @truncate(w >> 24))]) << 24) |
        (@as(u32, sbox[@as(u8, @truncate(w >> 16))]) << 16) |
        (@as(u32, sbox[@as(u8, @truncate(w >> 8))]) << 8) |
        @as(u32, sbox[@as(u8, @truncate(w))]);
}

fn subBytes(s: *[16]u8) void {
    for (s) |*b| b.* = sbox[b.*];
}

/// Row r is shifted left by r positions. The state is column-major:
/// index = r + 4*c, which is also the input byte order.
fn shiftRows(s: *[16]u8) void {
    const t = s.*;
    for (0..4) |r| {
        for (0..4) |c| {
            s[r + 4 * c] = t[r + 4 * ((c + r) % 4)];
        }
    }
}

fn mixColumns(s: *[16]u8) void {
    for (0..4) |c| {
        const a0 = s[4 * c];
        const a1 = s[4 * c + 1];
        const a2 = s[4 * c + 2];
        const a3 = s[4 * c + 3];
        const t = a0 ^ a1 ^ a2 ^ a3;
        s[4 * c] = a0 ^ t ^ xtime(a0 ^ a1);
        s[4 * c + 1] = a1 ^ t ^ xtime(a1 ^ a2);
        s[4 * c + 2] = a2 ^ t ^ xtime(a2 ^ a3);
        s[4 * c + 3] = a3 ^ t ^ xtime(a3 ^ a0);
    }
}

fn addRoundKey(s: *[16]u8, rk: []const u32) void {
    for (0..4) |c| {
        const w = rk[c];
        s[4 * c] ^= @truncate(w >> 24);
        s[4 * c + 1] ^= @truncate(w >> 16);
        s[4 * c + 2] ^= @truncate(w >> 8);
        s[4 * c + 3] ^= @truncate(w);
    }
}

const vectors = @import("aes_gcm_vectors.zig");

fn decode(out: []u8, s: []const u8) void {
    _ = std.fmt.hexToBytes(out[0 .. s.len / 2], s) catch unreachable;
}

test "aes: FIPS 197 / generated block vectors (8 cases, openssl-cross-checked)" {
    var key: [32]u8 = undefined;
    var pt: [16]u8 = undefined;
    var exp: [16]u8 = undefined;
    var got: [16]u8 = undefined;
    var n: usize = 0;
    for (vectors.ecb) |v| {
        decode(&key, v.key);
        decode(&pt, v.pt);
        decode(&exp, v.ct);
        // v.key is HEX TEXT: 64 chars == a 32-byte (AES-256) key.
        const k = if (v.key.len == 64) from256(key) else from128(key);
        k.encryptBlock(&pt, &got);
        std.testing.expectEqualSlices(u8, &exp, &got) catch |e| {
            std.debug.print("vector failed: {s}\n", .{v.name});
            return e;
        };
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), n);
}

/// Test helpers that dispatch on the key length stored in the vector file.
fn from128(key: [32]u8) Aes {
    var k: [16]u8 = undefined;
    @memcpy(&k, key[0..16]);
    return Aes.init128(&k);
}

fn from256(key: [32]u8) Aes {
    return Aes.init256(&key);
}
