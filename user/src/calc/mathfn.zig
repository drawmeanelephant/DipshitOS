//! calc/mathfn.zig — M24 K8 logarithmic & exponential functions for CALC.BIN.
//!
//! Pure float math: no GUI, no heap, no libm (freestanding EL0). exp/ln use
//! argument scaling plus a 10-term Taylor series; sqrt is Newton's method
//! per the card. pow_checked gives exact checked 64-bit integer powers so
//! the i64 engine never silently wraps.

const std = @import("std");

pub const MathError = error{
    Domain, // ln/log of <= 0, 0^negative, etc.
    Overflow,
};

const ln2: f64 = 0.6931471805599453;
const ln10: f64 = 2.302585092994046;

/// e^x via e^x = 2^n · e^r with r ∈ [−ln2/2, ln2/2] — the raw Taylor series
/// converges to ~1e-12 there in 10 terms.
pub fn exp(x: f64) f64 {
    const log2e = 1.4426950408889634;
    const n_f = @floor(x * log2e + 0.5);
    const n: i32 = @intFromFloat(n_f);
    const r = x - n_f * ln2;

    var term: f64 = 1.0;
    var s: f64 = 1.0;
    var k: usize = 1;
    while (k < 10) : (k += 1) {
        term *= r / @as(f64, @floatFromInt(k));
        s += term;
    }

    var p = s;
    var i: i32 = 0;
    if (n > 0) {
        while (i < n) : (i += 1) p *= 2.0;
    } else {
        while (i > n) : (i -= 1) p *= 0.5;
    }
    return p;
}

/// Natural log via x = m·2^k (m ∈ [1, 2)) and the fast-converging atanh
/// identity ln(m) = 2·atanh((m−1)/(m+1)).
pub fn ln(x: f64) MathError!f64 {
    if (!(x > 0)) return error.Domain;
    var m = x;
    var k: i32 = 0;
    while (m >= 2.0) : (k += 1) m /= 2.0;
    while (m < 1.0) : (k -= 1) m *= 2.0;

    const t = (m - 1.0) / (m + 1.0);
    var term = t;
    var s: f64 = 0;
    var j: usize = 0;
    while (j < 10) : (j += 1) {
        s += term / @as(f64, @floatFromInt(2 * j + 1));
        term *= t * t;
    }
    return @as(f64, @floatFromInt(k)) * ln2 + 2 * s;
}

pub fn log10(x: f64) MathError!f64 {
    return (try ln(x)) / ln10;
}

/// Newton's method square root (card spec).
pub fn sqrt(v: f64) f64 {
    if (v <= 0) return 0;
    var g = v;
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        g = 0.5 * (g + v / g);
    }
    return g;
}

/// Exact checked integer power for the engine's 'P' opcode. Negative
/// exponents produce non-integer magnitudes the i64 display can't hold
/// (±1 bases excepted); overflow raises instead of wrapping.
pub fn pow_checked(a: i64, b: i64) MathError!i64 {
    if (b == 0) return 1;
    if (b < 0) {
        if (a == 1) return 1;
        if (a == -1) return if (@mod(b, 2) == 0) 1 else -1;
        return error.Domain;
    }
    if (a == 0) return 0;
    if (b > 62) {
        if (a == 1) return 1;
        if (a == -1) return if (@mod(b, 2) == 0) 1 else -1;
        return error.Overflow;
    }
    var base = a;
    var acc: i64 = 1;
    var e: u6 = @intCast(b);
    while (true) {
        if (e & 1 == 1) acc = std.math.mul(i64, acc, base) catch return error.Overflow;
        e >>= 1;
        if (e == 0) break;
        base = std.math.mul(i64, base, base) catch return error.Overflow;
    }
    return acc;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "mathfn: ln / log10 issue cases" {
    try std.testing.expectApproxEqAbs(@as(f64, 1), try ln(std.math.e), 1e-9); // ln(e) = 1
    try std.testing.expectApproxEqAbs(@as(f64, 2), try log10(100), 1e-9); // log(100) = 2
    try std.testing.expectApproxEqAbs(@as(f64, 0), try ln(1), 1e-12);
    try std.testing.expectError(error.Domain, ln(0));
    try std.testing.expectError(error.Domain, ln(-3));
    try std.testing.expectError(error.Domain, log10(-1));
}

test "mathfn: exp round-trips with ln" {
    try std.testing.expectApproxEqAbs(@as(f64, 1), exp(0), 1e-12);
    try std.testing.expectApproxEqAbs(std.math.e, exp(1), 1e-9);
    // exp(ln(x)) ≈ x over several magnitudes
    try std.testing.expectApproxEqAbs(@as(f64, 20), exp(try ln(20)), 1e-7);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), exp(try ln(0.05)), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 100), exp(try ln(100)), 1e-8);
}

test "mathfn: sqrt Newton issue case" {
    try std.testing.expectApproxEqAbs(@as(f64, 4), sqrt(16.0), 1e-9); // sqrt(16) = 4
    try std.testing.expectApproxEqAbs(@as(f64, 3), sqrt(9.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), sqrt(0.0), 1e-12);
}

test "mathfn: pow_checked exact and checked" {
    try std.testing.expectEqual(@as(i64, 1024), try pow_checked(2, 10));
    try std.testing.expectEqual(@as(i64, 1), try pow_checked(5, 0));
    try std.testing.expectEqual(@as(i64, 0), try pow_checked(0, 3));
    try std.testing.expectEqual(@as(i64, -8), try pow_checked(-2, 3));
    try std.testing.expectEqual(@as(i64, -1), try pow_checked(-1, 999_001)); // odd
    try std.testing.expectEqual(@as(i64, 1), try pow_checked(1, 123_456_789));
    try std.testing.expectEqual(@as(i64, 1), try pow_checked(-1, 1_000_000)); // even
    try std.testing.expectError(error.Domain, pow_checked(0, -1)); // hmm — 0^-1
    try std.testing.expectError(error.Domain, pow_checked(2, -2));
    try std.testing.expectError(error.Overflow, pow_checked(10, 19));
    try std.testing.expectEqual(@as(i64, 1_000_000_000), try pow_checked(10, 9));
}
