//! calc/science.zig — M24 K7 trigonometry for CALC.BIN.
//!
//! Pure float math: no GUI, no heap, no libm (freestanding EL0). Taylor
//! series with 10 terms per the card; sin/cos get range reduction to
//! (-π, π] first. Inverse functions use a hybrid: fast series for small
//! arguments, half-π identity near the domain edge (where the raw series
//! converges too slowly to round-trip integer inputs like asin(1)).

const std = @import("std");

pub const pi: f64 = 3.141592653589793;

pub const ScienceError = error{
    Domain, // asin/acos outside [-1, 1], tan at cos = 0
};

fn deg_to_rad(degrees: f64) f64 {
    return degrees * pi / 180.0;
}

/// Reduce an angle in radians into (-π, π].
fn reduce(x: f64) f64 {
    const two_pi = 2.0 * pi;
    var a = @mod(x, two_pi);
    if (a > pi) a -= two_pi;
    return a;
}

/// Newton's method square root (shared by inverse-function identities).
pub fn sqrt(v: f64) f64 {
    if (v <= 0) return 0;
    var g = v;
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        g = 0.5 * (g + v / g);
    }
    return g;
}

/// Taylor sine, 10 terms (x^1 .. x^19). Input should be pre-reduced.
fn sin_series(a: f64) f64 {
    var term = a;
    var s = a;
    const a2 = a * a;
    var k: u32 = 1;
    while (k < 10) : (k += 1) {
        term *= -a2 / @as(f64, @floatFromInt((2 * k) * (2 * k + 1)));
        s += term;
    }
    return s;
}

/// Taylor cosine, 10 terms (x^0 .. x^18). Input should be pre-reduced.
fn cos_series(a: f64) f64 {
    var term: f64 = 1.0;
    var s: f64 = 1.0;
    const a2 = a * a;
    var k: u32 = 1;
    while (k < 10) : (k += 1) {
        term *= -a2 / @as(f64, @floatFromInt((2 * k - 1) * (2 * k)));
        s += term;
    }
    return s;
}

pub fn sin(x: f64) f64 {
    return sin_series(reduce(x));
}

pub fn cos(x: f64) f64 {
    return cos_series(reduce(x));
}

pub fn tan(x: f64) ScienceError!f64 {
    const c = cos(x);
    if (@abs(c) < 1e-12) return error.Domain;
    return sin(x) / c;
}

/// Series core for |x| <= ~0.72 — 10 terms converge tightly there.
fn asin_series(x: f64) f64 {
    var term = x;
    var s = x;
    const x2 = x * x;
    var k: u32 = 1;
    while (k < 10) : (k += 1) {
        const kf: f64 = @floatFromInt(k);
        const ratio = (2 * kf) * (2 * kf - 1) / (4 * kf * kf) * ((2 * kf - 1) / (2 * kf + 1));
        term *= ratio * x2;
        s += term;
    }
    return s;
}

pub fn asin(x: f64) ScienceError!f64 {
    if (@abs(x) > 1.0) return error.Domain;
    if (@abs(x) > 0.72) {
        // π/2 − asin(√(1−x²)) flips the slow-converging boundary case into
        // a tiny argument where the series is exact to ~1e-15.
        const comp = sqrt(1.0 - x * x);
        const inner = asin_series(comp);
        return if (x > 0) pi / 2.0 - inner else -(pi / 2.0 - inner);
    }
    return asin_series(x);
}

pub fn acos(x: f64) ScienceError!f64 {
    return pi / 2.0 - try asin(x);
}

pub fn atan(x: f64) f64 {
    if (@abs(x) > 1.0) {
        // atan(x) = sign(x)·π/2 − atan(1/x)
        const inv = atan(1.0 / x);
        return if (x > 0) pi / 2.0 - inv else -(pi / 2.0 - inv);
    }
    const ax = @abs(x);
    var s: f64 = undefined;
    if (ax > 0.5) {
        // Range shift: atan(a) = π/4 + atan((a−1)/(a+1)) maps [0.5, 1] into
        // [−1/3, 0] where the 10-term series is tight.
        const t = (ax - 1.0) / (ax + 1.0);
        s = pi / 4.0 + atan_series(t);
    } else {
        s = atan_series(ax);
    }
    return if (x < 0) -s else s;
}

/// Raw 10-term alternating series: Σ (−1)^k x^(2k+1)/(2k+1).
fn atan_series(x: f64) f64 {
    var term = x;
    var s = x;
    const x2 = x * x;
    var k: u32 = 1;
    while (k < 10) : (k += 1) {
        term *= -x2;
        s += term / @as(f64, @floatFromInt(2 * k + 1));
    }
    return s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const eps = 1e-9;

test "science: sin/cos basics" {
    try std.testing.expectApproxEqAbs(@as(f64, 0), sin(0), eps);
    try std.testing.expectApproxEqAbs(@as(f64, 1), cos(0), eps);
    try std.testing.expectApproxEqAbs(@as(f64, 1), sin(pi / 2.0), eps);
    try std.testing.expectApproxEqAbs(@as(f64, 0), cos(pi / 2.0), 1e-8);
    try std.testing.expectApproxEqAbs(@as(f64, 1), sin(90.0 * pi / 180.0), eps);
    // Range reduction: large angles wrap correctly.
    try std.testing.expectApproxEqAbs(@as(f64, 1), sin(pi / 2.0 + 4.0 * pi), eps);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), sin(pi / 6.0), eps);
}

test "science: tan" {
    try std.testing.expectApproxEqAbs(@as(f64, 1), try tan(pi / 4.0), eps);
    try std.testing.expectApproxEqAbs(@as(f64, 0), try tan(0), eps);
    try std.testing.expectError(error.Domain, tan(pi / 2.0));
}

test "science: asin/acos including boundary identity" {
    try std.testing.expectApproxEqAbs(pi / 2.0, try asin(1.0), 1e-12);
    try std.testing.expectApproxEqAbs(-pi / 2.0, try asin(-1.0), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), try asin(0), eps);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), try asin(sin(0.5)), 1e-7);
    try std.testing.expectApproxEqAbs(@as(f64, 0), try acos(1.0), 1e-12);
    try std.testing.expectApproxEqAbs(pi / 2.0, try acos(0.0), 1e-12);
    try std.testing.expectError(error.Domain, asin(1.5));
    try std.testing.expectError(error.Domain, acos(-1.01));
}

test "science: atan" {
    try std.testing.expectApproxEqAbs(@as(f64, 0), atan(0), eps);
    try std.testing.expectApproxEqAbs(pi / 4.0, atan(1.0), eps);
    // Round-trip: tan(atan(large)) recovers the value.
    try std.testing.expectApproxEqAbs(@as(f64, 1000), try tan(atan(1000.0)), 0.5);
    try std.testing.expectApproxEqAbs(-pi / 4.0, atan(-1.0), eps);
}

test "science: sqrt helper" {
    try std.testing.expectApproxEqAbs(@as(f64, 4), sqrt(16.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), sqrt(0.0), eps);
}
