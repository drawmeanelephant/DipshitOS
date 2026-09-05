//! VirelaiOS CALC.BIN — Milestone 11 Card A2 + M15 C9 + M24 K1–K5.
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
const tabapp = @import("lib/tabapp.zig");
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

const dates = @import("calc/dates.zig");

const stats_mod = @import("calc/stats.zig");
const Stats = stats_mod.Stats;

const defs_mod = @import("calc/defs.zig");
const Defs = defs_mod.Defs;

/// K15: resolver bridge — expr.zig's float evaluator needs a plain fn
/// pointer; the single CALC instance publishes its table here.
var active_defs: ?*const Defs = null;

fn resolve_def(name: []const u8) ?f64 {
    if (active_defs) |d| return d.get(name);
    return null;
}
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

const pow10_tab = [_]u64{ 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000, 1000000000, 10000000000 };

/// K12: decimal rendering with a ',' every three integer digits.
pub fn format_thousands(val: i64, out: []u8) []const u8 {
    var plain: [24]u8 = undefined;
    const s = format_i64(val, &plain);
    if (s.len == 0) return s;
    const digits = if (s[0] == '-') s[1..] else s;
    const groups = (digits.len + 2) / 3;
    const need = s.len + groups - 1;
    if (need > out.len) return out[0..0];
    var pos: usize = 0;
    if (s[0] == '-') {
        out[pos] = '-';
        pos += 1;
    }
    for (digits, 0..) |d, idx| {
        if (idx > 0 and (digits.len - idx) % 3 == 0) {
            out[pos] = ',';
            pos += 1;
        }
        out[pos] = d;
        pos += 1;
    }
    return out[0..pos];
}

/// K12: fixed-point with exactly `places` fractional digits (half-away
/// rounding). The scaled magnitude is clamped so the display path stays
/// exact in f64; this formats float-valued results (unit conversion),
/// not the i64 engine's own values.
pub fn format_fixed(val: f64, places: u8, out: []u8) []const u8 {
    const p: u64 = pow10_tab[@min(places, 10)];
    var scaled_f = @abs(val) * @as(f64, @floatFromInt(p));
    if (scaled_f >= 9.2e18) scaled_f = 9.2e18; // clamp; display-only path
    const scaled: u64 = @intFromFloat(@round(scaled_f));
    const int_part: u64 = scaled / p;
    const frac: u64 = scaled % p;

    var int_buf: [24]u8 = undefined;
    const int_str = format_i64(@intCast(int_part), &int_buf);

    var pos: usize = 0;
    if (val < 0 and pos < out.len) {
        out[pos] = '-';
        pos += 1;
    }
    const ic = @min(int_str.len, out.len - pos);
    @memcpy(out[pos .. pos + ic], int_str[0..ic]);
    pos += ic;
    if (places > 0 and pos + 1 < out.len) {
        out[pos] = '.';
        pos += 1;
        var frac_digits: [10]u8 = undefined;
        var fi: usize = @min(places, 10);
        var fv = frac;
        while (fi > 0) {
            fi -= 1;
            frac_digits[fi] = @as(u8, @intCast(fv % 10)) + '0';
            fv /= 10;
        }
        const fc = @min(@as(usize, places), out.len - pos);
        @memcpy(out[pos .. pos + fc], frac_digits[0..fc]);
        pos += fc;
    }
    return out[0..pos];
}

pub const CalcConfig = struct {
    dec_places: u8 = 2,
    thousands_sep: bool = false,
    hex_leading_zeros: bool = false,
};

fn parse_cfg_int(text: []const u8) ?i64 {
    var v: i64 = 0;
    var n: usize = 0;
    for (text) |ch| {
        if (ch < '0' or ch > '9') break;
        v = std.math.mul(i64, v, 10) catch return null;
        v = std.math.add(i64, v, ch - '0') catch return null;
        n += 1;
    }
    if (n == 0) return null;
    return v;
}

/// K12: parse "dec=N\nsep=0|1\nhexlz=0|1\n" — tolerant of junk lines.
pub fn parse_config(text: []const u8) CalcConfig {
    var cfg = CalcConfig{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (std.mem.startsWith(u8, line, "dec=")) {
            if (parse_cfg_int(line[4..])) |v| {
                if (v >= 0 and v <= 10) cfg.dec_places = @intCast(v);
            }
        } else if (std.mem.startsWith(u8, line, "sep=")) {
            cfg.thousands_sep = line.len > 4 and line[4] == '1';
        } else if (std.mem.startsWith(u8, line, "hexlz=")) {
            cfg.hex_leading_zeros = line.len > 6 and line[6] == '1';
        }
    }
    return cfg;
}

/// K12: render the config into `buf` for /data/calc_cfg.txt.
pub fn write_config(cfg: CalcConfig, buf: []u8) []const u8 {
    const out = std.fmt.bufPrint(buf, "dec={d}\nsep={d}\nhexlz={d}\n", .{
        cfg.dec_places,
        @as(u8, if (cfg.thousands_sep) 1 else 0),
        @as(u8, if (cfg.hex_leading_zeros) 1 else 0),
    }) catch return buf[0..0];
    return out;
}
pub const window_x: u32 = 48;
pub const window_y: u32 = 48;
pub const window_w: u32 = 512;
pub const window_h: u32 = 424;

pub const exit_status: u32 = 42;

// M42 SX3: the NATIVE button rects (the 512x424 layout the fixed grid
// was designed at). `layout` scales copies of these into the current canvas;
// the field initializers reference them so the identity mapping is the
// shipped layout.
pub const native_btn_m_store = Rect.make(8, 104, 56, 20);
pub const native_btn_m_recall = Rect.make(69, 104, 56, 20);
pub const native_btn_m_clear = Rect.make(130, 104, 56, 20);
pub const native_btn_prog = Rect.make(191, 104, 56, 20);
pub const native_btn_c = Rect.make(8, 130, 56, 20);
pub const native_btn_sign = Rect.make(69, 130, 56, 20);
pub const native_btn_mod = Rect.make(130, 130, 56, 20);
pub const native_btn_div = Rect.make(191, 130, 56, 20);
pub const native_btn_7 = Rect.make(8, 156, 56, 20);
pub const native_btn_8 = Rect.make(69, 156, 56, 20);
pub const native_btn_9 = Rect.make(130, 156, 56, 20);
pub const native_btn_mul = Rect.make(191, 156, 56, 20);
pub const native_btn_4 = Rect.make(8, 182, 56, 20);
pub const native_btn_5 = Rect.make(69, 182, 56, 20);
pub const native_btn_6 = Rect.make(130, 182, 56, 20);
pub const native_btn_sub = Rect.make(191, 182, 56, 20);
pub const native_btn_1 = Rect.make(8, 208, 56, 20);
pub const native_btn_2 = Rect.make(69, 208, 56, 20);
pub const native_btn_3 = Rect.make(130, 208, 56, 20);
pub const native_btn_add = Rect.make(191, 208, 56, 20);
pub const native_btn_0 = Rect.make(8, 234, 117, 20);
pub const native_btn_ce = Rect.make(130, 234, 56, 20);
pub const native_btn_eq = Rect.make(191, 234, 56, 20);
pub const native_btn_st = Rect.make(8, 104, 56, 20);
pub const native_btn_clr_mem = Rect.make(130, 104, 56, 20);
pub const native_btn_not = Rect.make(8, 130, 56, 20);
pub const native_btn_shl = Rect.make(69, 130, 56, 20);
pub const native_btn_shr = Rect.make(130, 130, 56, 20);
pub const native_btn_and = Rect.make(8, 156, 56, 20);
pub const native_btn_or = Rect.make(69, 156, 56, 20);
pub const native_btn_xor = Rect.make(130, 156, 56, 20);
pub const native_btn_hex = Rect.make(8, 182, 56, 20);
pub const native_btn_dec = Rect.make(69, 182, 56, 20);
pub const native_btn_oct = Rect.make(130, 182, 56, 20);
pub const native_btn_pi = Rect.make(260, 104, 56, 20);
pub const native_btn_euler = Rect.make(321, 104, 56, 20);
pub const native_btn_sqrt2 = Rect.make(382, 104, 56, 20);
pub const native_btn_phi = Rect.make(443, 104, 56, 20);
pub const native_btn_sin = Rect.make(8, 286, 56, 20);
pub const native_btn_cos = Rect.make(69, 286, 56, 20);
pub const native_btn_tan = Rect.make(130, 286, 56, 20);
pub const native_btn_deg_rad = Rect.make(191, 286, 56, 20);
pub const native_btn_asin = Rect.make(8, 312, 56, 20);
pub const native_btn_acos = Rect.make(69, 312, 56, 20);
pub const native_btn_atan = Rect.make(130, 312, 56, 20);
pub const native_btn_ln = Rect.make(8, 338, 56, 20);
pub const native_btn_log = Rect.make(69, 338, 56, 20);
pub const native_btn_exp = Rect.make(130, 338, 56, 20);
pub const native_btn_pow = Rect.make(191, 338, 56, 20);
pub const native_btn_sqrt = Rect.make(8, 364, 56, 20);
pub const native_btn_abs = Rect.make(69, 364, 56, 20);
pub const native_btn_sci = Rect.make(8, 260, 56, 20);
pub const native_btn_expr = Rect.make(69, 260, 56, 20);
pub const native_btn_rand = Rect.make(130, 260, 56, 20);

// Layout rects — standard mode
pub const native_history_area = Rect.make(8, 8, 496, 60);
pub const native_display_rect = Rect.make(8, 72, 496, 28);

// Layout rects — programmer mode (triple display)
pub const native_hex_display_rect = Rect.make(8, 72, 496, 18);
pub const native_dec_display_rect = Rect.make(8, 92, 496, 18);
pub const native_oct_display_rect = Rect.make(8, 112, 496, 18);
pub const native_reg_display_rect = Rect.make(8, 132, 496, 18);

// Layout rect — unit conversion bar (K3)
pub const native_convert_rect = Rect.make(8, 72, 496, 28);

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

/// M42 SX3: the per-state copies of the layout rects (draw AND hit-testing
/// read these, so scaled geometry and scaled hit tests cannot drift).
pub const LayoutRects = struct {
    history_area: Rect,
    display_rect: Rect,
    hex_display_rect: Rect,
    dec_display_rect: Rect,
    oct_display_rect: Rect,
    reg_display_rect: Rect,
    convert_rect: Rect,
};

pub const AppState = struct {
    engine: CalcEngine = .{},
    hist: HistoryRing = HistoryRing.init(),
    prog_mode: ProgrammerState = ProgrammerState.init(),

    // C9: history scroll state (separate from ring — tracks display position)
    history_cursor: ?usize = null,
    history_scroll: usize = 0,

    // K2: 4-slot memory
    mem_slots: [4]i64 = [_]i64{0} ** 4,
    cursor_kind: ui.CursorKind = .arrow, // M37 DQ4: per-region cursor state
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

    // K12: formatting controls (persisted to /data/calc_cfg.txt)
    cfg_active: bool = false, // settings bar visible
    cfg_row: u2 = 0, // selected row while the settings bar is open
    dec_places: u8 = 2, // fractional digits shown for float-valued results (0–10)
    thousands_sep: bool = false, // 1234567 -> "1,234,567"
    hex_leading_zeros: bool = false, // 16-digit padded hex in programmer mode

    // K13: date/time arithmetic (Ctrl+D bar over the history area)
    date_active: bool = false,
    date_buf: [40]u8 = [_]u8{0} ** 40, // command line: "d1 - d2", "d + N", "now"
    date_len: usize = 0,
    date_result_len: usize = 0,
    date_result: [48]u8 = [_]u8{0} ** 48,

    // K14: random numbers — xorshift64* seeded from the generic timer
    rand_state: u64 = 0, // 0 = unseeded

    // K15: named definitions (persisted to /data/calc_defs.txt)
    defs: Defs = .{},
    float_display: ?f64 = null, // exact render of a float-valued expression

    // K16: statistics mode (Ctrl+S bar over the history area)
    stats_active: bool = false,
    stats_input: [120]u8 = [_]u8{0} ** 120, // comma-separated list text
    stats_len: usize = 0,
    stats_store: Stats = .{},
    stats_result_len: usize = 0,
    stats_result: [64]u8 = [_]u8{0} ** 64,

    // ---- Standard mode buttons ----
    btn_m_store: Button = Button.init(native_btn_m_store, "MS"),
    btn_m_recall: Button = Button.init(native_btn_m_recall, "MR"),
    btn_m_clear: Button = Button.init(native_btn_m_clear, "MC"),
    btn_prog: Button = Button.init(native_btn_prog, "PROG"),

    btn_c: Button = Button.init(native_btn_c, "C"),
    btn_sign: Button = Button.init(native_btn_sign, "+/-"),
    btn_mod: Button = Button.init(native_btn_mod, "%"),
    btn_div: Button = Button.init(native_btn_div, "/"),

    btn_7: Button = Button.init(native_btn_7, "7"),
    btn_8: Button = Button.init(native_btn_8, "8"),
    btn_9: Button = Button.init(native_btn_9, "9"),
    btn_mul: Button = Button.init(native_btn_mul, "*"),

    btn_4: Button = Button.init(native_btn_4, "4"),
    btn_5: Button = Button.init(native_btn_5, "5"),
    btn_6: Button = Button.init(native_btn_6, "6"),
    btn_sub: Button = Button.init(native_btn_sub, "-"),

    btn_1: Button = Button.init(native_btn_1, "1"),
    btn_2: Button = Button.init(native_btn_2, "2"),
    btn_3: Button = Button.init(native_btn_3, "3"),
    btn_add: Button = Button.init(native_btn_add, "+"),

    btn_0: Button = Button.init(native_btn_0, "0"),
    btn_ce: Button = Button.init(native_btn_ce, "CE"),
    btn_eq: Button = Button.init(native_btn_eq, "="),

    // ---- Programmer mode buttons (K1) ----
    btn_st: Button = Button.init(native_btn_st, "ST"),
    btn_clr_mem: Button = Button.init(native_btn_clr_mem, "CLR"),

    btn_not: Button = Button.init(native_btn_not, "NOT"),
    btn_shl: Button = Button.init(native_btn_shl, "SHL"),
    btn_shr: Button = Button.init(native_btn_shr, "SHR"),

    btn_and: Button = Button.init(native_btn_and, "AND"),
    btn_or: Button = Button.init(native_btn_or, "OR"),
    btn_xor: Button = Button.init(native_btn_xor, "XOR"),

    btn_hex: Button = Button.init(native_btn_hex, "HEX"),
    btn_dec: Button = Button.init(native_btn_dec, "DEC"),
    btn_oct: Button = Button.init(native_btn_oct, "OCT"),

    // ---- K4 constant buttons (standard mode only) ----
    btn_pi: Button = Button.init(native_btn_pi, "PI"),
    btn_euler: Button = Button.init(native_btn_euler, "e"),
    btn_sqrt2: Button = Button.init(native_btn_sqrt2, "sqrt2"),
    btn_phi: Button = Button.init(native_btn_phi, "phi"),

    // ---- K7 trig buttons (standard mode, below keypad) ----
    btn_sin: Button = Button.init(native_btn_sin, "SIN"),
    btn_cos: Button = Button.init(native_btn_cos, "COS"),
    btn_tan: Button = Button.init(native_btn_tan, "TAN"),
    btn_deg_rad: Button = Button.init(native_btn_deg_rad, "RAD"),
    btn_asin: Button = Button.init(native_btn_asin, "ASIN"),
    btn_acos: Button = Button.init(native_btn_acos, "ACOS"),
    btn_atan: Button = Button.init(native_btn_atan, "ATAN"),

    // ---- K8 log/exp buttons (standard mode, below the trig rows) ----
    btn_ln: Button = Button.init(native_btn_ln, "LN"),
    btn_log: Button = Button.init(native_btn_log, "LOG"),
    btn_exp: Button = Button.init(native_btn_exp, "EXP"),
    btn_pow: Button = Button.init(native_btn_pow, "POW"),
    btn_sqrt: Button = Button.init(native_btn_sqrt, "SQRT"),
    btn_abs: Button = Button.init(native_btn_abs, "ABS"),
    // ---- K6 scientific notation toggle (standard mode, below keypad) ----
    btn_sci: Button = Button.init(native_btn_sci, "SCI"),

    // ---- K9 expression editor toggle (standard mode, next to SCI) ----
    btn_expr: Button = Button.init(native_btn_expr, "EXPR"),

    // ---- K14 random button (standard mode, same row as SCI/EXPR) ----
    btn_rand: Button = Button.init(native_btn_rand, "RAND"),

    /// M42 SX3 (issue #984): the tab-aware canvas. The app opens at the
    /// native 512x424; when the tabbed WM activates its tab the kernel's
    /// WIN_RESIZE seam delivers the full 1100x720 content viewport and
    /// `layout` maps the fixed grid into it (proportional on both axes).
    /// Without a resize (shim/WND desktop) every rect maps to itself — the
    /// legacy rendering is the fixed point.
    canvas_w: u32 = window_w,
    canvas_h: u32 = window_h,
    rects: LayoutRects = .{ .history_area = native_history_area, .display_rect = native_display_rect, .hex_display_rect = native_hex_display_rect, .dec_display_rect = native_dec_display_rect, .oct_display_rect = native_oct_display_rect, .reg_display_rect = native_reg_display_rect, .convert_rect = native_convert_rect },

    pub fn layout(self: *AppState, w: u32, h: u32) void {
        self.canvas_w = w;
        self.canvas_h = h;
        // Area rects (proportional on both axes)
        self.rects.history_area = tabapp.scale(native_history_area, window_w, window_h, w, h);
        self.rects.display_rect = tabapp.scale(native_display_rect, window_w, window_h, w, h);
        self.rects.hex_display_rect = tabapp.scale(native_hex_display_rect, window_w, window_h, w, h);
        self.rects.dec_display_rect = tabapp.scale(native_dec_display_rect, window_w, window_h, w, h);
        self.rects.oct_display_rect = tabapp.scale(native_oct_display_rect, window_w, window_h, w, h);
        self.rects.reg_display_rect = tabapp.scale(native_reg_display_rect, window_w, window_h, w, h);
        self.rects.convert_rect = tabapp.scale(native_convert_rect, window_w, window_h, w, h);
        // Button grid
        self.btn_m_store.rect = tabapp.scale(native_btn_m_store, window_w, window_h, w, h);
        self.btn_m_recall.rect = tabapp.scale(native_btn_m_recall, window_w, window_h, w, h);
        self.btn_m_clear.rect = tabapp.scale(native_btn_m_clear, window_w, window_h, w, h);
        self.btn_prog.rect = tabapp.scale(native_btn_prog, window_w, window_h, w, h);
        self.btn_c.rect = tabapp.scale(native_btn_c, window_w, window_h, w, h);
        self.btn_sign.rect = tabapp.scale(native_btn_sign, window_w, window_h, w, h);
        self.btn_mod.rect = tabapp.scale(native_btn_mod, window_w, window_h, w, h);
        self.btn_div.rect = tabapp.scale(native_btn_div, window_w, window_h, w, h);
        self.btn_7.rect = tabapp.scale(native_btn_7, window_w, window_h, w, h);
        self.btn_8.rect = tabapp.scale(native_btn_8, window_w, window_h, w, h);
        self.btn_9.rect = tabapp.scale(native_btn_9, window_w, window_h, w, h);
        self.btn_mul.rect = tabapp.scale(native_btn_mul, window_w, window_h, w, h);
        self.btn_4.rect = tabapp.scale(native_btn_4, window_w, window_h, w, h);
        self.btn_5.rect = tabapp.scale(native_btn_5, window_w, window_h, w, h);
        self.btn_6.rect = tabapp.scale(native_btn_6, window_w, window_h, w, h);
        self.btn_sub.rect = tabapp.scale(native_btn_sub, window_w, window_h, w, h);
        self.btn_1.rect = tabapp.scale(native_btn_1, window_w, window_h, w, h);
        self.btn_2.rect = tabapp.scale(native_btn_2, window_w, window_h, w, h);
        self.btn_3.rect = tabapp.scale(native_btn_3, window_w, window_h, w, h);
        self.btn_add.rect = tabapp.scale(native_btn_add, window_w, window_h, w, h);
        self.btn_0.rect = tabapp.scale(native_btn_0, window_w, window_h, w, h);
        self.btn_ce.rect = tabapp.scale(native_btn_ce, window_w, window_h, w, h);
        self.btn_eq.rect = tabapp.scale(native_btn_eq, window_w, window_h, w, h);
        self.btn_st.rect = tabapp.scale(native_btn_st, window_w, window_h, w, h);
        self.btn_clr_mem.rect = tabapp.scale(native_btn_clr_mem, window_w, window_h, w, h);
        self.btn_not.rect = tabapp.scale(native_btn_not, window_w, window_h, w, h);
        self.btn_shl.rect = tabapp.scale(native_btn_shl, window_w, window_h, w, h);
        self.btn_shr.rect = tabapp.scale(native_btn_shr, window_w, window_h, w, h);
        self.btn_and.rect = tabapp.scale(native_btn_and, window_w, window_h, w, h);
        self.btn_or.rect = tabapp.scale(native_btn_or, window_w, window_h, w, h);
        self.btn_xor.rect = tabapp.scale(native_btn_xor, window_w, window_h, w, h);
        self.btn_hex.rect = tabapp.scale(native_btn_hex, window_w, window_h, w, h);
        self.btn_dec.rect = tabapp.scale(native_btn_dec, window_w, window_h, w, h);
        self.btn_oct.rect = tabapp.scale(native_btn_oct, window_w, window_h, w, h);
        self.btn_pi.rect = tabapp.scale(native_btn_pi, window_w, window_h, w, h);
        self.btn_euler.rect = tabapp.scale(native_btn_euler, window_w, window_h, w, h);
        self.btn_sqrt2.rect = tabapp.scale(native_btn_sqrt2, window_w, window_h, w, h);
        self.btn_phi.rect = tabapp.scale(native_btn_phi, window_w, window_h, w, h);
        self.btn_sin.rect = tabapp.scale(native_btn_sin, window_w, window_h, w, h);
        self.btn_cos.rect = tabapp.scale(native_btn_cos, window_w, window_h, w, h);
        self.btn_tan.rect = tabapp.scale(native_btn_tan, window_w, window_h, w, h);
        self.btn_deg_rad.rect = tabapp.scale(native_btn_deg_rad, window_w, window_h, w, h);
        self.btn_asin.rect = tabapp.scale(native_btn_asin, window_w, window_h, w, h);
        self.btn_acos.rect = tabapp.scale(native_btn_acos, window_w, window_h, w, h);
        self.btn_atan.rect = tabapp.scale(native_btn_atan, window_w, window_h, w, h);
        self.btn_ln.rect = tabapp.scale(native_btn_ln, window_w, window_h, w, h);
        self.btn_log.rect = tabapp.scale(native_btn_log, window_w, window_h, w, h);
        self.btn_exp.rect = tabapp.scale(native_btn_exp, window_w, window_h, w, h);
        self.btn_pow.rect = tabapp.scale(native_btn_pow, window_w, window_h, w, h);
        self.btn_sqrt.rect = tabapp.scale(native_btn_sqrt, window_w, window_h, w, h);
        self.btn_abs.rect = tabapp.scale(native_btn_abs, window_w, window_h, w, h);
        self.btn_sci.rect = tabapp.scale(native_btn_sci, window_w, window_h, w, h);
        self.btn_expr.rect = tabapp.scale(native_btn_expr, window_w, window_h, w, h);
        self.btn_rand.rect = tabapp.scale(native_btn_rand, window_w, window_h, w, h);
    }

    pub fn init() AppState {
        var s = AppState{};
        // M37 DQ4: frozen aliases on purpose — Button.draw resolves them
        // live via ui.live_color(), so buttons follow the desktop theme.
        s.btn_eq.bg_color = ui.COLOR_ACCENT;
        s.btn_c.bg_color = ui.COLOR_DANGER;
        // Load history from FAT (K5)
        s.hist.load_from_fat();
        if (s.hist.len > history_visible) {
            s.history_scroll = s.hist.len - history_visible;
        }
        // Load formatting config from FAT (K12)
        s.cfg_load();
        // Load named definitions from FAT (K15)
        s.defs_load();
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
    // Random numbers (K14)
    // -------------------------------------------------------------------

    /// xorshift64* — tiny, deterministic given its seed, and re-seeded from
    /// the boot-counter at press time so consecutive presses differ. This
    /// is NOT the kernel CSPRNG: M24's ABI budget is zero new slots and no
    /// EL0 entropy seam exists, so the honest choice is a PRNG with the
    /// seed source documented.
    fn rand_next(self: *AppState) u64 {
        if (self.rand_state == 0) {
            self.rand_state = dates.now() | 1; // never zero
        }
        var x = self.rand_state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.rand_state = x;
        return x *% 0x2545F4914F6CDD1D;
    }

    /// RAND: display value N > 0 → uniform-ish [0, N); N == 0 → [0, 2^32).
    fn rand_apply(self: *AppState) void {
        const n = self.engine.current_val;
        const r = self.rand_next();
        var v: i64 = undefined;
        if (n > 0) {
            v = @intCast(r % @as(u64, @intCast(n)));
        } else {
            v = @intCast(r & 0xFFFF_FFFF);
        }
        self.engine.current_val = v;
        self.engine.is_entering_val = true;
        self.history_cursor = null;
        ui.write_console("calc: rand\n");
    }

    // -------------------------------------------------------------------
    // Definitions (K15)
    // -------------------------------------------------------------------

    const defs_path = "/host/calc_defs.txt"; // M34 HF5 (#739)

    fn defs_load(self: *AppState) void {
        var file_buf: [256]u8 = undefined;
        const fd = ui.file_open(defs_path, ui.MODE_READ);
        if (fd < 0) return;
        const n = ui.file_read(@as(u32, @intCast(fd)), &file_buf);
        ui.file_close(@as(u32, @intCast(fd)));
        if (n <= 0) return;
        self.defs.load_file_text(file_buf[0..@intCast(n)]);
    }

    fn defs_save(self: *const AppState) void {
        var buf: [256]u8 = undefined;
        const text = self.defs.write_file_text(&buf);
        const fd = ui.file_open(defs_path, ui.MODE_CREATE | ui.MODE_WRITE);
        if (fd < 0) return;
        _ = ui.file_write(@as(u32, @intCast(fd)), text);
        ui.file_close(@as(u32, @intCast(fd)));
    }

    // -------------------------------------------------------------------
    // Settings / formatting controls (K12)
    // -------------------------------------------------------------------

    const cfg_path = "/host/calc_cfg.txt"; // M34 HF5 (#739)

    fn cfg_load(self: *AppState) void {
        var file_buf: [64]u8 = undefined;
        const fd = ui.file_open(cfg_path, ui.MODE_READ);
        if (fd < 0) return;
        const n = ui.file_read(@as(u32, @intCast(fd)), &file_buf);
        ui.file_close(@as(u32, @intCast(fd)));
        if (n <= 0) return;
        const c = parse_config(file_buf[0..@intCast(n)]);
        self.dec_places = c.dec_places;
        self.thousands_sep = c.thousands_sep;
        self.hex_leading_zeros = c.hex_leading_zeros;
    }

    fn cfg_save(self: *const AppState) void {
        var buf: [64]u8 = undefined;
        const text = write_config(.{
            .dec_places = self.dec_places,
            .thousands_sep = self.thousands_sep,
            .hex_leading_zeros = self.hex_leading_zeros,
        }, &buf);
        const fd = ui.file_open(cfg_path, ui.MODE_CREATE | ui.MODE_WRITE);
        if (fd < 0) return;
        _ = ui.file_write(@as(u32, @intCast(fd)), text);
        ui.file_close(@as(u32, @intCast(fd)));
    }

    /// Adjust the selected settings row (+1/-1); toggles wrap booleans.
    fn cfg_adjust(self: *AppState, delta: i32) void {
        switch (self.cfg_row) {
            0 => {
                var v = @as(i32, self.dec_places) + delta;
                if (v < 0) v = 10; // wrap
                if (v > 10) v = 0;
                self.dec_places = @intCast(v);
            },
            1 => {
                if (delta != 0) self.thousands_sep = !self.thousands_sep;
            },
            else => {
                if (delta != 0) self.hex_leading_zeros = !self.hex_leading_zeros;
            },
        }
        self.cfg_save();
        ui.write_console("calc: cfg-save\n");
    }

    /// Click y within history_area → settings row (null when outside).
    fn cfg_row_at(self: *const AppState, y: u32) ?usize {
        if (y < self.rects.history_area.y + ui.pad_sm) return null;
        const rel = y - (self.rects.history_area.y + ui.pad_sm);
        const row = rel / 16;
        if (row > 2) return null;
        return row;
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
        // K12: optional thousands separator on the plain integer display
        if (self.thousands_sep) return format_thousands(v, buf);
        // K15: exact fractional render of a float-valued expression
        if (self.float_display) |fv| {
            if (!self.engine.is_entering_val) return format_fixed(fv, self.dec_places, buf);
        }
        return self.engine.format_display(buf);
    }

    // -------------------------------------------------------------------
    // Expression editor (K9)
    // -------------------------------------------------------------------

    fn expr_append(self: *AppState, ch: u8) void {
        if (self.expr_len >= self.expr_buf.len) return;
        const extra = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_' or ch == '=' or ch == '.';
        if (!expr_mod.is_expr_char(ch) and !extra) return;
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
        const text = self.expr_buf[0..self.expr_len];

        // K15: "def name = expression" stores a named value
        if (defs_mod.parse_def_command(text)) |cmd| {
            active_defs = &self.defs;
            defer active_defs = null;
            const v = expr_mod.evaluate_f64(cmd.expr, resolve_def) catch {
                self.engine.raise_error();
                ui.write_console("calc: def-error\n");
                return;
            };
            self.defs.put(cmd.name, v) catch {
                self.engine.raise_error();
                ui.write_console("calc: def-error\n");
                return;
            };
            self.defs_save();
            self.float_display = v;
            self.engine.is_entering_val = false;
            self.engine.has_error = false;
            self.push_history(text, @intFromFloat(@round(v)));
            self.expr_reset_input();
            ui.write_console("calc: def-ok\n");
            return;
        }

        // K15: identifier present -> float evaluation with definitions
        // any letter in the expression means a definition is referenced
        var has_ident = false;
        for (text) |ch| {
            if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
                has_ident = true;
                break;
            }
        }
        if (has_ident) {
            active_defs = &self.defs;
            defer active_defs = null;
            const fv = expr_mod.evaluate_f64(text, resolve_def) catch {
                self.engine.raise_error();
                ui.write_console("calc: expr-error\n");
                return;
            };
            self.engine.current_val = @intFromFloat(@round(fv));
            self.engine.is_entering_val = false;
            self.engine.has_error = false;
            self.float_display = fv;
            self.push_history(text, @intFromFloat(@round(fv)));
            self.expr_reset_input();
            ui.write_console("calc: expr-ok-float\n");
            return;
        }
        self.float_display = null;

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
    fn history_row_at(self: *const AppState, y: u32) ?usize {
        if (y < self.rects.history_area.y + ui.pad_sm) return null;
        const rel = y - (self.rects.history_area.y + ui.pad_sm);
        const row = rel / 10;
        if (row >= history_visible) return null;
        return row;
    }

    // -------------------------------------------------------------------
    // Draw
    // -------------------------------------------------------------------

    pub fn draw(self: *const AppState, win: u32) void {
        ui.draw_rect(win, Rect.make(0, 0, self.canvas_w, self.canvas_h), ui.theme_bg());

        if (self.prog_mode.active) {
            self.draw_programmer(win);
        } else {
            self.draw_standard(win);
        }
    }

    fn draw_standard(self: *const AppState, win: u32) void {
        // History area
        ui.draw_rect(win, self.rects.history_area, ui.theme_surface());
        ui.draw_rect_outline(win, self.rects.history_area, ui.border_w, ui.theme_border());
        var h_row: usize = 0;
        var h_idx = self.history_scroll;
        while (h_idx < self.hist.len and h_row < history_visible) : (h_idx += 1) {
            const entry = self.hist.get(h_idx);
            var buf: [40]u8 = undefined;
            const txt = HistoryRing.format_entry(entry, &buf);
            const y = self.rects.history_area.y + ui.pad_sm + @as(u32, @intCast(h_row)) * 10;
            const is_cursor = if (self.history_cursor) |c| c == h_idx else false;
            const col = if (is_cursor) ui.theme_accent() else ui.theme_text_muted();
            const cap = @min(txt.len, 60);
            ui.draw_text(win, txt[0..cap], self.rects.history_area.x + ui.pad_sm, y, col);
            h_row += 1;
        }
        if (self.hist.len > history_visible) {
            if (self.history_scroll > 0)
                ui.draw_text(win, "^", self.rects.history_area.x + self.rects.history_area.w - 10, self.rects.history_area.y + ui.pad_sm, ui.theme_text_muted());
            if (self.history_scroll + history_visible < self.hist.len)
                ui.draw_text(win, "v", self.rects.history_area.x + self.rects.history_area.w - 10, self.rects.history_area.y + self.rects.history_area.h - 10, ui.theme_text_muted());
        }

        // Display box
        ui.draw_rect(win, self.rects.display_rect, ui.theme_surface());
        ui.draw_rect_outline(win, self.rects.display_rect, ui.border_w, ui.theme_border());
        var disp_buf: [32]u8 = undefined;
        const disp_text = self.display_text(&disp_buf);
        const text_w = ui.measure_text(disp_text);
        const text_x = if (self.rects.display_rect.w > text_w + 16) self.rects.display_rect.x + self.rects.display_rect.w - text_w - 8 else self.rects.display_rect.x + 16;
        const text_y = self.rects.display_rect.y + (if (self.rects.display_rect.h > 12) (self.rects.display_rect.h - 12) / 2 else 0);
        ui.draw_text(win, disp_text, text_x, text_y, ui.theme_text_primary());

        // Memory indicator (K2)
        self.draw_mem_indicator(win, self.rects.display_rect.x + ui.pad_sm, text_y);

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

        // K14 random button
        self.btn_rand.draw(win);
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

        // K12 settings bar (when active, overlays the history area)
        if (self.cfg_active) {
            self.draw_cfg_bar(win);
        } else if (self.date_active) {
            // K13 date bar (when active, overlays the history area)
            self.draw_date_bar(win);
        } else if (self.stats_active) {
            // K16 stats bar (when active, overlays the history area)
            self.draw_stats_bar(win);
        }
    }

    fn draw_stats_bar(self: *const AppState, win: u32) void {
        ui.draw_rect(win, self.rects.history_area, ui.theme_surface());
        ui.draw_rect_outline(win, self.rects.history_area, ui.border_w, ui.theme_accent());

        var line0: [128]u8 = undefined;
        const prompt = "1,2,3 > ";
        @memcpy(line0[0..prompt.len], prompt);
        const dl = @min(self.stats_len, line0.len - prompt.len - 4);
        @memcpy(line0[prompt.len .. prompt.len + dl], self.stats_input[0..dl]);
        ui.draw_text(win, line0[0 .. prompt.len + dl], self.rects.history_area.x + ui.pad_sm, self.rects.history_area.y + ui.pad_sm, ui.theme_text_primary());

        if (self.stats_result_len > 0) {
            const rl = @min(self.stats_result_len, 60);
            ui.draw_text(win, self.stats_result[0..rl], self.rects.history_area.x + ui.pad_sm, self.rects.history_area.y + 20, ui.theme_accent());
        } else {
            const hint = "comma-separated values, Enter computes";
            ui.draw_text(win, hint, self.rects.history_area.x + ui.pad_sm, self.rects.history_area.y + 20, ui.theme_text_muted());
        }
    }

    fn fmt_stats_result(self: *AppState, comptime f: []const u8, args: anytype) usize {
        const s = std.fmt.bufPrint(&self.stats_result, f, args) catch return 0;
        return s.len;
    }

    fn stats_evaluate(self: *AppState) void {
        if (self.stats_len == 0) return;
        self.stats_store.parse_list(self.stats_input[0..self.stats_len]) catch {
            const msg = "? too many (max 100)";
            @memcpy(self.stats_result[0..msg.len], msg);
            self.stats_result_len = msg.len;
            ui.write_console("calc: stats-error\n");
            return;
        };
        const r = self.stats_store.compute() catch {
            const msg = "? enter numbers first";
            @memcpy(self.stats_result[0..msg.len], msg);
            self.stats_result_len = msg.len;
            ui.write_console("calc: stats-error\n");
            return;
        };
        // mean lands in the engine for chaining; full summary in the bar
        self.engine.current_val = @intFromFloat(@round(r.mean));
        self.engine.is_entering_val = false;
        self.engine.has_error = false;
        self.float_display = r.mean;
        self.stats_result_len = self.fmt_stats_result(
            "n={d} mean={d:.2} med={d:.2} min={d} max={d} sd={d:.2}",
            .{ r.n, r.mean, r.median, @as(i64, @intFromFloat(@round(r.min))), @as(i64, @intFromFloat(@round(r.max))), r.std_dev },
        );
        var hist_buf: [32]u8 = undefined;
        const hs = format_i64(@intCast(r.n), &hist_buf);
        self.push_history(hs, self.engine.current_val);
        self.stats_len = 0;
        ui.write_console("calc: stats-ok\n");
    }

    fn draw_date_bar(self: *const AppState, win: u32) void {
        ui.draw_rect(win, self.rects.history_area, ui.theme_surface());
        ui.draw_rect_outline(win, self.rects.history_area, ui.border_w, ui.theme_accent());

        // Row 0: the command line
        var line0: [56]u8 = undefined;
        const prompt = "> ";
        @memcpy(line0[0..prompt.len], prompt);
        const dl = @min(self.date_len, line0.len - prompt.len - 4);
        @memcpy(line0[prompt.len .. prompt.len + dl], self.date_buf[0..dl]);
        ui.draw_text(win, line0[0 .. prompt.len + dl], self.rects.history_area.x + ui.pad_sm, self.rects.history_area.y + ui.pad_sm, ui.theme_text_primary());

        // Row 1: result of the last operation (or usage hint)
        if (self.date_result_len > 0) {
            const rl = @min(self.date_result_len, 60);
            ui.draw_text(win, self.date_result[0..rl], self.rects.history_area.x + ui.pad_sm, self.rects.history_area.y + 20, ui.theme_accent());
        } else {
            const hint = "d1 - d2 | d + N | now";
            ui.draw_text(win, hint, self.rects.history_area.x + ui.pad_sm, self.rects.history_area.y + 20, ui.theme_text_muted());
        }
    }

    fn fmt_date_result(self: *AppState, comptime f: []const u8, args: anytype) usize {
        const s = std.fmt.bufPrint(&self.date_result, f, args) catch return 0;
        return s.len;
    }

    /// K13: evaluate the date command line; results are numeric in the; results are numeric in the
    /// engine/history (days or seconds), human-readable in the bar.
    fn date_evaluate(self: *AppState) void {
        if (self.date_len == 0) return;
        const text = self.date_buf[0..self.date_len];

        var out_len: usize = 0;
        var value: i64 = 0;

        if (std.mem.eql(u8, text, "now")) {
            value = @intCast(dates.now());
            out_len = self.fmt_date_result("{d}s since boot", .{value});
        } else if (std.mem.indexOf(u8, text, " - ")) |sep| {
            // date_diff
            const a = dates.parse(text[0..sep]) catch {
                self.date_fail();
                return;
            };
            const b = dates.parse(text[sep + 3 ..]) catch {
                self.date_fail();
                return;
            };
            value = a - b;
            out_len = self.fmt_date_result("{d} days", .{value});
        } else if (std.mem.indexOf(u8, text, " + ")) |sep| {
            // date_add
            const base = dates.parse(text[0..sep]) catch {
                self.date_fail();
                return;
            };
            var num_buf: [16]u8 = undefined;
            const rest = text[sep + 3 ..];
            if (rest.len >= num_buf.len) {
                self.date_fail();
                return;
            }
            @memcpy(num_buf[0..rest.len], rest);
            const days = parse_cfg_int(num_buf[0..rest.len]) orelse {
                self.date_fail();
                return;
            };
            value = base + days;
            var fmt_buf: [16]u8 = undefined;
            const new_date = dates.format(value, &fmt_buf);
            @memcpy(self.date_result[0..new_date.len], new_date);
            out_len = new_date.len;
        } else {
            // A bare date: show its day count
            value = dates.parse(text) catch {
                self.date_fail();
                return;
            };
            out_len = self.fmt_date_result("day {d}", .{value});
        }

        self.date_result_len = out_len;
        self.engine.current_val = value;
        self.engine.is_entering_val = false;
        self.engine.has_error = false;
        self.push_history(text, value);
        self.date_len = 0;
        ui.write_console("calc: date-ok\n");
    }

    fn date_fail(self: *AppState) void {
        const msg = "? (YYYY-MM-DD)";
        @memcpy(self.date_result[0..msg.len], msg);
        self.date_result_len = msg.len;
        self.engine.raise_error();
        ui.write_console("calc: date-error\n");
    }

    fn is_date_char(ch: u8) bool {
        return (ch >= '0' and ch <= '9') or ch == '-' or ch == '+' or ch == ' ' or
            ch == 'n' or ch == 'o' or ch == 'w';
    }

    fn draw_cfg_bar(self: *const AppState, win: u32) void {
        ui.draw_rect(win, self.rects.history_area, ui.theme_surface());
        ui.draw_rect_outline(win, self.rects.history_area, ui.border_w, ui.theme_accent());

        var row_buf: [48]u8 = undefined;
        const rows = [_][]const u8{
            std.fmt.bufPrint(row_buf[0..24], "DEC PLACES   < {d} >", .{self.dec_places}) catch "?",
            if (self.thousands_sep) "THOUSANDS    ON" else "THOUSANDS    OFF",
            if (self.hex_leading_zeros) "HEX PAD      ON" else "HEX PAD      OFF",
        };
        for (rows, 0..) |row_text, ri| {
            const y = self.rects.history_area.y + ui.pad_sm + @as(u32, @intCast(ri)) * 16;
            const col = if (ri == self.cfg_row) ui.theme_text_primary() else ui.theme_text_muted();
            ui.draw_text(win, row_text[0..@min(row_text.len, 60)], self.rects.history_area.x + ui.pad_sm, y, col);
        }
    }

    fn draw_programmer(self: *const AppState, win: u32) void {
        // Triple-line display (hex / dec / oct) — replaces history + single display
        ui.draw_rect(win, self.rects.hex_display_rect, ui.theme_surface());
        ui.draw_rect_outline(win, self.rects.hex_display_rect, ui.border_w, ui.theme_border());
        ui.draw_rect(win, self.rects.dec_display_rect, ui.theme_surface());
        ui.draw_rect_outline(win, self.rects.dec_display_rect, ui.border_w, ui.theme_border());
        ui.draw_rect(win, self.rects.oct_display_rect, ui.theme_surface());
        ui.draw_rect_outline(win, self.rects.oct_display_rect, ui.border_w, ui.theme_border());
        ui.draw_rect(win, self.rects.reg_display_rect, ui.theme_surface());
        ui.draw_rect_outline(win, self.rects.reg_display_rect, ui.border_w, ui.theme_border());

        const val = self.engine.current_val;

        // Hex
        var hex_buf: [24]u8 = undefined;
        // K12: optional 16-digit zero padding in hex display
        var hex_str_buf: [20]u8 = undefined;
        const raw_hex = prog.format_hex(val, &hex_buf);
        const hex_str = if (self.hex_leading_zeros and raw_hex.len < 16) blk: {
            const pad = 16 - raw_hex.len;
            @memset(hex_str_buf[0..pad], '0');
            @memcpy(hex_str_buf[pad .. pad + raw_hex.len], raw_hex);
            break :blk hex_str_buf[0 .. pad + raw_hex.len];
        } else raw_hex;
        var hex_label: [20]u8 = undefined;
        var hpos: usize = 0;
        const prefix = "0x";
        @memcpy(hex_label[hpos .. hpos + prefix.len], prefix);
        hpos += prefix.len;
        const hc = @min(hex_str.len, hex_label.len - hpos);
        @memcpy(hex_label[hpos .. hpos + hc], hex_str[0..hc]);
        hpos += hc;
        ui.draw_text(win, hex_label[0..hpos], self.rects.hex_display_rect.x + ui.pad_sm, self.rects.hex_display_rect.y + 5, ui.theme_text_primary());

        // Dec
        var dec_buf: [24]u8 = undefined;
        const dec_str = prog.format_dec(val, &dec_buf);
        ui.draw_text(win, dec_str, self.rects.dec_display_rect.x + ui.pad_sm, self.rects.dec_display_rect.y + 5, ui.theme_text_primary());

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
        ui.draw_text(win, oct_label[0..opos], self.rects.oct_display_rect.x + ui.pad_sm, self.rects.oct_display_rect.y + 5, ui.theme_text_muted());

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
        ui.draw_text(win, reg_buf[0..rpos], self.rects.reg_display_rect.x + ui.pad_sm, self.rects.reg_display_rect.y + 5, ui.theme_text_muted());

        // Memory indicator (K2)
        // Small indicator at right of reg display
        if (self.mem_any_nonzero) {
            ui.draw_text(win, "M", self.rects.reg_display_rect.x + self.rects.reg_display_rect.w - 12, self.rects.reg_display_rect.y + 5, ui.theme_text_muted());
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
                ui.draw_text(win, label[0..2], x, y, ui.theme_text_muted());
            } else {
                // Show just the slot number even if empty, dimmer
                ui.draw_text(win, label[0..2], x, y, ui.theme_bg());
            }
        }
    }

    fn draw_convert_bar(self: *const AppState, win: u32) void {
        // Conversion bar overlays the history area when active
        ui.draw_rect(win, self.rects.history_area, ui.theme_surface());
        ui.draw_rect_outline(win, self.rects.history_area, ui.border_w, ui.theme_accent());

        // Category buttons
        const cats = [_][]const u8{ "Temp", "Length", "Weight" };
        var cat_x: u32 = self.rects.history_area.x + ui.pad_sm;
        for (cats, 0..) |cat_name, ci| {
            const is_active = ci == self.convert_category;
            const col = if (is_active) ui.theme_accent() else ui.theme_text_muted();
            ui.draw_text(win, cat_name, cat_x, self.rects.history_area.y + ui.pad_sm, col);
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
        ui.draw_text(win, label_buf[0..lpos], self.rects.history_area.x + ui.pad_sm, self.rects.history_area.y + 16, ui.theme_text_primary());

        // Conversion result — K12: dec_places formats the fractional part
        var res_buf: [32]u8 = undefined;
        const result = self.convert_result();
        const result_str = format_fixed(result, self.dec_places, &res_buf);
        var full_buf: [32]u8 = undefined;
        var fpos: usize = 0;
        const eq_sign = "= ";
        @memcpy(full_buf[fpos .. fpos + eq_sign.len], eq_sign);
        fpos += eq_sign.len;
        const rc = @min(result_str.len, full_buf.len - fpos);
        @memcpy(full_buf[fpos .. fpos + rc], result_str[0..rc]);
        fpos += rc;
        ui.draw_text(win, full_buf[0..fpos], self.rects.history_area.x + ui.pad_sm, self.rects.history_area.y + 28, ui.theme_accent());
    }

    // -------------------------------------------------------------------
    // Mouse events
    // -------------------------------------------------------------------

    /// M37 DQ4: cursor kind from the pointer position. Emits
    /// `calc: cursor=<name>` on change (serial-observable).
    pub fn update_cursor(self: *AppState, x: u32, y: u32) void {
        _ = x;
        const over_clickable = y >= self.rects.display_rect.y + self.rects.display_rect.h + 2;
        const kind = ui.cursor_for_region(false, over_clickable, false);
        if (kind != self.cursor_kind) {
            self.cursor_kind = kind;
            var buf: [48]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "calc: cursor={s}\n", .{kind.name()}) catch return;
            ui.write_console(msg);
        }
    }

    pub fn handle_mouse_events(self: *AppState, ev: *const Event) bool {
        var changed = false;

        // M37 DQ4: pointer over the interactive band (below the main
        // display/history every mode puts buttons, settings rows, or the
        // convert bar; the programmer-mode readout rows are the known
        // exception and keep the arrow), arrow over read-only displays.
        if (ev.kind == ui.MOUSE_MOVE) self.update_cursor(ev.arg0, ev.arg1);

        // (update_cursor lives beside the mouse dispatch: Zig forbids
        // decls between struct fields.)
        if (self.prog_mode.active) {
            changed = self.handle_mouse_programmer(ev) or changed;
        } else {
            changed = self.handle_mouse_standard(ev) or changed;
        }

        return changed;
    }

    fn handle_mouse_standard(self: *AppState, ev: *const Event) bool {
        var changed = false;

        // K12: the settings bar consumes clicks over the history area
        // (act once, on release — DOWN+UP would double-adjust)
        if (self.cfg_active and ev.kind == ui.MOUSE_UP) {
            const x = ev.arg0;
            const y = ev.arg1;
            const inside = x >= self.rects.history_area.x and x < self.rects.history_area.x + self.rects.history_area.w and
                y >= self.rects.history_area.y and y < self.rects.history_area.y + self.rects.history_area.h;
            if (inside) {
                if (self.cfg_row_at(y)) |row| {
                    self.cfg_row = @intCast(row);
                    self.cfg_adjust(1);
                }
                return true;
            }
        }

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

        // K14 random button
        if (!changed) {
            if (self.btn_rand.handle_event(ev)) {
                self.rand_apply();
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
            const inside_x = x >= self.rects.history_area.x and x < self.rects.history_area.x + self.rects.history_area.w;
            const inside_y = y >= self.rects.history_area.y and y < self.rects.history_area.y + self.rects.history_area.h;
            if (inside_x and inside_y) {
                if (self.history_row_at(y)) |row| {
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
        const ctrl = (ev.flags & ui.MOD_CTRL) != 0; // Ctrl flag (ADR 0009: MOD_CTRL = 0x0002, not ALT's 0x04)

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

        // K12: Ctrl+, toggles the settings bar
        if (ctrl and ascii == ',') {
            self.cfg_active = !self.cfg_active;
            self.cfg_row = 0;
            ui.write_console(if (self.cfg_active) "calc: cfg-open\n" else "calc: cfg-close\n");
            return true;
        }

        // K16: Ctrl+S toggles statistics mode
        if (ctrl and (ascii == 's' or ascii == 'S')) {
            self.stats_active = !self.stats_active;
            self.stats_len = 0;
            ui.write_console(if (self.stats_active) "calc: stats-on\n" else "calc: stats-off\n");
            return true;
        }

        // K16: while the stats bar is open it consumes keys
        if (self.stats_active and !ctrl) {
            if (ascii == 0x08 or keycode == 0x2a) {
                if (self.stats_len > 0) self.stats_len -= 1;
                return true;
            }
            if (ascii == 0x1b or keycode == 0x29) {
                self.stats_active = false;
                ui.write_console("calc: stats-off\n");
                return true;
            }
            const ok_ch = (ascii >= '0' and ascii <= '9') or ascii == ',' or ascii == '.' or
                ascii == '-' or ascii == '+' or ascii == ' ';
            if (ok_ch and self.stats_len < self.stats_input.len) {
                self.stats_input[self.stats_len] = ascii;
                self.stats_len += 1;
                return true;
            }
            if (keycode == 0x28 or ascii == '\r' or ascii == '\n') {
                self.stats_evaluate();
                return true;
            }
            return true; // swallow everything else while open
        }

        // K13: Ctrl+D toggles the date bar
        if (ctrl and (ascii == 'd' or ascii == 'D')) {
            self.date_active = !self.date_active;
            self.date_len = 0;
            ui.write_console(if (self.date_active) "calc: date-open\n" else "calc: date-close\n");
            return true;
        }

        // K13: while the date bar is open it consumes keys
        if (self.date_active and !ctrl) {
            if (ascii == 0x08 or keycode == 0x2a) {
                if (self.date_len > 0) self.date_len -= 1;
                return true;
            }
            if (ascii == 0x1b or keycode == 0x29) {
                self.date_active = false;
                ui.write_console("calc: date-close\n");
                return true;
            }
            if (keycode == 0x28 or ascii == '\r' or ascii == '\n' or ascii == '=') {
                self.date_evaluate();
                return true;
            }
            if (is_date_char(ascii) and self.date_len < self.date_buf.len) {
                self.date_buf[self.date_len] = ascii;
                self.date_len += 1;
                return true;
            }
            return true; // swallow everything else while open
        }

        // K12: while the settings bar is open it consumes keys
        if (self.cfg_active) {
            if (keycode == 0x52) { // Up — move selection
                if (self.cfg_row > 0) self.cfg_row -= 1;
                return true;
            }
            if (keycode == 0x51) { // Down
                if (self.cfg_row < 2) self.cfg_row += 1;
                return true;
            }
            if (ascii == '+' or ascii == '=' or keycode == 0x4F) { // Right/increase
                self.cfg_adjust(1);
                return true;
            }
            if (ascii == '-' or keycode == 0x50) { // Left/decrease
                self.cfg_adjust(-1);
                return true;
            }
            if (ascii == ' ' or ascii == '\r' or ascii == '\n' or keycode == 0x28) {
                // Space/Enter: apply the row's primary action
                self.cfg_adjust(1);
                return true;
            }
            if (ascii == 0x1b or keycode == 0x29) {
                self.cfg_active = false;
                ui.write_console("calc: cfg-close\n");
                return true;
            }
            return true; // swallow everything else while open
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
            if (ascii == '=') {
                // inside a def line, '=' is literal text
                const t = self.expr_buf[0..self.expr_len];
                if (std.mem.startsWith(u8, std.mem.trim(u8, t, " "), "def")) {
                    self.expr_append(ascii);
                    return true;
                }
                self.expr_evaluate();
                return true;
            }
            if (keycode == 0x28 or ascii == '\r' or ascii == '\n') {
                self.expr_evaluate();
                return true;
            }
            if (!ctrl and (expr_mod.is_expr_char(ascii) or ascii == '.' or
                (ascii >= 'a' and ascii <= 'z') or (ascii >= 'A' and ascii <= 'Z') or ascii == '_'))
            {
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
            self.float_display = null;
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
            self.float_display = null;
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

        // K14: r/R generates a random number
        if (ascii == 'r' or ascii == 'R') {
            if (!ctrl) {
                self.rand_apply();
            }
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

/// K11: read one 32-byte NUL-terminated argv slot.
fn cli_arg(block: [*]u8, i: usize) []const u8 {
    const slot = block + i * 32;
    var len: usize = 0;
    while (len < 32 and slot[len] != 0) len += 1;
    return slot[0..len];
}

/// K11: CLI mode — `exec CALC.BIN <expr>` evaluates and prints, no GUI.
fn cli_main(argc: usize, argv_va: u64) noreturn {
    const block: [*]u8 = @ptrFromInt(argv_va);

    // Join up to argc args into one expression line ("2 + 3" works too).
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    var i: usize = 0;
    while (i < argc) : (i += 1) {
        const arg = cli_arg(block, i);
        if (argc == 1 and (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help"))) {
            ui.write_console("CALC.BIN - VirelaiOS calculator\n" ++
                "usage: exec CALC.BIN [expression]\n" ++
                "       exec CALC.BIN -h      show this help\n" ++
                "examples: exec CALC.BIN '2+3*4'   -> 2+3*4 = 14\n" ++
                "          exec CALC.BIN '(2+3)*4' -> (2+3)*4 = 20\n" ++
                "no args opens the GUI calculator.\n");
            ui.exit_process(0);
        }
        if (pos > 0 and pos < buf.len) {
            buf[pos] = ' ';
            pos += 1;
        }
        const c = @min(arg.len, buf.len - pos);
        @memcpy(buf[pos .. pos + c], arg[0..c]);
        pos += c;
    }
    if (pos == 0) gui_main();

    const result = expr_mod.evaluate(buf[0..pos]) catch {
        ui.write_console("calc: invalid expression\n");
        ui.exit_process(1);
    };

    // "<expr> = <result>"
    var out: [300]u8 = undefined;
    var opos: usize = 0;
    const ec = @min(pos, out.len - 24);
    @memcpy(out[0..ec], buf[0..ec]);
    opos += ec;
    @memcpy(out[opos .. opos + 3], " = ");
    opos += 3;
    var num_buf: [24]u8 = undefined;
    const ns = format_i64(result, &num_buf);
    const nc = @min(ns.len, out.len - opos - 1);
    @memcpy(out[opos .. opos + nc], ns[0..nc]);
    opos += nc;
    out[opos] = '\n';
    opos += 1;
    ui.write_console(out[0..opos]);
    ui.exit_process(exit_status);
}

fn gui_main() noreturn {
    var app = AppState.init();

    // M42 SX3: the tab-aware open. The window opens at the native 512x424
    // (the legacy shim/WND presentation is unchanged); under TABWM.BIN the
    // declaration is accepted and activation delivers the full 1100x720
    // content viewport via the kernel's WIN_RESIZE seam, which `layout`
    // maps the fixed grid into.
    const win_res = tabapp.TabApp.init(.{
        .name = "CALC.BIN",
        .title = "Calc",
        .x = window_x,
        .y = window_y,
        .w = window_w,
        .h = window_h,
    }) orelse {
        ui.write_console("calc: failed to open window\n");
        ui.exit_process(1);
    };
    var ta = win_res;

    ui.write_console("calc: open id=2\n");
    if (ta.tab_aware) {
        ui.write_console("calc: tab-aware (full-viewport)\n");
    } else {
        ui.write_console("calc: not-tab-aware (shim or WND desktop)\n");
    }

    app.draw(ta.win);
    ta.present();
    ui.emit_tokens_marker("calc");
    ui.write_console("calc: ready\n");
    // M37 DQ4 gate: let the compositor settle (several ticks) so the
    // kind-4 snapshot captures the presented frame, not a stale one.
    ui.sleep_ticks(2);
    ui.write_console("calc: settled\n");

    var ev: Event = undefined;

    while (true) {
        const wait_rc = ui.wait_event(&ev);
        if (wait_rc < 0) break;

        var dirty = false;

        if (ev.kind == ui.WIN_CLOSE) {
            ui.write_console("calc: win_close\n");
            break;
        }

        // M42 SX3: WM-lifecycle events (resize -> relayout) first.
        switch (ta.dispatch(&ev)) {
            .closed => break,
            .resized => {
                ui.write_console("calc: resize relayout\n");
                app.layout(ta.w, ta.h);
                dirty = true;
            },
            .none => {
                if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP or ev.kind == ui.MOUSE_MOVE) {
                    dirty = app.handle_mouse_events(&ev) or dirty;
                } else if (ev.kind == ui.KEY_DOWN) {
                    dirty = app.handle_keyboard_event(&ev) or dirty;
                }
            },
        }

        while (ui.poll_event(&ev) > 0) {
            switch (ta.dispatch(&ev)) {
                .closed => {
                    ui.write_console("calc: win_close\n");
                    ta.close_and_exit(exit_status);
                },
                .resized => {
                    ui.write_console("calc: resize relayout\n");
                    app.layout(ta.w, ta.h);
                    dirty = true;
                },
                .none => {
                    if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP or ev.kind == ui.MOUSE_MOVE) {
                        dirty = app.handle_mouse_events(&ev) or dirty;
                    } else if (ev.kind == ui.KEY_DOWN) {
                        dirty = app.handle_keyboard_event(&ev) or dirty;
                    }
                },
            }
        }

        if (dirty) {
            app.draw(ta.win);
            ta.present();
        }
    }

    ui.write_console("calc: exiting 43\n");
    ta.close_and_exit(exit_status);
}

/// K11 entry contract: the kernel's exec passes argc in x0 and the argv
/// block VA in x1 (card 3e, claim 4636). With args: CLI mode — evaluate,
/// print, exit. Without: open the GUI window.
pub export fn _start(argc: u64, argv_va: u64) callconv(.c) noreturn {
    if (argc > 0 and argv_va != 0) {
        cli_main(@intCast(argc), argv_va);
    }
    gui_main();
}

test "calc K11: cli_arg reads NUL-terminated 32-byte slots" {
    var block = [_]u8{0} ** 64;
    @memcpy(block[0..5], "2+3*4");
    try std.testing.expectEqualStrings("2+3*4", cli_arg(&block, 0));
    @memcpy(block[32..34], "xy");
    try std.testing.expectEqualStrings("xy", cli_arg(&block, 1));
    try std.testing.expectEqual(@as(usize, 0), cli_arg(&block, 2).len);
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

    var ev = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0x13, .arg1 = 'p' }; // Ctrl+P
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expect(app.prog_mode.active);

    ev.flags = ui.MOD_CTRL;
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
    var ev = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0x1e, .arg1 = '2' }; // Ctrl+2
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

    var ev = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0x18, .arg1 = 'u' }; // Ctrl+U
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expect(app.convert_active);

    ev.flags = ui.MOD_CTRL;
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
    var ev = Event{ .kind = ui.KEY_DOWN, .flags = if (ctrl) ui.MOD_CTRL else 0, .seq = 1, .arg0 = 0, .arg1 = ascii };
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
    var evc = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0, .arg1 = 'c' };
    try std.testing.expect(app.handle_keyboard_event(&evc));
    // Ctrl+Shift+C
    var evcs = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL | ui.MOD_SHIFT, .seq = 2, .arg0 = 0, .arg1 = 'C' };
    try std.testing.expect(app.handle_keyboard_event(&evcs));
    // Ctrl+V — host clipboard stub returns 0, paste is a no-op but consumed
    var evv = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 3, .arg0 = 0, .arg1 = 'v' };
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

test "calc K12: thousands separator formatting" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1,234,567", format_thousands(1234567, &buf));
    try std.testing.expectEqualStrings("999", format_thousands(999, &buf));
    try std.testing.expectEqualStrings("1,000", format_thousands(1000, &buf));
    try std.testing.expectEqualStrings("-12,345,678", format_thousands(-12345678, &buf));
    try std.testing.expectEqualStrings("0", format_thousands(0, &buf));
}

test "calc K12: fixed-point with dec places" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0.33", format_fixed(1.0 / 3.0, 2, &buf));
    try std.testing.expectEqualStrings("37.78", format_fixed(37.7778, 2, &buf)); // e.g. 100C in F-scale math
    try std.testing.expectEqualStrings("5.00", format_fixed(5, 2, &buf));
    try std.testing.expectEqualStrings("212.00", format_fixed(212, 2, &buf));
    try std.testing.expectEqualStrings("3.1416", format_fixed(3.14159, 4, &buf));
    try std.testing.expectEqualStrings("-2.50", format_fixed(-2.5, 2, &buf));
    try std.testing.expectEqualStrings("7", format_fixed(7, 0, &buf));
}

test "calc K12: config parse/write round-trip" {
    const cfg = CalcConfig{ .dec_places = 7, .thousands_sep = true, .hex_leading_zeros = true };
    var buf: [64]u8 = undefined;
    const text = write_config(cfg, &buf);
    const back = parse_config(text);
    try std.testing.expectEqual(@as(u8, 7), back.dec_places);
    try std.testing.expect(back.thousands_sep);
    try std.testing.expect(back.hex_leading_zeros);

    // Tolerant of junk; out-of-range values are ignored (defaults hold)
    const junk = parse_config("hello\ndec=99\nsep=yes\nhexlz=0\n");
    try std.testing.expectEqual(@as(u8, 2), junk.dec_places); // 99 rejected, default kept
    try std.testing.expect(!junk.thousands_sep); // only '1' means on
}

test "calc K12: Ctrl+, opens the settings bar; keys adjust" {
    var app = AppState.init();
    try std.testing.expect(!app.cfg_active);
    var ev = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0, .arg1 = ',' };
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expect(app.cfg_active);

    // '+' bumps dec places 2 -> 3
    var plus = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0, .arg1 = '+' };
    _ = app.handle_keyboard_event(&plus);
    try std.testing.expectEqual(@as(u8, 3), app.dec_places);

    // Down moves to THOUSANDS row; Enter toggles it on
    var down = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x51, .arg1 = 0 };
    _ = app.handle_keyboard_event(&down);
    var enter = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0x28, .arg1 = '\r' };
    _ = app.handle_keyboard_event(&enter);
    try std.testing.expect(app.thousands_sep);

    // Esc closes
    var esc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 5, .arg0 = 0x29, .arg1 = 0x1b };
    _ = app.handle_keyboard_event(&esc);
    try std.testing.expect(!app.cfg_active);
}

test "calc K12: settings bar click adjusts row" {
    var app = AppState.init();
    app.cfg_active = true;
    // Row 0 spans y=12..27 → click at y=14 increments dec places
    var ev_up = Event{ .kind = ui.MOUSE_UP, .flags = 0, .seq = 2, .arg0 = 40, .arg1 = 14 };
    _ = app.handle_mouse_events(&ev_up);
    try std.testing.expectEqual(@as(u8, 3), app.dec_places); // default 2 + 1

    // Row 1 (THOUSANDS) at y=28..43 toggles the separator on
    var ev2u = Event{ .kind = ui.MOUSE_UP, .flags = 0, .seq = 4, .arg0 = 40, .arg1 = 30 };
    _ = app.handle_mouse_events(&ev2u);
    try std.testing.expect(app.thousands_sep);
}

test "calc K12: display honors thousands separator" {
    var app = AppState.init();
    app.engine.current_val = 1234567;
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1234567", app.display_text(&buf));
    app.thousands_sep = true;
    try std.testing.expectEqualStrings("1,234,567", app.display_text(&buf));
}

test "calc K13: Ctrl+D opens date bar; diff command works" {
    var app = AppState.init();
    try std.testing.expect(!app.date_active);
    var evd = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0, .arg1 = 'd' };
    try std.testing.expect(app.handle_keyboard_event(&evd));
    try std.testing.expect(app.date_active);

    for ("2026-01-10 - 2026-01-01") |ch| {
        var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0, .arg1 = ch };
        _ = app.handle_keyboard_event(&ev);
    }
    var evr = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x28, .arg1 = '\r' };
    _ = app.handle_keyboard_event(&evr);
    // 9 days lands in engine + history; result line says "9 days"
    // "A - B" reads A minus B
    try std.testing.expectEqual(@as(i64, 9), app.engine.current_val);
    const e = app.hist.get(app.hist.len - 1);
    try std.testing.expectEqualStrings("2026-01-10 - 2026-01-01", e.text[0..e.len]);
    try std.testing.expectEqualStrings("9 days", app.date_result[0..app.date_result_len]);
}

test "calc K13: date_add renders the new date" {
    var app = AppState.init();
    app.date_active = true;
    for ("2026-01-01 + 30") |ch| {
        var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0, .arg1 = ch };
        _ = app.handle_keyboard_event(&ev);
    }
    var evr = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x28, .arg1 = '\r' };
    _ = app.handle_keyboard_event(&evr);
    // Engine holds the new date's epoch-day count (20484 = 2026-01-31)
    try std.testing.expectEqual(@as(i64, 20484), app.engine.current_val);
    try std.testing.expectEqualStrings("2026-01-31", app.date_result[0..app.date_result_len]);
}

test "calc K13: now yields a positive second count" {
    var app = AppState.init();
    app.date_active = true;
    for ("now") |ch| {
        var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0, .arg1 = ch };
        _ = app.handle_keyboard_event(&ev);
    }
    var evr = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x28, .arg1 = '\r' };
    _ = app.handle_keyboard_event(&evr);
    try std.testing.expect(app.engine.current_val > 0); // host stub counts by 42
    try std.testing.expect(app.date_result_len > 0);
}

test "calc K13: bad date raises ERROR marker" {
    var app = AppState.init();
    app.date_active = true;
    for ("2026-13-40") |ch| {
        var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0, .arg1 = ch };
        _ = app.handle_keyboard_event(&ev);
    }
    var evr = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x28, .arg1 = '\r' };
    _ = app.handle_keyboard_event(&evr);
    try std.testing.expect(app.engine.has_error);
    try std.testing.expectEqualStrings("? (YYYY-MM-DD)", app.date_result[0..app.date_result_len]);

    // Esc closes
    var esc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x29, .arg1 = 0x1b };
    _ = app.handle_keyboard_event(&esc);
    try std.testing.expect(!app.date_active);
}

test "calc K14: RAND button yields different values in [0, 2^32)" {
    var app = AppState.init();
    app.engine.current_val = 0; // zero display → full 32-bit range
    press_at(&app, 158, 270); // RAND at (130,260) center
    const a = app.engine.current_val;
    press_at(&app, 158, 270);
    const b = app.engine.current_val;
    try std.testing.expect(a >= 0 and a <= 0xFFFF_FFFF);
    try std.testing.expect(b >= 0 and b <= 0xFFFF_FFFF);
    try std.testing.expect(a != b); // seeded by an advancing timer stub
}

test "calc K14: RAND respects [0, N) with N on the display" {
    var app = AppState.init();
    app.engine.current_val = 10;
    var seen_nonzero = false;
    for (0..50) |_| {
        app.engine.current_val = 10; // re-set: RAND replaces the display value
        app.rand_apply();
        try std.testing.expect(app.engine.current_val >= 0 and app.engine.current_val < 10);
        if (app.engine.current_val > 0) seen_nonzero = true;
    }
    try std.testing.expect(seen_nonzero);

    // N == 1 always yields 0
    app.engine.current_val = 1;
    app.rand_apply();
    try std.testing.expectEqual(@as(i64, 0), app.engine.current_val);
}

test "calc K14: r key shortcut" {
    var app = AppState.init();
    var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0, .arg1 = 'r' };
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expect(app.engine.current_val >= 0);
}

test "calc K15: def pi = 3.14 then 2*pi displays 6.28" {
    var app = AppState.init();
    tap(&app, 97, 270); // EXPR on
    for ("def pi = 3.14") |ch| {
        var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0, .arg1 = ch };
        _ = app.handle_keyboard_event(&ev);
    }
    var evr = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x28, .arg1 = '\r' };
    _ = app.handle_keyboard_event(&evr);
    try std.testing.expect((app.defs.get("pi") orelse 0) > 3.139 and (app.defs.get("pi") orelse 0) < 3.141);
    try std.testing.expect(!app.engine.has_error);

    // 2 * pi -> 6.28 rendered with dec_places
    for ("2 * pi") |ch| {
        var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0, .arg1 = ch };
        _ = app.handle_keyboard_event(&ev);
    }
    _ = app.handle_keyboard_event(&evr);
    try std.testing.expectEqual(@as(?f64, 6.28), app.float_display);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("6.28", app.display_text(&buf));
}

test "calc K15: def persistence round-trip via pure text" {
    var app = AppState.init();
    app.date_active = false;
    _ = &app;
    // store two defs through the same path the def command uses
    app.defs.put("tax_rate", 0.08) catch unreachable;
    app.defs.put("n", 42) catch unreachable;
    var buf: [256]u8 = undefined;
    const text = app.defs.write_file_text(&buf);

    var fresh = AppState.init();
    fresh.defs.load_file_text(text);
    try std.testing.expectEqual(@as(?f64, 0.08), fresh.defs.get("tax_rate"));
    try std.testing.expectEqual(@as(?f64, 42), fresh.defs.get("n"));

    // and they resolve in expressions
    active_defs = &fresh.defs;
    defer active_defs = null;
    const v = try expr_mod.evaluate_f64("100 * tax_rate", resolve_def);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), v, 1e-9);
}

test "calc K15: unknown name and bad def raise errors" {
    var app = AppState.init();
    tap(&app, 97, 270);
    for ("2 * nope") |ch| {
        var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0, .arg1 = ch };
        _ = app.handle_keyboard_event(&ev);
    }
    var evr = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x28, .arg1 = '\r' };
    _ = app.handle_keyboard_event(&evr);
    try std.testing.expect(app.engine.has_error);

    // def without '=' fails cleanly
    app.engine.clear();
    app.expr_mode = true;
    app.expr_reset_input();
    for ("def broken") |ch| {
        var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0, .arg1 = ch };
        _ = app.handle_keyboard_event(&ev);
    }
    _ = app.handle_keyboard_event(&evr);
    try std.testing.expect(app.engine.has_error);
}

test "calc K16: Ctrl+S opens stats; [1,2,3,4,5] computes" {
    var app = AppState.init();
    try std.testing.expect(!app.stats_active);
    var evs = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0, .arg1 = 's' };
    try std.testing.expect(app.handle_keyboard_event(&evs));
    try std.testing.expect(app.stats_active);

    for ("1,2,3,4,5") |ch| {
        var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0, .arg1 = ch };
        _ = app.handle_keyboard_event(&ev);
    }
    var evr = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x28, .arg1 = '\r' };
    _ = app.handle_keyboard_event(&evr);

    // mean lands in engine (exact here); summary line carries the rest
    try std.testing.expectEqual(@as(i64, 3), app.engine.current_val);
    const text = app.stats_result[0..app.stats_result_len];
    try std.testing.expect(std.mem.indexOf(u8, text, "n=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mean=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "med=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "min=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "max=5") != null);

    // Esc closes
    var esc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0x29, .arg1 = 0x1b };
    _ = app.handle_keyboard_event(&esc);
    try std.testing.expect(!app.stats_active);
}

test "calc K16: plain s stays memory-store while stats closed" {
    var app = AppState.init();
    app.engine.current_val = 42;
    app.engine.is_entering_val = true;
    var ev = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0, .arg1 = 's' };
    _ = app.handle_keyboard_event(&ev);
    try std.testing.expect(!app.stats_active);
    try std.testing.expectEqual(@as(i64, 42), app.mem_slots[0]);
}

// ---------------------------------------------------------------------------
// Tests (M42 SX3/SX4 — the tab-aware layout)
// ---------------------------------------------------------------------------
test "calc layout: native canvas is the identity (zero-regression fixed point)" {
    var app = AppState.init();
    app.layout(window_w, window_h);
    // Area rects map to themselves exactly.
    try std.testing.expectEqual(native_history_area, app.rects.history_area);
    try std.testing.expectEqual(native_display_rect, app.rects.display_rect);
    // Every button maps to itself exactly (the shipped layout).
    try std.testing.expectEqual(native_btn_7.x, app.btn_7.rect.x);
    try std.testing.expectEqual(native_btn_7.y, app.btn_7.rect.y);
    try std.testing.expectEqual(native_btn_7.w, app.btn_7.rect.w);
    try std.testing.expectEqual(native_btn_7.h, app.btn_7.rect.h);
    try std.testing.expectEqual(native_btn_eq.x, app.btn_eq.rect.x);
    // Hit-test helpers agree with the identity geometry.
    try std.testing.expect(app.history_row_at(native_history_area.y + ui.pad_sm) != null);
}

test "calc layout: full viewport maps the grid inside 1100x720" {
    var app = AppState.init();
    app.layout(1100, 720);
    try std.testing.expectEqual(@as(u32, 1100), app.canvas_w);
    try std.testing.expectEqual(@as(u32, 720), app.canvas_h);

    // Every area rect stays inside the viewport.
    const areas = [_]Rect{ app.rects.history_area, app.rects.display_rect, app.rects.convert_rect };
    for (areas) |r| {
        try std.testing.expect(r.x + r.w <= 1100);
        try std.testing.expect(r.y + r.h <= 720);
    }

    // Every button rect stays inside the viewport and grows with it.
    const btns = [_]*const Button{ &app.btn_7, &app.btn_8, &app.btn_0, &app.btn_eq, &app.btn_c, &app.btn_m_store, &app.btn_pi, &app.btn_sin, &app.btn_rand };
    for (btns) |b| {
        try std.testing.expect(b.rect.x + b.rect.w <= 1100);
        try std.testing.expect(b.rect.y + b.rect.h <= 720);
        try std.testing.expect(b.rect.w >= native_btn_7.w); // proportional growth
    }

    // The eq button's native position maps proportionally.
    try std.testing.expectEqual(native_btn_eq.x * 1100 / 512, app.btn_eq.rect.x);
}

test "calc layout: hit-test helpers follow the scaled geometry" {
    var app = AppState.init();
    app.layout(1100, 720);
    // history_row_at is relative to the SCALED area: a click just inside
    // the scaled history area maps to a settings/row index, a click in the
    // viewport's far bottom-right (outside the scaled area) maps to null
    // for the row helpers.
    const inside_y = app.rects.history_area.y + ui.pad_sm;
    try std.testing.expect(app.history_row_at(inside_y) != null);
    try std.testing.expect(app.history_row_at(650) == null);
}
