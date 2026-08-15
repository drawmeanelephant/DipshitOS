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
        0x4d => { // End
            out[0] = 0x1b;
            out[1] = '[';
            out[2] = 'F';
            return 3;
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
// Report decode (keyboard boot report + best-effort absolute pointer)
// ---------------------------------------------------------------------------

/// Decode an 8-byte HID keyboard boot report: byte 0 = modifier, bytes 2-7
/// = up to six held keycodes (the boot protocol's rollover limit). A keycode
/// present now but not in the previously-held set is a key-DOWN; its ASCII
/// byte (shift applied) is pushed. The held set is then updated.
fn decode_keyboard_report(rep: []const u8) void {
    if (rep.len < 8) return;
    const mods = rep[0];
    const shift = (mods & mod_lshift) != 0 or (mods & mod_rshift) != 0;
    const ctrl = (mods & mod_lctrl) != 0 or (mods & mod_rctrl) != 0;
    kb_mods = mods;
    var keys: [6]u8 = [_]u8{0} ** 6;
    for (rep[2..8], 0..) |k, i| keys[i] = k;
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
    kb_held = keys;
}

/// Record a pointer report (best-effort absolute decode: buttons + little-
/// endian X/Y). The raw bytes are the ground truth; the absolute report's
/// exact word order is a claim-time observation, recorded honestly.
fn record_pointer_report(rep: []const u8) void {
    if (rep.len < 3) return;
    ptr_buttons = rep[0];
    ptr_x = @as(u16, rep[1]) | (@as(u16, rep[2]) << 8);
    if (rep.len >= 5) {
        ptr_y = @as(u16, rep[3]) | (@as(u16, rep[4]) << 8);
    }
    ptr_reports += 1;
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
