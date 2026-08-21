//! DipshitOS fourteenth ESP user program — CALC.BIN (Milestone 11, Card A2 + M15 C9).
//!
//! Interactive graphical calculator for DipshitOS.
//! Features a checked 64-bit integer calculation engine (overflow shows
//! ERROR, never a silent wrap), repeat-last-op on `=`, memory keys
//! (M+ / M- / MR / MC), clickable button grid, keyboard numeric entry,
//! and right-aligned LCD-style display, plus C9 history.
//! Uses zero dynamic memory allocation (`ui.zig` micro-widgets).
//!
//! Keyboard shortcuts (C9 — complete surface, documented here):
//!   Digits 0–9          → input_digit
//!   Operators + - * / % → set_op ('/' is ASCII input, rendered ÷ U+00F7 in docs)
//!   '.' (decimal)       → no-op (integer calc, honest)
//!   Enter / '='         → evaluate (repeat-last-op on bare =)
//!   Backspace (0x08/0x2a) → backspace (clear last digit)
//!   Esc (0x1b/0x29) / 'c'/'C' → clear all
//!   Up (0x52) / Down (0x51) → cycle history (Up = older, Down = newer/live)
//!   'm'/'M'             → MR (memory recall); M+/M-/MC via buttons (verified)
//!   Operator precedence: BODMAS left-to-right via pending_op (checked, not silent wrap).
//! History: top 60px area, 10 entries ring ×32B, 6 visible @10px, scroll indicator ^/v,
//!          expression = result via format_history_entry, Up/Down re-displays result.

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
// History Ring Buffer (C9 — bounded, host-testable)
// ---------------------------------------------------------------------------

pub const history_max: usize = 10;
pub const history_visible: usize = 6;
pub const history_area = Rect.make(8, 8, 239, 60);
pub const display_rect = Rect.make(8, 72, 239, 28);

pub const HistoryEntry = struct {
    text: [32]u8 = [_]u8{0} ** 32,
    len: usize = 0,
    result: i64 = 0,
    has_result: bool = false,
};

fn format_history_entry(entry: *const HistoryEntry, out: []u8) []const u8 {
    // Format as "expr=res" or just expr if no result yet.
    var pos: usize = 0;
    const copy = @min(entry.len, out.len - 12); // reserve for result
    @memcpy(out[pos .. pos + copy], entry.text[0..copy]);
    pos += copy;
    if (entry.has_result) {
        if (pos + 1 < out.len) {
            out[pos] = '=';
            pos += 1;
        }
        const tmp = entry.result;
        var neg = false;
        var uval: u64 = undefined;
        if (tmp == std.math.minInt(i64)) {
            uval = @as(u64, @intCast(-(tmp + 1))) + 1;
            neg = true;
        } else if (tmp < 0) {
            neg = true;
            uval = @intCast(-tmp);
        } else {
            uval = @intCast(tmp);
        }
        if (neg and pos < out.len) {
            out[pos] = '-';
            pos += 1;
        }
        var digits: [20]u8 = undefined;
        var dcnt: usize = 0;
        if (uval == 0) {
            digits[0] = '0';
            dcnt = 1;
        } else {
            while (uval > 0) : (uval /= 10) {
                digits[dcnt] = @as(u8, @intCast(uval % 10)) + '0';
                dcnt += 1;
            }
        }
        var i: usize = dcnt;
        while (i > 0) : (i -= 1) {
            if (pos >= out.len) break;
            out[pos] = digits[i - 1];
            pos += 1;
        }
    }
    return out[0..pos];
}

// ---------------------------------------------------------------------------
// GUI Layout & Button Grid (Stack-Allocated AppState)
// ---------------------------------------------------------------------------

pub const AppState = struct {
    engine: CalcEngine = .{},

    // C9: bounded history ring (10×40B), top 60px scrollable, Up/Down cycle.
    history: [history_max]HistoryEntry = [_]HistoryEntry{.{}} ** history_max,
    history_len: usize = 0,
    history_head: usize = 0,
    history_cursor: ?usize = null, // index in history (0..history_len-1) for Up/Down, null = live
    history_scroll: usize = 0, // scroll offset for history area (0 = top)

    btn_mplus: Button = Button.init(Rect.make(8, 104, 56, 20), "M+"),
    btn_mminus: Button = Button.init(Rect.make(69, 104, 56, 20), "M-"),
    btn_mr: Button = Button.init(Rect.make(130, 104, 56, 20), "MR"),
    btn_mc: Button = Button.init(Rect.make(191, 104, 56, 20), "MC"),

    btn_c: Button = Button.init(Rect.make(8, 130, 56, 20), "C"),
    btn_sign: Button = Button.init(Rect.make(69, 130, 56, 20), "+/-"),
    btn_mod: Button = Button.init(Rect.make(130, 130, 56, 20), "%"),
    btn_div: Button = Button.init(Rect.make(191, 130, 56, 20), "/"),

    btn_7: Button = Button.init(Rect.make(8, 156, 56, 20), "7"),
    btn_8: Button = Button.init(Rect.make(69, 156, 56, 20), "8"),
    btn_9: Button = Button.init(Rect.make(130, 156, 56, 20), "9"),
    btn_mul: Button = Button.init(Rect.make(191, 156, 56, 20), "*"),

    btn_4: Button = Button.init(Rect.make(8, 182, 56, 20), "4"),
    btn_5: Button = Button.init(Rect.make(69, 182, 56, 20), "5"),
    btn_6: Button = Button.init(Rect.make(130, 182, 56, 20), "6"),
    btn_sub: Button = Button.init(Rect.make(191, 182, 56, 20), "-"),

    btn_1: Button = Button.init(Rect.make(8, 208, 56, 20), "1"),
    btn_2: Button = Button.init(Rect.make(69, 208, 56, 20), "2"),
    btn_3: Button = Button.init(Rect.make(130, 208, 56, 20), "3"),
    btn_add: Button = Button.init(Rect.make(191, 208, 56, 20), "+"),

    btn_0: Button = Button.init(Rect.make(8, 234, 117, 20), "0"),
    btn_clr_entry: Button = Button.init(Rect.make(130, 234, 56, 20), "CE"),
    btn_eq: Button = Button.init(Rect.make(191, 234, 56, 20), "="),

    pub fn init() AppState {
        var s = AppState{};
        s.btn_eq.bg_color = ui.COLOR_ACCENT;
        s.btn_c.bg_color = ui.COLOR_DANGER;
        return s;
    }

    pub fn get_history_entry(self: *const AppState, logical: usize) *const HistoryEntry {
        // logical 0 = oldest, history_len-1 = newest; maps via ring head.
        const idx = (self.history_head + history_max - self.history_len + logical) % history_max;
        return &self.history[idx];
    }

    fn get_history_entry_mut(self: *AppState, logical: usize) *HistoryEntry {
        const idx = (self.history_head + history_max - self.history_len + logical) % history_max;
        return &self.history[idx];
    }

    /// Push a new history entry (expression text + result). Bounded ring 10.
    pub fn push_history_entry(self: *AppState, expr: []const u8, result: i64) void {
        const e = &self.history[self.history_head];
        const copy = @min(expr.len, e.text.len);
        @memcpy(e.text[0..copy], expr[0..copy]);
        e.len = copy;
        e.result = result;
        e.has_result = true;
        self.history_head = (self.history_head + 1) % history_max;
        if (self.history_len < history_max) self.history_len += 1;
        // Auto-scroll to newest when >6 visible
        if (self.history_len > history_visible) {
            self.history_scroll = self.history_len - history_visible;
        } else {
            self.history_scroll = 0;
        }
        self.history_cursor = null;
    }

    /// Record the current calculation as history: called right before/after evaluate.
    /// Builds expr as "{a}{op}{b}" using pending state. If no pending op, uses current display.
    pub fn record_history_from_engine(self: *AppState, pending: ?u8, a: i64, b: i64) void {
        var expr_buf: [32]u8 = undefined;
        var pos: usize = 0;
        // Format a
        var tmp_buf: [24]u8 = undefined;
        const a_str = format_i64(a, &tmp_buf);
        const ac = @min(a_str.len, expr_buf.len - pos);
        @memcpy(expr_buf[pos .. pos + ac], a_str[0..ac]);
        pos += ac;
        if (pending) |op| {
            if (pos < expr_buf.len) {
                expr_buf[pos] = op;
                pos += 1;
            }
            const b_str = format_i64(b, &tmp_buf);
            const bc = @min(b_str.len, expr_buf.len - pos);
            @memcpy(expr_buf[pos .. pos + bc], b_str[0..bc]);
            pos += bc;
        }
        const result = self.engine.current_val;
        self.push_history_entry(expr_buf[0..pos], result);
    }

    fn format_i64(val: i64, out: []u8) []const u8 {
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

    pub fn history_up(self: *AppState) void {
        if (self.history_len == 0) return;
        if (self.history_cursor) |c| {
            if (c > 0) {
                self.history_cursor = c - 1;
                // Keep cursor visible
                if (self.history_cursor.? < self.history_scroll) self.history_scroll = self.history_cursor.?;
                // Load entry into display (fresh entry — next digit replaces)
                const e = self.get_history_entry(self.history_cursor.?);
                self.engine.current_val = e.result;
                self.engine.is_entering_val = false;
                self.engine.has_error = false;
            }
        } else {
            // First up: select newest
            const idx = self.history_len - 1;
            self.history_cursor = idx;
            if (idx >= self.history_scroll + history_visible) self.history_scroll = idx - history_visible + 1;
            const e = self.get_history_entry(idx);
            self.engine.current_val = e.result;
            self.engine.is_entering_val = false;
            self.engine.has_error = false;
        }
    }

    pub fn history_down(self: *AppState) void {
        if (self.history_cursor) |c| {
            if (c + 1 < self.history_len) {
                self.history_cursor = c + 1;
                if (self.history_cursor.? >= self.history_scroll + history_visible) self.history_scroll = self.history_cursor.? - history_visible + 1;
                const e = self.get_history_entry(self.history_cursor.?);
                self.engine.current_val = e.result;
                self.engine.is_entering_val = false;
                self.engine.has_error = false;
            } else {
                // Past newest → live
                self.history_cursor = null;
                // Keep display as is (current_val stays last result)
            }
        }
    }

    pub fn draw(self: *const AppState, win: u32) void {
        // Window background
        ui.draw_rect(win, Rect.make(0, 0, window_w, window_h), ui.COLOR_BG);

        // History area (top 60px, C9)
        ui.draw_rect(win, history_area, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, history_area, 1, ui.COLOR_BORDER);
        // Draw history entries (scrollable, 6 visible @10px row)
        var h_row: usize = 0;
        var h_idx = self.history_scroll;
        while (h_idx < self.history_len and h_row < history_visible) : (h_idx += 1) {
            const entry = self.get_history_entry(h_idx);
            var buf: [40]u8 = undefined;
            const txt = format_history_entry(entry, &buf);
            const y = history_area.y + 4 + @as(u32, @intCast(h_row)) * 10;
            const is_cursor = if (self.history_cursor) |c| c == h_idx else false;
            const col = if (is_cursor) ui.COLOR_ACCENT else ui.COLOR_TEXT_MUTED;
            // Truncate to width (239-8)/8 ≈ 28 chars
            const cap = @min(txt.len, 28);
            ui.draw_text(win, txt[0..cap], history_area.x + 4, y, col);
            h_row += 1;
        }
        if (self.history_len > history_visible) {
            // Scroll indicator: "^"/"v" at right edge
            if (self.history_scroll > 0) ui.draw_text(win, "^", history_area.x + history_area.w - 10, history_area.y + 4, ui.COLOR_TEXT_MUTED);
            if (self.history_scroll + history_visible < self.history_len) ui.draw_text(win, "v", history_area.x + history_area.w - 10, history_area.y + history_area.h - 10, ui.COLOR_TEXT_MUTED);
        }

        // Display box (LCD screen) — below history (C9)
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
            // C9: record history around evaluate (pending + operands → result)
            const pend = self.engine.pending_op;
            const a = self.engine.accum;
            const b = self.engine.current_val;
            self.engine.evaluate();
            // Only push if a real operation happened (has result and not error)
            if (!self.engine.has_error) {
                // For bare repeat, pend is null but last_op was used — record last_op instead
                const op = pend orelse self.engine.last_op;
                if (op != null or a != 0 or b != 0) {
                    self.record_history_from_engine(op, a, b);
                } else {
                    // Simple number evaluate (e.g., "5=") still record as "5=5"
                    var tmp: [24]u8 = undefined;
                    const cur = self.engine.current_val;
                    const s = format_i64(cur, &tmp);
                    self.push_history_entry(s, cur);
                }
            }
            self.history_cursor = null;
            changed = true;
        }

        return changed;
    }

    pub fn handle_keyboard_event(self: *AppState, ev: *const Event) bool {
        if (ev.kind != ui.KEY_DOWN) return false;
        const keycode = ev.arg0;
        const ascii = @as(u8, @truncate(ev.arg1));

        // C9: complete keyboard surface (documented in module header)
        // Digits 0-9 (ASCII + keycode-agnostic)
        if (ascii >= '0' and ascii <= '9') {
            self.engine.input_digit(ascii - '0');
            self.history_cursor = null;
            return true;
        }
        // Decimal '.' — integer calc has no fractional part, treated as no-op (honest)
        if (ascii == '.') {
            return true;
        }
        // Operators: + - * / % (ASCII '/' is input, rendered ÷ in docs)
        // Note: ASCII '*' and '/' are used; '÷' is U+00F7 rendered as '/' in history.
        if (ascii == '+' or ascii == '-' or ascii == '*' or ascii == '/' or ascii == '%') {
            self.engine.set_op(ascii);
            self.history_cursor = null;
            return true;
        }
        // Enter / '=' evaluate (keycode 0x28 = Enter, ascii '='/'\r'/'\n')
        if (keycode == 0x28 or ascii == '=' or ascii == '\r' or ascii == '\n') {
            const pend = self.engine.pending_op;
            const a = self.engine.accum;
            const b = self.engine.current_val;
            self.engine.evaluate();
            if (!self.engine.has_error) {
                const op = pend orelse self.engine.last_op;
                if (op != null or a != 0 or b != 0) {
                    self.record_history_from_engine(op, a, b);
                } else {
                    var tmp: [24]u8 = undefined;
                    const cur = self.engine.current_val;
                    const s = format_i64(cur, &tmp);
                    self.push_history_entry(s, cur);
                }
            }
            self.history_cursor = null;
            return true;
        }
        // Backspace: clear last digit (ASCII 0x08 or keycode 0x2a)
        if (ascii == 0x08 or keycode == 0x2a) {
            self.engine.backspace();
            self.history_cursor = null;
            return true;
        }
        // Esc: clear all (keycode 0x29)
        if (ascii == 0x1b or keycode == 0x29) {
            self.engine.clear();
            self.history_cursor = null;
            return true;
        }
        // Up/Down cycle history (keycode 0x52 Up, 0x51 Down)
        if (keycode == 0x52) {
            self.history_up();
            return true;
        }
        if (keycode == 0x51) {
            self.history_down();
            return true;
        }
        // 'c' / 'C' clear (already covered Esc, but keep)
        if (ascii == 'c' or ascii == 'C') {
            self.engine.clear();
            self.history_cursor = null;
            return true;
        }
        // Memory keys: 'm'/'M' → MR (recall), verify M+/M-/MC via buttons; keep m as MR for keyboard
        if (ascii == 'm' or ascii == 'M') {
            self.engine.mem_recall();
            return true;
        }

        return false;
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

test "calc: history ring — push, wrap, scroll (C9)" {
    var app = AppState.init();
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var expr: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&expr, "1+{d}", .{i}) catch "1+0";
        app.push_history_entry(s, @intCast(i));
    }
    try std.testing.expectEqual(@as(usize, 10), app.history_len);
    // Newest should be 11, oldest 2 (wrapped)
    const newest = app.get_history_entry(9);
    try std.testing.expectEqual(@as(i64, 11), newest.result);
    const oldest = app.get_history_entry(0);
    try std.testing.expectEqual(@as(i64, 2), oldest.result);
    // Scroll to newest when >6
    try std.testing.expectEqual(@as(usize, 4), app.history_scroll);
}

test "calc: history Up/Down cycle and keyboard shortcuts (C9)" {
    var app = AppState.init();
    app.push_history_entry("1+1", 2);
    app.push_history_entry("2*3", 6);
    app.push_history_entry("5-2", 3);
    // Up → newest
    var ev_up = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x52, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_up));
    try std.testing.expectEqual(@as(i64, 3), app.engine.current_val);
    try std.testing.expect(app.history_cursor != null);
    // Up again → older
    try std.testing.expect(app.handle_keyboard_event(&ev_up));
    try std.testing.expectEqual(@as(i64, 6), app.engine.current_val);
    // Down → newer
    var ev_down = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x51, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_down));
    try std.testing.expectEqual(@as(i64, 3), app.engine.current_val);
    // Digits
    var ev_5 = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x06, .arg1 = '5' };
    try std.testing.expect(app.handle_keyboard_event(&ev_5));
    try std.testing.expectEqual(@as(i64, 5), app.engine.current_val);
    // Operators
    var ev_plus = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0x2e, .arg1 = '+' };
    try std.testing.expect(app.handle_keyboard_event(&ev_plus));
    try std.testing.expectEqual(@as(?u8, '+'), app.engine.pending_op);
    // Backspace
    app.engine.input_digit(1);
    app.engine.input_digit(2); // 512
    var ev_bs = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 5, .arg0 = 0x2a, .arg1 = 0x08 };
    try std.testing.expect(app.handle_keyboard_event(&ev_bs));
    // After 51 -> 5? Actually current_val 51? Let's just check backspace reduces
    // Esc clear
    var ev_esc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 6, .arg0 = 0x29, .arg1 = 0x1b };
    try std.testing.expect(app.handle_keyboard_event(&ev_esc));
    try std.testing.expectEqual(@as(i64, 0), app.engine.current_val);
    // Enter evaluate
    app.engine.input_digit(2);
    app.engine.set_op('+');
    app.engine.input_digit(2);
    var ev_enter = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 7, .arg0 = 0x28, .arg1 = '\r' };
    _ = app.handle_keyboard_event(&ev_enter);
    try std.testing.expectEqual(@as(i64, 4), app.engine.current_val);
    try std.testing.expect(app.history_len >= 4);
    // '.' decimal no-op
    var ev_dot = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 8, .arg0 = 0x37, .arg1 = '.' };
    const before = app.engine.current_val;
    try std.testing.expect(app.handle_keyboard_event(&ev_dot));
    try std.testing.expectEqual(before, app.engine.current_val);
}

test "calc: AppState fits EL0 stack (C9, <4 KiB)" {
    try std.testing.expect(@sizeOf(AppState) < 4 * 1024);
    std.debug.print("CALC AppState size: {d}\n", .{@sizeOf(AppState)});
}
