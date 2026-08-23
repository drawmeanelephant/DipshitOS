//! calc/dates.zig — M24 K13 date/time arithmetic for CALC.BIN.
//!
//! Pure civil-date math over proleptic Gregorian calendar: parse and
//! format YYYY-MM-DD, add days, diff days, leap years. No heap, no
//! syscalls. `now()` (seconds since boot) reads the AArch64 generic
//! timer directly — CNTFRQ_EL0/CNTPCT_EL0 are EL0-accessible — so no
//  ABI slot is spent; host tests skip the register read.

const std = @import("std");

pub const DateError = error{
    Syntax, // not YYYY-MM-DD or out-of-range field
};

/// Days since 1970-01-01 for a Y-M-D triple (proleptic Gregorian).
/// Valid for years 1..9999.
pub fn to_days(y: i64, m: i64, d: i64) DateError!i64 {
    if (m < 1 or m > 12) return error.Syntax;
    if (d < 1 or d > days_in_month(y, m)) return error.Syntax;
    // Howard Hinnant's civil_from_days inverse (days_from_civil).
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400; // [0, 399]
    const mp = @mod(m + 9, 12); // Mar=0 .. Feb=11
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Inverse of to_days: Y-M-D from days since epoch.
pub fn from_days(z_in: i64) struct { y: i64, m: i64, d: i64 } {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

pub fn is_leap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

pub fn days_in_month(y: i64, m: i64) i64 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (is_leap(y)) 29 else 28,
        else => 0,
    };
}

/// Parse "YYYY-MM-DD" into days since epoch.
pub fn parse(text: []const u8) DateError!i64 {
    if (text.len != 10) return error.Syntax;
    if (text[4] != '-' or text[7] != '-') return error.Syntax;
    const y = std.fmt.parseInt(i64, text[0..4], 10) catch return error.Syntax;
    const m = std.fmt.parseInt(i64, text[5..7], 10) catch return error.Syntax;
    const d = std.fmt.parseInt(i64, text[8..10], 10) catch return error.Syntax;
    return to_days(y, m, d);
}

/// Format days-since-epoch as YYYY-MM-DD into `buf` (≥11 bytes).
pub fn format(days: i64, buf: []u8) []const u8 {
    const p = from_days(days);
    const out = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u64, @intCast(p.y)),
        @as(u64, @intCast(p.m)),
        @as(u64, @intCast(p.d)),
    }) catch return buf[0..0];
    return out;
}

/// date_add: shift a date by `days` and re-format.
pub fn date_add(text: []const u8, days: i64, out_buf: []u8) DateError![]const u8 {
    const base = try parse(text);
    return format(base + days, out_buf);
}

/// date_diff: whole days from d1 to d2 (positive when d2 is later).
pub fn date_diff(d1: []const u8, d2: []const u8) DateError!i64 {
    return (try parse(d2)) - (try parse(d1));
}

/// Seconds since boot from the AArch64 generic timer (EL0-readable).
/// Host-test builds return a stub counter instead of reading registers.
var fake_uptime: u64 = 0;

pub fn now() u64 {
    if (@import("builtin").os.tag != .freestanding) {
        fake_uptime += 42; // deterministic in host tests
        return fake_uptime;
    }
    const freq: u64 = asm ("mrs x0, cntfrq_el0"
        : [ret] "={x0}" (-> u64),
    );
    const ct: u64 = asm ("mrs x0, cntpct_el0"
        : [ret] "={x0}" (-> u64),
    );
    return ct / freq;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "dates: issue case date_diff 2026-01-01 -> 2026-01-10 = 9" {
    try std.testing.expectEqual(@as(i64, 9), try date_diff("2026-01-01", "2026-01-10"));
    try std.testing.expectEqual(@as(i64, -9), try date_diff("2026-01-10", "2026-01-01"));
}

test "dates: leap years" {
    try std.testing.expect(is_leap(2024));
    try std.testing.expect(is_leap(2000));
    try std.testing.expect(!is_leap(1900));
    try std.testing.expect(!is_leap(2023));
    try std.testing.expectEqual(@as(i64, 29), days_in_month(2024, 2));
    try std.testing.expectEqual(@as(i64, 28), days_in_month(2023, 2));
}

test "dates: round-trip across a leap day and century edges" {
    var buf: [16]u8 = undefined;
    // 2024-02-28 + 1 = 2024-02-29 (+1) = 2024-03-01
    try std.testing.expectEqualStrings("2024-02-29", try date_add("2024-02-28", 1, &buf));
    try std.testing.expectEqualStrings("2024-03-01", try date_add("2024-02-28", 2, &buf));
    // Non-leap year skips straight over
    try std.testing.expectEqualStrings("2023-03-01", try date_add("2023-02-28", 1, &buf));
    // Epoch anchor
    try std.testing.expectEqualStrings("1970-01-01", format(0, &buf));
    try std.testing.expectEqual(@as(i64, 0), try parse("1970-01-01"));
    // Year 2000 leap (divisible by 400)
    try std.testing.expectEqualStrings("2000-02-29", try date_add("2000-02-28", 1, &buf));
    // Far future
    try std.testing.expectEqualStrings("9999-12-31", try date_add("9999-01-01", 364, &buf));
}

test "dates: syntax errors are typed" {
    try std.testing.expectError(error.Syntax, parse("2026-13-01"));
    try std.testing.expectError(error.Syntax, parse("2026-02-30"));
    try std.testing.expectError(error.Syntax, parse("20260201"));
    try std.testing.expectError(error.Syntax, parse(""));
}
