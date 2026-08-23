//! Milestone seven, card I3 (claim 6050): keyboard/pointer event FIFO +
//! keycode decode → Road Pops.
//!
//! The XHCI interrupt-IN reports (I1/I2) land here as keyboard/pointer
//! events. The shell idle loop is the drain site (the card-3d shell-idle-
//! drain pattern, next to the net RX drain): `drain()` polls the armed
//! interrupt-IN endpoints, decodes keyboard HID boot reports (modifier +
//! 6-key rollover) into ASCII bytes through a pure keymap, and records
//! pointer reports (buttons + absolute X/Y, best-effort — raw bytes are
//! the ground truth). The decoded bytes sit in a bounded pure-BSS FIFO that
//! the Road Pops tee's read path (`pop_byte`) hands to the shell's line
//! editor — the FIRST screen-side keystrokes reach the terminal.
//!
//! The keymap covers the usable ASCII subset: letters (shift → caps,
//! ctrl → the ADR 0008 D2 editing chords 0x01..0x1a), digits (shift → the
//! shifted symbol), Enter, Backspace, Tab, Space, the common punctuation,
//! and the editing nav cluster (arrows, Home, End, Delete) encoded as
//! `ESC [ <final>` sequences so the line editor stays byte-driven. Anything
//! outside the subset is honestly refused (no byte is invented).
//!
//! No libc, no POSIX, no allocation. The FIFO and driver state are fixed
//! BSS (the card-3d pattern); a full FIFO drops the newest byte and counts
//! it (bounded, never wraps).
//!
//! Host tests exercise the pure surface (keymap, FIFO, keyboard-report
//! decode); the `drain()` path is hardware-gated (a no-op when unarmed).

const std = @import("std");
const xhci = @import("xhci.zig"); // I1/I2: the XHCI transport + enumerated HID devices
const app_events = @import("events.zig"); // Milestone 9 (claim 7206): application event queues
const driving_award = @import("driving_award.zig"); // Milestone six G5: window focus query for event routing

pub const max_fifo: usize = 64;

/// The longest key sequence the keymap can produce (Delete's `ESC [ 3 ~`).
pub const max_key_bytes: usize = 4;

/// HID keyboard boot-protocol modifier bit masks.
const mod_lctrl: u8 = 0x01;
const mod_lshift: u8 = 0x02;
const mod_rctrl: u8 = 0x10;
const mod_rshift: u8 = 0x20;

/// The `input` monitor command's report shape.
pub const Report = struct {
    armed: bool,
    fifo_used: usize,
    fifo_max: usize,
    dropped: usize,
    events: usize,
    kb_mods: u8,
    kb_last_usage: u8,
    kb_last_byte: u8,
    ptr_buttons: u8,
    ptr_x: u16,
    ptr_y: u16,
    ptr_reports: usize,
};

// ---------------------------------------------------------------------------
// Driver state (pure BSS)
// ---------------------------------------------------------------------------

var armed_global: bool = false;

var fifo: [max_fifo]u8 = undefined;
var fifo_head: usize = 0;
var fifo_count: usize = 0;
var dropped: usize = 0;
var events: usize = 0;

var kb_mods: u8 = 0;
var kb_held: [6]u8 = [_]u8{0} ** 6;
var kb_last_usage: u8 = 0;
var kb_last_byte: u8 = 0;

var ptr_buttons: u8 = 0;
var ptr_x: u16 = 0;
var ptr_y: u16 = 0;
var ptr_reports: usize = 0;
/// Card U4 (claim 4993): the pointer became observable (at least one
/// report) and the click edge (buttons 0 -> nonzero) latches here until
/// the window manager consumes it via `take_click`.
var ptr_valid: bool = false;
var ptr_click_pending: bool = false;
/// Card U5 (claim 0935): the Alt+Tab chord (modifier 0x04/0x40 + Tab
/// usage 0x2b) latches here — the shell idle loop consumes it as a
/// focus-cycle request (ADR 0008 D4's keyboard cycling).
var alt_tab_pending: bool = false;
var alt_tab_shift: bool = false;
/// Arc4 #238: Ctrl+Shift+B lowers the focused window to back.
var lower_back_pending: bool = false;
/// Arc4 #241: Ctrl+F1/F2/F3 switches workspace. 0xff = no switch pending.
var workspace_switch_pending: u8 = 0xff;
/// M21 W4: Alt+` cycles workspaces directly.
var workspace_cycle_pending: bool = false;
/// M21 W1: Ctrl+T toggles tiling mode.
var tile_toggle_pending: bool = false;
/// M21 W2: Ctrl+M swaps master/detail in tiled mode.
var tile_swap_master_pending: bool = false;
/// M21 W3: Ctrl+N minimizes the focused window.
var minimize_pending: bool = false;
/// M21 W6: Ctrl+Shift+M toggles maximize.
var maximize_pending: bool = false;
/// M21 W7: F11 toggles fullscreen.
var fullscreen_pending: bool = false;
/// M21 W8: Ctrl+Shift+T toggles always-on-top.
var always_on_top_pending: bool = false;
/// M27 G2: Ctrl+Shift+A opens about dialog.
var about_pending: bool = false;
/// M21 W10: Alt+arrow movement. 0xff = no movement pending.
var move_pending_dx: i32 = 0;
var move_pending_dy: i32 = 0;
var move_pending_fine: bool = false;

/// Diagnostic hooks (kernel/src/main.zig wires these to uart_puts/uart_hex
/// under `--input`; null in host tests and the default VM).
pub var debug: ?*const fn ([]const u8) void = null;
pub var debug_hex: ?*const fn (u64) void = null;

fn dbg(bytes: []const u8) void {
    if (debug) |d| d(bytes);
}
fn dbg_hex(v: u64) void {
    if (debug_hex) |d| d(v);
}

/// Arm the input path (called by kernel/src/main.zig after the XHCI
/// transport is up and the devices are enumerated). Until armed, `drain()`
/// is a no-op and `pop_byte` returns null.
pub fn arm() void {
    armed_global = true;
}

pub fn armed() bool {
    return armed_global;
}

// ---------------------------------------------------------------------------
// HID-usage → ASCII keymap (pure — host-testable)
// ---------------------------------------------------------------------------

/// Map a HID keyboard boot-protocol usage ID to an ASCII byte, applying
/// shift when set. Returns null for usages outside the usable subset (the
/// card's honest bound: no invented bytes).
pub fn hid_to_ascii(usage: u8, shift: bool) ?u8 {
    if (usage >= 0x04 and usage <= 0x1d) {
        // a..z
        return if (shift) 'A' + (usage - 0x04) else 'a' + (usage - 0x04);
    }
    if (usage >= 0x1e and usage <= 0x27) {
        // 1..0 (the top row)
        const unshifted = "1234567890";
        const shifted = "!@#$%^&*()";
        const i = usage - 0x1e;
        return if (shift) shifted[i] else unshifted[i];
    }
    return switch (usage) {
        0x28 => '\n', // Enter / Return
        0x2a => 0x08, // Backspace
        0x2b => '\t', // Tab
        0x2c => ' ', // Space
        0x2d => if (shift) '_' else '-',
        0x2e => if (shift) '+' else '=',
        0x2f => if (shift) '{' else '[',
        0x30 => if (shift) '}' else ']',
        0x31 => if (shift) '|' else '\\',
        0x33 => if (shift) ':' else ';',
        0x34 => if (shift) '"' else '\'',
        0x35 => if (shift) '~' else '`',
        0x36 => if (shift) '<' else ',',
        0x37 => if (shift) '>' else '.',
        0x38 => if (shift) '?' else '/',
        else => null,
    };
}

/// Decode one HID keyboard usage (with shift/ctrl modifiers) into 0-4
/// bytes of console input, written to `out`; returns the byte count (0 =
/// the usage is outside the usable subset — no bytes are invented). The
/// editing nav cluster arrives as `ESC [ <final>` sequences and ctrl + a-z
/// as the ASCII control codes, both consumed by the line editor (ADR 0008
/// D2); everything else is the printable `hid_to_ascii` mapping.
pub fn hid_to_bytes(usage: u8, shift: bool, ctrl: bool, out: *[max_key_bytes]u8) usize {
    if (ctrl) {
        if (usage >= 0x04 and usage <= 0x1d) {
            out[0] = (usage - 0x04) + 0x01; // Ctrl-A..Ctrl-Z
            return 1;
        }
        return 0;
    }
    switch (usage) {
        0x29 => { // Escape (lone ESC — the line editor treats it as a no-op key)
            out[0] = 0x1b;
            return 1;
        },
        0x4f => { // Right arrow
            out[0] = 0x1b;
            out[1] = '[';
            out[2] = 'C';
            return 3;
        },
        0x50 => { // Left arrow
            out[0] = 0x1b;
            out[1] = '[';
            out[2] = 'D';
            return 3;
        },
        0x51 => { // Down arrow
            out[0] = 0x1b;
            out[1] = '[';
            out[2] = 'B';
            return 3;
        },
        0x52 => { // Up arrow
            out[0] = 0x1b;
            out[1] = '[';
            out[2] = 'A';
            return 3;
        },
        0x4a => { // Home
            out[0] = 0x1b;
            out[1] = '[';
            out[2] = 'H';
            return 3;
        },
        0x4b => { // PageUp (the shell's scroll interceptor consumes CSI 5 ~)
            out[0] = 0x1b;
            out[1] = '[';
            out[2] = '5';
            out[3] = '~';
            return 4;
        },
        0x4d => { // End
            out[0] = 0x1b;
            out[1] = '[';
            out[2] = 'F';
            return 3;
        },
        0x4e => { // PageDown (the shell's scroll interceptor consumes CSI 6 ~)
            out[0] = 0x1b;
            out[1] = '[';
            out[2] = '6';
            out[3] = '~';
            return 4;
        },
        0x4c => { // Delete (forward)
            out[0] = 0x1b;
            out[1] = '[';
            out[2] = '3';
            out[3] = '~';
            return 4;
        },
        else => {},
    }
    if (hid_to_ascii(usage, shift)) |b| {
        out[0] = b;
        return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Bounded byte FIFO (the line-editor feed)
// ---------------------------------------------------------------------------

fn push_byte(b: u8) void {
    if (fifo_count >= max_fifo) {
        dropped += 1;
        return;
    }
    fifo[(fifo_head + fifo_count) % max_fifo] = b;
    fifo_count += 1;
}

/// Pop the next decoded keyboard byte, or null when the FIFO is empty.
/// The Road Pops tee consults this before falling back to serial.
pub fn pop_byte() ?u8 {
    if (fifo_count == 0) return null;
    const b = fifo[fifo_head];
    fifo_head = (fifo_head + 1) % max_fifo;
    fifo_count -= 1;
    return b;
}

// ---------------------------------------------------------------------------
// Arc5 #245: Compose state machine (ADR 0014)
// ---------------------------------------------------------------------------

/// Compose state: IDLE (normal) or WAITING (Alt held, awaiting second key).
const ComposeState = enum { idle, waiting };

/// A single compose pair: two HID usage IDs → Unicode codepoint.
const ComposePair = struct {
    first: u8,
    second: u8,
    codepoint: u21,
};

/// Compile-time compose table: ~27 pairs for common accented characters.
/// Alt + first_key + second_key → Unicode codepoint.
const compose_table = [_]ComposePair{
    // Alt + e + vowel → acute accent
    .{ .first = 0x08, .second = 0x04, .codepoint = 0x00e1 }, // e+a → á
    .{ .first = 0x08, .second = 0x05, .codepoint = 0x00e9 }, // e+e → é
    .{ .first = 0x08, .second = 0x0c, .codepoint = 0x00ed }, // e+i → í
    .{ .first = 0x08, .second = 0x12, .codepoint = 0x00f3 }, // e+o → ó
    .{ .first = 0x08, .second = 0x18, .codepoint = 0x00fa }, // e+u → ú
    // Alt + u + vowel → umlaut
    .{ .first = 0x18, .second = 0x04, .codepoint = 0x00e4 }, // u+a → ä
    .{ .first = 0x18, .second = 0x05, .codepoint = 0x00eb }, // u+e → ë
    .{ .first = 0x18, .second = 0x0c, .codepoint = 0x00ef }, // u+i → ï
    .{ .first = 0x18, .second = 0x12, .codepoint = 0x00f6 }, // u+o → ö
    .{ .first = 0x18, .second = 0x18, .codepoint = 0x00fc }, // u+u → ü
    // Alt + ` + vowel → grave accent
    .{ .first = 0x35, .second = 0x04, .codepoint = 0x00e0 }, // `+a → à
    .{ .first = 0x35, .second = 0x05, .codepoint = 0x00e8 }, // `+e → è
    .{ .first = 0x35, .second = 0x0c, .codepoint = 0x00ec }, // `+i → ì
    .{ .first = 0x35, .second = 0x12, .codepoint = 0x00f2 }, // `+o → ò
    .{ .first = 0x35, .second = 0x18, .codepoint = 0x00f9 }, // `+u → ù
    // Alt + n + n → tilde
    .{ .first = 0x11, .second = 0x11, .codepoint = 0x00f1 }, // n+n → ñ
    // Alt + c → cedilla
    .{ .first = 0x06, .second = 0x06, .codepoint = 0x00e7 }, // c+c → ç
};

/// Current compose state (BSS, bounded, no allocation).
var compose_state: ComposeState = .idle;
/// The first key of a pending compose sequence (HID usage).
var compose_first: u8 = 0;

/// Look up a compose pair in the table. Returns the Unicode codepoint or null.
fn compose_lookup(first: u8, second: u8) ?u21 {
    for (compose_table) |pair| {
        if (pair.first == first and pair.second == second) return pair.codepoint;
    }
    return null;
}

/// Reset compose state (called on Alt release or focus change).
pub fn compose_reset() void {
    compose_state = .idle;
}

/// List all compose sequences for the `compose` monitor command.
pub fn compose_list(con: anytype) void {
    con.print_line("compose: Alt + key1 + key2 → Unicode codepoint");
    for (compose_table) |pair| {
        con.puts("  Alt+");
        con.puts(&[_]u8{hid_to_ascii(pair.first, false) orelse '?'});
        con.puts("+");
        con.puts(&[_]u8{hid_to_ascii(pair.second, false) orelse '?'});
        con.puts(" → U+");
        var buf: [4]u8 = undefined;
        var v = pair.codepoint;
        var i: usize = 4;
        while (i > 0) : (i -= 1) {
            const nib = @as(u8, @intCast(v & 0xf));
            buf[i - 1] = if (nib < 10) '0' + nib else 'a' + nib - 10;
            v >>= 4;
        }
        con.print_line(&buf);
    }
}

// ---------------------------------------------------------------------------
// Report decode (keyboard boot report + best-effort absolute pointer)
// ---------------------------------------------------------------------------

/// Map raw HID keyboard boot report modifier byte to ADR 0009 modifier flags.
pub fn hid_modifiers_to_flags(mods: u8) u16 {
    var flags: u16 = 0;
    if ((mods & mod_lshift) != 0 or (mods & mod_rshift) != 0) flags |= app_events.MOD_SHIFT;
    if ((mods & mod_lctrl) != 0 or (mods & mod_rctrl) != 0) flags |= app_events.MOD_CTRL;
    if ((mods & 0x04) != 0 or (mods & 0x40) != 0) flags |= app_events.MOD_ALT;
    if ((mods & 0x08) != 0 or (mods & 0x80) != 0) flags |= app_events.MOD_CMD;
    return flags;
}

/// Decode an 8-byte HID keyboard boot report: byte 0 = modifier, bytes 2-7
/// = up to six held keycodes (the boot protocol's rollover limit). A keycode
/// present now but not in the previously-held set is a key-DOWN; its ASCII
/// byte (shift applied) is pushed. The held set is then updated.
/// Card E2 (claim 7206): when a user window is focused, KEY_DOWN / KEY_UP
/// events are pushed to the owning process's event queue.
pub fn decode_keyboard_report(rep: []const u8) void {
    if (rep.len < 8) return;
    const mods = rep[0];
    const flags = hid_modifiers_to_flags(mods);
    const shift = (flags & app_events.MOD_SHIFT) != 0;
    const ctrl = (flags & app_events.MOD_CTRL) != 0;
    const alt = (flags & app_events.MOD_ALT) != 0;
    kb_mods = mods;
    var keys: [6]u8 = [_]u8{0} ** 6;
    for (rep[2..8], 0..) |k, i| keys[i] = k; // Card U5 (ADR 0008 D4): Alt+Tab cycles window focus — the
    // chord is consumed as a window-manager signal across all windows.
    // C2 (M15): capture Shift for reverse cycling.
    for (keys) |k| {
        if (k == 0x2b and alt) {
            var held = false;
            for (kb_held) |h| {
                if (h == k) {
                    held = true;
                    break;
                }
            }
            if (!held) {
                alt_tab_pending = true;
                alt_tab_shift = shift;
            }
        }
        // M21 W4: Alt+` (backtick, usage 0x35) cycles workspaces.
        if (k == 0x35 and alt) {
            var held = false;
            for (kb_held) |h| {
                if (h == k) {
                    held = true;
                    break;
                }
            }
            if (!held) {
                workspace_cycle_pending = true;
            }
        }
        // Arc4 #238: Ctrl+Shift+B lowers focused window to back.
        if (k == 0x05 and (flags & app_events.MOD_CTRL) != 0 and (flags & app_events.MOD_SHIFT) != 0) {
            var held = false;
            for (kb_held) |h| {
                if (h == k) {
                    held = true;
                    break;
                }
            }
            if (!held) {
                lower_back_pending = true;
            }
        }
        // Arc4 #241: Ctrl+F1/F2/F3 switches workspace.
        if ((flags & app_events.MOD_CTRL) != 0) {
            var ws: u8 = 0xff;
            if (k == 0x58) ws = 0; // F1
            if (k == 0x59) ws = 1; // F2
            if (k == 0x5a) ws = 2; // F3
            if (ws != 0xff) {
                var held = false;
                for (kb_held) |h| {
                    if (h == k) {
                        held = true;
                        break;
                    }
                }
                if (!held) {
                    workspace_switch_pending = ws;
                }
            }
            // M21 W1: Ctrl+T toggles tiling mode.
            if (k == 0x17) { // 't' usage
                var held = false;
                for (kb_held) |h| {
                    if (h == k) {
                        held = true;
                        break;
                    }
                }
                if (!held) {
                    tile_toggle_pending = true;
                }
            }
            // M21 W2: Ctrl+M swaps master/detail in tiled mode.
            if (k == 0x10) { // 'm' usage
                var held = false;
                for (kb_held) |h| {
                    if (h == k) {
                        held = true;
                        break;
                    }
                }
                if (!held) {
                    tile_swap_master_pending = true;
                }
            }
            // M21 W3: Ctrl+N minimizes the focused window.
            if (k == 0x11) { // 'n' usage
                var held = false;
                for (kb_held) |h| {
                    if (h == k) {
                        held = true;
                        break;
                    }
                }
                if (!held) {
                    minimize_pending = true;
                }
            }
            // M21 W6: Ctrl+Shift+M toggles maximize.
            if (k == 0x10 and (flags & app_events.MOD_SHIFT) != 0) { // 'm' + Shift
                var held = false;
                for (kb_held) |h| {
                    if (h == k) {
                        held = true;
                        break;
                    }
                }
                if (!held) {
                    maximize_pending = true;
                }
            }
            // M21 W8: Ctrl+Shift+T toggles always-on-top.
            if (k == 0x17 and (flags & app_events.MOD_SHIFT) != 0) { // 't' + Shift
                var held = false;
                for (kb_held) |h| {
                    if (h == k) {
                        held = true;
                        break;
                    }
                }
                if (!held) {
                    always_on_top_pending = true;
                }
            }
            // M27 G2: Ctrl+Shift+A opens about dialog.
            if (k == 0x04 and (flags & app_events.MOD_SHIFT) != 0) { // 'a' + Shift
                var held = false;
                for (kb_held) |h| {
                    if (h == k) {
                        held = true;
                        break;
                    }
                }
                if (!held) {
                    about_pending = true;
                }
            }
        }
        // M21 W7: F11 (usage 0x5c) toggles fullscreen.
        if (k == 0x5c) {
            var held = false;
            for (kb_held) |h| {
                if (h == k) {
                    held = true;
                    break;
                }
            }
            if (!held) {
                fullscreen_pending = true;
            }
        }
        // M21 W10: Alt+arrow for keyboard window movement.
        if (alt) {
            var dx: i32 = 0;
            var dy: i32 = 0;
            if (k == 0x4f) dx = 16; // Right arrow
            if (k == 0x50) dx = -16; // Left arrow
            if (k == 0x52) dy = -16; // Up arrow
            if (k == 0x51) dy = 16; // Down arrow
            if (dx != 0 or dy != 0) {
                var held = false;
                for (kb_held) |h| {
                    if (h == k) {
                        held = true;
                        break;
                    }
                }
                if (!held) {
                    // Alt+Shift = fine movement (1px).
                    move_pending_dx = if (shift) @divTrunc(dx, 16) else dx;
                    move_pending_dy = if (shift) @divTrunc(dy, 16) else dy;
                    move_pending_fine = shift;
                }
            }
        }
    }

    if (driving_award.focused_owner()) |owner_pid| {
        // Milestone 9 Card E2: Route keyboard events to focused user window process!
        // 1. Key DOWN: keys present now but not in kb_held
        for (keys) |k| {
            if (k == 0) continue;
            var held = false;
            for (kb_held) |h| {
                if (h == k) {
                    held = true;
                    break;
                }
            }
            if (!held) {
                kb_last_usage = k;
                const ascii_char: u32 = if (hid_to_ascii(k, shift)) |ch| ch else 0;
                // Arc5 #245: Compose state machine (ADR 0014).
                // When Alt is held, route through compose logic instead of
                // immediately dispatching KEY_DOWN.
                if (alt and k != 0 and compose_state == .idle) {
                    // Alt + key: start compose sequence (save pending event).
                    compose_state = .waiting;
                    compose_first = k;
                } else if (compose_state == .waiting) {
                    // Second key of compose sequence: look up the pair.
                    const cp = compose_lookup(compose_first, k);
                    compose_state = .idle;
                    if (cp) |codepoint| {
                        // Compose match: dispatch KEY_DOWN with Unicode codepoint.
                        app_events.push(owner_pid, .{
                            .kind = app_events.KEY_DOWN,
                            .flags = flags,
                            .seq = 0,
                            .arg0 = k,
                            .arg1 = codepoint,
                        });
                        events += 1;
                    } else {
                        // Compose miss: dispatch both keys as normal KEY_DOWN.
                        const first_ascii: u32 = if (hid_to_ascii(compose_first, shift)) |ch| ch else 0;
                        app_events.push(owner_pid, .{
                            .kind = app_events.KEY_DOWN,
                            .flags = flags,
                            .seq = 0,
                            .arg0 = compose_first,
                            .arg1 = first_ascii,
                        });
                        events += 1;
                        app_events.push(owner_pid, .{
                            .kind = app_events.KEY_DOWN,
                            .flags = flags,
                            .seq = 0,
                            .arg0 = k,
                            .arg1 = ascii_char,
                        });
                        events += 1;
                    }
                } else {
                    // Normal KEY_DOWN: no compose active.
                    app_events.push(owner_pid, .{
                        .kind = app_events.KEY_DOWN,
                        .flags = flags,
                        .seq = 0,
                        .arg0 = k,
                        .arg1 = ascii_char,
                    });
                    events += 1;
                }
                // Arc4 #236: translate PageUp/PageDown to MOUSE_SCROLL events.
                // On VZ the absolute pointer has no wheel byte, so this is the
                // working scroll path. ScrollView/HScrollBar consume kind 12.
                if (k == 0x4b) { // PageUp
                    // Packed arg0: magnitude=1, sign=0 (scroll up).
                    app_events.push(owner_pid, .{
                        .kind = app_events.MOUSE_SCROLL,
                        .flags = 0,
                        .seq = 0,
                        .arg0 = 1, // magnitude=1, bit15=0 (up)
                        .arg1 = 0,
                    });
                    events += 1;
                } else if (k == 0x4e) { // PageDown
                    // Packed arg0: magnitude=1, sign=1 (scroll down).
                    app_events.push(owner_pid, .{
                        .kind = app_events.MOUSE_SCROLL,
                        .flags = 0,
                        .seq = 0,
                        .arg0 = 0x8001, // magnitude=1, bit15=1 (down)
                        .arg1 = 0,
                    });
                    events += 1;
                }
            }
        }
        // 2. Key UP: keys in kb_held but not in keys now
        for (kb_held) |h| {
            if (h == 0) continue;
            var still_held = false;
            for (keys) |k| {
                if (k == h) {
                    still_held = true;
                    break;
                }
            }
            if (!still_held) {
                const ascii_char: u32 = if (hid_to_ascii(h, shift)) |ch| ch else 0;
                app_events.push(owner_pid, .{
                    .kind = app_events.KEY_UP,
                    .flags = flags,
                    .seq = 0,
                    .arg0 = h,
                    .arg1 = ascii_char,
                });
            }
        }
    } else {
        // Terminal / console route (existing behavior)
        for (keys) |k| {
            if (k == 0) continue;
            var held = false;
            for (kb_held) |h| {
                if (h == k) {
                    held = true;
                    break;
                }
            }
            if (!held) {
                kb_last_usage = k;
                if (alt and k == 0x2b) {
                    continue;
                }
                var out: [max_key_bytes]u8 = undefined;
                const n = hid_to_bytes(k, shift, ctrl, &out);
                if (n > 0) {
                    kb_last_byte = out[n - 1]; // the sequence's final byte
                    var i: usize = 0;
                    while (i < n) : (i += 1) push_byte(out[i]);
                    events += 1;
                }
            }
        }
    }
    kb_held = keys;
}

/// Record a pointer report (best-effort absolute decode: buttons + little-
/// endian X/Y). The raw bytes are the ground truth; the absolute report's
/// exact word order is a claim-time observation, recorded honestly.
fn record_pointer_report(rep: []const u8) void {
    if (rep.len < 3) return;
    const prev_buttons = ptr_buttons;
    ptr_buttons = rep[0];
    ptr_x = @as(u16, rep[1]) | (@as(u16, rep[2]) << 8);
    if (rep.len >= 5) {
        ptr_y = @as(u16, rep[3]) | (@as(u16, rep[4]) << 8);
    }
    ptr_reports += 1;
    ptr_valid = true;
    if (prev_buttons == 0 and (ptr_buttons & 0x01) != 0) ptr_click_pending = true;
}

/// The shell-idle-loop drain: poll each enumerated device's interrupt-IN
/// endpoint for a completed report, decode it, and (for the keyboard) push
/// the decoded bytes. No-op when unarmed (default VM / host tests).
pub fn drain() void {
    if (!armed_global) return;
    var i: usize = 0;
    while (i < xhci.EnumMax) : (i += 1) {
        const d = xhci.enum_devs[i];
        if (!d.present or d.ep_in_num == 0) continue;
        // Non-blocking: a no-pending-event poll is one cheap event-ring
        // read, so the idle loop is not slowed by the blocking budget
        // (`usb report` keeps the blocking path).
        if (xhci.xhci_poll_intr_nb(d.slot_id)) {
            const rep = xhci.xhci_report(d.slot_id);
            const bytes = rep.bytes[0..rep.len];
            switch (xhci.hid_kind[i]) {
                .keyboard => decode_keyboard_report(bytes),
                // The absolute pointer enumerates with bInterfaceProtocol 0
                // (not a boot mouse), so hid_kind is .unknown — the raw
                // report is still recorded best-effort.
                .mouse, .unknown => record_pointer_report(bytes),
            }
        }
    }
}

pub fn report() Report {
    return .{
        .armed = armed_global,
        .fifo_used = fifo_count,
        .fifo_max = max_fifo,
        .dropped = dropped,
        .events = events,
        .kb_mods = kb_mods,
        .kb_last_usage = kb_last_usage,
        .kb_last_byte = kb_last_byte,
        .ptr_buttons = ptr_buttons,
        .ptr_x = ptr_x,
        .ptr_y = ptr_y,
        .ptr_reports = ptr_reports,
    };
}

/// Card U4 (claim 4993): the pointer snapshot for the window manager.
pub const PointerState = struct { x: u16, y: u16, buttons: u8, valid: bool };
pub fn pointer_state() PointerState {
    return .{ .x = ptr_x, .y = ptr_y, .buttons = ptr_buttons, .valid = ptr_valid };
}

/// Card U4: a consumed click edge (the pointer cell, HID logical units).
pub const Click = struct { x: u16, y: u16 };

/// Consume the latched click edge (buttons 0 -> nonzero). Returns the
/// click's pointer cell or null when no click is pending.
pub fn take_click() ?Click {
    if (!ptr_click_pending) return null;
    ptr_click_pending = false;
    return .{ .x = ptr_x, .y = ptr_y };
}

/// Card U5: consume the Alt+Tab chord edge.
pub fn take_alt_tab() bool {
    if (take_alt_tab_shift() != null) return true;
    return false;
}

/// C2 (M15): Alt still held (either left 0x04 or right 0x40).
pub fn alt_held() bool {
    return (kb_mods & 0x04) != 0 or (kb_mods & 0x40) != 0;
}

/// C2 (M15): consume the Alt+Tab edge with Shift direction — null if no edge, else `true` if Shift+Tab (reverse), `false` if plain Tab.
pub fn take_alt_tab_shift() ?bool {
    if (!alt_tab_pending) return null;
    alt_tab_pending = false;
    const s = alt_tab_shift;
    alt_tab_shift = false;
    return s;
}

/// Arc4 #238: consume the Ctrl+Shift+B chord edge.
pub fn take_lower_back() bool {
    if (!lower_back_pending) return false;
    lower_back_pending = false;
    return true;
}

/// Arc4 #241: consume the Ctrl+F1/F2/F3 workspace switch edge.
pub fn take_workspace_switch() ?u8 {
    if (workspace_switch_pending == 0xff) return null;
    const ws = workspace_switch_pending;
    workspace_switch_pending = 0xff;
    return ws;
}

/// M21 W1: consume the Ctrl+T tiling toggle edge.
pub fn take_tile_toggle() bool {
    if (!tile_toggle_pending) return false;
    tile_toggle_pending = false;
    return true;
}

/// M21 W2: consume the Ctrl+M master swap edge.
pub fn take_tile_swap_master() bool {
    if (!tile_swap_master_pending) return false;
    tile_swap_master_pending = false;
    return true;
}

/// M21 W3: consume the Ctrl+N minimize edge.
pub fn take_minimize() bool {
    if (!minimize_pending) return false;
    minimize_pending = false;
    return true;
}

/// M21 W4: consume the Alt+` workspace cycle edge.
pub fn take_workspace_cycle() bool {
    if (!workspace_cycle_pending) return false;
    workspace_cycle_pending = false;
    return true;
}

/// M21 W6: consume the Ctrl+Shift+M maximize toggle edge.
pub fn take_maximize() bool {
    if (!maximize_pending) return false;
    maximize_pending = false;
    return true;
}

/// M21 W7: consume the F11 fullscreen toggle edge.
pub fn take_fullscreen() bool {
    if (!fullscreen_pending) return false;
    fullscreen_pending = false;
    return true;
}

/// M21 W8: consume the Ctrl+Shift+T always-on-top toggle edge.
pub fn take_always_on_top() bool {
    if (!always_on_top_pending) return false;
    always_on_top_pending = false;
    return true;
}

/// M27 G2: consume the Ctrl+Shift+A about dialog edge.
pub fn take_about() bool {
    if (!about_pending) return false;
    about_pending = false;
    return true;
}

pub const MoveDelta = struct { dx: i32, dy: i32 };

/// M21 W10: consume the Alt+arrow movement edge. Returns (dx, dy) or
/// null if no movement is pending.
pub fn take_move() ?MoveDelta {
    if (move_pending_dx == 0 and move_pending_dy == 0) return null;
    const result = MoveDelta{ .dx = move_pending_dx, .dy = move_pending_dy };
    move_pending_dx = 0;
    move_pending_dy = 0;
    return result;
}

// ---------------------------------------------------------------------------
// Tests (host-side; pure surface, no hardware)
// ---------------------------------------------------------------------------

test "input: hid_to_ascii maps the usable subset (unshifted + shifted)" {
    try std.testing.expectEqual(@as(?u8, 'a'), hid_to_ascii(0x04, false));
    try std.testing.expectEqual(@as(?u8, 'A'), hid_to_ascii(0x04, true));
    try std.testing.expectEqual(@as(?u8, 'z'), hid_to_ascii(0x1d, false));
    try std.testing.expectEqual(@as(?u8, 'Z'), hid_to_ascii(0x1d, true));
    try std.testing.expectEqual(@as(?u8, '1'), hid_to_ascii(0x1e, false));
    try std.testing.expectEqual(@as(?u8, '!'), hid_to_ascii(0x1e, true));
    try std.testing.expectEqual(@as(?u8, '0'), hid_to_ascii(0x27, false));
    try std.testing.expectEqual(@as(?u8, ')'), hid_to_ascii(0x27, true));
    try std.testing.expectEqual(@as(?u8, '\n'), hid_to_ascii(0x28, false));
    try std.testing.expectEqual(@as(?u8, ' '), hid_to_ascii(0x2c, false));
    try std.testing.expectEqual(@as(?u8, '-'), hid_to_ascii(0x2d, false));
    try std.testing.expectEqual(@as(?u8, '_'), hid_to_ascii(0x2d, true));
    try std.testing.expectEqual(@as(?u8, 0x08), hid_to_ascii(0x2a, false));
}

test "input: usages outside the usable subset are refused (no invented bytes)" {
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0x00, false));
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0x29, false)); // Escape
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0x39, false)); // Caps Lock
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0x4c, false)); // Pause
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0xe0, false)); // Left Ctrl
}

test "input: hid_to_bytes maps the nav cluster to ESC sequences" {
    var out: [max_key_bytes]u8 = undefined;
    // Up arrow -> ESC [ A (3 bytes).
    var n = hid_to_bytes(0x52, false, false, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u8, "\x1b[A", out[0..n]);
    // Left arrow -> ESC [ D.
    n = hid_to_bytes(0x50, false, false, &out);
    try std.testing.expectEqualSlices(u8, "\x1b[D", out[0..n]);
    // End -> ESC [ F; Delete -> ESC [ 3 ~ (4 bytes).
    n = hid_to_bytes(0x4d, false, false, &out);
    try std.testing.expectEqualSlices(u8, "\x1b[F", out[0..n]);
    n = hid_to_bytes(0x4c, false, false, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(u8, "\x1b[3~", out[0..n]);
    // PageUp -> ESC [ 5 ~, PageDown -> ESC [ 6 ~ (4 bytes each) — the
    // shell's scroll interceptor consumes these (M18 T1).
    n = hid_to_bytes(0x4b, false, false, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(u8, "\x1b[5~", out[0..n]);
    n = hid_to_bytes(0x4e, false, false, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(u8, "\x1b[6~", out[0..n]);
    // Escape -> a lone ESC byte (the line editor treats it as a no-op).
    n = hid_to_bytes(0x29, false, false, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x1b), out[0]);
    // Not a printable, not a nav key: no bytes invented.
    try std.testing.expectEqual(@as(usize, 0), hid_to_bytes(0x39, false, false, &out)); // Caps Lock
}

test "input: hid_to_bytes maps ctrl+a-z to ASCII control codes" {
    var out: [max_key_bytes]u8 = undefined;
    // Ctrl-A (usage 0x04) -> 0x01; Ctrl-C (usage 0x06) -> 0x03; Ctrl-Z -> 0x1a.
    try std.testing.expectEqual(@as(usize, 1), hid_to_bytes(0x04, false, true, &out));
    try std.testing.expectEqual(@as(u8, 0x01), out[0]);
    try std.testing.expectEqual(@as(usize, 1), hid_to_bytes(0x06, false, true, &out));
    try std.testing.expectEqual(@as(u8, 0x03), out[0]);
    try std.testing.expectEqual(@as(usize, 1), hid_to_bytes(0x1d, false, true, &out));
    try std.testing.expectEqual(@as(u8, 0x1a), out[0]);
    // Ctrl + non-letter is outside the usable subset (no invented bytes).
    try std.testing.expectEqual(@as(usize, 0), hid_to_bytes(0x28, false, true, &out)); // Ctrl+Enter
}

test "input: keyboard report decode pushes a ctrl chord and an arrow sequence" {
    _ = driving_award.focus(0);
    fifo_count = 0;
    fifo_head = 0;
    events = 0;
    kb_held = [_]u8{0} ** 6;
    // Left Ctrl (0x01) held + 'a' (usage 0x04) pressed -> 0x01 (Ctrl-A).
    decode_keyboard_report(&[_]u8{ 0x01, 0, 0x04, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 1), fifo_count);
    try std.testing.expectEqual(@as(u8, 0x01), pop_byte().?);
    // Release; then Up arrow (usage 0x52) -> ESC [ A (3 bytes).
    decode_keyboard_report(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
    decode_keyboard_report(&[_]u8{ 0, 0, 0x52, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 3), fifo_count);
    try std.testing.expectEqual(@as(u8, 0x1b), pop_byte().?);
    try std.testing.expectEqual(@as(u8, '['), pop_byte().?);
    try std.testing.expectEqual(@as(u8, 'A'), pop_byte().?);
    try std.testing.expectEqual(@as(?u8, null), pop_byte());
    try std.testing.expectEqual(@as(usize, 2), events);
}

test "input: keyboard report decode pushes key-down bytes with shift" {
    // Reset the module state (host tests share the globals).
    _ = driving_award.focus(0);
    fifo_count = 0;
    fifo_head = 0;
    events = 0;
    dropped = 0;
    kb_held = [_]u8{0} ** 6;
    // Shift held + 'I' key (usage 0x0c) pressed: byte 0 = 0x02 (left shift),
    // byte 2 = 0x0c.
    decode_keyboard_report(&[_]u8{ 0x02, 0, 0x0c, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 1), fifo_count);
    try std.testing.expectEqual(@as(u8, 'I'), pop_byte().?);
    try std.testing.expectEqual(@as(?u8, null), pop_byte());
    try std.testing.expectEqual(@as(usize, 1), events);
    // Key released: no new key-down, no new byte.
    decode_keyboard_report(&[_]u8{ 0x02, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), fifo_count);
}

test "input: a held key does not re-fire (no repeat on unchanged report)" {
    _ = driving_award.focus(0);
    fifo_count = 0;
    fifo_head = 0;
    events = 0;
    kb_held = [_]u8{0} ** 6;
    const pressed = [_]u8{ 0, 0, 0x04, 0, 0, 0, 0, 0 }; // 'a' held
    decode_keyboard_report(&pressed);
    decode_keyboard_report(&pressed); // unchanged → no second push
    try std.testing.expectEqual(@as(usize, 1), fifo_count);
    try std.testing.expectEqual(@as(u8, 'a'), pop_byte().?);
    try std.testing.expectEqual(@as(?u8, null), pop_byte());
    try std.testing.expectEqual(@as(usize, 1), events);
}

test "input: FIFO is bounded and drops on overflow, never wrapping" {
    fifo_count = 0;
    fifo_head = 0;
    dropped = 0;
    var i: usize = 0;
    while (i < max_fifo + 3) : (i += 1) push_byte('x');
    try std.testing.expectEqual(@as(usize, max_fifo), fifo_count);
    try std.testing.expectEqual(@as(usize, 3), dropped);
    // Drains exactly the first max_fifo bytes in order.
    var n: usize = 0;
    while (pop_byte()) |b| {
        try std.testing.expectEqual(@as(u8, 'x'), b);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, max_fifo), n);
}

test "input: pointer report is recorded best-effort (buttons + LE X/Y)" {
    ptr_buttons = 0;
    ptr_x = 0;
    ptr_y = 0;
    ptr_reports = 0;
    record_pointer_report(&[_]u8{ 0x01, 0x34, 0x12, 0x78, 0x56 });
    try std.testing.expectEqual(@as(u8, 0x01), ptr_buttons);
    try std.testing.expectEqual(@as(u16, 0x1234), ptr_x);
    try std.testing.expectEqual(@as(u16, 0x5678), ptr_y);
    try std.testing.expectEqual(@as(usize, 1), ptr_reports);
}

test "input: drain is a no-op when unarmed" {
    armed_global = false;
    const before = fifo_count;
    drain();
    try std.testing.expectEqual(before, fifo_count);
    try std.testing.expect(!report().armed);
    armed_global = true;
    try std.testing.expect(report().armed);
    armed_global = false;
}

test "input: hid_modifiers_to_flags maps modifiers to ADR 0009 bitmasks" {
    try std.testing.expectEqual(@as(u16, 0), hid_modifiers_to_flags(0));
    try std.testing.expectEqual(app_events.MOD_SHIFT, hid_modifiers_to_flags(0x02)); // left shift
    try std.testing.expectEqual(app_events.MOD_SHIFT, hid_modifiers_to_flags(0x20)); // right shift
    try std.testing.expectEqual(app_events.MOD_CTRL, hid_modifiers_to_flags(0x01)); // left ctrl
    try std.testing.expectEqual(app_events.MOD_CTRL, hid_modifiers_to_flags(0x10)); // right ctrl
    try std.testing.expectEqual(app_events.MOD_ALT, hid_modifiers_to_flags(0x04)); // left alt
    try std.testing.expectEqual(app_events.MOD_ALT, hid_modifiers_to_flags(0x40)); // right alt
    try std.testing.expectEqual(app_events.MOD_CMD, hid_modifiers_to_flags(0x08)); // left cmd
    try std.testing.expectEqual(app_events.MOD_CMD, hid_modifiers_to_flags(0x80)); // right cmd
    try std.testing.expectEqual(app_events.MOD_SHIFT | app_events.MOD_CTRL | app_events.MOD_ALT | app_events.MOD_CMD, hid_modifiers_to_flags(0x02 | 0x01 | 0x04 | 0x08));
}

test "input: keyboard routing delivers KEY_DOWN and KEY_UP events to focused user window" {
    app_events.init();
    driving_award.arm();
    // Open a user window owned by pid 2 (delivers WIN_FOCUS)
    const res = driving_award.user_open(10, 10, 100, 100, 2);
    try std.testing.expect(res == .opened);
    const win_id = res.opened;
    try std.testing.expectEqual(@as(?usize, 2), driving_award.focused_owner());
    _ = app_events.pop(2); // Consume WIN_FOCUS

    fifo_count = 0;
    fifo_head = 0;
    kb_held = [_]u8{0} ** 6;

    // Press 'a' (usage 0x04) with left shift (0x02)
    decode_keyboard_report(&[_]u8{ 0x02, 0, 0x04, 0, 0, 0, 0, 0 });
    // Terminal FIFO is untouched
    try std.testing.expectEqual(@as(usize, 0), fifo_count);

    // Event queue for pid 2 receives KEY_DOWN
    try std.testing.expectEqual(@as(usize, 1), app_events.pending(2));
    const ev1 = app_events.pop(2).?;
    try std.testing.expectEqual(app_events.KEY_DOWN, ev1.kind);
    try std.testing.expectEqual(app_events.MOD_SHIFT, ev1.flags);
    try std.testing.expectEqual(@as(u32, 0x04), ev1.arg0);
    try std.testing.expectEqual(@as(u32, 'A'), ev1.arg1);

    // Release 'a'
    decode_keyboard_report(&[_]u8{ 0x02, 0, 0, 0, 0, 0, 0, 0 });
    // Event queue for pid 2 receives KEY_UP
    try std.testing.expectEqual(@as(usize, 1), app_events.pending(2));
    const ev2 = app_events.pop(2).?;
    try std.testing.expectEqual(app_events.KEY_UP, ev2.kind);
    try std.testing.expectEqual(app_events.MOD_SHIFT, ev2.flags);
    try std.testing.expectEqual(@as(u32, 0x04), ev2.arg0);
    try std.testing.expectEqual(@as(u32, 'A'), ev2.arg1);

    // Clean up window
    _ = driving_award.user_close(win_id);
}
