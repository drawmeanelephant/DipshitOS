//! SHA-512 (M47 CP1, ADR 0023) — the FIPS 180-4 64-bit hash that Ed25519
//! (CP4) is built on. Streaming context, caller-buffered, no allocation.
//!
//! Verified against the FIPS 180-4 examples as class-A `zig test`. No libc,
//! no POSIX, no allocation.

const std = @import("std");

pub const block_len = 128;
pub const digest_len = 64;

const k = [80]u64{
    0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
    0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
    0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
    0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
    0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
    0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
    0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
    0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
    0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
    0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
    0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
    0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
    0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
    0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
    0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
    0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
    0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
    0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
    0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
    0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
};

const iv = [8]u64{
    0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
    0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
};

pub const Sha512 = struct {
    state: [8]u64 = iv,
    buf: [block_len]u8 = undefined,
    buf_len: usize = 0,
    total: u128 = 0,

    pub fn init() Sha512 {
        return .{};
    }

    pub fn update(self: *Sha512, bytes: []const u8) void {
        self.total +%= bytes.len;
        var i: usize = 0;
        if (self.buf_len != 0) {
            const need = block_len - self.buf_len;
            const take = @min(need, bytes.len);
            @memcpy(self.buf[self.buf_len..][0..take], bytes[0..take]);
            self.buf_len += take;
            i += take;
            if (self.buf_len == block_len) {
                compress(&self.state, &self.buf);
                self.buf_len = 0;
            }
        }
        while (i + block_len <= bytes.len) : (i += block_len) {
            compress(&self.state, bytes[i..][0..block_len]);
        }
        if (i < bytes.len) {
            const tail = bytes.len - i;
            @memcpy(self.buf[0..tail], bytes[i..]);
            self.buf_len = tail;
        }
    }

    pub fn final(self: *Sha512, out: *[digest_len]u8) void {
        const bit_len: u128 = self.total << 3;
        self.buf[self.buf_len] = 0x80;
        self.buf_len += 1;
        if (self.buf_len > block_len - 16) {
            @memset(self.buf[self.buf_len..block_len], 0);
            compress(&self.state, &self.buf);
            self.buf_len = 0;
        }
        @memset(self.buf[self.buf_len .. block_len - 16], 0);
        std.mem.writeInt(u128, self.buf[block_len - 16 ..][0..16], bit_len, .big);
        compress(&self.state, &self.buf);
        for (0..8) |j| std.mem.writeInt(u64, out[j * 8 ..][0..8], self.state[j], .big);
    }
};

fn compress(state: *[8]u64, block: *const [block_len]u8) void {
    var w: [80]u64 = undefined;
    for (0..16) |j| w[j] = std.mem.readInt(u64, block[j * 8 ..][0..8], .big);
    for (16..80) |j| {
        const x = w[j - 15];
        const y = w[j - 2];
        const s0 = std.math.rotr(u64, x, 1) ^ std.math.rotr(u64, x, 8) ^ (x >> 7);
        const s1 = std.math.rotr(u64, y, 19) ^ std.math.rotr(u64, y, 61) ^ (y >> 6);
        w[j] = w[j - 16] +% s0 +% w[j - 7] +% s1;
    }

    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];

    for (0..80) |j| {
        const s1 = std.math.rotr(u64, e, 14) ^ std.math.rotr(u64, e, 18) ^ std.math.rotr(u64, e, 41);
        const ch = (e & f) ^ (~e & g);
        const t1 = h +% s1 +% ch +% k[j] +% w[j];
        const s0 = std.math.rotr(u64, a, 28) ^ std.math.rotr(u64, a, 34) ^ std.math.rotr(u64, a, 39);
        const maj = (a & b) ^ (a & c) ^ (b & c);
        const t2 = s0 +% maj;
        h = g;
        g = f;
        f = e;
        e = d +% t1;
        d = c;
        c = b;
        b = a;
        a = t1 +% t2;
    }

    state[0] +%= a;
    state[1] +%= b;
    state[2] +%= c;
    state[3] +%= d;
    state[4] +%= e;
    state[5] +%= f;
    state[6] +%= g;
    state[7] +%= h;
}

/// One-shot SHA-512.
pub fn sha512(out: *[digest_len]u8, bytes: []const u8) void {
    var h = Sha512.init();
    h.update(bytes);
    h.final(out);
}

test "sha512: FIPS 180-4 empty message" {
    var out: [64]u8 = undefined;
    sha512(&out, "");
    const exp = try hex("cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "sha512: FIPS 180-4 \"abc\"" {
    var out: [64]u8 = undefined;
    sha512(&out, "abc");
    const exp = try hex("ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "sha512: FIPS 180-4 112-byte multi-block message" {
    var out: [64]u8 = undefined;
    sha512(&out, "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu");
    const exp = try hex("8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "sha512: streaming across every chunk boundary equals one-shot" {
    const msg = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu";
    var one: [64]u8 = undefined;
    sha512(&one, msg);
    var chunk: usize = 1;
    while (chunk <= msg.len) : (chunk += 1) {
        var h = Sha512.init();
        var i: usize = 0;
        while (i < msg.len) : (i += chunk) h.update(msg[i..@min(i + chunk, msg.len)]);
        var got: [64]u8 = undefined;
        h.final(&got);
        try std.testing.expectEqualSlices(u8, &one, &got);
    }
}

fn hex(comptime s: []const u8) ![s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.BadHex;
    return out;
}
