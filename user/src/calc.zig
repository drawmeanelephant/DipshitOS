//! DipshitOS fourteenth ESP user program — CALC.BIN (Milestone 11, Card A2).
//!
//! Interactive graphical calculator for DipshitOS.
//! Features a checked 64-bit integer calculation engine (overflow shows
//! ERROR, never a silent wrap), repeat-last-op on `=`, memory keys
//! (M+ / M- / MR / MC), clickable button grid, keyboard numeric entry,
//! and right-aligned LCD-style display.
//! Uses zero dynamic memory allocation (`ui.zig` micro-widgets).

const std = @import("std");
const ui = @import("lib/ui.zig");
const Rect = ui.Rect;
const Button = ui.Button;
const Event = ui.Event;

pub const window_id: u32 = 2;
pub const window_x: u32 = 48;
pub const window_y: u32 = 48;
pub const window_w: u32 = 512;
pub const window_h: u32 = 384;

pub const exit_status: u32 = 42;

// ---------------------------------------------------------------------------
// 64-bit Integer Calculator Engine
// ---------------------------------------------------------------------------

pub const CalcEngine = struct {
    accum: i64 = 0,
    current_val: i64 = 0,
    pending_op: ?u8 = null,
    last_op: ?u8 = null,
    last_operand: i64 = 0,
    is_entering_val: bool = false,
    has_error: bool = false,
    mem: i64 = 0,
    mem_flag: bool = false,

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
            // the i64 bounds instead of silently wrapping. (The old clamp
            // let a 19th digit on an 18-digit entry overflow — a silent
            // wrap in the ReleaseSmall build.)
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
        // Negating INT64_MIN would overflow (two's complement); treat it
        // like any other overflow — ERROR — instead of silently wrapping.
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
    /// op, REPEAT the last one (`5 + 3 = =` → 8, then 11, then 14). All
    /// arithmetic is CHECKED: an i64 overflow sets `has_error` (ERROR on the
    /// display) instead of silently wrapping, and breaks the pending/repeat
    /// chain — the divide-by-zero contract extended to every overflow shape
    /// (including the two's-complement `INT64_MIN / -1`).
    pub fn evaluate(self: *CalcEngine) void {
        if (self.has_error) return;
        if (self.pending_op) |op| {
            self.eval_binary(op, self.accum, self.current_val);
        } else if (self.last_op) |op| {
            // Repeat-last-op: the current value is the previous result; the
            // operand is the one the last binary op consumed.
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
                    // INT64_MIN / -1 overflows (the result would be
                    // INT64_MAX + 1); @divTrunc would trap. ERROR instead.
                    err = true;
                } else {
                    res = @divTrunc(a, b);
                }
            },
            '%' => {
                if (b == 0) {
                    err = true;
                } else if (a == std.math.minInt(i64) and b == -1) {
                    // The remainder is mathematically 0 and @rem would trap
                    // on the overflowing quotient — return 0 directly.
                    res = 0;
                } else {
                    res = @rem(a, b);
                }
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
            // A completed binary op seeds the repeat chain.
            self.last_op = op;
            self.last_operand = b;
        }
        self.pending_op = null;
        self.is_entering_val = false;
    }

    /// Shared error contract: ERROR on the display and the pending/repeat
    /// chain broken. `C` restores operation; memory is untouched.
    fn fail(self: *CalcEngine) void {
        self.has_error = true;
        self.accum = 0;
        self.current_val = 0;
        self.pending_op = null;
        self.last_op = null;
        self.last_operand = 0;
        self.is_entering_val = false;
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

    // -------------------------------------------------------------------
    // Memory register (M+ / M- / MR / MC). Bounded like everything else:
    // one i64 + a set flag, checked the same way as the arithmetic.
    // -------------------------------------------------------------------

    pub fn mem_add(self: *CalcEngine) void {
        if (self.has_error) return;
        self.mem = std.math.add(i64, self.mem, self.current_val) catch {
            self.fail();
            return;
        };
        self.mem_flag = true;
        self.is_entering_val = false;
    }

    pub fn mem_sub(self: *CalcEngine) void {
        if (self.has_error) return;
        self.mem = std.math.sub(i64, self.mem, self.current_val) catch {
            self.fail();
            return;
        };
        self.mem_flag = true;
        self.is_entering_val = false;
    }

    pub fn mem_recall(self: *CalcEngine) void {
        if (self.has_error) return;
        self.current_val = self.mem;
        self.is_entering_val = true;
    }

    pub fn mem_clear(self: *CalcEngine) void {
        if (self.has_error) return;
        self.mem = 0;
        self.mem_flag = false;
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
        // Magnitude without wrapping arithmetic: -(val + 1) + 1 is safe even
        // for INT64_MIN, whose negation does not fit in i64.
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

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// GUI Layout & Button Grid (Stack-Allocated AppState)
// ---------------------------------------------------------------------------

pub const AppState = struct {
    engine: CalcEngine = .{},

    btn_mplus: Button = Button.init(Rect.make(8, 40, 56, 20), "M+"),
    btn_mminus: Button = Button.init(Rect.make(69, 40, 56, 20), "M-"),
    btn_mr: Button = Button.init(Rect.make(130, 40, 56, 20), "MR"),
    btn_mc: Button = Button.init(Rect.make(191, 40, 56, 20), "MC"),

    btn_c: Button = Button.init(Rect.make(8, 66, 56, 20), "C"),
    btn_sign: Button = Button.init(Rect.make(69, 66, 56, 20), "+/-"),
    btn_mod: Button = Button.init(Rect.make(130, 66, 56, 20), "%"),
    btn_div: Button = Button.init(Rect.make(191, 66, 56, 20), "/"),

    btn_7: Button = Button.init(Rect.make(8, 92, 56, 20), "7"),
    btn_8: Button = Button.init(Rect.make(69, 92, 56, 20), "8"),
    btn_9: Button = Button.init(Rect.make(130, 92, 56, 20), "9"),
    btn_mul: Button = Button.init(Rect.make(191, 92, 56, 20), "*"),

    btn_4: Button = Button.init(Rect.make(8, 118, 56, 20), "4"),
    btn_5: Button = Button.init(Rect.make(69, 118, 56, 20), "5"),
    btn_6: Button = Button.init(Rect.make(130, 118, 56, 20), "6"),
    btn_sub: Button = Button.init(Rect.make(191, 118, 56, 20), "-"),

    btn_1: Button = Button.init(Rect.make(8, 144, 56, 20), "1"),
    btn_2: Button = Button.init(Rect.make(69, 144, 56, 20), "2"),
    btn_3: Button = Button.init(Rect.make(130, 144, 56, 20), "3"),
    btn_add: Button = Button.init(Rect.make(191, 144, 56, 20), "+"),

    btn_0: Button = Button.init(Rect.make(8, 170, 117, 20), "0"),
    btn_clr_entry: Button = Button.init(Rect.make(130, 170, 56, 20), "CE"),
    btn_eq: Button = Button.init(Rect.make(191, 170, 56, 20), "="),

    pub fn init() AppState {
        var s = AppState{};
        s.btn_eq.bg_color = ui.COLOR_ACCENT;
        s.btn_c.bg_color = ui.COLOR_DANGER;
        return s;
    }

    pub fn draw(self: *const AppState, win: u32) void {
        // Window background
        ui.draw_rect(win, Rect.make(0, 0, window_w, window_h), ui.COLOR_BG);

        // Display box (LCD screen)
        const display_rect = Rect.make(8, 8, 239, 28);
        ui.draw_rect(win, display_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, display_rect, 1, ui.COLOR_BORDER);

        var disp_str_buf: [32]u8 = undefined;
        const disp_text = self.engine.format_display(&disp_str_buf);

        // Right-align the display text
        const text_w = @as(u32, @intCast(disp_text.len)) * 8;
        const text_x = if (display_rect.w > text_w + 8) display_rect.x + display_rect.w - text_w - 8 else display_rect.x + 4;
        const text_y = display_rect.y + (display_rect.h - 8) / 2;
        ui.draw_text(win, disp_text, text_x, text_y, ui.COLOR_TEXT_PRIMARY);

        // Memory indicator: a small 'M' at the left of the display while the
        // memory register holds a value (MC clears it).
        if (self.engine.mem_flag) {
            ui.draw_char(win, 'M', display_rect.x + 4, text_y, ui.COLOR_TEXT_MUTED);
        }

        // Draw buttons
        self.btn_mplus.draw(win);
        self.btn_mminus.draw(win);
        self.btn_mr.draw(win);
        self.btn_mc.draw(win);

        self.btn_c.draw(win);
        self.btn_sign.draw(win);
        self.btn_mod.draw(win);
        self.btn_div.draw(win);

        self.btn_7.draw(win);
        self.btn_8.draw(win);
        self.btn_9.draw(win);
        self.btn_mul.draw(win);

        self.btn_4.draw(win);
        self.btn_5.draw(win);
        self.btn_6.draw(win);
        self.btn_sub.draw(win);

        self.btn_1.draw(win);
        self.btn_2.draw(win);
        self.btn_3.draw(win);
        self.btn_add.draw(win);

        self.btn_0.draw(win);
        self.btn_clr_entry.draw(win);
        self.btn_eq.draw(win);
    }

    pub fn handle_mouse_events(self: *AppState, ev: *const Event) bool {
        var changed = false;

        if (self.btn_mplus.handle_event(ev)) {
            self.engine.mem_add();
            changed = true;
        } else if (self.btn_mminus.handle_event(ev)) {
            self.engine.mem_sub();
            changed = true;
        } else if (self.btn_mr.handle_event(ev)) {
            self.engine.mem_recall();
            changed = true;
        } else if (self.btn_mc.handle_event(ev)) {
            self.engine.mem_clear();
            changed = true;
        } else if (self.btn_c.handle_event(ev)) {
            self.engine.clear();
            changed = true;
        } else if (self.btn_sign.handle_event(ev)) {
            self.engine.toggle_sign();
            changed = true;
        } else if (self.btn_mod.handle_event(ev)) {
            self.engine.set_op('%');
            changed = true;
        } else if (self.btn_div.handle_event(ev)) {
            self.engine.set_op('/');
            changed = true;
        } else if (self.btn_7.handle_event(ev)) {
            self.engine.input_digit(7);
            changed = true;
        } else if (self.btn_8.handle_event(ev)) {
            self.engine.input_digit(8);
            changed = true;
        } else if (self.btn_9.handle_event(ev)) {
            self.engine.input_digit(9);
            changed = true;
        } else if (self.btn_mul.handle_event(ev)) {
            self.engine.set_op('*');
            changed = true;
        } else if (self.btn_4.handle_event(ev)) {
            self.engine.input_digit(4);
            changed = true;
        } else if (self.btn_5.handle_event(ev)) {
            self.engine.input_digit(5);
            changed = true;
        } else if (self.btn_6.handle_event(ev)) {
            self.engine.input_digit(6);
            changed = true;
        } else if (self.btn_sub.handle_event(ev)) {
            self.engine.set_op('-');
            changed = true;
        } else if (self.btn_1.handle_event(ev)) {
            self.engine.input_digit(1);
            changed = true;
        } else if (self.btn_2.handle_event(ev)) {
            self.engine.input_digit(2);
            changed = true;
        } else if (self.btn_3.handle_event(ev)) {
            self.engine.input_digit(3);
            changed = true;
        } else if (self.btn_add.handle_event(ev)) {
            self.engine.set_op('+');
            changed = true;
        } else if (self.btn_0.handle_event(ev)) {
            self.engine.input_digit(0);
            changed = true;
        } else if (self.btn_clr_entry.handle_event(ev)) {
            self.engine.current_val = 0;
            self.engine.is_entering_val = false;
            changed = true;
        } else if (self.btn_eq.handle_event(ev)) {
            self.engine.evaluate();
            changed = true;
        }

        return changed;
    }

    pub fn handle_keyboard_event(self: *AppState, ev: *const Event) bool {
        if (ev.kind != ui.KEY_DOWN) return false;
        const ascii = @as(u8, @truncate(ev.arg1));

        if (ascii >= '0' and ascii <= '9') {
            self.engine.input_digit(ascii - '0');
            return true;
        }

        switch (ascii) {
            '+', '-', '*', '/', '%' => {
                self.engine.set_op(ascii);
                return true;
            },
            '=', '\r', '\n' => {
                self.engine.evaluate();
                return true;
            },
            'c', 'C', 0x1b => {
                self.engine.clear();
                return true;
            },
            'm', 'M' => {
                self.engine.mem_recall();
                return true;
            },
            0x08 => {
                self.engine.backspace();
                return true;
            },
            else => return false,
        }
    }
};

// ---------------------------------------------------------------------------
// Entry Point (EL0)
// ---------------------------------------------------------------------------

pub export fn _start() callconv(.c) noreturn {
    var app = AppState.init();

    // 1. Open Window
    const win_res = ui.win_open(window_x, window_y, window_w, window_h);
    if (win_res < 0) {
        ui.write_console("calc: failed to open window\n");
        ui.exit_process(1);
    }
    const win = @as(u32, @intCast(win_res));

    ui.write_console("calc: open id=2\n");

    // 2. Initial Draw & Present
    app.draw(win);
    ui.win_present(win);
    ui.write_console("calc: ready\n");

    // 3. Event Loop
    var ev: Event = undefined;
    while (true) {
        const wait_rc = ui.wait_event(&ev);
        if (wait_rc < 0) break;

        var dirty = false;

        if (ev.kind == ui.WIN_CLOSE) {
            ui.write_console("calc: win_close\n");
            break;
        }

        if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP or ev.kind == ui.MOUSE_MOVE) {
            dirty = app.handle_mouse_events(&ev) or dirty;
        } else if (ev.kind == ui.KEY_DOWN) {
            dirty = app.handle_keyboard_event(&ev) or dirty;
        }

        // Drain any pending events in the queue before redraw pass
        while (ui.poll_event(&ev) > 0) {
            if (ev.kind == ui.WIN_CLOSE) {
                ui.write_console("calc: win_close\n");
                ui.win_close(win);
                ui.exit_process(exit_status);
            }
            if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP or ev.kind == ui.MOUSE_MOVE) {
                dirty = app.handle_mouse_events(&ev) or dirty;
            } else if (ev.kind == ui.KEY_DOWN) {
                dirty = app.handle_keyboard_event(&ev) or dirty;
            }
        }

        if (dirty) {
            app.draw(win);
            ui.win_present(win);
        }
    }

    ui.write_console("calc: exiting 43\n");
    ui.win_close(win);
    ui.exit_process(exit_status);
}

// ---------------------------------------------------------------------------
// Unit Tests (Class A Host Validation)
// ---------------------------------------------------------------------------

test "calc: integer arithmetic operations" {
    var c = CalcEngine.init();

    // 12 + 34 = 46
    c.input_digit(1);
    c.input_digit(2);
    c.set_op('+');
    c.input_digit(3);
    c.input_digit(4);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 46), c.current_val);

    // 46 * 2 = 92
    c.set_op('*');
    c.input_digit(2);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 92), c.current_val);

    // 92 - 100 = -8
    c.set_op('-');
    c.input_digit(1);
    c.input_digit(0);
    c.input_digit(0);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, -8), c.current_val);

    // -8 / 2 = -4
    c.set_op('/');
    c.input_digit(2);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, -4), c.current_val);
}

test "calc: division by zero protection" {
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

test "calc: backspace and clear" {
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

test "calc: checked arithmetic — overflow shows ERROR instead of wrapping" {
    var c = CalcEngine.init();

    // Add overflow: INT64_MAX + 1.
    c.accum = std.math.maxInt(i64);
    c.current_val = 1;
    c.is_entering_val = true;
    c.pending_op = '+';
    c.evaluate();
    try std.testing.expect(c.has_error);
    try std.testing.expectEqual(@as(i64, 0), c.current_val);

    // Subtract overflow: INT64_MIN - 1.
    c.clear();
    c.accum = std.math.minInt(i64);
    c.current_val = 1;
    c.is_entering_val = true;
    c.pending_op = '-';
    c.evaluate();
    try std.testing.expect(c.has_error);

    // Multiply overflow: 4e9 * 4e9 = 1.6e19 > INT64_MAX.
    c.clear();
    c.accum = 4_000_000_000;
    c.current_val = 4_000_000_000;
    c.is_entering_val = true;
    c.pending_op = '*';
    c.evaluate();
    try std.testing.expect(c.has_error);

    // INT64_MIN / -1: the two's-complement overflow @divTrunc would trap on.
    c.clear();
    c.accum = std.math.minInt(i64);
    c.current_val = -1;
    c.is_entering_val = true;
    c.pending_op = '/';
    c.evaluate();
    try std.testing.expect(c.has_error);

    // INT64_MIN % -1 is mathematically 0 — no error, no trap.
    c.clear();
    c.accum = std.math.minInt(i64);
    c.current_val = -1;
    c.is_entering_val = true;
    c.pending_op = '%';
    c.evaluate();
    try std.testing.expect(!c.has_error);
    try std.testing.expectEqual(@as(i64, 0), c.current_val);

    // Toggle-sign of INT64_MIN is an overflow too.
    c.clear();
    c.current_val = std.math.minInt(i64);
    c.is_entering_val = true;
    c.toggle_sign();
    try std.testing.expect(c.has_error);

    // Digit entry can never wrap: a digit past the i64 bound is refused,
    // not silently wrapped.
    c.clear();
    c.current_val = std.math.maxInt(i64);
    c.is_entering_val = true;
    c.input_digit(9);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), c.current_val);
    try std.testing.expect(!c.has_error);
}

test "calc: repeat-last-op on '='" {
    var c = CalcEngine.init();
    c.input_digit(5);
    c.set_op('+');
    c.input_digit(3);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 8), c.current_val);

    // Bare '=' repeats: 8 + 3 = 11, then 14.
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 11), c.current_val);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 14), c.current_val);

    // A new operator starts a fresh chain: 14 * 2 = 28, then 28 * 2 = 56.
    c.set_op('*');
    c.input_digit(2);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 28), c.current_val);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 56), c.current_val);
}

test "calc: digit after '=' re-uses the repeat operand (constant mode)" {
    var c = CalcEngine.init();
    c.input_digit(5);
    c.set_op('+');
    c.input_digit(3);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 8), c.current_val);

    // A fresh operand + '=' applies the retained +3: 2 + 3 = 5.
    c.input_digit(2);
    try std.testing.expectEqual(@as(i64, 2), c.current_val);
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 5), c.current_val);

    // C clears the chain: a bare '=' after C is a no-op.
    c.clear();
    c.evaluate();
    try std.testing.expectEqual(@as(i64, 0), c.current_val);
}

test "calc: memory keys M+ / M- / MR / MC" {
    var c = CalcEngine.init();
    c.input_digit(1);
    c.input_digit(2); // 12
    c.mem_add();
    try std.testing.expect(c.mem_flag);
    try std.testing.expectEqual(@as(i64, 12), c.mem);

    c.input_digit(5); // 5 — a fresh entry (mem_add ended entering mode)
    c.mem_add();
    try std.testing.expectEqual(@as(i64, 17), c.mem);

    c.mem_sub();
    try std.testing.expectEqual(@as(i64, 12), c.mem);

    // MR recalls into the display and starts a fresh entry.
    c.mem_recall();
    try std.testing.expectEqual(@as(i64, 12), c.current_val);
    try std.testing.expect(c.is_entering_val);

    // C does not clear memory (that is MC's job).
    c.clear();
    try std.testing.expectEqual(@as(i64, 12), c.mem);
    try std.testing.expect(c.mem_flag);

    c.mem_clear();
    try std.testing.expect(!c.mem_flag);
    try std.testing.expectEqual(@as(i64, 0), c.mem);
    c.mem_recall();
    try std.testing.expectEqual(@as(i64, 0), c.current_val);
}

test "calc: memory overflow is checked" {
    var c = CalcEngine.init();
    c.mem = std.math.maxInt(i64);
    c.mem_flag = true;
    c.current_val = 1;
    c.is_entering_val = true;
    c.mem_add();
    try std.testing.expect(c.has_error);
}

test "calc: format_display handles negatives, zero, and INT64_MIN without wrapping" {
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
