//! Programmer mode state for CALC.BIN (K1).
//!
//! Handles hex/octal/decimal formatting, 8 scratch registers (R0–R7),
//! and the mode toggle.  Zero GUI dependencies — the caller (calc.zig)
//! handles layout and rendering.

const std = @import("std");

pub const Base = enum(u2) {
    hex = 0,
    dec = 1,
    oct = 2,
};

pub const num_registers: usize = 8;

pub const ProgrammerState = struct {
    active: bool = false,
    base: Base = .dec,
    registers: [num_registers]i64 = [_]i64{0} ** num_registers,
    active_reg: u3 = 0, // which register is selected (0–7)

    pub fn init() ProgrammerState {
        return .{};
    }

    pub fn toggle(self: *ProgrammerState) void {
        self.active = !self.active;
    }

    pub fn set_base(self: *ProgrammerState, b: Base) void {
        self.base = b;
    }

    /// Store current_val into the active register.
    pub fn store_reg(self: *ProgrammerState, val: i64) void {
        self.registers[self.active_reg] = val;
    }

    /// Recall the active register value.
    pub fn recall_reg(self: *const ProgrammerState) i64 {
        return self.registers[self.active_reg];
    }

    /// Cycle to the next register (0–7 wrapping).
    pub fn next_reg(self: *ProgrammerState) void {
        self.active_reg = @intCast((@as(usize, self.active_reg) + 1) % num_registers);
    }
};

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

/// Format value as hex string into `out`.  Returns the written slice.
/// Uses uppercase hex digits (A–F).  Prefix "0x" included.
pub fn format_hex(val: i64, out: []u8) []const u8 {
    const uval: u64 = @bitCast(val);
    if (uval == 0) {
        out[0] = '0';
        return out[0..1];
    }
    const hex_chars = "0123456789ABCDEF";
    var temp: [16]u8 = undefined;
    var idx: usize = 0;
    var v = uval;
    while (v > 0) {
        temp[idx] = hex_chars[v & 0x0F];
        v >>= 4;
        idx += 1;
    }
    // Reverse into output
    var pos: usize = 0;
    var i: usize = idx;
    while (i > 0) : (i -= 1) {
        out[pos] = temp[i - 1];
        pos += 1;
    }
    return out[0..pos];
}

/// Format value as octal string into `out`.  Returns the written slice.
pub fn format_oct(val: i64, out: []u8) []const u8 {
    const uval: u64 = @bitCast(val);
    if (uval == 0) {
        out[0] = '0';
        return out[0..1];
    }
    var temp: [22]u8 = undefined;
    var idx: usize = 0;
    var v = uval;
    while (v > 0) {
        temp[idx] = @as(u8, @intCast(v & 7)) + '0';
        v >>= 3;
        idx += 1;
    }
    var pos: usize = 0;
    var i: usize = idx;
    while (i > 0) : (i -= 1) {
        out[pos] = temp[i - 1];
        pos += 1;
    }
    return out[0..pos];
}

/// Format value as decimal string into `out`.  Returns the written slice.
/// Handles negative values and INT64_MIN.
pub fn format_dec(val: i64, out: []u8) []const u8 {
    if (val == 0) {
        out[0] = '0';
        return out[0..1];
    }
    const is_neg = val < 0;
    var uval: u64 = if (is_neg) @as(u64, @intCast(-(val + 1))) + 1 else @intCast(val);
    var temp: [20]u8 = undefined;
    var idx: usize = 0;
    while (uval > 0) {
        temp[idx] = @as(u8, @intCast(uval % 10)) + '0';
        uval /= 10;
        idx += 1;
    }
    var pos: usize = 0;
    if (is_neg) {
        out[pos] = '-';
        pos += 1;
    }
    var i: usize = idx;
    while (i > 0) : (i -= 1) {
        out[pos] = temp[i - 1];
        pos += 1;
    }
    return out[0..pos];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "programmer: toggle mode" {
    var p = ProgrammerState.init();
    try std.testing.expect(!p.active);
    p.toggle();
    try std.testing.expect(p.active);
    p.toggle();
    try std.testing.expect(!p.active);
}

test "programmer: register store/recall" {
    var p = ProgrammerState.init();
    p.store_reg(42);
    try std.testing.expectEqual(@as(i64, 42), p.recall_reg());

    p.next_reg();
    try std.testing.expectEqual(@as(u3, 1), p.active_reg);
    p.store_reg(99);
    try std.testing.expectEqual(@as(i64, 99), p.recall_reg());

    // Go back to reg 0
    p.active_reg = 0;
    try std.testing.expectEqual(@as(i64, 42), p.recall_reg());
}

test "programmer: register cycling wraps" {
    var p = ProgrammerState.init();
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        p.next_reg();
    }
    try std.testing.expectEqual(@as(u3, 0), p.active_reg);
}

test "programmer: format_hex basic" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0", format_hex(0, &buf));
    try std.testing.expectEqualStrings("FF", format_hex(0xFF, &buf));
    try std.testing.expectEqualStrings("10", format_hex(16, &buf));
    try std.testing.expectEqualStrings("DEADBEEF", format_hex(@bitCast(@as(u64, 0xDEADBEEF)), &buf));
}

test "programmer: format_oct basic" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0", format_oct(0, &buf));
    try std.testing.expectEqualStrings("77", format_oct(63, &buf));
    try std.testing.expectEqualStrings("10", format_oct(8, &buf));
}

test "programmer: format_dec basic" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0", format_dec(0, &buf));
    try std.testing.expectEqualStrings("42", format_dec(42, &buf));
    try std.testing.expectEqualStrings("-7", format_dec(-7, &buf));
    try std.testing.expectEqualStrings("-9223372036854775808", format_dec(std.math.minInt(i64), &buf));
}
