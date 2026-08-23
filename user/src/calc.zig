//! DipshitOS CALC.BIN — Milestone 11 Card A2 + M15 C9 + M24 K1–K5.
//!
//! Interactive graphical calculator with checked 64-bit integer engine,
//! scrollable history, clickable button grid, and keyboard input.
//!
//! M24 additions:
//!   K1 — Programmer mode (Ctrl+P): hex/oct/dec display, AND/OR/XOR/NOT/SHL/SHR
//!   K2 — 4-slot memory (M0–M3): Ctrl+1/2/3/4 selects slot
//!   K3 — Unit conversion (Ctrl+U): temp/length/weight categories
//!   K4 — Mathematical constants: π, e, √2, φ buttons
//!   K5 — History persistence: save/load from FAT
//!   K7 — Trigonometry: SIN/COS/TAN/ASIN/ACOS/ATAN, DEG/RAD toggle
//!   K6 — Scientific notation display: SCI toggle, auto-switch at 1e10
//!   K8 — Log/exp: LN/LOG/EXP/POW/SQRT/ABS buttons
//!   K9 — Expression editor: EXPR toggle, type full expressions, click
//!        history rows to edit
//!   K10 — Clipboard: Ctrl+C result, Ctrl+Shift+C "expr = result", Ctrl+V paste
//!
//! Keyboard shortcuts:
//!   Digits 0–9          → input_digit
//!   Operators + - * / % → set_op
//!   Enter / '='         → evaluate (repeat-last-op on bare =)
//!   Backspace           → backspace
//!   Esc / C             → clear all
//!   Up / Down           → cycle history
//!   M                   → memory recall (active slot)
//!   Ctrl+P              → toggle programmer mode
//!   Ctrl+U              → toggle unit conversion bar
//!   Ctrl+1/2/3/4        → select memory slot

const std = @import("std");
const ui = @import("lib/ui.zig");
const Rect = ui.Rect;
const Button = ui.Button;
const Event = ui.Event;

const engine = @import("calc/engine.zig");
const CalcEngine = engine.CalcEngine;
const format_i64 = engine.format_i64;
const format_sci = engine.format_sci;
const sci_auto = engine.sci_auto;

const history_mod = @import("calc/history.zig");
const HistoryRing = history_mod.Ring;
const history_max = history_mod.max_entries;
const history_visible = history_mod.visible_count;

const prog = @import("calc/programmer.zig");
const ProgrammerState = prog.ProgrammerState;
const Base = prog.Base;

const constants = @import("calc/constants.zig");

const expr_mod = @import("calc/expr.zig");
const mathfn = @import("calc/mathfn.zig");
const science = @import("calc/science.zig");

// ---------------------------------------------------------------------------
// Window constants
// ---------------------------------------------------------------------------

pub const window_id: u32 = 2;

/// K10: parse a leading (optionally signed) integer out of pasted text.
/// Tolerates trailing junk; requires at least one digit. Overflow → null
/// rather than a silent wrap.
pub fn parse_pasted_number(text: []const u8) ?i64 {
    var i: usize = 0;
    var neg = false;
    if (i < text.len and (text[i] == '-' or text[i] == '+')) {
        neg = text[i] == '-';
        i += 1;
    }
    var v: i64 = 0;
    var n: usize = 0;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (n += 1) {
        v = std.math.mul(i64, v, 10) catch return null;
        v = std.math.add(i64, v, text[i] - '0') catch return null;
        i += 1;
    }
    if (n == 0) return null;
    return if (neg) -v else v;
}
pub const window_x: u32 = 48;
pub const window_y: u32 = 48;
pub const window_w: u32 = 512;
pub const window_h: u32 = 424;

pub const exit_status: u32 = 42;

// Layout rects — standard mode
const history_area = Rect.make(8, 8, 496, 60);
const display_rect = Rect.make(8, 72, 496, 28);

// Layout rects — programmer mode (triple display)
const hex_display_rect = Rect.make(8, 72, 496, 18);
const dec_display_rect = Rect.make(8, 92, 496, 18);
const oct_display_rect = Rect.make(8, 112, 496, 18);
const reg_display_rect = Rect.make(8, 132, 496, 18);

// Layout rect — unit conversion bar (K3)
const convert_rect = Rect.make(8, 72, 496, 28);

// ---------------------------------------------------------------------------
// Unit conversion (K3)
// ---------------------------------------------------------------------------

const TempUnit = enum { c, f, k };
const LengthUnit = enum { m, ft, inch, cm, mm };
const WeightUnit = enum { kg, lb, g, oz };

const temp_names = [_][]const u8{ "C", "F", "K" };
const length_names = [_][]const u8{ "m", "ft", "in", "cm", "mm" };
const weight_names = [_][]const u8{ "kg", "lb", "g", "oz" };

/// Normalize a temperature to Celsius as the base unit.
fn temp_to_base(unit: TempUnit, val: f64) f64 {
    return switch (unit) {
        .c => val,
        .f => (val - 32.0) * 5.0 / 9.0,
        .k => val - 273.15,
    };
}

fn temp_from_base(unit: TempUnit, celsius: f64) f64 {
    return switch (unit) {
        .c => celsius,
        .f => celsius * 9.0 / 5.0 + 32.0,
        .k => celsius + 273.15,
    };
}

/// Normalize a length to meters.
fn length_to_base(unit: LengthUnit, val: f64) f64 {
    return switch (unit) {
        .m => val,
        .ft => val * 0.3048,
        .inch => val * 0.0254,
        .cm => val * 0.01,
        .mm => val * 0.001,
    };
}

fn length_from_base(unit: LengthUnit, meters: f64) f64 {
    return switch (unit) {
        .m => meters,
        .ft => meters / 0.3048,
        .inch => meters / 0.0254,
        .cm => meters * 100.0,
        .mm => meters * 1000.0,
    };
}

/// Normalize a weight to grams.
fn weight_to_base(unit: WeightUnit, val: f64) f64 {
    return switch (unit) {
        .g => val,
        .kg => val * 1000.0,
        .lb => val * 453.592,
        .oz => val * 28.3495,
    };
}

fn weight_from_base(unit: WeightUnit, grams: f64) f64 {
    return switch (unit) {
        .g => grams,
        .kg => grams / 1000.0,
        .lb => grams / 453.592,
        .oz => grams / 28.3495,
    };
}

// ---------------------------------------------------------------------------
// App State
// ---------------------------------------------------------------------------

pub const AppState = struct {
    engine: CalcEngine = .{},
    hist: HistoryRing = HistoryRing.init(),
    prog_mode: ProgrammerState = ProgrammerState.init(),

    // C9: history scroll state (separate from ring — tracks display position)
    history_cursor: ?usize = null,
    history_scroll: usize = 0,

    // K2: 4-slot memory
    mem_slots: [4]i64 = [_]i64{0} ** 4,
    mem_active_slot: usize = 0,
    mem_any_nonzero: bool = false,

    // K3: unit conversion
    convert_active: bool = false,
    convert_category: u2 = 0, // 0=temp, 1=length, 2=weight
    convert_from_idx: u3 = 0,
    convert_to_idx: u3 = 1,
    convert_value: f64 = 0.0,

    // K4: constant buttons only shown in standard mode

    // K7: trigonometry — DEG/RAD mode (default RAD) + function buttons
    deg_mode: bool = false,
    // K6: scientific notation display
    sci_mode: bool = false,

    // K9: expression editor
    expr_mode: bool = false,
    expr_buf: [48]u8 = [_]u8{0} ** 48,
    expr_len: usize = 0,

    // ---- Standard mode buttons ----
    btn_m_store: Button = Button.init(Rect.make(8, 104, 56, 20), "MS"),
    btn_m_recall: Button = Button.init(Rect.make(69, 104, 56, 20), "MR"),
    btn_m_clear: Button = Button.init(Rect.make(130, 104, 56, 20), "MC"),
    btn_prog: Button = Button.init(Rect.make(191, 104, 56, 20), "PROG"),

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
    btn_ce: Button = Button.init(Rect.make(130, 234, 56, 20), "CE"),
    btn_eq: Button = Button.init(Rect.make(191, 234, 56, 20), "="),

    // ---- Programmer mode buttons (K1) ----
    btn_st: Button = Button.init(Rect.make(8, 104, 56, 20), "ST"),
    btn_clr_mem: Button = Button.init(Rect.make(130, 104, 56, 20), "CLR"),

    btn_not: Button = Button.init(Rect.make(8, 130, 56, 20), "NOT"),
    btn_shl: Button = Button.init(Rect.make(69, 130, 56, 20), "SHL"),
    btn_shr: Button = Button.init(Rect.make(130, 130, 56, 20), "SHR"),

    btn_and: Button = Button.init(Rect.make(8, 156, 56, 20), "AND"),
    btn_or: Button = Button.init(Rect.make(69, 156, 56, 20), "OR"),
    btn_xor: Button = Button.init(Rect.make(130, 156, 56, 20), "XOR"),

    btn_hex: Button = Button.init(Rect.make(8, 182, 56, 20), "HEX"),
    btn_dec: Button = Button.init(Rect.make(69, 182, 56, 20), "DEC"),
    btn_oct: Button = Button.init(Rect.make(130, 182, 56, 20), "OCT"),

    // ---- K4 constant buttons (standard mode only) ----
    btn_pi: Button = Button.init(Rect.make(260, 104, 56, 20), "PI"),
    btn_euler: Button = Button.init(Rect.make(321, 104, 56, 20), "e"),
    btn_sqrt2: Button = Button.init(Rect.make(382, 104, 56, 20), "sqrt2"),
    btn_phi: Button = Button.init(Rect.make(443, 104, 56, 20), "phi"),

    // ---- K7 trig buttons (standard mode, below keypad) ----
    btn_sin: Button = Button.init(Rect.make(8, 286, 56, 20), "SIN"),
    btn_cos: Button = Button.init(Rect.make(69, 286, 56, 20), "COS"),
    btn_tan: Button = Button.init(Rect.make(130, 286, 56, 20), "TAN"),
    btn_deg_rad: Button = Button.init(Rect.make(191, 286, 56, 20), "RAD"),
    btn_asin: Button = Button.init(Rect.make(8, 312, 56, 20), "ASIN"),
    btn_acos: Button = Button.init(Rect.make(69, 312, 56, 20), "ACOS"),
    btn_atan: Button = Button.init(Rect.make(130, 312, 56, 20), "ATAN"),

    // ---- K8 log/exp buttons (standard mode, below the trig rows) ----
    btn_ln: Button = Button.init(Rect.make(8, 338, 56, 20), "LN"),
    btn_log: Button = Button.init(Rect.make(69, 338, 56, 20), "LOG"),
    btn_exp: Button = Button.init(Rect.make(130, 338, 56, 20), "EXP"),
    btn_pow: Button = Button.init(Rect.make(191, 338, 56, 20), "POW"),
    btn_sqrt: Button = Button.init(Rect.make(8, 364, 56, 20), "SQRT"),
    btn_abs: Button = Button.init(Rect.make(69, 364, 56, 20), "ABS"),
    // ---- K6 scientific notation toggle (standard mode, below keypad) ----
    btn_sci: Button = Button.init(Rect.make(8, 260, 56, 20), "SCI"),

    // ---- K9 expression editor toggle (standard mode, next to SCI) ----
    btn_expr: Button = Button.init(Rect.make(69, 260, 56, 20), "EXPR"),

    pub fn init() AppState {
        var s = AppState{};
        s.btn_eq.bg_color = ui.COLOR_ACCENT;
        s.btn_c.bg_color = ui.COLOR_DANGER;
        // Load history from FAT (K5)
        s.hist.load_from_fat();
        if (s.hist.len > history_visible) {
            s.history_scroll = s.hist.len - history_visible;
        }
        return s;
    }

    // -------------------------------------------------------------------
    // Memory (K2)
    // -------------------------------------------------------------------

    fn mem_store_active(self: *AppState) void {
        self.mem_slots[self.mem_active_slot] = self.engine.current_val;
        self.update_mem_flag();
    }

    fn mem_recall_active(self: *AppState) void {
        if (self.engine.has_error) return;
        self.engine.current_val = self.mem_slots[self.mem_active_slot];
        self.engine.is_entering_val = true;
    }

    fn mem_clear_active(self: *AppState) void {
        self.mem_slots[self.mem_active_slot] = 0;
        self.update_mem_flag();
    }

    fn mem_clear_all(self: *AppState) void {
        self.mem_slots = [_]i64{0} ** 4;
        self.mem_any_nonzero = false;
    }

    fn mem_add_active(self: *AppState) void {
        if (self.engine.has_error) return;
        self.mem_slots[self.mem_active_slot] = std.math.add(
            i64,
            self.mem_slots[self.mem_active_slot],
            self.engine.current_val,
        ) catch {
            // Overflow doesn't affect the engine — just ignore
            return;
        };
        self.engine.is_entering_val = false;
        self.update_mem_flag();
    }

    fn mem_sub_active(self: *AppState) void {
        if (self.engine.has_error) return;
        self.mem_slots[self.mem_active_slot] = std.math.sub(
            i64,
            self.mem_slots[self.mem_active_slot],
            self.engine.current_val,
        ) catch return;
        self.engine.is_entering_val = false;
        self.update_mem_flag();
    }

    fn update_mem_flag(self: *AppState) void {
        self.mem_any_nonzero = false;
        for (self.mem_slots) |v| {
            if (v != 0) {
                self.mem_any_nonzero = true;
                break;
            }
        }
    }

    // -------------------------------------------------------------------
    // Clipboard (K10)
    // -------------------------------------------------------------------

    /// Copy the current result to the shared clipboard; with_expr copies
    /// the newest history entry as "<expr> = <result>".
    fn copy_to_clipboard(self: *const AppState, with_expr: bool) void {
        var buf: [96]u8 = undefined;
        _ = ui.clipboard_set(self.clipboard_payload(with_expr, &buf));
    }

    fn clipboard_payload(self: *const AppState, with_expr: bool, buf: []u8) []const u8 {
        var pos: usize = 0;
        if (with_expr and self.hist.len > 0) {
            const e = self.hist.get(self.hist.len - 1);
            const c = @min(e.len, buf.len);
            @memcpy(buf[0..c], e.text[0..c]);
            pos += c;
            if (pos + 3 <= buf.len) {
                @memcpy(buf[pos .. pos + 3], " = ");
                pos += 3;
            }
        }
        var tmp: [24]u8 = undefined;
        const s = format_i64(self.engine.current_val, &tmp);
        const c2 = @min(s.len, buf.len - pos);
        @memcpy(buf[pos .. pos + c2], s[0..c2]);
        pos += c2;
        return buf[0..pos];
    }

    /// Paste a number from the shared clipboard into the display.
    fn paste_from_clipboard(self: *AppState) void {
        var buf: [64]u8 = undefined;
        const n = ui.clipboard_get(&buf);
        if (n <= 0) return;
        const len: usize = @min(@as(usize, @intCast(n)), buf.len);
        if (parse_pasted_number(buf[0..len])) |v| {
            self.engine.current_val = v;
            self.engine.is_entering_val = true;
            self.engine.has_error = false;
            self.history_cursor = null;
            ui.write_console("calc: clip-paste\n");
        }
    }

    // -------------------------------------------------------------------
    // History helpers
    // -------------------------------------------------------------------

    pub fn get_history_entry(self: *const AppState, logical: usize) *const history_mod.Entry {
        return self.hist.get(logical);
    }

    fn push_history(self: *AppState, expr: []const u8, result: i64) void {
        self.hist.push(expr, result);
        if (self.hist.len > history_visible) {
            self.history_scroll = self.hist.len - history_visible;
        } else {
            self.history_scroll = 0;
        }
        self.history_cursor = null;
        // K5: persist to FAT after each new entry
        self.hist.save_to_fat();
    }

    fn record_history_from_engine(self: *AppState, pending: ?u8, a: i64, b: i64) void {
        var expr_buf: [32]u8 = undefined;
        var pos: usize = 0;
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
        self.push_history(expr_buf[0..pos], self.engine.current_val);
    }

    pub fn history_up(self: *AppState) void {
        if (self.hist.len == 0) return;
        if (self.history_cursor) |c| {
            if (c > 0) {
                self.history_cursor = c - 1;
                if (self.history_cursor.? < self.history_scroll) self.history_scroll = self.history_cursor.?;
                const e = self.hist.get(self.history_cursor.?);
                self.engine.current_val = e.result;
                self.engine.is_entering_val = false;
                self.engine.has_error = false;
            }
        } else {
            const idx = self.hist.len - 1;
            self.history_cursor = idx;
            if (idx >= self.history_scroll + history_visible) self.history_scroll = idx - history_visible + 1;
            const e = self.hist.get(idx);
            self.engine.current_val = e.result;
            self.engine.is_entering_val = false;
            self.engine.has_error = false;
        }
    }

    pub fn history_down(self: *AppState) void {
        if (self.history_cursor) |c| {
            if (c + 1 < self.hist.len) {
                self.history_cursor = c + 1;
                if (self.history_cursor.? >= self.history_scroll + history_visible)
                    self.history_scroll = self.history_cursor.? - history_visible + 1;
                const e = self.hist.get(self.history_cursor.?);
                self.engine.current_val = e.result;
                self.engine.is_entering_val = false;
                self.engine.has_error = false;
            } else {
                self.history_cursor = null;
            }
        }
    }

    // -------------------------------------------------------------------
    // Evaluate + record (shared between mouse and keyboard)
    // -------------------------------------------------------------------

    fn do_evaluate(self: *AppState) void {
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
                self.push_history(s, cur);
            }
        }
        self.history_cursor = null;
    }

    // -------------------------------------------------------------------
    // Unit conversion (K3)
    // -------------------------------------------------------------------

    fn convert_result(self: *const AppState) f64 {
        const from_idx: usize = self.convert_from_idx;
        const to_idx: usize = self.convert_to_idx;
        const val = self.convert_value;
        const cat: usize = self.convert_category;

        if (cat == 0) {
            // Temperature
            if (from_idx == to_idx) return val;
            const from_unit: TempUnit = @enumFromInt(from_idx);
            const to_unit: TempUnit = @enumFromInt(to_idx);
            const base = temp_to_base(from_unit, val);
            return temp_from_base(to_unit, base);
        } else if (cat == 1) {
            // Length
            if (from_idx == to_idx) return val;
            const from_unit: LengthUnit = @enumFromInt(from_idx);
            const to_unit: LengthUnit = @enumFromInt(to_idx);
            const base = length_to_base(from_unit, val);
            return length_from_base(to_unit, base);
        } else {
            // Weight
            if (from_idx == to_idx) return val;
            const from_unit: WeightUnit = @enumFromInt(from_idx);
            const to_unit: WeightUnit = @enumFromInt(to_idx);
            const base = weight_to_base(from_unit, val);
            return weight_from_base(to_unit, base);
        }
    }

    fn unit_names_for_category(cat: usize) []const []const u8 {
        return switch (cat) {
            0 => &temp_names,
            1 => &length_names,
            2 => &weight_names,
            else => &temp_names,
        };
    }

    /// Update convert_value from the engine's current value (called when
    /// the user is in conversion mode and types a number).
    fn sync_convert_value(self: *AppState) void {
        self.convert_value = @floatFromInt(self.engine.current_val);
    }

    // -------------------------------------------------------------------
    // Logarithmic & exponential (K8)
    // -------------------------------------------------------------------

    /// Store a float function result, rounded to the engine's i64.
    fn store_unary_result(self: *AppState, result: mathfn.MathError!f64) void {
        if (result) |r| {
            const rounded = @round(r);
            if (!std.math.isFinite(rounded) or @abs(rounded) > 9.2e18) {
                self.engine.raise_error();
                return;
            }
            self.engine.current_val = @intFromFloat(rounded);
            self.engine.is_entering_val = true;
        } else |_| {
            self.engine.raise_error();
        }
    }

    // -------------------------------------------------------------------
    // Trigonometry (K7)
    // -------------------------------------------------------------------

    fn store_float_result(self: *AppState, r: f64) void {
        const rounded = @round(r);
        if (!std.math.isFinite(rounded) or @abs(rounded) > 9.2e18) {
            self.engine.raise_error();
            return;
        }
        self.engine.current_val = @intFromFloat(rounded);
        self.engine.is_entering_val = true;
    }

    /// Current value as an angle, converted to radians in DEG mode.
    fn angle_in(self: *const AppState) f64 {
        const v: f64 = @floatFromInt(self.engine.current_val);
        return if (self.deg_mode) v * science.pi / 180.0 else v;
    }

    fn apply_trig_result(self: *AppState, result: science.ScienceError!f64) void {
        if (result) |r| {
            self.store_float_result(r);
        } else |_| {
            self.engine.raise_error();
        }
    }

    /// Inverse functions produce angles — convert back to degrees in DEG mode.
    fn apply_inv_angle(self: *AppState, result: science.ScienceError!f64) void {
        if (result) |r| {
            const out = if (self.deg_mode) r * 180.0 / science.pi else r;
            self.store_float_result(out);
        } else |_| {
            self.engine.raise_error();
        }
    }

    // -------------------------------------------------------------------
    // Display text (K6: SCI toggle + auto-switch at |v| >= 1e10)
    // -------------------------------------------------------------------

    fn display_text(self: *const AppState, buf: []u8) []const u8 {
        // K9: while editing an expression, the raw text is the display.
        if (self.expr_mode and self.expr_len > 0) {
            const c = @min(self.expr_len, buf.len);
            @memcpy(buf[0..c], self.expr_buf[0..c]);
            return buf[0..c];
        }
        if (self.engine.has_error) return self.engine.format_display(buf);
        const v = self.engine.current_val;
        if (self.sci_mode or sci_auto(v)) {
            return format_sci(@floatFromInt(v), buf);
        }
        return self.engine.format_display(buf);
    }

    // -------------------------------------------------------------------
    // Expression editor (K9)
    // -------------------------------------------------------------------

    fn expr_append(self: *AppState, ch: u8) void {
        if (self.expr_len >= self.expr_buf.len) return;
        if (!expr_mod.is_expr_char(ch)) return;
        self.expr_buf[self.expr_len] = ch;
        self.expr_len += 1;
    }

    fn expr_backspace(self: *AppState) void {
        if (self.expr_len > 0) self.expr_len -= 1;
    }

    fn expr_reset_input(self: *AppState) void {
        self.expr_len = 0;
    }

    fn expr_exit(self: *AppState) void {
        self.expr_mode = false;
        self.expr_reset_input();
    }

    /// Evaluate the edited expression; on success record "expr=result" in
    /// history exactly like a button-flow calculation.
    fn expr_evaluate(self: *AppState) void {
        if (self.expr_len == 0) return;
        const result = expr_mod.evaluate(self.expr_buf[0..self.expr_len]) catch {
            self.engine.raise_error();
            ui.write_console("calc: expr-error\n");
            return;
        };
        self.engine.current_val = result;
        self.engine.is_entering_val = false;
        self.engine.has_error = false;
        self.push_history(self.expr_buf[0..self.expr_len], result);
        self.expr_reset_input();
        ui.write_console("calc: expr-ok\n");
    }

    /// Load a history entry's expression back into the editor (K9:
    /// click a history entry to edit it).
    fn expr_load_from_history(self: *AppState, logical_idx: usize) void {
        if (logical_idx >= self.hist.len) return;
        const e = self.hist.get(logical_idx);
        const n = @min(e.len, self.expr_buf.len);
        @memcpy(self.expr_buf[0..n], e.text[0..n]);
        self.expr_len = n;
        self.expr_mode = true;
        self.history_cursor = null;
        ui.write_console("calc: expr-edit\n");
    }

    /// Row index under a history-area click, or null.
    fn history_row_at(y: u32) ?usize {
        if (y < history_area.y + 4) return null;
        const rel = y - (history_area.y + 4);
        const row = rel / 10;
        if (row >= history_visible) return null;
        return row;
    }

    // -------------------------------------------------------------------
    // Draw
    // -------------------------------------------------------------------

    pub fn draw(self: *const AppState, win: u32) void {
        ui.draw_rect(win, Rect.make(0, 0, window_w, window_h), ui.COLOR_BG);

        if (self.prog_mode.active) {
            self.draw_programmer(win);
        } else {
            self.draw_standard(win);
        }
    }

    fn draw_standard(self: *const AppState, win: u32) void {
        // History area
        ui.draw_rect(win, history_area, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, history_area, 1, ui.COLOR_BORDER);
        var h_row: usize = 0;
        var h_idx = self.history_scroll;
        while (h_idx < self.hist.len and h_row < history_visible) : (h_idx += 1) {
            const entry = self.hist.get(h_idx);
            var buf: [40]u8 = undefined;
            const txt = HistoryRing.format_entry(entry, &buf);
            const y = history_area.y + 4 + @as(u32, @intCast(h_row)) * 10;
            const is_cursor = if (self.history_cursor) |c| c == h_idx else false;
            const col = if (is_cursor) ui.COLOR_ACCENT else ui.COLOR_TEXT_MUTED;
            const cap = @min(txt.len, 60);
            ui.draw_text(win, txt[0..cap], history_area.x + 4, y, col);
            h_row += 1;
        }
        if (self.hist.len > history_visible) {
            if (self.history_scroll > 0)
                ui.draw_text(win, "^", history_area.x + history_area.w - 10, history_area.y + 4, ui.COLOR_TEXT_MUTED);
            if (self.history_scroll + history_visible < self.hist.len)
                ui.draw_text(win, "v", history_area.x + history_area.w - 10, history_area.y + history_area.h - 10, ui.COLOR_TEXT_MUTED);
        }

        // Display box
        ui.draw_rect(win, display_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, display_rect, 1, ui.COLOR_BORDER);
        var disp_buf: [32]u8 = undefined;
        const disp_text = self.display_text(&disp_buf);
        const text_w = @as(u32, @intCast(disp_text.len)) * 8;
        const text_x = if (display_rect.w > text_w + 16) display_rect.x + display_rect.w - text_w - 8 else display_rect.x + 16;
        const text_y = display_rect.y + (display_rect.h - 8) / 2;
        ui.draw_text(win, disp_text, text_x, text_y, ui.COLOR_TEXT_PRIMARY);

        // Memory indicator (K2)
        self.draw_mem_indicator(win, display_rect.x + 4, text_y);

        // Buttons — standard mode
        self.btn_m_store.draw(win);
        self.btn_m_recall.draw(win);
        self.btn_m_clear.draw(win);
        self.btn_prog.draw(win);

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
        self.btn_ce.draw(win);
        self.btn_eq.draw(win);

        // K4 constant buttons (standard mode only)
        self.btn_pi.draw(win);
        self.btn_euler.draw(win);
        self.btn_sqrt2.draw(win);
        self.btn_phi.draw(win);

        // K7 trig buttons (standard mode)
        self.btn_sin.draw(win);
        self.btn_cos.draw(win);
        self.btn_tan.draw(win);
        self.btn_deg_rad.draw(win);
        self.btn_asin.draw(win);
        self.btn_acos.draw(win);
        self.btn_atan.draw(win);

        // K6 scientific-notation toggle
        self.btn_sci.draw(win);

        // K9 expression editor toggle
        self.btn_expr.draw(win);

        // K8 log/exp buttons (standard mode)
        self.btn_ln.draw(win);
        self.btn_log.draw(win);
        self.btn_exp.draw(win);
        self.btn_pow.draw(win);
        self.btn_sqrt.draw(win);
        self.btn_abs.draw(win);

        // K3 conversion bar (when active, overlays the history area)
        if (self.convert_active) {
            self.draw_convert_bar(win);
        }
    }

    fn draw_programmer(self: *const AppState, win: u32) void {
        // Triple-line display (hex / dec / oct) — replaces history + single display
        ui.draw_rect(win, hex_display_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, hex_display_rect, 1, ui.COLOR_BORDER);
        ui.draw_rect(win, dec_display_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, dec_display_rect, 1, ui.COLOR_BORDER);
        ui.draw_rect(win, oct_display_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, oct_display_rect, 1, ui.COLOR_BORDER);
        ui.draw_rect(win, reg_display_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, reg_display_rect, 1, ui.COLOR_BORDER);

        const val = self.engine.current_val;

        // Hex
        var hex_buf: [24]u8 = undefined;
        const hex_str = prog.format_hex(val, &hex_buf);
        var hex_label: [20]u8 = undefined;
        var hpos: usize = 0;
        const prefix = "0x";
        @memcpy(hex_label[hpos .. hpos + prefix.len], prefix);
        hpos += prefix.len;
        const hc = @min(hex_str.len, hex_label.len - hpos);
        @memcpy(hex_label[hpos .. hpos + hc], hex_str[0..hc]);
        hpos += hc;
        ui.draw_text(win, hex_label[0..hpos], hex_display_rect.x + 4, hex_display_rect.y + 5, ui.COLOR_TEXT_PRIMARY);

        // Dec
        var dec_buf: [24]u8 = undefined;
        const dec_str = prog.format_dec(val, &dec_buf);
        ui.draw_text(win, dec_str, dec_display_rect.x + 4, dec_display_rect.y + 5, ui.COLOR_TEXT_PRIMARY);

        // Oct
        var oct_buf: [24]u8 = undefined;
        const oct_str = prog.format_oct(val, &oct_buf);
        var oct_label: [20]u8 = undefined;
        var opos: usize = 0;
        const oct_prefix = "0o";
        @memcpy(oct_label[opos .. opos + oct_prefix.len], oct_prefix);
        opos += oct_prefix.len;
        const oc = @min(oct_str.len, oct_label.len - opos);
        @memcpy(oct_label[opos .. opos + oc], oct_str[0..oc]);
        opos += oc;
        ui.draw_text(win, oct_label[0..opos], oct_display_rect.x + 4, oct_display_rect.y + 5, ui.COLOR_TEXT_MUTED);

        // Register display (R0–R7)
        var reg_buf: [32]u8 = undefined;
        var rpos: usize = 0;
        const ri: usize = self.prog_mode.active_reg;
        const rlabel = "R";
        @memcpy(reg_buf[rpos .. rpos + rlabel.len], rlabel);
        rpos += rlabel.len;
        reg_buf[rpos] = @as(u8, @intCast(ri)) + '0';
        rpos += 1;
        reg_buf[rpos] = ':';
        rpos += 1;
        reg_buf[rpos] = ' ';
        rpos += 1;
        const rval = self.prog_mode.registers[ri];
        var rval_buf: [20]u8 = undefined;
        const rval_str = prog.format_hex(rval, &rval_buf);
        const rvc = @min(rval_str.len, reg_buf.len - rpos - 4);
        @memcpy(reg_buf[rpos .. rpos + 2], "0x");
        rpos += 2;
        @memcpy(reg_buf[rpos .. rpos + rvc], rval_str[0..rvc]);
        rpos += rvc;
        ui.draw_text(win, reg_buf[0..rpos], reg_display_rect.x + 4, reg_display_rect.y + 5, ui.COLOR_TEXT_MUTED);

        // Memory indicator (K2)
        // Small indicator at right of reg display
        if (self.mem_any_nonzero) {
            ui.draw_text(win, "M", reg_display_rect.x + reg_display_rect.w - 12, reg_display_rect.y + 5, ui.COLOR_TEXT_MUTED);
        }

        // Buttons — programmer mode
        self.btn_st.draw(win);
        self.btn_m_recall.draw(win);
        self.btn_clr_mem.draw(win);
        self.btn_prog.draw(win);

        self.btn_not.draw(win);
        self.btn_shl.draw(win);
        self.btn_shr.draw(win);
        self.btn_div.draw(win);

        self.btn_and.draw(win);
        self.btn_or.draw(win);
        self.btn_xor.draw(win);
        self.btn_mul.draw(win);

        self.btn_hex.draw(win);
        self.btn_dec.draw(win);
        self.btn_oct.draw(win);
        self.btn_sub.draw(win);

        // Digits + eq (same grid positions as standard mode, shifted up)
        self.btn_7.draw(win);
        self.btn_8.draw(win);
        self.btn_9.draw(win);
        self.btn_add.draw(win);

        self.btn_4.draw(win);
        self.btn_5.draw(win);
        self.btn_6.draw(win);
        self.btn_c.draw(win);

        self.btn_1.draw(win);
        self.btn_2.draw(win);
        self.btn_3.draw(win);
        self.btn_eq.draw(win);

        self.btn_0.draw(win);
        self.btn_ce.draw(win);
        self.btn_sign.draw(win); // reuse +/- as NOT shortcut label
    }

    fn draw_mem_indicator(self: *const AppState, win: u32, x: u32, y: u32) void {
        // Show "M0" through "M3" if the active slot has content
        if (self.mem_any_nonzero) {
            var label: [4]u8 = undefined;
            label[0] = 'M';
            label[1] = @as(u8, @intCast(self.mem_active_slot)) + '0';
            const slot_val = self.mem_slots[self.mem_active_slot];
            if (slot_val != 0) {
                ui.draw_text(win, label[0..2], x, y, ui.COLOR_TEXT_MUTED);
            } else {
                // Show just the slot number even if empty, dimmer
                ui.draw_text(win, label[0..2], x, y, ui.COLOR_BG);
            }
        }
    }

    fn draw_convert_bar(self: *const AppState, win: u32) void {
        // Conversion bar overlays the history area when active
        ui.draw_rect(win, history_area, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, history_area, 1, ui.COLOR_ACCENT);

        // Category buttons
        const cats = [_][]const u8{ "Temp", "Length", "Weight" };
        var cat_x: u32 = history_area.x + 4;
        for (cats, 0..) |cat_name, ci| {
            const is_active = ci == self.convert_category;
            const col = if (is_active) ui.COLOR_ACCENT else ui.COLOR_TEXT_MUTED;
            ui.draw_text(win, cat_name, cat_x, history_area.y + 4, col);
            cat_x += @as(u32, @intCast(cat_name.len)) * 8 + 12;
        }

        // From/To unit labels
        const names = unit_names_for_category(@as(usize, self.convert_category));
        const from_name = if (self.convert_from_idx < names.len) names[self.convert_from_idx] else "?";
        const to_name = if (self.convert_to_idx < names.len) names[self.convert_to_idx] else "?";

        var label_buf: [32]u8 = undefined;
        var lpos: usize = 0;
        @memcpy(label_buf[lpos .. lpos + 4], "From");
        lpos += 4;
        label_buf[lpos] = ' ';
        lpos += 1;
        @memcpy(label_buf[lpos .. lpos + from_name.len], from_name);
        lpos += from_name.len;
        @memcpy(label_buf[lpos .. lpos + 4], "  To");
        lpos += 4;
        label_buf[lpos] = ' ';
        lpos += 1;
        @memcpy(label_buf[lpos .. lpos + to_name.len], to_name);
        lpos += to_name.len;
        ui.draw_text(win, label_buf[0..lpos], history_area.x + 4, history_area.y + 16, ui.COLOR_TEXT_PRIMARY);

        // Conversion result
        var res_buf: [24]u8 = undefined;
        const result = self.convert_result();
        // Format the f64 result as a simple decimal string
        const result_int: i64 = @intFromFloat(result);
        const result_str = format_i64(result_int, &res_buf);
        var full_buf: [32]u8 = undefined;
        var fpos: usize = 0;
        const eq_sign = "= ";
        @memcpy(full_buf[fpos .. fpos + eq_sign.len], eq_sign);
        fpos += eq_sign.len;
        const rc = @min(result_str.len, full_buf.len - fpos);
        @memcpy(full_buf[fpos .. fpos + rc], result_str[0..rc]);
        fpos += rc;
        ui.draw_text(win, full_buf[0..fpos], history_area.x + 4, history_area.y + 28, ui.COLOR_ACCENT);
    }

    // -------------------------------------------------------------------
    // Mouse events
    // -------------------------------------------------------------------

    pub fn handle_mouse_events(self: *AppState, ev: *const Event) bool {
        var changed = false;

        if (self.prog_mode.active) {
            changed = self.handle_mouse_programmer(ev) or changed;
        } else {
            changed = self.handle_mouse_standard(ev) or changed;
        }

        return changed;
    }

    fn handle_mouse_standard(self: *AppState, ev: *const Event) bool {
        var changed = false;

        // K2: memory buttons
        if (self.btn_m_store.handle_event(ev)) {
            self.mem_store_active();
            changed = true;
        } else if (self.btn_m_recall.handle_event(ev)) {
            self.mem_recall_active();
            changed = true;
        } else if (self.btn_m_clear.handle_event(ev)) {
            self.mem_clear_all();
            changed = true;
        } else if (self.btn_prog.handle_event(ev)) {
            self.prog_mode.toggle();
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
            self.history_cursor = null;
            changed = true;
        } else if (self.btn_8.handle_event(ev)) {
            self.engine.input_digit(8);
            self.history_cursor = null;
            changed = true;
        } else if (self.btn_9.handle_event(ev)) {
            self.engine.input_digit(9);
            self.history_cursor = null;
            changed = true;
        } else if (self.btn_mul.handle_event(ev)) {
            self.engine.set_op('*');
            changed = true;
        } else if (self.btn_4.handle_event(ev)) {
            self.engine.input_digit(4);
            self.history_cursor = null;
            changed = true;
        } else if (self.btn_5.handle_event(ev)) {
            self.engine.input_digit(5);
            self.history_cursor = null;
            changed = true;
        } else if (self.btn_6.handle_event(ev)) {
            self.engine.input_digit(6);
            self.history_cursor = null;
            changed = true;
        } else if (self.btn_sub.handle_event(ev)) {
            self.engine.set_op('-');
            changed = true;
        } else if (self.btn_1.handle_event(ev)) {
            self.engine.input_digit(1);
            self.history_cursor = null;
            changed = true;
        } else if (self.btn_2.handle_event(ev)) {
            self.engine.input_digit(2);
            self.history_cursor = null;
            changed = true;
        } else if (self.btn_3.handle_event(ev)) {
            self.engine.input_digit(3);
            self.history_cursor = null;
            changed = true;
        } else if (self.btn_add.handle_event(ev)) {
            self.engine.set_op('+');
            changed = true;
        } else if (self.btn_0.handle_event(ev)) {
            self.engine.input_digit(0);
            self.history_cursor = null;
            changed = true;
        } else if (self.btn_ce.handle_event(ev)) {
            self.engine.current_val = 0;
            self.engine.is_entering_val = false;
            changed = true;
        } else if (self.btn_eq.handle_event(ev)) {
            self.do_evaluate();
            changed = true;
        }

        // K4 constant buttons (standard mode only)
        if (!changed) {
            if (self.btn_pi.handle_event(ev)) {
                self.engine.current_val = constants.table[0].value;
                self.engine.is_entering_val = true;
                self.engine.has_error = false;
                self.history_cursor = null;
                changed = true;
            } else if (self.btn_euler.handle_event(ev)) {
                self.engine.current_val = constants.table[1].value;
                self.engine.is_entering_val = true;
                self.engine.has_error = false;
                self.history_cursor = null;
                changed = true;
            } else if (self.btn_sqrt2.handle_event(ev)) {
                self.engine.current_val = constants.table[2].value;
                self.engine.is_entering_val = true;
                self.engine.has_error = false;
                self.history_cursor = null;
                changed = true;
            } else if (self.btn_phi.handle_event(ev)) {
                self.engine.current_val = constants.table[3].value;
                self.engine.is_entering_val = true;
                self.engine.has_error = false;
                self.history_cursor = null;
                changed = true;
            }
        }

        // K7 trig buttons (standard mode)
        if (!changed) {
            if (self.btn_sin.handle_event(ev)) {
                self.apply_trig_result(science.sin(self.angle_in()));
                changed = true;
            } else if (self.btn_cos.handle_event(ev)) {
                self.apply_trig_result(science.cos(self.angle_in()));
                changed = true;
            } else if (self.btn_tan.handle_event(ev)) {
                self.apply_trig_result(science.tan(self.angle_in()));
                changed = true;
            } else if (self.btn_deg_rad.handle_event(ev)) {
                self.deg_mode = !self.deg_mode;
                self.btn_deg_rad.label = if (self.deg_mode) "DEG" else "RAD";
                ui.write_console(if (self.deg_mode) "calc: deg-mode\n" else "calc: rad-mode\n");
                changed = true;
            } else if (self.btn_asin.handle_event(ev)) {
                self.apply_inv_angle(science.asin(@floatFromInt(self.engine.current_val)));
                changed = true;
            } else if (self.btn_acos.handle_event(ev)) {
                self.apply_inv_angle(science.acos(@floatFromInt(self.engine.current_val)));
                changed = true;
            } else if (self.btn_atan.handle_event(ev)) {
                self.apply_inv_angle(science.atan(@floatFromInt(self.engine.current_val)));
                changed = true;
            }
        }

        // K6 scientific-notation toggle
        if (!changed) {
            if (self.btn_sci.handle_event(ev)) {
                self.sci_mode = !self.sci_mode;
                if (self.sci_mode) {
                    ui.write_console("calc: sci-on\n");
                } else {
                    ui.write_console("calc: sci-off\n");
                }
                changed = true;
            }
        }

        // K9 expression editor toggle
        if (!changed) {
            if (self.btn_expr.handle_event(ev)) {
                self.expr_mode = !self.expr_mode;
                self.expr_reset_input();
                ui.write_console(if (self.expr_mode) "calc: expr-on\n" else "calc: expr-off\n");
                changed = true;
            }
        }

        // K8 log/exp buttons
        if (!changed) {
            const v: f64 = @floatFromInt(self.engine.current_val);
            if (self.btn_ln.handle_event(ev)) {
                self.store_unary_result(mathfn.ln(v));
                changed = true;
            } else if (self.btn_log.handle_event(ev)) {
                self.store_unary_result(mathfn.log10(v));
                changed = true;
            } else if (self.btn_exp.handle_event(ev)) {
                self.store_unary_result(mathfn.exp(v));
                changed = true;
            } else if (self.btn_pow.handle_event(ev)) {
                self.engine.set_op('P');
                changed = true;
            } else if (self.btn_sqrt.handle_event(ev)) {
                self.store_unary_result(mathfn.sqrt(v));
                changed = true;
            } else if (self.btn_abs.handle_event(ev)) {
                self.store_unary_result(@abs(v));
                changed = true;
            }
        }

        // K9: click a history row to edit that entry's expression
        if (!changed and (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP)) {
            const x = ev.arg0;
            const y = ev.arg1;
            const inside_x = x >= history_area.x and x < history_area.x + history_area.w;
            const inside_y = y >= history_area.y and y < history_area.y + history_area.h;
            if (inside_x and inside_y) {
                if (history_row_at(y)) |row| {
                    const logical = self.history_scroll + row;
                    if (logical < self.hist.len) {
                        self.expr_load_from_history(logical);
                        changed = true;
                    }
                }
            }
        }

        return changed;
    }

    fn handle_mouse_programmer(self: *AppState, ev: *const Event) bool {
        var changed = false;

        // K2: programmer memory buttons
        if (self.btn_st.handle_event(ev)) {
            self.prog_mode.store_reg(self.engine.current_val);
            changed = true;
        } else if (self.btn_m_recall.handle_event(ev)) {
            if (!self.engine.has_error) {
                self.engine.current_val = self.prog_mode.recall_reg();
                self.engine.is_entering_val = true;
                changed = true;
            }
        } else if (self.btn_clr_mem.handle_event(ev)) {
            self.prog_mode.registers = [_]i64{0} ** prog.num_registers;
            changed = true;
        } else if (self.btn_prog.handle_event(ev)) {
            self.prog_mode.toggle();
            changed = true;
        } else if (self.btn_not.handle_event(ev)) {
            self.engine.bitwise_not();
            changed = true;
        } else if (self.btn_shl.handle_event(ev)) {
            self.engine.set_op('L');
            changed = true;
        } else if (self.btn_shr.handle_event(ev)) {
            self.engine.set_op('R');
            changed = true;
        } else if (self.btn_div.handle_event(ev)) {
            self.engine.set_op('/');
            changed = true;
        } else if (self.btn_and.handle_event(ev)) {
            self.engine.set_op('A');
            changed = true;
        } else if (self.btn_or.handle_event(ev)) {
            self.engine.set_op('O');
            changed = true;
        } else if (self.btn_xor.handle_event(ev)) {
            self.engine.set_op('X');
            changed = true;
        } else if (self.btn_mul.handle_event(ev)) {
            self.engine.set_op('*');
            changed = true;
        } else if (self.btn_hex.handle_event(ev)) {
            self.prog_mode.set_base(.hex);
            changed = true;
        } else if (self.btn_dec.handle_event(ev)) {
            self.prog_mode.set_base(.dec);
            changed = true;
        } else if (self.btn_oct.handle_event(ev)) {
            self.prog_mode.set_base(.oct);
            changed = true;
        } else if (self.btn_sub.handle_event(ev)) {
            self.engine.set_op('-');
            changed = true;
        }

        // Shared buttons (same grid positions in programmer mode)
        if (!changed) {
            if (self.btn_7.handle_event(ev)) {
                self.engine.input_digit(7);
                self.history_cursor = null;
                changed = true;
            } else if (self.btn_8.handle_event(ev)) {
                self.engine.input_digit(8);
                self.history_cursor = null;
                changed = true;
            } else if (self.btn_9.handle_event(ev)) {
                self.engine.input_digit(9);
                self.history_cursor = null;
                changed = true;
            } else if (self.btn_add.handle_event(ev)) {
                self.engine.set_op('+');
                changed = true;
            } else if (self.btn_4.handle_event(ev)) {
                self.engine.input_digit(4);
                self.history_cursor = null;
                changed = true;
            } else if (self.btn_5.handle_event(ev)) {
                self.engine.input_digit(5);
                self.history_cursor = null;
                changed = true;
            } else if (self.btn_6.handle_event(ev)) {
                self.engine.input_digit(6);
                self.history_cursor = null;
                changed = true;
            } else if (self.btn_c.handle_event(ev)) {
                self.engine.clear();
                changed = true;
            } else if (self.btn_1.handle_event(ev)) {
                self.engine.input_digit(1);
                self.history_cursor = null;
                changed = true;
            } else if (self.btn_2.handle_event(ev)) {
                self.engine.input_digit(2);
                self.history_cursor = null;
                changed = true;
            } else if (self.btn_3.handle_event(ev)) {
                self.engine.input_digit(3);
                self.history_cursor = null;
                changed = true;
            } else if (self.btn_eq.handle_event(ev)) {
                self.do_evaluate();
                changed = true;
            } else if (self.btn_0.handle_event(ev)) {
                self.engine.input_digit(0);
                self.history_cursor = null;
                changed = true;
            } else if (self.btn_ce.handle_event(ev)) {
                self.engine.current_val = 0;
                self.engine.is_entering_val = false;
                changed = true;
            } else if (self.btn_sign.handle_event(ev)) {
                // In programmer mode, +/- still toggles sign
                self.engine.toggle_sign();
                changed = true;
            }
        }

        return changed;
    }

    // -------------------------------------------------------------------
    // Keyboard events
    // -------------------------------------------------------------------

    pub fn handle_keyboard_event(self: *AppState, ev: *const Event) bool {
        if (ev.kind != ui.KEY_DOWN) return false;
        const keycode = ev.arg0;
        const ascii = @as(u8, @truncate(ev.arg1));
        const ctrl = (ev.flags & 0x04) != 0; // Ctrl flag (bit 2)

        // Ctrl+P: toggle programmer mode
        if (ctrl and (ascii == 'p' or ascii == 'P')) {
            self.prog_mode.toggle();
            if (self.prog_mode.active) {
                ui.write_console("calc: prog-on\n");
            } else {
                ui.write_console("calc: prog-off\n");
            }
            return true;
        }

        // K10: Ctrl+C copies the result; Ctrl+Shift+C copies "expr = result"
        if (ctrl and (ascii == 'c' or ascii == 'C')) {
            const shift = (ev.flags & ui.MOD_SHIFT) != 0;
            self.copy_to_clipboard(shift);
            ui.write_console(if (shift) "calc: clip-copy-expr\n" else "calc: clip-copy\n");
            return true;
        }

        // K10: Ctrl+V pastes a number from the shared clipboard
        if (ctrl and (ascii == 'v' or ascii == 'V')) {
            self.paste_from_clipboard();
            return true;
        }

        // Ctrl+U: toggle unit conversion (K3)
        if (ctrl and (ascii == 'u' or ascii == 'U')) {
            self.convert_active = !self.convert_active;
            if (self.convert_active) {
                self.sync_convert_value();
                ui.write_console("calc: conv-on\n");
            } else {
                ui.write_console("calc: conv-off\n");
            }
            return true;
        }

        // Ctrl+1/2/3/4: select memory slot (K2)
        if (ctrl and ascii >= '1' and ascii <= '4') {
            self.mem_active_slot = ascii - '1';
            ui.write_console("calc: mem-slot\n");
            return true;
        }

        // K9: while the expression editor is active it consumes keys
        if (self.expr_mode) {
            if (ascii == 0x08 or keycode == 0x2a) {
                self.expr_backspace();
                return true;
            }
            if (ascii == 0x1b or keycode == 0x29) {
                self.expr_exit();
                ui.write_console("calc: expr-off\n");
                return true;
            }
            if (keycode == 0x28 or ascii == '=' or ascii == '\r' or ascii == '\n') {
                self.expr_evaluate();
                return true;
            }
            if (!ctrl and expr_mod.is_expr_char(ascii)) {
                self.expr_append(ascii);
                return true;
            }
            return true; // swallow unhandled keys while editing
        }

        // If in programmer mode, handle hex input (0-9, a-f)
        if (self.prog_mode.active and self.prog_mode.base == .hex) {
            if (ascii >= 'a' and ascii <= 'f') {
                const digit_val: i64 = 10 + (ascii - 'a');
                self.input_hex_digit(digit_val);
                self.history_cursor = null;
                return true;
            }
            if (ascii >= 'A' and ascii <= 'F') {
                const digit_val: i64 = 10 + (ascii - 'A');
                self.input_hex_digit(digit_val);
                self.history_cursor = null;
                return true;
            }
        }

        // Digits 0-9
        if (ascii >= '0' and ascii <= '9') {
            self.engine.input_digit(ascii - '0');
            self.history_cursor = null;
            if (self.convert_active) self.sync_convert_value();
            return true;
        }

        // Decimal '.' — integer calc no-op
        if (ascii == '.') return true;

        // Operators
        if (ascii == '+' or ascii == '-' or ascii == '*' or ascii == '/' or ascii == '%') {
            self.engine.set_op(ascii);
            self.history_cursor = null;
            return true;
        }

        // Bitwise operators (programmer mode)
        if (self.prog_mode.active) {
            if (ascii == '&' or ascii == 'A') {
                self.engine.set_op('A');
                self.history_cursor = null;
                return true;
            }
            if (ascii == '|' or ascii == 'O') {
                self.engine.set_op('O');
                self.history_cursor = null;
                return true;
            }
            if (ascii == '^' or ascii == 'X') {
                self.engine.set_op('X');
                self.history_cursor = null;
                return true;
            }
            if (ascii == '~') {
                self.engine.bitwise_not();
                self.history_cursor = null;
                return true;
            }
            if (ascii == '<') {
                self.engine.set_op('L');
                self.history_cursor = null;
                return true;
            }
            if (ascii == '>') {
                self.engine.set_op('R');
                self.history_cursor = null;
                return true;
            }
        }

        // Enter / '='
        if (keycode == 0x28 or ascii == '=' or ascii == '\r' or ascii == '\n') {
            self.do_evaluate();
            return true;
        }

        // Backspace
        if (ascii == 0x08 or keycode == 0x2a) {
            self.engine.backspace();
            self.history_cursor = null;
            return true;
        }

        // Esc: clear all
        if (ascii == 0x1b or keycode == 0x29) {
            self.engine.clear();
            self.history_cursor = null;
            return true;
        }

        // Up/Down history
        if (keycode == 0x52) {
            self.history_up();
            return true;
        }
        if (keycode == 0x51) {
            self.history_down();
            return true;
        }

        // c/C: clear
        if (ascii == 'c' or ascii == 'C') {
            if (!ctrl) {
                self.engine.clear();
                self.history_cursor = null;
            }
            return true;
        }

        // m/M: memory recall (active slot)
        if (ascii == 'm' or ascii == 'M') {
            if (!ctrl) {
                self.mem_recall_active();
            }
            return true;
        }

        // s/S: memory store (active slot) (K2 keyboard shortcut)
        if (ascii == 's' or ascii == 'S') {
            if (!ctrl) {
                self.mem_store_active();
            }
            return true;
        }

        return false;
    }

    /// Input a hex digit value (0–15) in programmer hex mode.
    fn input_hex_digit(self: *AppState, val: i64) void {
        if (self.engine.has_error) return;
        if (!self.engine.is_entering_val) {
            self.engine.current_val = val;
            self.engine.is_entering_val = true;
        } else {
            const grown = std.math.mul(i64, self.engine.current_val, 16) catch return;
            self.engine.current_val = std.math.add(i64, grown, val) catch return;
        }
    }
};

// ---------------------------------------------------------------------------
// Entry Point (EL0)
// ---------------------------------------------------------------------------

pub export fn _start() callconv(.c) noreturn {
    var app = AppState.init();

    const win_res = ui.win_open(window_x, window_y, window_w, window_h);
    if (win_res < 0) {
        ui.write_console("calc: failed to open window\n");
        ui.exit_process(1);
    }
    const win = @as(u32, @intCast(win_res));

    ui.write_console("calc: open id=2\n");

    app.draw(win);
    ui.win_present(win);
    ui.write_console("calc: ready\n");

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
// Unit Tests
// ---------------------------------------------------------------------------

test "calc: AppState fits EL0 stack (<8 KiB)" {
    try std.testing.expect(@sizeOf(AppState) < 8 * 1024);
    std.debug.print("CALC AppState size: {d}\n", .{@sizeOf(AppState)});
}

test "calc: programmer mode toggle" {
    var app = AppState.init();
    try std.testing.expect(!app.prog_mode.active);

    var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0x04, .seq = 1, .arg0 = 0x13, .arg1 = 'p' }; // Ctrl+P
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expect(app.prog_mode.active);

    ev.flags = 0x04;
    ev.arg1 = 'p';
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expect(!app.prog_mode.active);
}

test "calc: K2 memory 4-slot store/recall" {
    var app = AppState.init();

    // Store 42 in slot 0
    app.engine.current_val = 42;
    app.engine.is_entering_val = true;
    app.mem_store_active();
    try std.testing.expectEqual(@as(i64, 42), app.mem_slots[0]);
    try std.testing.expect(app.mem_any_nonzero);

    // Switch to slot 1, store 99
    app.mem_active_slot = 1;
    app.engine.current_val = 99;
    app.mem_store_active();
    try std.testing.expectEqual(@as(i64, 99), app.mem_slots[1]);

    // Recall slot 0
    app.mem_active_slot = 0;
    app.mem_recall_active();
    try std.testing.expectEqual(@as(i64, 42), app.engine.current_val);
    try std.testing.expect(app.engine.is_entering_val);

    // Clear all
    app.mem_clear_all();
    try std.testing.expect(!app.mem_any_nonzero);
    try std.testing.expectEqual(@as(i64, 0), app.mem_slots[0]);
    try std.testing.expectEqual(@as(i64, 0), app.mem_slots[1]);
}

test "calc: K2 Ctrl+1/2/3/4 slot selection" {
    var app = AppState.init();
    var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0x04, .seq = 1, .arg0 = 0x1e, .arg1 = '2' }; // Ctrl+2
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expectEqual(@as(usize, 1), app.mem_active_slot);

    ev.arg1 = '4';
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expectEqual(@as(usize, 3), app.mem_active_slot);
}

test "calc: K4 constant button inserts value" {
    var app = AppState.init();
    // Simulate clicking PI button (MOUSE_DOWN then MOUSE_UP)
    var ev_down = Event{ .kind = ui.MOUSE_DOWN, .flags = 0, .seq = 1, .arg0 = 288, .arg1 = 114 };
    _ = app.handle_mouse_events(&ev_down);
    var ev_up = Event{ .kind = ui.MOUSE_UP, .flags = 0, .seq = 2, .arg0 = 288, .arg1 = 114 };
    _ = app.handle_mouse_events(&ev_up);
    try std.testing.expectEqual(@as(i64, 3), app.engine.current_val);
    try std.testing.expect(app.engine.is_entering_val);
}

test "calc: K4 constant keyboard shortcut (not mapped, button only)" {
    // Constants are button-only in standard mode — keyboard doesn't
    // insert constants (the user uses the button grid).
    var app = AppState.init();
    const before = app.engine.current_val;
    var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x06, .arg1 = '5' };
    _ = app.handle_keyboard_event(&ev);
    try std.testing.expectEqual(@as(i64, 5), app.engine.current_val);
    _ = before;
}

fn click_button(app: *AppState, x: u32, y: u32) void {
    var ev_down = Event{ .kind = ui.MOUSE_DOWN, .flags = 0, .seq = 1, .arg0 = x, .arg1 = y };
    _ = app.handle_mouse_events(&ev_down);
    var ev_up = Event{ .kind = ui.MOUSE_UP, .flags = 0, .seq = 2, .arg0 = x, .arg1 = y };
    _ = app.handle_mouse_events(&ev_up);
}

test "calc K7: sin(90deg) = 1 via buttons" {
    var app = AppState.init();
    // Type 90 (digits 9, 0)
    var ev9 = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x09, .arg1 = '9' };
    _ = app.handle_keyboard_event(&ev9);
    var ev0 = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0, .arg1 = '0' };
    _ = app.handle_keyboard_event(&ev0);
    try std.testing.expectEqual(@as(i64, 90), app.engine.current_val);

    // Switch to DEG mode (button at 191,286 center → 219,296)
    click_button(&app, 219, 296);
    try std.testing.expect(app.deg_mode);

    // SIN button at (8,286) center → 36,296
    click_button(&app, 36, 296);
    try std.testing.expectEqual(@as(i64, 1), app.engine.current_val);
}

test "calc K7: cos(0) = 1 in default RAD mode" {
    var app = AppState.init();
    try std.testing.expect(!app.deg_mode); // RAD is the default
    // COS button at (69,286) center → 97,296; current value is 0
    click_button(&app, 97, 296);
    try std.testing.expectEqual(@as(i64, 1), app.engine.current_val);
}

test "calc K7: inverse functions round-trip in DEG mode" {
    var app = AppState.init();
    // DEG on, asin(1) → 90
    click_button(&app, 219, 296); // DEG/RAD toggle
    app.engine.current_val = 1;
    app.engine.is_entering_val = true;
    click_button(&app, 36, 322); // ASIN at (8,312) center → 36,322
    try std.testing.expectEqual(@as(i64, 90), app.engine.current_val);

    // acos(1) → 0
    app.engine.current_val = 1;
    click_button(&app, 97, 322); // ACOS at (69,312) center → 97,322
    try std.testing.expectEqual(@as(i64, 0), app.engine.current_val);

    // atan(1) → 45 in DEG
    app.engine.current_val = 1;
    click_button(&app, 158, 322); // ATAN at (130,312) center → 158,322
    try std.testing.expectEqual(@as(i64, 45), app.engine.current_val);
}

test "calc K7: tan(90deg) and asin(2) raise ERROR" {
    var app = AppState.init();
    click_button(&app, 219, 296); // DEG mode
    app.engine.current_val = 90;
    app.engine.is_entering_val = true;
    click_button(&app, 158, 296); // TAN at (130,286)
    try std.testing.expect(app.engine.has_error);

    app.engine.clear();
    app.engine.current_val = 2;
    app.engine.is_entering_val = true;
    click_button(&app, 36, 322); // ASIN out of domain
    try std.testing.expect(app.engine.has_error);
}

test "calc: K3 unit conversion toggle" {
    var app = AppState.init();
    try std.testing.expect(!app.convert_active);

    var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0x04, .seq = 1, .arg0 = 0x18, .arg1 = 'u' }; // Ctrl+U
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expect(app.convert_active);

    ev.flags = 0x04;
    ev.arg1 = 'u';
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expect(!app.convert_active);
}

test "calc: K3 temperature conversion (C→F = 100→212)" {
    var app = AppState.init();
    app.convert_active = true;
    app.convert_category = 0; // temp
    app.convert_from_idx = 0; // C
    app.convert_to_idx = 1; // F
    app.convert_value = 100.0;
    const result = app.convert_result();
    // 100°C = 212°F (within floating point tolerance)
    try std.testing.expect(result > 211.0 and result < 213.0);
}

test "calc: K3 length conversion (m→ft)" {
    var app = AppState.init();
    app.convert_active = true;
    app.convert_category = 1; // length
    app.convert_from_idx = 0; // m
    app.convert_to_idx = 1; // ft
    app.convert_value = 1.0;
    const result = app.convert_result();
    // 1m = 3.28084ft
    try std.testing.expect(result > 3.27 and result < 3.29);
}

test "calc: K3 weight conversion (kg→lb)" {
    var app = AppState.init();
    app.convert_active = true;
    app.convert_category = 2; // weight
    app.convert_from_idx = 0; // kg
    app.convert_to_idx = 1; // lb
    app.convert_value = 1.0;
    const result = app.convert_result();
    // 1kg = 2.20462lb
    try std.testing.expect(result > 2.20 and result < 2.21);
}

test "calc K6: format_sci large integer (123456789012345 → 1.23456e+14)" {
    var buf: [32]u8 = undefined;
    const s = format_sci(123456789012345.0, &buf);
    try std.testing.expectEqualStrings("1.23456e+14", s);
}

test "calc K6: format_sci small value (0.000001234 → 1.234e-6)" {
    var buf: [32]u8 = undefined;
    const s = format_sci(0.000001234, &buf);
    try std.testing.expectEqualStrings("1.234e-6", s);
}

test "calc K6: format_sci zero, negative, exact power, trailing-zero strip" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", format_sci(0.0, &buf));
    try std.testing.expectEqualStrings("-5.2e+4", format_sci(-52000.0, &buf));
    try std.testing.expectEqualStrings("1e+10", format_sci(1e10, &buf));
    try std.testing.expectEqualStrings("1.23e+4", format_sci(12300.0, &buf));
    try std.testing.expectEqualStrings("5.67e-8", format_sci(5.67e-8, &buf));
}

test "calc K6: auto-switch at |v| >= 1e10" {
    try std.testing.expect(sci_auto(12_345_678_901));
    try std.testing.expect(!sci_auto(9_999_999_999));
    try std.testing.expect(!sci_auto(0));
    try std.testing.expect(sci_auto(-20_000_000_000));

    // Display path: big value renders scientific even with sci_mode off.
    var app = AppState.init();
    app.engine.current_val = 123456789012345;
    var buf: [32]u8 = undefined;
    const s = app.display_text(&buf);
    try std.testing.expectEqualStrings("1.23456e+14", s);

    // Small values keep plain formatting when SCI is off.
    app.engine.current_val = 42;
    try std.testing.expectEqualStrings("42", app.display_text(&buf));
}

test "calc K6: SCI button toggles mode" {
    var app = AppState.init();
    try std.testing.expect(!app.sci_mode);
    // SCI button rect: (8, 260, 56, 20) → click center (36, 270)
    var ev_down = Event{ .kind = ui.MOUSE_DOWN, .flags = 0, .seq = 1, .arg0 = 36, .arg1 = 270 };
    _ = app.handle_mouse_events(&ev_down);
    var ev_up = Event{ .kind = ui.MOUSE_UP, .flags = 0, .seq = 2, .arg0 = 36, .arg1 = 270 };
    _ = app.handle_mouse_events(&ev_up);
    try std.testing.expect(app.sci_mode);

    // With SCI on, even a small value displays scientific.
    app.engine.current_val = 7;
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("7e+0", app.display_text(&buf));

    // Second click toggles back off.
    _ = app.handle_mouse_events(&ev_down);
    _ = app.handle_mouse_events(&ev_up);
    try std.testing.expect(!app.sci_mode);
    try std.testing.expectEqualStrings("7", app.display_text(&buf));
}

fn tap_key(app: *AppState, ascii: u8, ctrl: bool) bool {
    var ev = Event{ .kind = ui.KEY_DOWN, .flags = if (ctrl) 0x04 else 0, .seq = 1, .arg0 = 0, .arg1 = ascii };
    return app.handle_keyboard_event(&ev);
}

test "calc K9: EXPR toggle button" {
    var app = AppState.init();
    try std.testing.expect(!app.expr_mode);
    tap(&app, 97, 270); // EXPR at (69,260) center
    try std.testing.expect(app.expr_mode);
    tap(&app, 97, 270);
    try std.testing.expect(!app.expr_mode);
}

test "calc K9: type 2+3*4 and Enter yields 14" {
    var app = AppState.init();
    tap(&app, 97, 270); // EXPR on
    for ("2+3*4") |ch| _ = tap_key(&app, ch, false);
    try std.testing.expectEqualStrings("2+3*4", app.expr_buf[0..app.expr_len]);
    // Display shows the raw expression while editing
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2+3*4", app.display_text(&buf));
    _ = tap_key(&app, '\r', false); // Enter evaluates
    try std.testing.expectEqual(@as(i64, 14), app.engine.current_val);
    try std.testing.expectEqual(@as(usize, 0), app.expr_len);
    // Expression (not just result) is in history
    const e = app.hist.get(app.hist.len - 1);
    try std.testing.expectEqualStrings("2+3*4", e.text[0..e.len]);
    try std.testing.expectEqual(@as(i64, 14), e.result);
}

test "calc K9: parens precedence (2+3)*4 = 20" {
    var app = AppState.init();
    tap(&app, 97, 270);
    for ("(2+3)*4=") |ch| _ = tap_key(&app, ch, false);
    try std.testing.expectEqual(@as(i64, 20), app.engine.current_val);
}

test "calc K9: backspace edits the expression" {
    var app = AppState.init();
    tap(&app, 97, 270);
    for ("12+3") |ch| _ = tap_key(&app, ch, false);
    _ = tap_key(&app, 0x08, false); // Backspace removes '3'
    try std.testing.expectEqualStrings("12+", app.expr_buf[0..app.expr_len]);
    _ = tap_key(&app, '5', false);
    _ = tap_key(&app, '\r', false);
    try std.testing.expectEqual(@as(i64, 17), app.engine.current_val);
}

test "calc K9: click a history row to edit its expression" {
    var app = AppState.init();
    tap(&app, 97, 270);
    for ("2+3*4") |ch| _ = tap_key(&app, ch, false);
    _ = tap_key(&app, '\r', false);

    // Exit editor mode, then click the newest history row (bottom row of
    // the history area: y = 8+4+5*10 = 62; x anywhere in the area)
    tap(&app, 97, 270);
    var ev_up = Event{ .kind = ui.MOUSE_UP, .flags = 0, .seq = 9, .arg0 = 200, .arg1 = 15 };
    _ = app.handle_mouse_events(&ev_up);
    try std.testing.expect(app.expr_mode);
    try std.testing.expectEqualStrings("2+3*4", app.expr_buf[0..app.expr_len]);

    // Edit it to 2+3*5 and re-evaluate
    _ = tap_key(&app, 0x08, false);
    _ = tap_key(&app, '5', false);
    _ = tap_key(&app, '\r', false);
    try std.testing.expectEqual(@as(i64, 17), app.engine.current_val);
}

test "calc K9: syntax error raises ERROR state" {
    var app = AppState.init();
    tap(&app, 97, 270);
    for ("2+") |ch| _ = tap_key(&app, ch, false);
    _ = tap_key(&app, '\r', false);
    try std.testing.expect(app.engine.has_error);
    // Editor keeps the broken expression visible for fixing (serial
    // marker calc: expr-error records the failure).
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2+", app.display_text(&buf));
    // Fix it and re-evaluate
    _ = tap_key(&app, '3', false);
    _ = tap_key(&app, '\r', false);
    try std.testing.expect(!app.engine.has_error);
    try std.testing.expectEqual(@as(i64, 5), app.engine.current_val);
}

test "calc K10: payload is the result as text" {
    var app = AppState.init();
    app.engine.current_val = 42;
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("42", app.clipboard_payload(false, &buf));
    app.engine.current_val = -7;
    try std.testing.expectEqualStrings("-7", app.clipboard_payload(false, &buf));
}

test "calc K10: Shift payload is 'expr = result'" {
    var app = AppState.init();
    // Evaluate something so history has an entry
    app.engine.current_val = 14;
    var tmp_buf: [24]u8 = undefined;
    const s = format_i64(2, &tmp_buf);
    _ = s;
    app.push_history("2+3*4", 14);
    app.engine.current_val = 14;
    var buf: [96]u8 = undefined;
    const p = app.clipboard_payload(true, &buf);
    try std.testing.expectEqualStrings("2+3*4 = 14", p);
    // Without history, falls back to just the result
    var empty = AppState.init();
    empty.engine.current_val = 9;
    var buf2: [96]u8 = undefined;
    try std.testing.expectEqualStrings("9", empty.clipboard_payload(true, &buf2));
}

test "calc K10: parse_pasted_number" {
    try std.testing.expectEqual(@as(?i64, 42), parse_pasted_number("42"));
    try std.testing.expectEqual(@as(?i64, -7), parse_pasted_number("-7"));
    try std.testing.expectEqual(@as(?i64, 5), parse_pasted_number("+5"));
    try std.testing.expectEqual(@as(?i64, 12), parse_pasted_number("12\n"));
    try std.testing.expectEqual(@as(?i64, null), parse_pasted_number("abc"));
    try std.testing.expectEqual(@as(?i64, null), parse_pasted_number(""));
    try std.testing.expectEqual(@as(?i64, null), parse_pasted_number("-"));
    try std.testing.expectEqual(@as(?i64, null), parse_pasted_number("999999999999999999999999"));
}

test "calc K10: copy/paste chords are consumed" {
    var app = AppState.init();
    app.engine.current_val = 42;
    // Ctrl+C
    var evc = Event{ .kind = ui.KEY_DOWN, .flags = 0x04, .seq = 1, .arg0 = 0, .arg1 = 'c' };
    try std.testing.expect(app.handle_keyboard_event(&evc));
    // Ctrl+Shift+C
    var evcs = Event{ .kind = ui.KEY_DOWN, .flags = 0x04 | ui.MOD_SHIFT, .seq = 2, .arg0 = 0, .arg1 = 'C' };
    try std.testing.expect(app.handle_keyboard_event(&evcs));
    // Ctrl+V — host clipboard stub returns 0, paste is a no-op but consumed
    var evv = Event{ .kind = ui.KEY_DOWN, .flags = 0x04, .seq = 3, .arg0 = 0, .arg1 = 'v' };
    try std.testing.expect(app.handle_keyboard_event(&evv));
    // Plain c still clears (no clash)
    app.engine.current_val = 5;
    var evplain = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0, .arg1 = 'c' };
    _ = app.handle_keyboard_event(&evplain);
    try std.testing.expectEqual(@as(i64, 0), app.engine.current_val);
}

test "calc K8: sqrt(16) = 4 via button" {
    var app = AppState.init();
    app.engine.current_val = 16;
    app.engine.is_entering_val = true;
    tap(&app, 36, 374); // SQRT at (8,364) center
    try std.testing.expectEqual(@as(i64, 4), app.engine.current_val);
}

test "calc K8: log(100) = 2 via button" {
    var app = AppState.init();
    app.engine.current_val = 100;
    app.engine.is_entering_val = true;
    tap(&app, 97, 348); // LOG at (69,338) center
    try std.testing.expectEqual(@as(i64, 2), app.engine.current_val);
}

test "calc K8: ln rounds (ln(e)≈1, entered as 3)" {
    var app = AppState.init();
    app.engine.current_val = 3;
    app.engine.is_entering_val = true;
    tap(&app, 36, 348); // LN at (8,338) center; ln(3)=1.0986 → 1
    try std.testing.expectEqual(@as(i64, 1), app.engine.current_val);
}

test "calc K8: exp(1) ≈ e rounds to 3" {
    var app = AppState.init();
    app.engine.current_val = 1;
    app.engine.is_entering_val = true;
    tap(&app, 158, 348); // EXP at (130,338) center
    try std.testing.expectEqual(@as(i64, 3), app.engine.current_val);
}

test "calc K8: abs and domain errors" {
    var app = AppState.init();
    app.engine.current_val = -42;
    app.engine.is_entering_val = true;
    tap(&app, 97, 374); // ABS at (69,364) center
    try std.testing.expectEqual(@as(i64, 42), app.engine.current_val);

    app.engine.current_val = -5;
    tap(&app, 36, 348); // ln(-5) → ERROR
    try std.testing.expect(app.engine.has_error);
}

test "calc K8: POW evaluates exact integer power" {
    var app = AppState.init();
    // 2 POW 10 = : type 2, POW button, type 10, Enter
    var ev2 = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x03, .arg1 = '2' };
    _ = app.handle_keyboard_event(&ev2);
    tap(&app, 219, 348); // POW at (191,338) center
    var ev1 = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x02, .arg1 = '1' };
    _ = app.handle_keyboard_event(&ev1);
    var ev0 = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x0d, .arg1 = '0' };
    _ = app.handle_keyboard_event(&ev0);
    try std.testing.expect(!app.engine.has_error);
    var ev_eq = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0x28, .arg1 = '\r' };
    _ = app.handle_keyboard_event(&ev_eq);
    try std.testing.expectEqual(@as(i64, 1024), app.engine.current_val);

    // Overflow raises ERROR: 10 POW 19
    app.engine.clear();
    app.engine.accum = 10;
    app.engine.pending_op = 'P';
    app.engine.current_val = 19;
    app.engine.is_entering_val = true;
    app.engine.evaluate();
    try std.testing.expect(app.engine.has_error);
}

fn press_at(app: *AppState, x: u32, y: u32) void {
    var ev_down = Event{ .kind = ui.MOUSE_DOWN, .flags = 0, .seq = 1, .arg0 = x, .arg1 = y };
    _ = app.handle_mouse_events(&ev_down);
    var ev_up = Event{ .kind = ui.MOUSE_UP, .flags = 0, .seq = 2, .arg0 = x, .arg1 = y };
    _ = app.handle_mouse_events(&ev_up);
}

fn tap(app: *AppState, x: u32, y: u32) void {
    press_at(app, x, y);
}
