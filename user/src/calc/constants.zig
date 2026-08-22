//! Mathematical constants for CALC.BIN (K4).
//!
//! Each constant is a comptime i64 value (truncated to integer precision)
//! with a label for the button and a formatted string for the display.
//! Since CALC.BIN is an integer calculator, constants are stored as their
//! truncated integer value.  π → 3, e → 2, √2 → 1, φ → 1.
//!
//! However, the march doc says "π (3.14159…)" — the display should show
//! the decimal approximation as text, but the internal value is the
//! integer truncation.  For a calculator that only does integer math,
//! this is honest: pressing π inserts 3 into the accumulator, ready
//! for the next operation.  The button label says "π ≈ 3.14159" so the
//! user knows what they're getting.

const std = @import("std");

/// Number of available constants.
pub const count: usize = 4;

pub const Constant = struct {
    label: []const u8,
    value: i64,
    approx: []const u8, // decimal approximation string for display
};

/// The constant table.  Order matches button layout in the GUI.
pub const table: [count]Constant = .{
    .{ .label = "PI", .value = 3, .approx = "3.14159" },
    .{ .label = "e", .value = 2, .approx = "2.71828" },
    .{ .label = "sqrt2", .value = 1, .approx = "1.41421" },
    .{ .label = "phi", .value = 1, .approx = "1.61803" },
};

/// Get a constant by index.  Returns null if out of range.
pub fn get(idx: usize) ?Constant {
    if (idx < count) return table[idx];
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "constants: table has expected entries" {
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(i64, 3), table[0].value); // π
    try std.testing.expectEqual(@as(i64, 2), table[1].value); // e
    try std.testing.expectEqual(@as(i64, 1), table[2].value); // √2
    try std.testing.expectEqual(@as(i64, 1), table[3].value); // φ
}

test "constants: get by index" {
    const c = get(0);
    try std.testing.expect(c != null);
    try std.testing.expectEqual(@as(i64, 3), c.?.value);
    try std.testing.expect(get(4) == null);
}
