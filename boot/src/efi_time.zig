//! Pure EFI-time -> Unix-epoch conversion (#1058).
//!
//! The loader reads `RuntimeServices.GetTime` — a broken-down wall-clock
//! face (year/month/day/hour/min/sec) — and turns it into seconds since the
//! Unix epoch with Howard Hinnant's `days_from_civil`. The fields are taken
//! AS WRITTEN (the platform's wall clock), so the result is a *wall-clock
//! epoch*: `% 86400` is local seconds-since-midnight, and the full value is
//! usable for timestamps. Keeping the conversion pure and self-contained
//! makes it host-testable — the loader itself is UEFI-only.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");

/// Sentinel for "the firmware gave no clock" (no RTC, or GetTime failed).
pub const no_epoch: u64 = std.math.maxInt(u64);

/// Days from 1970-01-01 to `year`-`month`-`day` in the proleptic Gregorian
/// calendar (Howard Hinnant's days_from_civil). `month` is 1..12, `day`
/// 1..31. Valid for the whole EFI year range (and beyond).
pub fn daysFromCivil(year_in: i64, month: i64, day: i64) i64 {
    const year = if (month <= 2) year_in - 1 else year_in;
    const era = @divFloor(year, 400);
    const yoe = year - era * 400; // [0, 399]
    const mp = if (month > 2) month - 3 else month + 9; // [0, 11]
    const doy = @divFloor(153 * mp + 2, 5) + day - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// Unix wall-clock seconds for an EFI broken-down face, or null when any
/// field is out of range (or the date precedes 1970-01-01). Pure.
pub fn toEpochSecs(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) ?u64 {
    if (year < 1970 or year > 9999) return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;
    const days = daysFromCivil(@intCast(year), @intCast(month), @intCast(day));
    const secs = days * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    if (secs < 0) return null;
    return @intCast(secs);
}

/// Local seconds since midnight for a wall-clock epoch (the tray's face).
pub fn timeOfDay(epoch_secs: u64) u64 {
    return epoch_secs % 86_400;
}

// ---------------------------------------------------------------------------
// Tests (host: pure, no UEFI)
// ---------------------------------------------------------------------------

test "efi_time: daysFromCivil anchors known dates" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 10957), daysFromCivil(2000, 1, 1));
    try std.testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
    // Leap day boundaries.
    try std.testing.expectEqual(@as(i64, 19782), daysFromCivil(2024, 2, 29));
    try std.testing.expectEqual(@as(i64, 19783), daysFromCivil(2024, 3, 1));
}

test "efi_time: toEpochSecs matches known Unix timestamps (UTC)" {
    try std.testing.expectEqual(@as(?u64, 0), toEpochSecs(1970, 1, 1, 0, 0, 0));
    try std.testing.expectEqual(@as(?u64, 946684800), toEpochSecs(2000, 1, 1, 0, 0, 0));
    try std.testing.expectEqual(@as(?u64, 1789043696), toEpochSecs(2026, 9, 10, 12, 34, 56));
    try std.testing.expectEqual(@as(?u64, 1709251199), toEpochSecs(2024, 2, 29, 23, 59, 59));
    // A full day is exactly 86_400 s.
    try std.testing.expectEqual(@as(?u64, 86_400), toEpochSecs(1970, 1, 2, 0, 0, 0));
    // Signed 32-bit boundary.
    try std.testing.expectEqual(@as(?u64, 2147483647), toEpochSecs(2038, 1, 19, 3, 14, 7));
}

test "efi_time: out-of-range faces are rejected" {
    try std.testing.expectEqual(@as(?u64, null), toEpochSecs(1969, 12, 31, 23, 59, 59));
    try std.testing.expectEqual(@as(?u64, null), toEpochSecs(1970, 0, 1, 0, 0, 0));
    try std.testing.expectEqual(@as(?u64, null), toEpochSecs(1970, 13, 1, 0, 0, 0));
    try std.testing.expectEqual(@as(?u64, null), toEpochSecs(1970, 1, 0, 0, 0, 0));
    try std.testing.expectEqual(@as(?u64, null), toEpochSecs(1970, 1, 1, 24, 0, 0));
    try std.testing.expectEqual(@as(?u64, null), toEpochSecs(1970, 1, 1, 0, 60, 0));
    try std.testing.expectEqual(@as(?u64, null), toEpochSecs(1970, 1, 1, 0, 0, 60));
}

test "efi_time: timeOfDay wraps at midnight" {
    try std.testing.expectEqual(@as(u64, 0), timeOfDay(0));
    try std.testing.expectEqual(@as(u64, 45296), timeOfDay(12 * 3600 + 34 * 60 + 56));
    try std.testing.expectEqual(@as(u64, 10), timeOfDay(86400 + 10));
}
