//! Curve25519 field arithmetic (M47 CP3/CP4, ADR 0023).
//!
//! Field elements are integers mod p = 2^255 − 19 held in a u256; products
//! use a u512 wide value reduced by the constant fold 2^256 ≡ 38 and
//! 2^255 ≡ 19. This favors a provable reduction over micro-optimization;
//! the operations are branch-minimal (mask-based selects) and allocation-
//! free. Shared by X25519 (CP3) and Ed25519 (CP4).
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");
const ct = @import("ct.zig");

pub const p: u256 = (1 << 255) - 19;
const mask256: u512 = (1 << 256) - 1;
const mask255: u512 = (1 << 255) - 1;

pub const Fe = u256;
pub const one: Fe = 1;

/// Reduce a 512-bit product into [0, p). Fixed fold count; the final
/// conditional subtraction is a mask select (no secret branch).
pub fn reduce(x: u512) Fe {
    var v: u512 = x;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        v = (v & mask256) + (v >> 256) * 38;
    }
    const b256 = v >> 256;
    v = (v & mask256) + b256 * 38;
    const b255 = v >> 255;
    v = (v & mask255) + b255 * 19;
    var r: Fe = @truncate(v);
    const ge = r >= p;
    r = if (ge) r - p else r;
    return r;
}

pub inline fn add(a: Fe, b: Fe) Fe {
    const s = a + b; // a,b < p < 2^255 so s < 2^256
    const ge = s >= p;
    return if (ge) s - p else s;
}

pub inline fn sub(a: Fe, b: Fe) Fe {
    const t = a +% (p -% b); // in [0, 2p)
    const ge = t >= p;
    return if (ge) t - p else t;
}

pub inline fn neg(a: Fe) Fe {
    return sub(0, a);
}

pub inline fn mul(a: Fe, b: Fe) Fe {
    return reduce(@as(u512, a) * @as(u512, b));
}

pub inline fn sq(a: Fe) Fe {
    return mul(a, a);
}

/// Multiply by the Montgomery constant 121665 (a24).
pub inline fn mulA24(a: Fe) Fe {
    return reduce(@as(u512, a) * @as(u512, 121665));
}

/// Fixed-exponent power (exponent is public by construction).
pub fn pow(a: Fe, e: u256) Fe {
    var result: Fe = 1;
    var base = a;
    var exp = e;
    while (exp != 0) {
        if ((exp & 1) != 0) result = mul(result, base);
        base = sq(base);
        exp >>= 1;
    }
    return result;
}

/// Multiplicative inverse: a^(p−2).
pub fn inv(a: Fe) Fe {
    return pow(a, p - 2);
}

/// Decode a 32-byte little-endian value into the field. Inputs are treated
/// as public (used for coordinates/scalars with the high bit already
/// masked); reduces once, which is enough because the caller masks bit 255.
pub fn fromBytes(b: *const [32]u8) Fe {
    var v: Fe = 0;
    for (0..32) |i| v |= @as(Fe, b[i]) << @intCast(8 * i);
    const ge = v >= p;
    return if (ge) v - p else v;
}

/// Encode a field element as 32 little-endian bytes.
pub fn toBytes(f: Fe) [32]u8 {
    var out: [32]u8 = undefined;
    var v = f;
    for (0..32) |i| {
        out[i] = @truncate(v);
        v >>= 8;
    }
    return out;
}

/// Branchless conditional swap of two field elements.
pub inline fn cswap(mask: bool, a: *Fe, b: *Fe) void {
    ct.ctSwap(Fe, mask, a, b);
}

/// True when the low bit of the canonical encoding is 1 (sign of x).
pub inline fn isNegative(f: Fe) bool {
    return (f & 1) == 1;
}

test "curve25519: p is 2^255-19" {
    try std.testing.expectEqual(@as(u256, 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed), p);
}

test "curve25519: add/sub agree with wide arithmetic" {
    const a: Fe = p - 1; // -1
    const b: Fe = p - 2; // -2
    // (-1) + (-2) = -3 = p-3
    try std.testing.expectEqual(@as(Fe, p - 3), add(a, b));
    // (-2) - (-1) = -1 = p-1
    try std.testing.expectEqual(@as(Fe, p - 1), sub(b, a));
    // (-1) - (-2) = 1
    try std.testing.expectEqual(@as(Fe, 1), sub(a, b));
    try std.testing.expectEqual(@as(Fe, 0), add(a, 1));
}

test "curve25519: multiplication is field multiplication" {
    const x: Fe = 0x1234567890abcdef112233445566778899aabbccddeeff001122334455667788;
    const y: Fe = 0xfedcba0987654321ffeeddccbbaa99887766554433221100ffeeddccbbaa9988;
    const want: Fe = @intCast((@as(u512, x) * @as(u512, y)) % p);
    try std.testing.expectEqual(want, mul(x, y));
    // x * x^-1 == 1
    if (x != 0) try std.testing.expectEqual(@as(Fe, 1), mul(x, inv(x)));
}

test "curve25519: sub and neg are consistent" {
    const vals = [_]Fe{ 0, 1, 2, p - 1, p - 19, 0x1234567890abcdef };
    for (vals) |a| {
        try std.testing.expectEqual(a, sub(a, 0));
        try std.testing.expectEqual(@as(Fe, 0), add(a, neg(a)));
        try std.testing.expectEqual(neg(a), sub(0, a));
    }
}

test "curve25519: reduce handles maximum products" {
    const max: Fe = p - 1;
    try std.testing.expectEqual(@as(Fe, 1), reduce(@as(u512, max) * @as(u512, max)));
    try std.testing.expectEqual(@as(Fe, 0), reduce(@as(u512, p) * @as(u512, p)));
    try std.testing.expectEqual(@as(Fe, 0), mul(0, max));
    try std.testing.expectEqual(@as(Fe, max), mul(1, max));
}
