//! Ed25519 (RFC 8032), M47 CP4, ADR 0023.
//!
//! Pure Ed25519 over Curve25519 (the `curve25519.zig` field): key
//! derivation, detached signing, and verification. The scalar-mult ladder
//! is branch-minimal (mask-based point selection) per ADR 0023 D3; signing
//! is constant-time in the secret scalar and nonce. No allocation, no I/O.
//!
//! Verified against the RFC 8032 §7.1 TEST 1–3 + SHA(abc) vectors, with a
//! negative verification case, as class-A `zig test`.

const std = @import("std");
const f = @import("curve25519.zig");
const sha512 = @import("sha512.zig");
const ct = @import("ct.zig");

const Fe = f.Fe;

pub const public_key_len = 32;
pub const secret_key_len = 32;
pub const signature_len = 64;

/// Edwards d = -121665/121666 mod p.
const d: Fe = 0x52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3;
/// sqrt(-1) mod p (2^((p-1)/4)).
const sqrt_m1: Fe = 0x2b8324804fc1df0b2b4d00993dfbd7a72f431806ad2fe478c4ee1b274a0ea0b0;
const two_d: Fe = f.add(d, d);
/// The group order ℓ = 2^252 + 27742317777372353535851937790883648493.
const L: u256 = (1 << 252) + 27742317777372353535851937790883648493;

/// Compressed base point (y = 4/5, even x).
const B_compressed = [32]u8{
    0x58, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
    0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
};

pub const Point = struct {
    X: Fe,
    Y: Fe,
    Z: Fe,
    T: Fe,
};

fn identity() Point {
    return .{ .X = 0, .Y = 1, .Z = 1, .T = 0 };
}

fn feEq(a: Fe, b: Fe) bool {
    return a == b;
}

fn pointEq(a: Point, b: Point) bool {
    return feEq(f.mul(a.X, b.Z), f.mul(b.X, a.Z)) and
        feEq(f.mul(a.Y, b.Z), f.mul(b.Y, a.Z));
}

fn pointSelect(mask: bool, a: Point, b: Point) Point {
    return .{
        .X = ct.ctSelect(Fe, mask, a.X, b.X),
        .Y = ct.ctSelect(Fe, mask, a.Y, b.Y),
        .Z = ct.ctSelect(Fe, mask, a.Z, b.Z),
        .T = ct.ctSelect(Fe, mask, a.T, b.T),
    };
}

/// add-2008-hwcd-3 for a = -1 (complete for Edwards25519).
fn addPoints(p: Point, q: Point) Point {
    const a = f.mul(f.sub(p.Y, p.X), f.sub(q.Y, q.X));
    const b = f.mul(f.add(p.Y, p.X), f.add(q.Y, q.X));
    const c = f.mul(f.mul(p.T, two_d), q.T);
    const dd = f.mul(f.mul(p.Z, q.Z), 2);
    const e = f.sub(b, a);
    const ff = f.sub(dd, c);
    const g = f.add(dd, c);
    const h = f.add(b, a);
    return .{
        .X = f.mul(e, ff),
        .Y = f.mul(g, h),
        .T = f.mul(e, h),
        .Z = f.mul(ff, g),
    };
}

/// dbl-2008-hwcd for a = -1.
fn doublePoint(p: Point) Point {
    const a = f.sq(p.X);
    const b = f.sq(p.Y);
    const c = f.add(f.sq(p.Z), f.sq(p.Z));
    const h = f.neg(f.add(a, b)); // H = D - B = -A - B
    const e = f.sub(f.sub(f.sq(f.add(p.X, p.Y)), a), b);
    const g = f.sub(b, a);
    const ff = f.sub(g, c);
    return .{
        .X = f.mul(e, ff),
        .Y = f.mul(g, h),
        .T = f.mul(e, h),
        .Z = f.mul(ff, g),
    };
}

/// Constant-time-ish scalar multiplication: 256 fixed iterations, the add
/// chosen with a mask (ADR 0023 D3).
fn scalarMultPoint(p: Point, scalar: *const [32]u8) Point {
    var result = identity();
    var i: i32 = 255;
    while (i >= 0) : (i -= 1) {
        result = doublePoint(result);
        const bit = ((scalar[@intCast(@divTrunc(i, 8))] >> @intCast(i & 7)) & 1) == 1;
        const sum = addPoints(result, p);
        result = pointSelect(bit, sum, result);
    }
    return result;
}

fn basePoint() Point {
    return decompress(&B_compressed) orelse unreachable;
}

fn encodePoint(p: Point) [32]u8 {
    const zinv = f.inv(p.Z);
    const x = f.mul(p.X, zinv);
    const y = f.mul(p.Y, zinv);
    var out = f.toBytes(y);
    out[31] |= @as(u8, @intFromBool(f.isNegative(x))) << 7;
    return out;
}

/// Strict field decode: reject non-canonical encodings (y >= p).
fn decodeFieldStrict(b: *const [32]u8) ?Fe {
    var v: Fe = 0;
    for (0..32) |i| v |= @as(Fe, b[i]) << @intCast(8 * i);
    if (v >= f.p) return null;
    return v;
}

fn decompress(b: *const [32]u8) ?Point {
    const sign_bit = (b[31] >> 7) & 1;
    var yb = b.*;
    yb[31] &= 0x7f;
    const y = decodeFieldStrict(&yb) orelse return null;
    const y2 = f.sq(y);
    const u = f.sub(y2, 1);
    const v = f.add(f.mul(d, y2), 1);
    // x = u v^3 (u v^7)^((p-5)/8)
    const v3 = f.mul(f.sq(v), v);
    const v7 = f.mul(f.sq(v3), v);
    var x = f.mul(f.mul(u, v3), f.pow(f.mul(u, v7), (f.p - 5) >> 3));
    const vx2 = f.mul(v, f.sq(x));
    if (!feEq(vx2, u)) {
        if (!feEq(vx2, f.neg(u))) return null;
        x = f.mul(x, sqrt_m1);
    }
    if (x == 0 and sign_bit == 1) return null;
    if (f.isNegative(x) != (sign_bit == 1)) x = f.neg(x);
    return .{ .X = x, .Y = y, .Z = 1, .T = f.mul(x, y) };
}

fn leToU256(b: *const [32]u8) u256 {
    var v: u256 = 0;
    for (0..32) |i| v |= @as(u256, b[i]) << @intCast(8 * i);
    return v;
}

fn leToU512(b: *const [64]u8) u512 {
    var v: u512 = 0;
    for (0..64) |i| v |= @as(u512, b[i]) << @intCast(8 * i);
    return v;
}

fn u256ToLe(v: u256) [32]u8 {
    var out: [32]u8 = undefined;
    var x = v;
    for (0..32) |i| {
        out[i] = @truncate(x);
        x >>= 8;
    }
    return out;
}

/// Reduce a 512-bit little-endian scalar modulo ℓ by fixed-count
/// double-and-conditional-subtract (no secret branch).
fn modL(x: u512) u256 {
    var rem: u256 = 0;
    var i: i32 = 511;
    while (i >= 0) : (i -= 1) {
        const bit: u256 = @intCast((x >> @intCast(i)) & 1);
        const doubled = (rem << 1) | bit;
        const ge = doubled >= L;
        rem = if (ge) doubled - L else doubled;
    }
    return rem;
}

/// Derive the 32-byte public key from a 32-byte secret seed.
pub fn derivePublicKey(pk: *[32]u8, sk: *const [32]u8) void {
    var h: [64]u8 = undefined;
    sha512.sha512(&h, sk);
    var a: [32]u8 = h[0..32].*;
    a[0] &= 248;
    a[31] &= 63;
    a[31] |= 64;
    pk.* = encodePoint(scalarMultPoint(basePoint(), &a));
}

/// Sign `msg` with the 32-byte secret seed; `sig` receives 64 bytes (R‖S).
pub fn sign(sig: *[64]u8, msg: []const u8, sk: *const [32]u8) void {
    var h: [64]u8 = undefined;
    sha512.sha512(&h, sk);
    var a: [32]u8 = h[0..32].*;
    a[0] &= 248;
    a[31] &= 63;
    a[31] |= 64;

    const bp = basePoint();
    const pk = encodePoint(scalarMultPoint(bp, &a));

    var nonce_hash = sha512.Sha512.init();
    nonce_hash.update(h[32..64]);
    nonce_hash.update(msg);
    var nh: [64]u8 = undefined;
    nonce_hash.final(&nh);
    const r = modL(leToU512(&nh));
    const r_bytes = u256ToLe(r);
    const r_point = scalarMultPoint(bp, &r_bytes);
    const r_enc = encodePoint(r_point);

    var k_hash = sha512.Sha512.init();
    k_hash.update(&r_enc);
    k_hash.update(&pk);
    k_hash.update(msg);
    var kh: [64]u8 = undefined;
    k_hash.final(&kh);
    const k = modL(leToU512(&kh));

    const s = modL(@as(u512, r) + @as(u512, k) * @as(u512, leToU256(&a)));

    @memcpy(sig[0..32], &r_enc);
    sig[32..64].* = u256ToLe(s);
}

/// Verify a 64-byte signature over `msg` against a 32-byte public key.
pub fn verify(sig: *const [64]u8, msg: []const u8, pk: *const [32]u8) bool {
    const a_point = decompress(pk) orelse return false;
    var r_bytes: [32]u8 = sig[0..32].*;
    const r_point = decompress(&r_bytes) orelse return false;
    var s_bytes: [32]u8 = sig[32..64].*;
    const s = leToU256(&s_bytes);
    if (s >= L) return false;

    var k_hash = sha512.Sha512.init();
    k_hash.update(&r_bytes);
    k_hash.update(pk);
    k_hash.update(msg);
    var kh: [64]u8 = undefined;
    k_hash.final(&kh);
    const k = modL(leToU512(&kh));

    const sb = scalarMultPoint(basePoint(), &s_bytes);
    const k_bytes = u256ToLe(k);
    const ka = scalarMultPoint(a_point, &k_bytes);
    const rhs = addPoints(r_point, ka);
    return pointEq(sb, rhs);
}

fn hex(comptime s: []const u8) ![s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.BadHex;
    return out;
}

test "ed25519: constants are consistent (d = -121665/121666, sqrt_m1^2 = -1)" {
    const lhs = f.mul(f.neg(121665), f.inv(121666));
    try std.testing.expectEqual(d, lhs);
    try std.testing.expectEqual(f.neg(@as(Fe, 1)), f.sq(sqrt_m1));
}

test "ed25519: base point round-trips and has order dividing L" {
    const bp = basePoint();
    try std.testing.expectEqualSlices(u8, &B_compressed, &encodePoint(bp));
    // [L]B is the identity.
    const lb = scalarMultPoint(bp, &u256ToLe(L));
    try std.testing.expectEqualSlices(u8, &f.toBytes(1), &encodePoint(lb));
}

test "ed25519: RFC 8032 §7.1 TEST 1 (empty message)" {
    const sk = try hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    const pk_exp = try hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
    const sig_exp = try hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b");
    var pk: [32]u8 = undefined;
    derivePublicKey(&pk, &sk);
    try std.testing.expectEqualSlices(u8, &pk_exp, &pk);
    var sig: [64]u8 = undefined;
    sign(&sig, "", &sk);
    try std.testing.expectEqualSlices(u8, &sig_exp, &sig);
    try std.testing.expect(verify(&sig, "", &pk));
}

test "ed25519: RFC 8032 §7.1 TEST 2 (one byte)" {
    const sk = try hex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb");
    const pk_exp = try hex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c");
    const msg = try hex("72");
    const sig_exp = try hex("92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00");
    var pk: [32]u8 = undefined;
    derivePublicKey(&pk, &sk);
    try std.testing.expectEqualSlices(u8, &pk_exp, &pk);
    var sig: [64]u8 = undefined;
    sign(&sig, &msg, &sk);
    try std.testing.expectEqualSlices(u8, &sig_exp, &sig);
    try std.testing.expect(verify(&sig, &msg, &pk));
}

test "ed25519: RFC 8032 §7.1 TEST 3 (two bytes)" {
    const sk = try hex("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7");
    const pk_exp = try hex("fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025");
    const msg = try hex("af82");
    const sig_exp = try hex("6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a");
    var pk: [32]u8 = undefined;
    derivePublicKey(&pk, &sk);
    try std.testing.expectEqualSlices(u8, &pk_exp, &pk);
    var sig: [64]u8 = undefined;
    sign(&sig, &msg, &sk);
    try std.testing.expectEqualSlices(u8, &sig_exp, &sig);
    try std.testing.expect(verify(&sig, &msg, &pk));
}

test "ed25519: RFC 8032 §7.1 TEST SHA(abc)" {
    const sk = try hex("833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42");
    const pk_exp = try hex("ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf");
    const msg = try hex("ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f");
    const sig_exp = try hex("dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704");
    var pk: [32]u8 = undefined;
    derivePublicKey(&pk, &sk);
    try std.testing.expectEqualSlices(u8, &pk_exp, &pk);
    var sig: [64]u8 = undefined;
    sign(&sig, &msg, &sk);
    try std.testing.expectEqualSlices(u8, &sig_exp, &sig);
    try std.testing.expect(verify(&sig, &msg, &pk));
}

test "ed25519: verification rejects a tampered message, signature, or key" {
    const sk = try hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    var pk: [32]u8 = undefined;
    derivePublicKey(&pk, &sk);
    var sig: [64]u8 = undefined;
    sign(&sig, "hello", &sk);
    try std.testing.expect(verify(&sig, "hello", &pk));
    try std.testing.expect(!verify(&sig, "hell0", &pk));
    var bad = sig;
    bad[0] ^= 1;
    try std.testing.expect(!verify(&bad, "hello", &pk));
    var bad_pk = pk;
    bad_pk[0] ^= 1;
    try std.testing.expect(!verify(&sig, "hello", &bad_pk));
}
