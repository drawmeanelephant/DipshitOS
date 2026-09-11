//! Poly1305 one-time authenticator (RFC 8439 §2.5), M47 CP2, ADR 0023.
//!
//! Streaming, caller-buffered, no allocation. The accumulator is a 130-bit
//! value held in a u256; multiplication uses a u512 product with the
//! constant-fold reduction 2^130 ≡ 5 (mod 2^130−5) at a fixed iteration
//! count (no secret-dependent branches). Adequate for KATs and the EL0
//! demo; a limb form can replace the internals behind this API later.
//!
//! Verified against the RFC 8439 §2.5.2 vector as class-A `zig test`.

const std = @import("std");

const p130: u256 = (1 << 130) - 5;
const mask130: u512 = (1 << 130) - 1;

fn mulMod(a: u256, b: u256) u256 {
    var v: u512 = @as(u512, a) * @as(u512, b);
    // Fold the bits above 130 with 2^130 ≡ 5. Three folds take the
    // product (< 2^255) below 2^130.
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const lo = v & mask130;
        const hi = v >> 130;
        v = lo + hi * 5;
    }
    var r: u256 = @truncate(v);
    const ge = r >= p130;
    r = if (ge) r - p130 else r;
    return r;
}

pub const Poly1305 = struct {
    r: u256,
    s: u128,
    acc: u256 = 0,
    buf: [16]u8 = undefined,
    buf_len: usize = 0,

    pub fn init(key: *const [32]u8) Poly1305 {
        var rb: [16]u8 = key[0..16].*;
        rb[3] &= 15;
        rb[7] &= 15;
        rb[11] &= 15;
        rb[15] &= 15;
        rb[4] &= 252;
        rb[8] &= 252;
        rb[12] &= 252;
        var r: u256 = 0;
        for (0..16) |i| r |= @as(u256, rb[i]) << @intCast(8 * i);
        var s: u128 = 0;
        for (0..16) |i| s |= @as(u128, key[16 + i]) << @intCast(8 * i);
        return .{ .r = r, .s = s };
    }

    pub fn update(self: *Poly1305, bytes: []const u8) void {
        var i: usize = 0;
        if (self.buf_len != 0) {
            const need = 16 - self.buf_len;
            const take = @min(need, bytes.len);
            @memcpy(self.buf[self.buf_len..][0..take], bytes[0..take]);
            self.buf_len += take;
            i += take;
            if (self.buf_len == 16) {
                self.absorb(&self.buf, 16);
                self.buf_len = 0;
            }
        }
        while (i + 16 <= bytes.len) : (i += 16) {
            self.absorb(bytes[i..][0..16], 16);
        }
        if (i < bytes.len) {
            const tail = bytes.len - i;
            @memcpy(self.buf[0..tail], bytes[i..]);
            self.buf_len = tail;
        }
    }

    pub fn final(self: *Poly1305, out: *[16]u8) void {
        if (self.buf_len != 0) {
            self.absorb(&self.buf, self.buf_len);
            self.buf_len = 0;
        }
        const sum = self.acc + self.s;
        for (0..16) |i| out[i] = @truncate(sum >> @intCast(8 * i));
    }

    fn absorb(self: *Poly1305, blk: *const [16]u8, nbytes: usize) void {
        var n: u256 = 0;
        for (0..nbytes) |i| n |= @as(u256, blk[i]) << @intCast(8 * i);
        n += @as(u256, 1) << @intCast(8 * nbytes);
        self.acc = mulMod(self.acc + n, self.r);
    }
};

/// One-shot Poly1305.
pub fn poly1305(out: *[16]u8, msg: []const u8, key: *const [32]u8) void {
    var p = Poly1305.init(key);
    p.update(msg);
    p.final(out);
}

test "poly1305: RFC 8439 §2.5.2 KAT" {
    const key = try hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b");
    var out: [16]u8 = undefined;
    poly1305(&out, "Cryptographic Forum Research Group", &key);
    const exp = try hex("a8061dc1305136c6c22b8baf0c0127a9");
    try std.testing.expectEqualSlices(u8, &exp, &out);
}

test "poly1305: streaming in every chunk size equals one-shot" {
    const key = try hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b");
    const msg = "Cryptographic Forum Research Group";
    var one: [16]u8 = undefined;
    poly1305(&one, msg, &key);
    var chunk: usize = 1;
    while (chunk <= msg.len + 1) : (chunk += 1) {
        var p = Poly1305.init(&key);
        var i: usize = 0;
        while (i < msg.len) : (i += chunk) p.update(msg[i..@min(i + chunk, msg.len)]);
        var got: [16]u8 = undefined;
        p.final(&got);
        try std.testing.expectEqualSlices(u8, &one, &got);
    }
}

test "poly1305: empty message authenticates to s" {
    const key = try hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b");
    var out: [16]u8 = undefined;
    poly1305(&out, "", &key);
    try std.testing.expectEqualSlices(u8, key[16..32], &out);
}

fn hex(comptime s: []const u8) ![s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.BadHex;
    return out;
}
