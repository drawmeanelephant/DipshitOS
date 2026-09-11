//! Constant-time helpers (M47 CP1/CP5, ADR 0023 D3).
//!
//! Secret-dependent branches, memory indices, and early exits are forbidden
//! in the crypto primitives. These helpers carry that discipline: selection
//! is arithmetic (mask-based), swaps are branchless, and `wipe` writes
//! through a volatile pointer so an optimizer cannot elide key erasure.
//!
//! LIMIT (ADR 0023 D3): this is cache/branch discipline, not a hardened
//! power/EM side-channel defense. Zig is not a constant-time compiler; the
//! discipline is enforced by construction and inspection. Inputs whose
//! LENGTH is secret cannot be handled in constant time and must not be
//! used with these helpers (lengths are public by contract).
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");

/// Equal-length comparison with no early exit. If the lengths differ the
/// result is false, but the length is assumed public (see the file limit).
pub fn ctEq(a: []const u8, b: []const u8) bool {
    var diff: u8 = 0;
    const n = @min(a.len, b.len);
    for (0..n) |i| diff |= a[i] ^ b[i];
    diff |= @as(u8, @intFromBool(a.len != b.len));
    return diff == 0;
}

/// The complement of `ctEq` (kept separate so call sites read clearly).
pub fn ctNe(a: []const u8, b: []const u8) bool {
    return !ctEq(a, b);
}

/// Branchless select: `mask == true` yields `a`, else `b`. Works for any
/// unsigned integer type (u8..u512); the mask is expanded arithmetically,
/// never with an `if`.
pub inline fn ctSelect(comptime T: type, mask: bool, a: T, b: T) T {
    const one: T = @intFromBool(mask);
    const m: T = 0 -% one;
    return (a & m) | (b & ~m);
}

/// Branchless conditional swap of two values (the Montgomery ladder's
/// primitive). `mask == true` swaps.
pub inline fn ctSwap(comptime T: type, mask: bool, a: *T, b: *T) void {
    const one: T = @intFromBool(mask);
    const m: T = 0 -% one;
    const t = (a.* ^ b.*) & m;
    a.* ^= t;
    b.* ^= t;
}

/// Best-effort zeroization. The volatile store prevents the optimizer from
/// removing the writes as dead stores.
pub fn wipe(buf: []u8) void {
    for (buf) |*b| {
        const p: *volatile u8 = b;
        p.* = 0;
    }
}

// ---------------------------------------------------------------------------
// Host tests
// ---------------------------------------------------------------------------

test "ct: ctEq / ctNe agree and fold length mismatch" {
    try std.testing.expect(ctEq("abc", "abc"));
    try std.testing.expect(!ctEq("abc", "abd"));
    try std.testing.expect(!ctEq("abc", "ab"));
    try std.testing.expect(ctEq("", ""));
    try std.testing.expect(ctNe("abc", "abd"));
    try std.testing.expect(!ctNe("abc", "abc"));
}

test "ct: ctSelect is exact for both masks across widths" {
    try std.testing.expectEqual(@as(u8, 0xaa), ctSelect(u8, true, 0xaa, 0x55));
    try std.testing.expectEqual(@as(u8, 0x55), ctSelect(u8, false, 0xaa, 0x55));
    try std.testing.expectEqual(@as(u256, 7), ctSelect(u256, true, 7, 9));
    try std.testing.expectEqual(@as(u256, 9), ctSelect(u256, false, 7, 9));
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ffff), ctSelect(u64, true, ~@as(u64, 0), 0));
    try std.testing.expectEqual(@as(u64, 0), ctSelect(u64, false, ~@as(u64, 0), 0));
}

test "ct: ctSwap swaps exactly when asked" {
    var a: u32 = 0x1111_1111;
    var b: u32 = 0x2222_2222;
    ctSwap(u32, false, &a, &b);
    try std.testing.expectEqual(@as(u32, 0x1111_1111), a);
    try std.testing.expectEqual(@as(u32, 0x2222_2222), b);
    ctSwap(u32, true, &a, &b);
    try std.testing.expectEqual(@as(u32, 0x2222_2222), a);
    try std.testing.expectEqual(@as(u32, 0x1111_1111), b);
}

test "ct: wipe zeroes the buffer" {
    var buf = [_]u8{ 1, 2, 3, 4, 5 };
    wipe(&buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0 }, &buf);
}
