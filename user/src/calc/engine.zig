//! CalcEngine — checked 64-bit integer calculator core.
//!
//! Pure arithmetic: no GUI, no heap, no history.  Overflow shows ERROR
//! (never a silent wrap), repeat-last-op on bare `=`, BODMAS left-to-right
//! via pending_op.  Memory is a single i64 register (+flag) — M24 K2
//! extends this to 4 slots in the caller layer.

const std = @import("std");

pub const CalcEngine = struct {
    accum: i64 = 0,
    current_val: i64 = 0,
    pending_op: ?u8 = null,
    last_op: ?u8 = null,
    last_operand: i64 = 0,
    is_entering_val: bool = false,
    has_error: bool = false,

    pub fn init() CalcEngine {
        return .{};
    }

    pub fn input_digit(self: *CalcEngine, digit: u8) void {
        if (digit > 9) return;
        self.has_error = false;
        if (!self.is_entering_val) {
            self.current_val = @as(i64, digit);
            self.is_entering_val = true;
        } else {
            // Checked growth: refuse a digit that would push the entry past
            // the i64 bounds instead of silently wrapping.
            const grown = std.math.mul(i64, self.current_val, 10) catch return;
            if (self.current_val >= 0) {
                self.current_val = std.math.add(i64, grown, @as(i64, digit)) catch return;
            } else {
                self.current_val = std.math.sub(i64, grown, @as(i64, digit)) catch return;
            }
        }
    }

    pub fn backspace(self: *CalcEngine) void {
        if (!self.is_entering_val) return;
        self.current_val = @divTrunc(self.current_val, 10);
        if (self.current_val == 0) {
            self.is_entering_val = false;
        }
    }

    pub fn toggle_sign(self: *CalcEngine) void {
        if (self.has_error) return;
        if (self.current_val == std.math.minInt(i64)) {
            self.fail();
            return;
        }
        self.current_val = -self.current_val;
        self.is_entering_val = true;
    }

    pub fn set_op(self: *CalcEngine, op: u8) void {
        if (self.has_error) return;
        if (self.is_entering_val) {
            self.evaluate();
        }
        self.accum = self.current_val;
        self.pending_op = op;
        self.is_entering_val = false;
    }

    /// Evaluate the pending binary op — or, on a bare `=` with no pending
    /// op, REPEAT the last one (`5 + 3 = =` → 8, then 11, then 14).
    pub fn evaluate(self: *CalcEngine) void {
        if (self.has_error) return;
        if (self.pending_op) |op| {
            self.eval_binary(op, self.accum, self.current_val);
        } else if (self.last_op) |op| {
            self.eval_binary(op, self.current_val, self.last_operand);
        }
    }

    fn eval_binary(self: *CalcEngine, op: u8, a: i64, b: i64) void {
        var res: i64 = 0;
        var err = false;
        switch (op) {
            '+' => res = std.math.add(i64, a, b) catch blk: {
                err = true;
                break :blk 0;
            },
            '-' => res = std.math.sub(i64, a, b) catch blk: {
                err = true;
                break :blk 0;
            },
            '*' => res = std.math.mul(i64, a, b) catch blk: {
                err = true;
                break :blk 0;
            },
            '/' => {
                if (b == 0) {
                    err = true;
                } else if (a == std.math.minInt(i64) and b == -1) {
                    err = true;
                } else {
                    res = @divTrunc(a, b);
                }
            },
            '%' => {
                if (b == 0) {
                    err = true;
                } else if (a == std.math.minInt(i64) and b == -1) {
                    res = 0;
                } else {
                    res = @rem(a, b);
                }
            },
            // Bitwise operations (K1 — programmer mode)
            'A' => res = a & b, // AND
            'O' => res = a | b, // OR
            'X' => res = a ^ b, // XOR
            'L' => { // SHL
                const shift: u6 = if (b < 0 or b > 63) 0 else @intCast(b);
                res = a <<| shift;
            },
            'R' => { // SHR (arithmetic)
                const shift: u6 = if (b < 0 or b > 63) 0 else @intCast(b);
                res = a >> shift;
            },
            else => res = b,
        }
        if (err) {
            self.fail();
            return;
        }
        self.current_val = res;
        self.accum = res;
        if (self.pending_op != null) {
            self.last_op = op;
            self.last_operand = b;
        }
        self.pending_op = null;
        self.is_entering_val = false;
    }

    /// Bitwise NOT — unary operator (K1 programmer mode).
    pub fn bitwise_not(self: *CalcEngine) void {
        if (self.has_error) return;
        self.current_val = ~self.current_val;
        self.is_entering_val = true;
    }

    /// Shared error contract: ERROR on display, pending/repeat chain broken.
    fn fail(self: *CalcEngine) void {
        self.has_error = true;
        self.accum = 0;
        self.current_val = 0;
        self.pending_op = null;
        self.last_op = null;
        self.last_operand = 0;
        self.is_entering_val = false;
    }

    /// Raise the error state from the caller layer (K9 expression
    /// syntax/overflow/div-zero errors).
    pub fn raise_error(self: *CalcEngine) void {
        self.fail();
    }

    pub fn clear(self: *CalcEngine) void {
        self.accum = 0;
        self.current_val = 0;
        self.pending_op = null;
        self.last_op = null;
        self.last_operand = 0;
        self.is_entering_val = false;
        self.has_error = false;
    }

    pub fn format_display(self: *const CalcEngine, out: []u8) []const u8 {
        if (self.has_error) {
            const err_msg = "ERROR";
            @memcpy(out[0..err_msg.len], err_msg);
            return out[0..err_msg.len];
        }

        const val = self.current_val;
        if (val == 0) {
            out[0] = '0';
            return out[0..1];
        }

        const is_neg = (val < 0);
        var uval: u64 = undefined;
        if (is_neg) {
            uval = @as(u64, @intCast(-(val + 1))) + 1;
        } else {
            uval = @intCast(val);
        }

        var temp: [24]u8 = undefined;
        var idx: usize = 0;
        while (uval > 0) {
            temp[idx] = @as(u8, @intCast(uval % 10)) + '0';
            uval /= 10;
            idx += 1;
        }

        var out_idx: usize = 0;
        if (is_neg) {
            out[out_idx] = '-';
            out_idx += 1;
        }

        var i: usize = idx;
        while (i > 0) : (i -= 1) {
            out[out_idx] = temp[i - 1];
            out_idx += 1;
        }

        return out[0..out_idx];
    }
};

/// Format an i64 into a caller-provided buffer (standalone helper).
pub fn format_i64(val: i64, out: []u8) []const u8 {
    if (val == 0) {
        out[0] = '0';
        return out[0..1];
    }
    const neg = val < 0;
    var uval: u64 = if (neg) @as(u64, @intCast(-(val + 1))) + 1 else @intCast(val);
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    while (uval > 0) : (uval /= 10) {
        tmp[n] = @as(u8, @intCast(uval % 10)) + '0';
        n += 1;
    }
    var pos: usize = 0;
    if (neg) {
        out[pos] = '-';
        pos += 1;
    }
    var i: usize = n;
    while (i > 0) : (i -= 1) {
        out[pos] = tmp[i - 1];
        pos += 1;
    }
    return out[0..pos];
}

/// Scientific notation with 6 significant digits — K6.
/// `d.ddddd e+NN` / `d.ddd e-NN`; trailing zeros are stripped from the
/// fraction and the exponent is never zero-padded (`1.23e+4`, not
/// `1.23000e+04`). Mantissa digits are truncated (not rounded) at 6 sig
/// figs so the display never double-rounds a longer value upward.
pub fn format_sci(val: f64, out: []u8) []const u8 {
    if (val == 0) {
        out[0] = '0';
        return out[0..1];
    }

    var pos: usize = 0;
    if (out.len < 8) return out[0..0]; // need room for "-d e+NN" minimum

    var m = @abs(val);
    if (val < 0) {
        if (pos < out.len) {
            out[pos] = '-';
            pos += 1;
        }
    }

    // Normalize to [1, 10) by power-of-10 steps.
    var exp: i32 = 0;
    while (m >= 10.0) : (exp += 1) m /= 10.0;
    while (m < 1.0) : (exp -= 1) m *= 10.0;

    // Truncate to 6 significant digits as an integer 100000..999999.
    var scaled: u64 = @intFromFloat(m * 100000.0);
    if (scaled > 999_999) scaled = 999_999;

    // Emit d.dddd, stripping trailing zeros (and a bare '.').
    var digits: [6]u8 = undefined;
    var di: usize = 6;
    while (di > 0) {
        di -= 1;
        digits[di] = @as(u8, @intCast(scaled % 10)) + '0';
        scaled /= 10;
    }
    var frac_end: usize = 6;
    while (frac_end > 1 and digits[frac_end - 1] == '0') frac_end -= 1;

    out[pos] = digits[0];
    pos += 1;
    if (frac_end > 1) {
        out[pos] = '.';
        pos += 1;
        const fc = frac_end - 1;
        @memcpy(out[pos .. pos + fc], digits[1..frac_end]);
        pos += fc;
    }

    // Exponent: sign + minimal decimal digits.
    out[pos] = 'e';
    pos += 1;
    const eneg = exp < 0;
    var eabs: u32 = @intCast(if (eneg) -exp else exp);
    if (eneg) {
        out[pos] = '-';
        pos += 1;
    } else {
        out[pos] = '+';
        pos += 1;
    }
    var etmp: [10]u8 = undefined;
    var en: usize = 0;
    while (true) {
        etmp[en] = @as(u8, @intCast(eabs % 10)) + '0';
        en += 1;
        eabs /= 10;
        if (eabs == 0) break;
    }
    var ei: usize = en;
    while (ei > 0) : (ei -= 1) {
        out[pos] = etmp[ei - 1];
        pos += 1;
    }
    return out[0..pos];
}

/// K6 auto-switch threshold — |v| >= 1e10 renders scientific even when SCI
/// mode is off. (The issue's < 1e-4 half is unreachable for nonzero
/// integers; format_sci covers fractional magnitudes when they exist.)
pub fn sci_auto(v: i64) bool {
    if (v == 0) return false;
    const av: u64 = if (v < 0) @as(u64, @intCast(-(v + 1))) + 1 else @intCast(v);
    return av >= 10_000_000_000;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "engine: integer arithmetic operations" {
    var c = CalcEngine.init();

    c.input_digit(1);
    c.input_digit(2);
    c.set_op('+');
    c.input_digit(3);
    c.input_digit(4);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 46), c.current_val);

    c.set_op('*');
    c.input_digit(2);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 92), c.current_val);

    c.set_op('-');
    c.input_digit(1);
    c.input_digit(0);
    c.input_digit(0);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, -8), c.current_val);

    c.set_op('/');
    c.input_digit(2);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, -4), c.current_val);
}

test "engine: division by zero protection" {
    var c = CalcEngine.init();
    c.input_digit(5);
    c.set_op('/');
    c.input_digit(0);
    c.evaluate();
    try std.testing.expect(c.has_error);

    var buf: [32]u8 = undefined;
    const str = c.format_display(&buf);
    try std.testing.expectEqualStrings("ERROR", str);
}

test "engine: backspace and clear" {
    var c = CalcEngine.init();
    c.input_digit(1);
    c.input_digit(2);
    c.input_digit(3);
    try std.testing.expectEqual(@as(i64, 123), c.current_val);

    c.backspace();
    try std.testing.expectEqual(@as(i64, 12), c.current_val);

    c.clear();
    try std.testing.expectEqual(@as(i64, 0), c.current_val);
    try std.testing.expect(!c.is_entering_val);
}

test "engine: checked arithmetic — overflow shows ERROR" {
    var c = CalcEngine.init();

    c.accum = std.math.maxInt(i64);
    c.current_val = 1;
    c.is_entering_val = true;
    c.pending_op = '+';
    c.evaluate();
    try std.testing.expect(c.has_error);

    c.clear();
    c.accum = std.math.minInt(i64);
    c.current_val = 1;
    c.is_entering_val = true;
    c.pending_op = '-';
    c.evaluate();
    try std.testing.expect(c.has_error);

    c.clear();
    c.accum = 4_000_000_000;
    c.current_val = 4_000_000_000;
    c.is_entering_val = true;
    c.pending_op = '*';
    c.evaluate();
    try std.testing.expect(c.has_error);

    c.clear();
    c.accum = std.math.minInt(i64);
    c.current_val = -1;
    c.is_entering_val = true;
    c.pending_op = '/';
    c.evaluate();
    try std.testing.expect(c.has_error);

    c.clear();
    c.accum = std.math.minInt(i64);
    c.current_val = -1;
    c.is_entering_val = true;
    c.pending_op = '%';
    c.evaluate();
    try std.testing.expect(!c.has_error);
    try std.testing.expectEqual(@as(i64, 0), c.current_val);

    c.clear();
    c.current_val = std.math.minInt(i64);
    c.is_entering_val = true;
    c.toggle_sign();
    try std.testing.expect(c.has_error);

    c.clear();
    c.current_val = std.math.maxInt(i64);
    c.is_entering_val = true;
    c.input_digit(9);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), c.current_val);
    try std.testing.expect(!c.has_error);
}

test "engine: repeat-last-op on '='" {
    var c = CalcEngine.init();
    c.input_digit(5);
    c.set_op('+');
    c.input_digit(3);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 8), c.current_val);

    c.evaluate();
    try std.testing.expectEqual(@as(i64, 11), c.current_val);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 14), c.current_val);

    c.set_op('*');
    c.input_digit(2);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 28), c.current_val);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 56), c.current_val);
}

test "engine: digit after '=' re-uses repeat operand" {
    var c = CalcEngine.init();
    c.input_digit(5);
    c.set_op('+');
    c.input_digit(3);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 8), c.current_val);

    c.input_digit(2);
    try std.testing.expectEqual(@as(i64, 2), c.current_val);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 5), c.current_val);

    c.clear();
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 0), c.current_val);
}

test "engine: bitwise NOT" {
    var c = CalcEngine.init();
    c.input_digit(0);
    c.bitwise_not();
    try std.testing.expectEqual(@as(i64, -1), c.current_val);

    c.clear();
    c.input_digit(1);
    c.bitwise_not();
    // ~1 = -2 in two's complement
    try std.testing.expectEqual(@as(i64, -2), c.current_val);
}

test "engine: bitwise AND / OR / XOR" {
    var c = CalcEngine.init();

    // 0xFF AND 0x0F = 0x0F
    c.current_val = 0xFF;
    c.set_op('A');
    c.input_digit(0);
    // Hmm, input_digit builds decimal. Let me just set directly for bitwise tests.
    c.clear();
    c.accum = 0xFF;
    c.current_val = 0x0F;
    c.is_entering_val = true;
    c.pending_op = 'A';
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 0x0F), c.current_val);

    // 0xFF OR 0xF0 = 0xFF
    c.clear();
    c.accum = 0xFF;
    c.current_val = 0xF0;
    c.is_entering_val = true;
    c.pending_op = 'O';
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 0xFF), c.current_val);

    // 0xFF XOR 0x0F = 0xF0
    c.clear();
    c.accum = 0xFF;
    c.current_val = 0x0F;
    c.is_entering_val = true;
    c.pending_op = 'X';
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 0xF0), c.current_val);
}

test "engine: SHL / SHR" {
    var c = CalcEngine.init();

    // 1 << 4 = 16
    c.accum = 1;
    c.current_val = 4;
    c.is_entering_val = true;
    c.pending_op = 'L';
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 16), c.current_val);

    // 128 >> 3 = 16
    c.clear();
    c.accum = 128;
    c.current_val = 3;
    c.is_entering_val = true;
    c.pending_op = 'R';
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 16), c.current_val);
}

test "engine: format_display handles negatives, zero, and INT64_MIN" {
    var c = CalcEngine.init();
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", c.format_display(&buf));

    c.current_val = -1234;
    try std.testing.expectEqualStrings("-1234", c.format_display(&buf));

    c.current_val = std.math.minInt(i64);
    try std.testing.expectEqualStrings("-9223372036854775808", c.format_display(&buf));

    c.current_val = std.math.maxInt(i64);
    try std.testing.expectEqualStrings("9223372036854775807", c.format_display(&buf));

    c.has_error = true;
    try std.testing.expectEqualStrings("ERROR", c.format_display(&buf));
}

test "format_i64 standalone helper" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0", format_i64(0, &buf));
    try std.testing.expectEqualStrings("42", format_i64(42, &buf));
    try std.testing.expectEqualStrings("-7", format_i64(-7, &buf));
    try std.testing.expectEqualStrings("-9223372036854775808", format_i64(std.math.minInt(i64), &buf));
}
