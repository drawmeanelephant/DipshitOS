//! DipshitOS fourteenth ESP user program — CALC.BIN (Milestone 11, Card A2).
//!
//! Interactive graphical calculator for DipshitOS.
//! Features a 64-bit integer calculation engine, clickable button grid,
//! keyboard numeric entry, and right-aligned LCD-style display.
//! Uses zero dynamic memory allocation (`ui.zig` micro-widgets).

const std = @import("std");
const ui = @import("lib/ui.zig");
const Rect = ui.Rect;
const Button = ui.Button;
const Event = ui.Event;

pub const window_id: u32 = 2;
pub const window_x: u32 = 48;
pub const window_y: u32 = 48;
pub const window_w: u32 = 256;
pub const window_h: u192 = 192;

pub const exit_status: u32 = 42;

// ---------------------------------------------------------------------------
// 64-bit Integer Calculator Engine
// ---------------------------------------------------------------------------

pub const CalcEngine = struct {
    accum: i64 = 0,
    current_val: i64 = 0,
    pending_op: ?u8 = null,
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
            // Guard against overflow: clamp or limit to 18 digits
            if (self.current_val >= 0 and self.current_val < 922337203685477580) {
                self.current_val = self.current_val * 10 + @as(i64, digit);
            } else if (self.current_val < 0 and self.current_val > -922337203685477580) {
                self.current_val = self.current_val * 10 - @as(i64, digit);
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
        self.current_val = -self.current_val;
        self.is_entering_val = true;
    }

    pub fn set_op(self: *CalcEngine, op: u8) void {
        if (self.is_entering_val) {
            self.evaluate();
        }
        self.accum = self.current_val;
        self.pending_op = op;
        self.is_entering_val = false;
    }

    pub fn evaluate(self: *CalcEngine) void {
        if (self.pending_op) |op| {
            var res: i64 = 0;
            switch (op) {
                '+' => {
                    res = self.accum +% self.current_val;
                },
                '-' => {
                    res = self.accum -% self.current_val;
                },
                '*' => {
                    res = self.accum *% self.current_val;
                },
                '/' => {
                    if (self.current_val == 0) {
                        self.has_error = true;
                        self.current_val = 0;
                        self.accum = 0;
                        self.pending_op = null;
                        self.is_entering_val = false;
                        return;
                    }
                    res = @divTrunc(self.accum, self.current_val);
                },
                '%' => {
                    if (self.current_val == 0) {
                        self.has_error = true;
                        self.current_val = 0;
                        self.accum = 0;
                        self.pending_op = null;
                        self.is_entering_val = false;
                        return;
                    }
                    res = @rem(self.accum, self.current_val);
                },
                else => {
                    res = self.current_val;
                },
            }
            self.current_val = res;
            self.accum = res;
            self.pending_op = null;
            self.is_entering_val = false;
        }
    }

    pub fn clear(self: *CalcEngine) void {
        self.accum = 0;
        self.current_val = 0;
        self.pending_op = null;
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
        var uval: u64 = if (is_neg) @intCast(-%val) else @intCast(val);

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

    btn_c: Button = Button.init(Rect.make(8, 44, 56, 24), "C"),
    btn_sign: Button = Button.init(Rect.make(69, 44, 56, 24), "+/-"),
    btn_mod: Button = Button.init(Rect.make(130, 44, 56, 24), "%"),
    btn_div: Button = Button.init(Rect.make(191, 44, 56, 24), "/"),

    btn_7: Button = Button.init(Rect.make(8, 72, 56, 24), "7"),
    btn_8: Button = Button.init(Rect.make(69, 72, 56, 24), "8"),
    btn_9: Button = Button.init(Rect.make(130, 72, 56, 24), "9"),
    btn_mul: Button = Button.init(Rect.make(191, 72, 56, 24), "*"),

    btn_4: Button = Button.init(Rect.make(8, 100, 56, 24), "4"),
    btn_5: Button = Button.init(Rect.make(69, 100, 56, 24), "5"),
    btn_6: Button = Button.init(Rect.make(130, 100, 56, 24), "6"),
    btn_sub: Button = Button.init(Rect.make(191, 100, 56, 24), "-"),

    btn_1: Button = Button.init(Rect.make(8, 128, 56, 24), "1"),
    btn_2: Button = Button.init(Rect.make(69, 128, 56, 24), "2"),
    btn_3: Button = Button.init(Rect.make(130, 128, 56, 24), "3"),
    btn_add: Button = Button.init(Rect.make(191, 128, 56, 24), "+"),

    btn_0: Button = Button.init(Rect.make(8, 156, 117, 24), "0"),
    btn_clr_entry: Button = Button.init(Rect.make(130, 156, 56, 24), "CE"),
    btn_eq: Button = Button.init(Rect.make(191, 156, 56, 24), "="),

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

        // Draw buttons
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

        if (self.btn_c.handle_event(ev)) {
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
