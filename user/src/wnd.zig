//! VirelaiOS M32 WMS3+WMS5 — WND.BIN, the long-lived EL0 window-manager SERVER
//! (issues #623/#625).
//!
//! WMS3 (issue #623): REGISTERs via `sys_wmctl` (slot 65, cmd 1) at startup,
//! then loops on `sys_wait_event` (slot 22), servicing the kernel's kind-18
//! `COMPOSITE_TICK` and issuing `REQUEST_PRESENT` (slot 65, cmd 3) at its OWN
//! cadence (every `present_every` ticks, not every tick). While it is
//! registered the shell idle drain is a no-op (WMS2), so THIS loop drives the
//! desktop's scanout presents.
//!
//! WMS5 (issue #625): the registered WM owns INPUT — the kernel fans the raw
//! pointer stream (kind 19 WM_POINTER), the window-registry mirrors (kind 20
//! WM_WINDOW), and — Gate 2 (claim 4278) — the raw keyboard stream (kind 21
//! WM_KEY) out to this process, and stops consuming geometry itself. This
//! server hit-tests and DECIDES geometry:
//!   * drag-to-move from kind 19 (title-bar grab -> SET_WINDOW rects);
//!   * snap-on-drop (a drag ending near a scanout edge issues the snapped rect);
//!   * tile / master-swap, minimize/restore, maximize/restore, workspace
//!     switch/cycle, fullscreen, always-on-top from kind 21 chords — all
//!     issued through SET_WINDOW (cmd 2) rects + SET_STATE (cmd 4) state, the
//!     frozen ADR 0007 encoding. The kernel clamps + blits whatever it gets.
//!
//! It NEVER exits — it occupies its scheduler slot + process row for the whole
//! session, like COUNTER.BIN/PEER.BIN. The loop is a draining server: each
//! wake (a `sys_wait_event` return) serves the WHOLE queued backlog, then the
//! next `sys_wait_event` parks it until the kernel pushes more — bounded work
//! per wake, and a blocked-in-wait rings around a hung one stalling the ring.
//! The kernel round-robins every tick regardless (the WMS2 exit fallback
//! covers the WM being killed; blocking-in-wait covers a hung one).
//!
//! The pure policy RULES it issues are compiled from the SAME source as the
//! kernel shim (`kernel/src/wnd_core.zig`, the drift guard) — the tile/snap/
//! maximize rect math and the chrome policy are one physical file, so the two
//! implementations cannot behaviorally drift while both are live.
//!
//! Written as a real Zig program (freestanding, no libc/POSIX) with inline
//! `svc` syscall wrappers — the payload grew past the WMS3-era naked-asm
//! pacing loop once policy landed (Gate 2). It imports mutable globals, so it
//! is built through the segmented DSK3 loader path (`linker-segmented.ld` +
//! `elf2bin.py --segments`) exactly like GLOBALS.BIN. The markers it writes
//! are pinned `pub const`s so host tests and the live gates' grep targets
//! cannot drift.

const std = @import("std");
// The drift guard: BOTH the kernel shim and this WM server compile the same
// pure rules from one file — the two implementations cannot behaviorally
// drift while both are live. Provided by build.zig as an anonymous import
// (the kernel compiles the same file from kernel/src/wnd_core.zig).
const wnd_core = @import("wnd_core");
pub const ui = @import("lib/ui.zig");
pub const sexiburger = @import("lib/sexiburger.zig");
pub const Command = sexiburger.Command;
pub const SectionId = sexiburger.SectionId;
pub const ActionRegistry = sexiburger.ActionRegistry;
pub const SexiburgerMenu = sexiburger.SexiburgerMenu;
pub const Rect = ui.Rect;

// ---------------------------------------------------------------------------
// Syscall numbers (slots frozen in ADR 0007; the same numbers the naked
// payload used — no new syscalls).
// ---------------------------------------------------------------------------
const sys_write: u64 = 1;
const sys_yield_num: u64 = 2;
const sys_wait_event_num: u64 = 22;
const sys_wmctl: u64 = 65;

// Slot-65 subcommands (ADR 0007 — frozen by WMS1/claim 1484, extended by
// WMS4 (cmd 2 chrome) and WMS5 Gate 2 (cmd 4 SET_STATE)).
const wmctl_register: u64 = 1;
const wmctl_set_window: u64 = 2;
const wmctl_request_present: u64 = 3;
const wmctl_set_state: u64 = 4;
const wmctl_alt_tab: u64 = 5;
/// ALT_TAB action 3 (commit) — the WM tells the kernel which window to
/// focus+raise+dismiss to. The kernel clamps + repaints the overlay blit.
const alt_tab_commit: u64 = 3;
// WMS6 Gate B (issue #626): the notification-center decision channel.
// NOTIF_CENTER (cmd 6) a0 = 0 close / 1 open / 2 clear-all; NOTIF_DISMISS
// (cmd 7) a0 = row index. The kernel clamps + blits from its own state.
const wmctl_notif_center: u64 = 6;
const notif_close_act: u64 = 0;
const notif_open_act: u64 = 1;
const notif_clear_act: u64 = 2;
const wmctl_notif_dismiss: u64 = 7;
// WMS6 Gate C (issue #626): the tooltip decision channel. TOOLTIP (cmd 8)
// a0 = 0 hide / 1 show (text via ptr/len, the 32-byte M27 bound). The WM
// decides when/what; the kernel clamps + blits below its own cursor.
const wmctl_tooltip: u64 = 8;
const tooltip_show_act: u64 = 1;
const tooltip_hide_act: u64 = 0;
// WMS6 Gate D (issue #626): the dock decision channel. DOCK (cmd 9) a0 =
// icon index (0..4) — the WM decides which icon a click hits; the kernel
// applies the same clamped chain the shim runs (restore/focus/open).
const wmctl_dock: u64 = 9;
// WMS6 Gate E (issue #626): the tray decision channel. TRAY (cmd 10) — the
// WM owns the tray WIDGET CONTENT: the clock string, theme letter, and
// clipboard indicator. a0 = flags (bit 0 clock, bit 1 theme, bit 2
// clipboard); a1 = the 5-byte "HH:MM" clock text packed little-endian; a2 =
// theme letter (low byte) | clipboard filled (bit 8). The kernel clamps +
// stores + repaints; the shim fallback re-derives all three from its own
// state (no-WM mode is byte-identical).
const wmctl_tray: u64 = 10;
const tray_flag_clock: u64 = 0b001;
const tray_flag_theme: u64 = 0b010;
const tray_flag_clip: u64 = 0b100;
// WMS8 Gate 2 (issue #628): the modal-dialog decision channel. DIALOG (cmd
// 11) a0 = 0 close / 1 open / 2 toggle. The WM — not the kernel — decides
// WHEN the about dialog opens/closes/toggles (it owns the kind-21 keyboard
// stream); the kernel applies the same clamped primitives the shim runs and
// blits the modal from its own `about_dialog_open` state.
const wmctl_dialog: u64 = 11;
const dialog_toggle_act: u64 = 2;
// WMS8 Gate 4 (issue #628): the unsaved-changes dialog rides the same
// DIALOG seam — a0 = 3 show (a1 = target window), 4 save, 5 dont-save,
// 6 cancel — applied through the kernel's own unsaved_dialog_* primitives.
const dialog_unsaved_show: u64 = 3;
const dialog_unsaved_save: u64 = 4;
const dialog_unsaved_dont_save: u64 = 5;
const dialog_unsaved_cancel: u64 = 6;
// S6 Tab model (Milestone 19, issue #782)
const wmctl_attach_tab: u64 = 18;
const wmctl_detach_tab: u64 = 19;
const wmctl_activate_tab: u64 = 20;
/// sys_clipboard_get (slot 39) — the WM probes the clipboard each tray
/// refresh (filled = return length != 0) to decide the indicator state.
const sys_clipboard_get: u64 = 39;
/// WMS7 (issue #627, Gate A): the app↔WM mailbox protocol rides the frozen
/// mailbox syscalls — sys_ipc_recv (slot 6) drains the WM's own request
/// inbox; sys_ipc_send (slot 5) returns the ack to the requester. No new
/// ABI; the mailbox.service loop below is EL0 policy.
const sys_ipc_recv: u64 = 6;
const sys_ipc_send: u64 = 5;

// ---------------------------------------------------------------------------
// Syscall wrappers (AArch64 `svc #0` — the fixed-register ABI).
// ---------------------------------------------------------------------------
fn syscall0(num: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
        : .{ .memory = true });
    return res;
}

fn syscall1(num: u64, arg0: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
        : .{ .memory = true });
    return res;
}

fn syscall2(num: u64, arg0: u64, arg1: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
        : .{ .memory = true });
    return res;
}

fn syscall3(num: u64, arg0: u64, arg1: u64, arg2: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
        : .{ .memory = true });
    return res;
}

fn syscall6(num: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
          [arg3] "{x3}" (arg3),
          [arg4] "{x4}" (arg4),
          [arg5] "{x5}" (arg5),
        : .{ .memory = true });
    return res;
}

/// Write a marker line to the serial console (fd 1) — the live gates' grep
/// targets. `msg` is a slice (in rodata/data).
fn write_marker(msg: []const u8) void {
    _ = syscall3(sys_write, 1, @intFromPtr(msg.ptr), msg.len);
}

/// The kernel event struct (same layout as events.Event — u16 kind, u16
/// flags, u32 seq, u32 arg0, u32 arg1; `sys_wait_event` fills it).
const Event = extern struct {
    kind: u16,
    flags: u16,
    seq: u32,
    arg0: u32,
    arg1: u32,
};

// ---------------------------------------------------------------------------
// Pinned markers + tuning (the live gates' grep targets — DO NOT change).
// ---------------------------------------------------------------------------

/// Written right after REGISTER returns 0 (proves the WM is live + seated).
pub const registered_marker: []const u8 = "wnd: registered\n";
/// Written every `marker_every` REQUEST_PRESENTs — the observable present
/// cadence (a marker per present would flood the serial over a long run).
pub const present_marker: []const u8 = "wnd: present\n";
/// Present every Nth COMPOSITE_TICK (its own cadence, not every tick).
/// Ticks are 1 Hz on VZ, so every 2 ticks = a present every 2 s.
pub const present_every: u32 = 2;
/// Write a present marker every Nth present. With cadence 2 s this bounds
/// serial volume to one line per present.
pub const marker_every: u32 = 1;
/// The kind-18 event the loop services (must match kernel events.COMPOSITE_TICK).
pub const composite_tick_kind: u64 = 18;

// WMS5 (issue #625): the event kinds the WM services — the raw pointer
// stream (19, WM_POINTER), the window-registry mirrors (20, WM_WINDOW), and
// the raw keyboard stream (21, WM_KEY, Gate 2). Pinned against kernel events
// (drift guard), like kind 18.
pub const wm_pointer_kind: u64 = 19;
pub const wm_window_kind: u64 = 20;
pub const wm_key_kind: u64 = 21;
/// Left-button bit inside the WM_POINTER `flags` byte (must match the HID
/// button byte the kernel fans out: 0x01 = left).
pub const btn_left: u8 = 0x01;
/// The title-bar drag markers — written on grab / move-while-held / drop.
/// The live gate greps these to prove the WM — not the kernel — moved the
/// window (the kernel's own geometry is gated off while a WM is registered).
pub const grab_marker: []const u8 = "wnd: grab\n";
pub const drag_marker: []const u8 = "wnd: drag\n";
pub const drop_marker: []const u8 = "wnd: drop\n";

// WMS5 Gate 2 (issue #625, claim 4278): the policy markers — one per
// geometry decision the WM issues over the seam. The live gate greps these
// to prove the WM — not the kernel — decided (the kernel's keyboard geometry
// consumers are gated off while a WM is registered).
pub const tile_marker: []const u8 = "wnd: tile\n";
pub const snap_marker: []const u8 = "wnd: snap\n";
pub const min_marker: []const u8 = "wnd: min\n";
pub const max_marker: []const u8 = "wnd: max\n";
pub const ws_marker: []const u8 = "wnd: ws\n";
pub const fs_marker: []const u8 = "wnd: fs\n";
pub const aot_marker: []const u8 = "wnd: aot\n";
// S6 Tab model (Milestone 19, issue #782)
pub const tab_attach_marker: []const u8 = "wnd: tab-attach";
pub const tab_detach_marker: []const u8 = "wnd: tab-detach";
pub const tab_activate_marker: []const u8 = "wnd: tab-activate";
pub const tab_cycle_marker: []const u8 = "wnd: tab-cycle";
// S1/S5 Action registry seam (Milestone 19, issues #701, #705)
pub const action_reg_marker: []const u8 = "wnd: action-registered";
pub const action_inv_marker: []const u8 = "wnd: action-invoked";
// Issue #821 Phase 1: Global God Menu decision markers
pub const god_menu_open_marker: []const u8 = "wnd: god-menu open\n";
pub const god_menu_close_marker: []const u8 = "wnd: god-menu close\n";
pub const god_menu_exec_marker: []const u8 = "wnd: god-menu exec";

// WMS6 Gate A (issue #626): the Alt+Tab decision marker. The WM prints the
// target id after the pinned prefix (`wnd: alt-tab id=N`) so the live gate
// can prove the WM — not the kernel — picked the window that gets focus.
pub const alt_tab_marker: []const u8 = "wnd: alt-tab";

// WMS6 Gate B (issue #626): the notification-center decision markers — the
// WM opens/closes/clears/dismisses via NOTIF_CENTER/NOTIF_DISMISS. The live
// gate greps `wnd: notif` to prove the WM — not the kernel — decided.
pub const notif_open_marker: []const u8 = "wnd: notif-open\n";
pub const notif_close_marker: []const u8 = "wnd: notif-close\n";
pub const notif_clear_marker: []const u8 = "wnd: notif-clear\n";
pub const notif_dismiss_marker: []const u8 = "wnd: notif-dismiss\n";

// WMS6 Gate B: the tray region the WM hit-tests for a notification-center
// click — must mirror the kernel shim's tray_rect (fb_w - 80, taskbar row)
// so the injected click hits BOTH surfaces in the gate's two boots.
pub const tray_w: u32 = 80;

// WMS6 Gate C (issue #626): the tooltip decision markers — the WM shows /
// hides a tooltip via TOOLTIP (cmd 8). The live gate greps `wnd: tooltip`
// to prove the WM — not the kernel — decided what the hover shows.
pub const tooltip_show_marker: []const u8 = "wnd: tooltip\n";
pub const tooltip_hide_marker: []const u8 = "wnd: tooltip-hide\n";
/// The tooltip text the WM decides for a tray hover (rides ptr/len).
pub const tray_tooltip_text: []const u8 = "Clock";

// WMS6 Gate D (issue #626): the dock decision marker (the live gate greps
// `wnd: dock` to prove the WM — not the kernel — hit-tested the icon) and the
// icon hover labels the WM issues over the Gate-C TOOLTIP seam (the bar's
// glyphs are c n t b s — Calc, Notes, Terminal, Browser, Settings).
pub const dock_marker: []const u8 = "wnd: dock";
pub const dock_labels = [_][]const u8{ "Calc", "Notes", "Terminal", "Browser", "Settings" };

// WMS8 Gate 2 (issue #628): the about-dialog decision marker (the live gate
// greps `wnd: about` to prove the WM — not the kernel — decided Ctrl+Shift+A).
pub const about_marker: []const u8 = "wnd: about\n";

// WMS8 Gate 4 (issue #628): the unsaved-changes dialog decision markers — the
// live gate greps `wnd: unsaved-*` to prove the WM — not the kernel — decided
// when the dialog shows and which button applies.
pub const unsaved_dialog_marker: []const u8 = "wnd: unsaved-dialog\n";
pub const unsaved_save_marker: []const u8 = "wnd: unsaved-save\n";
pub const unsaved_discard_marker: []const u8 = "wnd: unsaved-discard\n";
pub const unsaved_cancel_marker: []const u8 = "wnd: unsaved-cancel\n";

/// WMS8 Gate 2 (issue #628): the about-dialog decision. Ctrl+Shift+A (kind
/// 21, usage 0x04) fans to the WM because it owns the keyboard stream; the WM
/// issues DIALOG (cmd 11) toggle — the SAME kernel primitive the shim's
/// Ctrl+Shift+A chord runs, so a WM decision and a shim chord are byte-
/// identical (parity by construction). The kernel blits the modal from its
/// own state.
fn toggle_about() void {
    _ = syscall6(sys_wmctl, wmctl_dialog, dialog_toggle_act, 0, 0, 0, 0);
    write_marker(about_marker);
}

/// WMS8 Gate 4 (issue #628): a dirty window's close button was clicked — the
/// WM, not the kernel, decides to show the unsaved-changes dialog (DIALOG 3,
/// target = the window id). The kernel applies its own `unsaved_dialog_show`.
fn show_unsaved_dialog(id: u8) void {
    _ = syscall6(sys_wmctl, wmctl_dialog, dialog_unsaved_show, id, 0, 0, 0);
    unsaved_dialog_open = true;
    write_marker(unsaved_dialog_marker);
}

/// WMS8 Gate 4 (issue #628): a dialog button was clicked — the WM decides the
/// choice and issues DIALOG 4/5/6; the kernel applies the SAME primitives the
/// shim's button click ran (parity by construction).
fn apply_unsaved_choice(choice: wnd_core.UnsavedChoice) void {
    switch (choice) {
        .save => {
            _ = syscall6(sys_wmctl, wmctl_dialog, dialog_unsaved_save, 0, 0, 0, 0);
            write_marker(unsaved_save_marker);
        },
        .dont_save => {
            _ = syscall6(sys_wmctl, wmctl_dialog, dialog_unsaved_dont_save, 0, 0, 0, 0);
            write_marker(unsaved_discard_marker);
        },
        .cancel => {
            _ = syscall6(sys_wmctl, wmctl_dialog, dialog_unsaved_cancel, 0, 0, 0, 0);
            write_marker(unsaved_cancel_marker);
        },
        .none => return,
    }
    unsaved_dialog_open = false;
}

// WMS6 Gate E (issue #626): the tray decision marker — written when the WM
// issues TRAY with CHANGED content (`wnd: tray clock=HH:MM theme=D
// clip=yes/no`). The live gate greps it to prove the WM — not the kernel —
// owns the tray widgets (the kernel render is source-selected off the
// WM-declared values once set).
pub const tray_marker: []const u8 = "wnd: tray";
/// The theme letter the WM declares — the WM is the theme owner; parity
/// with the shim's default 'D' (the kernel clamps to D/L/A).
pub const tray_theme_letter: u8 = 'D';
/// The tray refresh cadence: re-decide the widget content every Nth
/// COMPOSITE_TICK (kind-18 ticks are 1 Hz on VZ = seconds). The clock
/// REFRESHES under the WM — it was frozen while a WM was registered (the
/// kernel's drain is gated off), the exact gap this gate closes.
pub const tray_refresh_every: u64 = 10;
/// The clipboard probe buffer the WM reads each refresh (filled = returned
/// length != 0). The kernel clamps to its capacity.
pub const tray_clip_probe: usize = 32;

// WMS7 Gate A (issue #627): the app↔WM mailbox protocol marker — written per
// applied request (`wnd: mail kind=N id=M seq=S applied=yes|no title=..`).
// The live gate greps it to prove the WM SERVED a mail request (the app asked
// the WM, not the kernel, over the mailbox).
pub const mail_marker: []const u8 = "wnd: mail";
/// The 64-B mailbox slot bound the WM_RPC message must fit (wnd_core owns it).
pub const mail_inbox_max: usize = wnd_core.wm_rpc_max;

// ADR 0009 modifier bits (must match kernel events MOD_*).
pub const mod_shift: u16 = 0x0001;
pub const mod_ctrl: u16 = 0x0002;
pub const mod_alt: u16 = 0x0004;

// HID keyboard usages for the chords the WM owns (must match the usages
// input.zig decodes: Ctrl+T tile, Ctrl+M master-swap, Ctrl+N minimize,
// Ctrl+Shift+M maximize, Ctrl+Shift+T always-on-top, Ctrl+F1-3 workspace
// switch, Alt+` workspace cycle, F11 fullscreen).
pub const usage_t: u8 = 0x17;
pub const usage_m: u8 = 0x10;
pub const usage_n: u8 = 0x11;
pub const usage_f1: u8 = 0x58;
pub const usage_f2: u8 = 0x59;
pub const usage_f3: u8 = 0x5a;
pub const usage_backtick: u8 = 0x35;
pub const usage_f11: u8 = 0x5c;
pub const usage_tab: u8 = 0x2b;
pub const usage_w: u8 = 0x1a; // S6 Tab model: Ctrl+W closes/detaches tab
pub const usage_a: u8 = 0x04; // M27 G2 / WMS8 Gate 2: Ctrl+Shift+A toggles the about dialog
pub const usage_space: u8 = 0x2c; // Issue #821: Ctrl+Space toggles Sexiburger God Menu

pub fn hid_to_ascii(usage: u8, shift: bool) ?u8 {
    if (usage >= 0x04 and usage <= 0x1d) {
        return if (shift) 'A' + (usage - 0x04) else 'a' + (usage - 0x04);
    }
    if (usage >= 0x1e and usage <= 0x27) {
        const unshifted = "1234567890";
        const shifted = "!@#$%^&*()";
        const i = usage - 0x1e;
        return if (shift) shifted[i] else unshifted[i];
    }
    return switch (usage) {
        0x28 => '\n',
        0x2a => 0x08,
        0x2b => '\t',
        0x2c => ' ',
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

// WMS4 (issue #624): the EXACT values the chrome-descriptor blob embeds.
// Pinned against the shared wnd_core parity policy below, so the EL0 blob
// cannot drift from the kernel's expectation without a test failure.
pub const policy_kind: u32 = 0x3f;
pub const policy_flags: u32 = 0x01;
pub const policy_border_rgb: u32 = 0x0c1826;
pub const policy_border_unfocus_rgb: u32 = 0x475569;
pub const policy_title_bg_rgb: u32 = 0x1a2b3c;
pub const policy_title_fg_rgb: u32 = 0xffffff;
pub const policy_ring_rgb: u32 = 0x3b82f6;
pub const policy_close_rgb: u32 = 0xef4444;
pub const policy_min_rgb: u32 = 0x94a3b8;
pub const policy_pin_rgb: u32 = 0x38bdf8;

// ---------------------------------------------------------------------------
// The WM's own policy state (WMS5 Gate 2 — what the kernel used to own).
// ---------------------------------------------------------------------------

/// The one mirrored user window the WM tracks (the live gates open exactly
/// one window — NOTEPAD — so the WMS5 asm kept one slot; policy extends it
/// to the full user-window range 2..5 with a per-id table).
const max_user_windows: usize = 4;

const MirrorWin = struct {
    id: u8 = 0,
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    visible: bool = false,
    focused: bool = false,
    workspace: u8 = 0,
    // S6 Tab model (Milestone 19, issue #782)
    tab_parent: u8 = 0,
    tab_active: bool = true,
    // WMS8 Gate 4 (issue #628): the kernel's dirty flag, carried by the
    // kind-20 mirror (bit 12) — the WM's unsaved-dialog decision input.
    unsaved: bool = false,
    valid: bool = false,
    // Gate 2 policy state: the WM's own copies of what the kernel shim
    // tracked (tile slots, snap-restore rect, pre-max/pre-fs rects).
    minimized: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    always_on_top: bool = false,
    pre_max_x: u32 = 0,
    pre_max_y: u32 = 0,
    pre_max_w: u32 = 0,
    pre_max_h: u32 = 0,
    snap_last_x: u32 = 0,
    snap_last_y: u32 = 0,
    snap_last_w: u32 = 0,
    snap_last_h: u32 = 0,
    snapped: bool = false,
    snap_valid: bool = false,
};

/// The mirror table (id 2..5 -> slots 0..3).
var mirrors: [max_user_windows]MirrorWin = undefined;
// WMS8 Gate 4 (issue #628): the unsaved-changes dialog open state the WM
// tracks to route dialog-button clicks (the kernel's open state is the
// applied truth; this is the WM's decision-side mirror).
var unsaved_dialog_open: bool = false;
var current_workspace: u8 = 0;
var tile_mode: bool = false;
var tile_master_id: u8 = 0xff;
var tile_stack_id: u8 = 0xff;
var tile_master_side: bool = true;

fn mirror_slot(id: u8) ?usize {
    if (id < 2 or id > 5) return null;
    return id - 2;
}

fn mirror(id: u8) ?*MirrorWin {
    const s = mirror_slot(id) orelse return null;
    return &mirrors[s];
}

fn focused_mirror() ?*MirrorWin {
    for (&mirrors) |*m| {
        if (m.valid and m.focused) return m;
    }
    return null;
}

/// The scanout dimensions the WM computes rects from (the fixed 1280x720
/// scanout; single-sourced in wnd_core so the WM and kernel agree).
const fb_w = wnd_core.fb_w;
const fb_h = wnd_core.fb_h;
const taskbar_h = wnd_core.taskbar_h;
const dock_w = wnd_core.dock_w;

// ---------------------------------------------------------------------------
// Issue #821 Phase 1: Global Sexiburger God Menu Overlay & Action Dispatch
// ---------------------------------------------------------------------------

pub const AppAction = struct {
    owner_id: u8 = 0,
    section: u8 = 2,
    label: [32]u8 = [_]u8{0} ** 32,
    label_len: usize = 0,
    verb: [24]u8 = [_]u8{0} ** 24,
    verb_len: usize = 0,
};

var app_actions: [8]AppAction = [_]AppAction{.{}} ** 8;
var app_actions_count: usize = 0;

pub const god_menu_w: u32 = 488;
pub const god_menu_h: u32 = 316;

pub var god_menu: SexiburgerMenu = undefined;
pub var god_menu_initialized: bool = false;
pub var god_menu_win: ?u32 = null;
pub var god_menu_open: bool = false;
var god_menu_mascot_pixels: [24 * 24]u32 = undefined;
var god_menu_mascot_loaded: bool = false;
var god_menu_prev_focus: u8 = 0;
const mascot_qoi_bytes = @embedFile("lib/fixtures/qoi/mascot_24x24.qoi");

pub fn init_god_menu_if_needed() void {
    if (!god_menu_initialized) {
        god_menu = SexiburgerMenu.init(Rect.make(0, 0, god_menu_w, god_menu_h));
        if (!god_menu_mascot_loaded) {
            const decoded = ui.image.qoi.decode(mascot_qoi_bytes, &god_menu_mascot_pixels) catch null;
            if (decoded) |qhdr| {
                god_menu.raster_mascot = ui.image.Image{
                    .width = qhdr.width,
                    .height = qhdr.height,
                    .pixels = &god_menu_mascot_pixels,
                };
                god_menu_mascot_loaded = true;
            }
        }
        god_menu_initialized = true;
    }
}

pub fn populate_god_menu() void {
    init_god_menu_if_needed();
    god_menu.registry = ActionRegistry.init_empty();

    // 1. System (Top Bun / Crown)
    _ = god_menu.registry.register_command(.system, "About VirelaiOS", "Ctrl+Shift+A", "about", null) catch {};
    _ = god_menu.registry.register_command(.system, "System Monitor", "Ctrl+Esc", "top", null) catch {};
    _ = god_menu.registry.register_command(.system, "Settings Panel", "Ctrl+,", "settings", null) catch {};
    _ = god_menu.registry.register_command(.system, "Reboot System", "", "reboot", null) catch {};
    _ = god_menu.registry.register_command(.system, "Power Off", "", "shutdown", null) catch {};

    // 2. Apps (Lettuce) - Launchable applications
    _ = god_menu.registry.register_command(.apps, "Text Editor", "Ctrl+Alt+E", "notepad", null) catch {};
    _ = god_menu.registry.register_command(.apps, "Calculator", "Ctrl+Alt+C", "calc", null) catch {};
    _ = god_menu.registry.register_command(.apps, "File Browser", "Ctrl+Alt+F", "file", null) catch {};
    _ = god_menu.registry.register_command(.apps, "Terminal (Road Pops)", "Ctrl+Alt+T", "devcons", null) catch {};

    // 3. Active App (Tomato) - Live actions from focused app via mailbox seam
    var active_count: usize = 0;
    for (app_actions[0..app_actions_count]) |act| {
        if (act.label_len > 0) {
            _ = god_menu.registry.register_command(
                .active_app,
                act.label[0..act.label_len],
                "",
                act.verb[0..act.verb_len],
                null,
            ) catch {};
            active_count += 1;
        }
    }
    if (active_count == 0) {
        _ = god_menu.registry.register_command(.active_app, "Save Document", "Ctrl+S", "save", null) catch {};
        _ = god_menu.registry.register_command(.active_app, "Find in Document", "Ctrl+F", "find", null) catch {};
    }

    // 4. Windows & tabs (Cheese) - Dynamic list of open windows from mirrors
    var win_count_added: usize = 0;
    for (mirrors) |m| {
        if (m.valid and m.visible) {
            var wbuf: [32]u8 = undefined;
            const wlabel = std.fmt.bufPrint(&wbuf, "Window {d} (Active)", .{m.id}) catch "Window";
            var vbuf: [24]u8 = undefined;
            const wverb = std.fmt.bufPrint(&vbuf, "win-{d}", .{m.id}) catch "win";
            _ = god_menu.registry.register_command(.windows_tabs, wlabel, "", wverb, null) catch {};
            win_count_added += 1;
        }
    }
    if (win_count_added == 0) {
        _ = god_menu.registry.register_command(.windows_tabs, "New Tab", "Ctrl+T", "tab-new", null) catch {};
        _ = god_menu.registry.register_command(.windows_tabs, "Close Tab", "Ctrl+W", "tab-close", null) catch {};
        _ = god_menu.registry.register_command(.windows_tabs, "Next Tab", "Ctrl+Tab", "tab-next", null) catch {};
    }

    // 5. Services (Patty) - Quick tools / services
    _ = god_menu.registry.register_command(.services, "Toggle Theme (Light/Dark)", "Ctrl+Shift+L", "theme", null) catch {};
    _ = god_menu.registry.register_command(.services, "Notifications Panel", "", "notify", null) catch {};
    _ = god_menu.registry.register_command(.services, "Clipboard History", "Ctrl+Shift+V", "clipboard", null) catch {};

    // 6. Power / Mascot (Heel Bun)
    _ = god_menu.registry.register_command(.power, "Sexipus Mascot Diagnostics", "", "sexiburger", null) catch {};
    _ = god_menu.registry.register_command(.power, "Cascade Windows", "Alt+C", "cascade", null) catch {};

    god_menu.clear_search();
}

pub fn redraw_god_menu() void {
    if (god_menu_win) |wid| {
        god_menu.draw(wid);
        ui.win_present(wid);
    }
}

pub fn execute_god_menu_command(cmd: Command) void {
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} verb={s} label={s}\n", .{ god_menu_exec_marker, cmd.verb, cmd.label }) catch "wnd: god-menu exec\n";
    write_marker(msg);

    if (std.mem.eql(u8, cmd.verb, "about")) {
        toggle_about();
    } else if (std.mem.eql(u8, cmd.verb, "theme")) {
        write_marker("wnd: theme toggled\n");
    } else if (std.mem.eql(u8, cmd.verb, "notepad")) {
        _ = ui.exec_program("NOTEPAD.BIN");
    } else if (std.mem.eql(u8, cmd.verb, "calc")) {
        _ = ui.exec_program("CALC.BIN");
    } else if (std.mem.eql(u8, cmd.verb, "file")) {
        _ = ui.exec_program("FILE.BIN");
    } else if (std.mem.eql(u8, cmd.verb, "top")) {
        _ = ui.exec_program("TOP.BIN");
    } else if (std.mem.eql(u8, cmd.verb, "devcons")) {
        _ = ui.exec_program("DEVCONS.BIN");
    } else if (std.mem.eql(u8, cmd.verb, "notify")) {
        _ = syscall6(sys_wmctl, wmctl_notif_center, notif_open_act, 0, 0, 0, 0);
    } else if (std.mem.startsWith(u8, cmd.verb, "win-")) {
        if (cmd.verb.len > 4) {
            const wid_char = cmd.verb[4];
            if (wid_char >= '2' and wid_char <= '5') {
                const wid: u8 = wid_char - '0';
                _ = syscall6(sys_wmctl, wmctl_alt_tab, wid, alt_tab_commit, 0, 0, 0);
            }
        }
    } else if (cmd.section == .active_app) {
        var inv_buf: [80]u8 = undefined;
        const inv_msg = std.fmt.bufPrint(&inv_buf, "{s} label={s}\n", .{ action_inv_marker, cmd.label }) catch "wnd: action-invoked\n";
        write_marker(inv_msg);
    }
}

pub fn toggle_god_menu() void {
    if (god_menu_open) {
        if (god_menu_win) |wid| {
            ui.win_close(wid);
            god_menu_win = null;
        }
        god_menu_open = false;
        god_menu.open = false;
        write_marker(god_menu_close_marker);
        if (god_menu_prev_focus >= 2 and god_menu_prev_focus <= 5) {
            _ = syscall6(sys_wmctl, wmctl_alt_tab, god_menu_prev_focus, alt_tab_commit, 0, 0, 0);
        }
    } else {
        god_menu_prev_focus = if (focused_mirror()) |fm| fm.id else 0;
        populate_god_menu();
        const menu_x = if (fb_w > god_menu_w) (fb_w - god_menu_w) / 2 else 0;
        const menu_y = if (fb_h > god_menu_h) (fb_h - god_menu_h) / 2 else 0;
        const w_res = ui.win_open(menu_x, menu_y, god_menu_w, god_menu_h);
        if (w_res >= 0) {
            const wid: u32 = @intCast(w_res);
            god_menu_win = wid;
            god_menu_open = true;
            god_menu.open = true;
            god_menu.rect = Rect.make(0, 0, god_menu_w, god_menu_h);
            redraw_god_menu();
            write_marker(god_menu_open_marker);
        } else {
            write_marker("wnd: god-menu open-failed\n");
        }
    }
}

// ---------------------------------------------------------------------------
// The policy actions (each issues SET_WINDOW rects / SET_STATE state).
// ---------------------------------------------------------------------------

/// SET_WINDOW(id, x|y<<16, w|h<<16) — propose a rect (kernel clamps + blits).
fn set_window_rect(id: u8, x: u32, y: u32, w: u32, h: u32) void {
    _ = syscall6(sys_wmctl, wmctl_set_window, id, x | (y << 16), w | (h << 16), 0, 0);
}

/// SET_STATE(id, state) — visibility (bits 0-1), workspace (bits 8-15),
/// always-on-top (bit 16). The ALL id = global workspace switch.
fn set_state(id: u8, visible: ?bool, ws: ?u8, aot: bool) void {
    var st: u64 = 2; // no visibility change (2/3)
    if (visible) |v| st = if (v) 1 else 0;
    if (ws) |w| st |= @as(u64, w) << 8;
    if (aot) st |= 1 << 16;
    _ = syscall6(sys_wmctl, wmctl_set_state, id, st, 0, 0, 0);
}

/// Switch the CURRENT workspace globally (SET_STATE with a0 = ALL).
fn switch_workspace(ws: u8) void {
    _ = syscall6(sys_wmctl, wmctl_set_state, 0xFFFF_FFFF, @as(u64, ws) << 8, 0, 0, 0);
}

/// M21 W1: toggle the focused window floating/tiled. Mirrors the kernel
/// shim's rule (max 2 tiled windows; a third shifts master -> stack).
fn toggle_tiling() void {
    const fm = focused_mirror() orelse return;
    const fid = fm.id;
    // Already master? detach (promote stack).
    if (tile_mode and tile_master_id == fid) {
        if (tile_stack_id != 0xff) {
            tile_master_id = tile_stack_id;
            tile_stack_id = 0xff;
        } else {
            tile_master_id = 0xff;
            tile_mode = false;
        }
    } else if (tile_mode and tile_stack_id == fid) {
        tile_stack_id = 0xff;
        if (tile_master_id == 0xff) tile_mode = false;
    } else {
        // Not yet tiled — add this window.
        if (tile_master_id == 0xff) {
            tile_master_id = fid;
        } else if (tile_stack_id == 0xff) {
            tile_stack_id = fid;
        } else {
            // Both slots occupied — detach the oldest (master) and shift.
            tile_master_id = tile_stack_id;
            tile_stack_id = fid;
        }
        tile_mode = true;
    }
    write_marker(tile_marker);
    apply_tile_layout();
}

/// M21 W2: swap which window is master and which is detail (flip the side).
fn swap_master() void {
    if (!tile_mode or tile_master_id == 0xff or tile_stack_id == 0xff) return;
    const mid = tile_master_id;
    tile_master_id = tile_stack_id;
    tile_stack_id = mid;
    tile_master_side = !tile_master_side;
    write_marker(tile_marker);
    apply_tile_layout();
}

/// Apply the tile layout through the shared wnd_core math (master 2/3,
/// detail 1/3 — the SAME rule the kernel shim's apply_tile_layout uses).
fn apply_tile_layout() void {
    if (!tile_mode) return;
    const tl = wnd_core.tile_layout(fb_w, fb_h, taskbar_h, dock_w, 667, tile_master_side);
    if (tile_master_id != 0xff) {
        if (mirror(tile_master_id)) |m| {
            m.x = tl.master_x;
            m.y = tl.y;
            m.w = tl.master_w;
            m.h = tl.h;
            set_window_rect(m.id, m.x, m.y, m.w, m.h);
        }
    }
    if (tile_stack_id != 0xff) {
        if (mirror(tile_stack_id)) |m| {
            m.x = tl.detail_x;
            m.y = tl.y;
            m.w = tl.detail_w;
            m.h = tl.h;
            set_window_rect(m.id, m.x, m.y, m.w, m.h);
        }
    }
}

/// M21 W3: minimize/restore the focused window (SET_STATE visibility).
fn toggle_minimize() void {
    const fm = focused_mirror() orelse return;
    if (fm.minimized) {
        fm.minimized = false;
        set_state(fm.id, true, null, false);
        // Restore the saved rect (the kernel kept it; we mirror the truth).
        if (fm.snap_valid) {
            set_window_rect(fm.id, fm.snap_last_x, fm.snap_last_y, fm.snap_last_w, fm.snap_last_h);
            fm.x = fm.snap_last_x;
            fm.y = fm.snap_last_y;
            fm.w = fm.snap_last_w;
            fm.h = fm.snap_last_h;
            fm.snap_valid = false;
        }
        write_marker(min_marker);
    } else {
        fm.minimized = true;
        // Save the current rect for restore (the WM's own pre-min copy).
        fm.snap_last_x = fm.x;
        fm.snap_last_y = fm.y;
        fm.snap_last_w = fm.w;
        fm.snap_last_h = fm.h;
        fm.snap_valid = true;
        set_state(fm.id, false, null, false);
        write_marker(min_marker);
    }
}

/// M21 W6: maximize/restore the focused window (SET_WINDOW max rect).
fn toggle_maximize() void {
    const fm = focused_mirror() orelse return;
    if (fm.maximized) {
        fm.maximized = false;
        if (fm.snap_valid) {
            set_window_rect(fm.id, fm.snap_last_x, fm.snap_last_y, fm.snap_last_w, fm.snap_last_h);
            fm.x = fm.snap_last_x;
            fm.y = fm.snap_last_y;
            fm.w = fm.snap_last_w;
            fm.h = fm.snap_last_h;
            fm.snap_valid = false;
        }
        write_marker(max_marker);
    } else {
        const mx = wnd_core.maximize_rect(fb_w, fb_h, taskbar_h, dock_w);
        fm.maximized = true;
        fm.snap_last_x = fm.x;
        fm.snap_last_y = fm.y;
        fm.snap_last_w = fm.w;
        fm.snap_last_h = fm.h;
        fm.snap_valid = true;
        fm.x = mx.x;
        fm.y = mx.y;
        fm.w = mx.w;
        fm.h = mx.h;
        set_window_rect(fm.id, mx.x, mx.y, mx.w, mx.h);
        write_marker(max_marker);
    }
}

/// M21 W7: fullscreen/restore the focused window (SET_WINDOW full rect).
fn toggle_fullscreen() void {
    const fm = focused_mirror() orelse return;
    if (fm.fullscreen) {
        fm.fullscreen = false;
        if (fm.snap_valid) {
            set_window_rect(fm.id, fm.snap_last_x, fm.snap_last_y, fm.snap_last_w, fm.snap_last_h);
            fm.x = fm.snap_last_x;
            fm.y = fm.snap_last_y;
            fm.w = fm.snap_last_w;
            fm.h = fm.snap_last_h;
            fm.snap_valid = false;
        }
        write_marker(fs_marker);
    } else {
        const fs = wnd_core.fullscreen_rect(fb_w, fb_h);
        fm.fullscreen = true;
        fm.snap_last_x = fm.x;
        fm.snap_last_y = fm.y;
        fm.snap_last_w = fm.w;
        fm.snap_last_h = fm.h;
        fm.snap_valid = true;
        fm.x = fs.x;
        fm.y = fs.y;
        fm.w = fs.w;
        fm.h = fs.h;
        set_window_rect(fm.id, fs.x, fs.y, fs.w, fs.h);
        write_marker(fs_marker);
    }
}

/// M21 W8: toggle always-on-top on the focused window (SET_STATE bit 16).
fn toggle_always_on_top() void {
    const fm = focused_mirror() orelse return;
    fm.always_on_top = !fm.always_on_top;
    set_state(fm.id, null, null, true);
    write_marker(aot_marker);
}

/// WMS5 Gate 2: snap the mirror window to the zone under the drop point
/// (M15 C3 rule from wnd_core — corners first, then edges; 20 px threshold).
fn snap_window_to(id: u8, px: u32, py: u32) void {
    const m = mirror(id) orelse return;
    const zone = wnd_core.snap_zone_for_point(px, py, fb_w, fb_h);
    if (zone == .none) return;
    const zb = wnd_core.snap_zone_bounds(zone, fb_w, fb_h, taskbar_h) orelse return;
    // The kernel clamps to user_buf_w/h; we propose the zone-centered rect.
    const win_w = @min(zb.w, wnd_core.user_buf_w);
    const win_h = @min(zb.h, wnd_core.user_buf_h);
    const win_x = zb.x + (zb.w - win_w) / 2;
    const win_y = zb.y + (zb.h - win_h) / 2;
    if (!m.snapped) {
        m.snap_last_x = m.x;
        m.snap_last_y = m.y;
        m.snap_last_w = m.w;
        m.snap_last_h = m.h;
        m.snap_valid = true;
    }
    m.snapped = true;
    m.x = win_x;
    m.y = win_y;
    m.w = win_w;
    m.h = win_h;
    set_window_rect(m.id, win_x, win_y, win_w, win_h);
    write_marker(snap_marker);
}

// ---------------------------------------------------------------------------
// S6 Tab model (Milestone 19, issue #782) — WM registry tabs.
// ---------------------------------------------------------------------------

fn attach_tab(child_id: u8, parent_id: u8) bool {
    if (child_id == parent_id or child_id > 0xff or parent_id > 0xff) return false;
    const cm = mirror(child_id) orelse return false;
    const pm = mirror(parent_id) orelse return false;
    cm.tab_parent = parent_id;
    cm.tab_active = false;
    cm.x = pm.x;
    cm.y = pm.y;
    cm.w = pm.w;
    cm.h = pm.h;
    set_window_rect(child_id, pm.x, pm.y, pm.w, pm.h);
    _ = syscall6(sys_wmctl, wmctl_attach_tab, child_id, parent_id, 0, 0, 0);
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} child={d} parent={d}\n", .{ tab_attach_marker, child_id, parent_id }) catch "wnd: tab-attach\n";
    write_marker(msg);
    return true;
}

fn detach_tab(child_id: u8) bool {
    const cm = mirror(child_id) orelse return false;
    if (cm.tab_parent == 0) return false;
    cm.tab_parent = 0;
    cm.tab_active = true;
    cm.x +%= 24;
    cm.y +%= 24;
    set_window_rect(child_id, cm.x, cm.y, cm.w, cm.h);
    set_state(child_id, true, null, false);
    _ = syscall6(sys_wmctl, wmctl_detach_tab, child_id, 0, 0, 0, 0);
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} child={d}\n", .{ tab_detach_marker, child_id }) catch "wnd: tab-detach\n";
    write_marker(msg);
    return true;
}

fn activate_tab(tab_id: u8) bool {
    const tm = mirror(tab_id) orelse return false;
    const parent = if (tm.tab_parent != 0) tm.tab_parent else tab_id;
    for (&mirrors) |*m| {
        if (!m.valid) continue;
        const item_parent = if (m.tab_parent != 0) m.tab_parent else m.id;
        if (item_parent == parent) {
            if (m.id == tab_id) {
                m.tab_active = true;
                set_state(m.id, true, null, false);
                _ = syscall6(sys_wmctl, wmctl_alt_tab, m.id, alt_tab_commit, 0, 0, 0);
            } else {
                m.tab_active = false;
                set_state(m.id, false, null, false);
            }
        }
    }
    _ = syscall6(sys_wmctl, wmctl_activate_tab, tab_id, 0, 0, 0, 0);
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} id={d}\n", .{ tab_activate_marker, tab_id }) catch "wnd: tab-activate\n";
    write_marker(msg);
    return true;
}

fn cycle_tabs() void {
    const fm = focused_mirror() orelse return;
    var tab_items: [max_user_windows]wnd_core.TabItem = undefined;
    var count: usize = 0;
    for (&mirrors) |*m| {
        if (!m.valid) continue;
        tab_items[count] = .{
            .window_id = m.id,
            .parent_id = m.tab_parent,
            .active = m.tab_active,
        };
        count += 1;
    }
    if (wnd_core.cycle_next_tab(tab_items[0..count], fm.id)) |next_id| {
        _ = activate_tab(next_id);
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s} active={d}\n", .{ tab_cycle_marker, next_id }) catch "wnd: tab-cycle\n";
        write_marker(msg);
    }
}

// ---------------------------------------------------------------------------
// WMS6 Gate A — the Alt+Tab policy (which window gets focus).
// ---------------------------------------------------------------------------

/// Print the Alt+Tab decision with its target id (the live gate greps the
/// pinned prefix + the value).
fn write_alt_tab_marker(id: u8) void {
    var buf: [40]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} id={d}\n", .{ alt_tab_marker, id }) catch "wnd: alt-tab id=0\n";
    write_marker(s);
}

/// The next Alt+Tab target: the window AFTER the focused one in the mirror
/// registry (wrap), skipping hidden or off-workspace windows — the same
/// M21 W3/W4 rules the shim's snapshot uses. Pure (host-testable). Returns
/// null when fewer than two windows are cyclable (mirror the shim's no-op).
fn next_alt_tab_target() ?u8 {
    // Collect the cyclable candidates (valid + visible + current workspace).
    var cands: [max_user_windows]u8 = undefined;
    var cnt: usize = 0;
    var focus_idx: ?usize = null;
    for (&mirrors) |*m| {
        if (!m.valid or m.id < 2) continue;
        if (!m.visible) continue;
        if (m.workspace != current_workspace) continue;
        if (cnt < max_user_windows) cands[cnt] = m.id;
        if (m.focused) focus_idx = cnt;
        cnt += 1;
    }
    if (cnt < 2) return null; // not enough windows to Alt+Tab (mirror the shim)
    // Pick the next window after the focused one (starting slot 0 if none).
    const start = focus_idx orelse 0;
    return cands[(start + 1) % cnt];
}

/// The WM's Alt+Tab policy: decide the switch target via `next_alt_tab_target`,
/// then issue ALT_TAB commit so the kernel focuses/raises the WM's choice
/// (the kernel clamps + repaints).
fn handle_alt_tab() void {
    const target = next_alt_tab_target() orelse return;
    _ = syscall6(sys_wmctl, wmctl_alt_tab, target, alt_tab_commit, 0, 0, 0);
    write_alt_tab_marker(target);
}

// ---------------------------------------------------------------------------
// WMS6 Gate D — the dock policy (icon clicks + hover labels).
// ---------------------------------------------------------------------------

/// Hit-test the dock icon grid — mirrors the shim's M15 C4 geometry: 24 px
/// left bar, 20×20 icons at (2, 8+idx*32), 5 icons. Returns the icon index.
fn dock_icon_at(px: u32, py: u32) ?u8 {
    if (px < 2 or px >= 22) return null;
    if (py < 8) return null;
    const rel = py - 8;
    const idx = rel / 32;
    if (idx >= 5) return null;
    if (rel - idx * 32 >= 20) return null;
    return @intCast(idx);
}

/// Print the dock decision with its icon index (the live gate greps the
/// pinned prefix + the value).
fn write_dock_marker(idx: u8) void {
    var buf: [40]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} idx={d}\n", .{ dock_marker, idx }) catch "wnd: dock idx=0\n";
    write_marker(s);
}

/// The dock icon-click decision: issue DOCK <idx> so the kernel applies the
/// same clamped chain the shim runs (restore-first-minimized -> focus/raise
/// -> open). The kernel clamps + blits.
fn handle_dock_click(idx: u8) void {
    _ = syscall6(sys_wmctl, wmctl_dock, idx, 0, 0, 0, 0);
    write_dock_marker(idx);
}

/// The dock hover-label decision: entering an icon (or moving to a new one)
/// shows the icon's label via the Gate-C TOOLTIP seam; leaving hides it.
fn handle_dock_hover(prev: ?u8, cur: ?u8) void {
    if (cur) |c| {
        if (prev == null or prev.? != c) {
            const label = dock_labels[c];
            _ = syscall6(sys_wmctl, wmctl_tooltip, tooltip_show_act, 0, 0, @intFromPtr(label.ptr), label.len);
            write_marker(tooltip_show_marker);
        }
    } else if (prev != null) {
        _ = syscall6(sys_wmctl, wmctl_tooltip, tooltip_hide_act, 0, 0, 0, 0);
        write_marker(tooltip_hide_marker);
    }
}

// ---------------------------------------------------------------------------
// WMS6 Gate E (issue #626): the tray widget-content policy. The WM — not the
// kernel — owns what the tray shows: the clock string (formatted from its own
// 1 Hz tick counter, the same minute-rollover formula the shim's format_hhmm
// uses — parity by value), the theme letter (the WM is the theme owner;
// parity 'D'), and the clipboard indicator (a sys_clipboard_get probe).
// ---------------------------------------------------------------------------

/// The last content the WM declared (so a refresh only re-issues on change,
/// mirroring the shim's drain: repaint when something changed, not every
/// tick).
const TrayState = struct {
    clock: [5]u8 = .{ '0', '0', ':', '0', '0' },
    clock_set: bool = false,
    clip: bool = false,
};

/// Format HH:MM from the 1 Hz tick count (seconds since this WM registered)
/// — the same formula the shim's format_hhmm uses (minute rollover, 24 h
/// wrap), so parity-by-value holds.
pub fn format_wm_hhmm(buf: *[5]u8, ticks: u64) []const u8 {
    const total_minutes = (ticks / 60) % (24 * 60);
    const hh = total_minutes / 60;
    const mm = total_minutes % 60;
    buf[0] = @as(u8, @intCast('0' + hh / 10));
    buf[1] = @as(u8, @intCast('0' + hh % 10));
    buf[2] = ':';
    buf[3] = @as(u8, @intCast('0' + mm / 10));
    buf[4] = @as(u8, @intCast('0' + mm % 10));
    return buf[0..5];
}

/// The tray refresh decision: compute the widget content from the WM's own
/// state and, when it differs from what was last declared, issue TRAY (cmd
/// 10) and write the `wnd: tray` marker. Returns true when it issued.
pub fn tray_tick_policy(ticks: u64, clip_filled: bool, state: *TrayState) bool {
    var clock_buf: [5]u8 = undefined;
    const clock = format_wm_hhmm(&clock_buf, ticks);
    if (state.clock_set and std.mem.eql(u8, state.clock[0..], clock) and state.clip == clip_filled) {
        return false; // nothing changed — no re-issue (mirrors the shim drain)
    }
    state.clock = clock_buf;
    state.clip = clip_filled;
    state.clock_set = true;
    // Pack the 5-byte clock text little-endian into a1 (the frozen encoding).
    var clock_packed: u64 = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) clock_packed |= @as(u64, clock_buf[i]) << @intCast(i * 8);
    const a2 = @as(u64, tray_theme_letter) | (if (clip_filled) @as(u64, 1) << 8 else 0);
    _ = syscall6(sys_wmctl, wmctl_tray, tray_flag_clock | tray_flag_theme | tray_flag_clip, clock_packed, a2, 0, 0);
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} clock={s} theme={c} clip={s}\n", .{
        tray_marker,
        clock,
        tray_theme_letter,
        if (clip_filled) "yes" else "no",
    }) catch "wnd: tray\n";
    write_marker(s);
    return true;
}

// ---------------------------------------------------------------------------
// WMS7 Gate A (issue #627): the app↔WM mailbox service loop. The WM serves
// bounded IPC requests from apps (the wire format, WM_RPC, is single-sourced
// in wnd_core so the server and the app cannot drift). Runs once per tick
// (kind-18 at 1 Hz => <= 1 s request latency — accepted + documented).
// ---------------------------------------------------------------------------

/// Send a WM_RPC reply to `reply_to` (the requesting app's pid) — the echo
/// kind + seq with the applied flag, so the app's bounded poll has something
/// definitive to match. A dead/unknown reply target is simply dropped (the
/// sys_ipc_send returns EINVAL before any copy — honest, no loss inside the
/// kernel mailbox).
fn wnd_mail_reply(reply_to: u8, req: *const wnd_core.WmRpc, applied: bool) void {
    var rep: wnd_core.WmRpc = .{
        .kind = req.kind | wnd_core.wm_rpc_reply_flag,
        .id = req.id,
        .seq = req.seq,
        .reply_to = reply_to,
        .applied = if (applied) 1 else 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = [_]u8{0} ** wnd_core.wm_rpc_title_max,
    };
    const rep_bytes = std.mem.asBytes(&rep);
    _ = syscall3(sys_ipc_send, reply_to, @intFromPtr(rep_bytes.ptr), rep_bytes.len);
}

/// Apply ONE WM_RPC request through the WM's OWN clamped primitives — the
/// same paths its native decisions use, so a mail-driven raise/config is
/// byte-identical to a WM-native one. Returns whether it applied.
fn wnd_mail_apply(req: *const wnd_core.WmRpc) bool {
    switch (req.kind & 0x7f) {
        wnd_core.wm_rpc_kind_raise => {
            // WIN_RAISE: focus + raise via the ALT_TAB-commit path (the
            // proven WMS6 Gate-A primitive; a bad id returns EINVAL).
            const rc = syscall6(sys_wmctl, wmctl_alt_tab, req.id, alt_tab_commit, 0, 0, 0);
            return rc == 0;
        },
        wnd_core.wm_rpc_kind_config => {
            // WIN_CONFIG: clamped move/resize via the SET_WINDOW rect path.
            const rc = syscall6(sys_wmctl, wmctl_set_window, req.id, @as(u64, req.x) | (@as(u64, req.y) << 16), @as(u64, req.w) | (@as(u64, req.h) << 16), 0, 0);
            return rc == 0;
        },
        wnd_core.wm_rpc_kind_register_action => {
            var label_slice: []const u8 = req.title[0..];
            for (req.title, 0..) |c, i| {
                if (c == 0) {
                    label_slice = req.title[0..i];
                    break;
                }
            }
            if (app_actions_count < app_actions.len) {
                var act = &app_actions[app_actions_count];
                act.owner_id = req.id;
                act.section = @intCast(@min(req.x, 5));
                const copy_l = @min(label_slice.len, act.label.len);
                @memcpy(act.label[0..copy_l], label_slice[0..copy_l]);
                act.label_len = copy_l;
                const verb = "test-act";
                const copy_v = @min(verb.len, act.verb.len);
                @memcpy(act.verb[0..copy_v], verb[0..copy_v]);
                act.verb_len = copy_v;
                app_actions_count += 1;
            }
            var buf: [80]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s} section={d} label={s} verb=test-act\n", .{ action_reg_marker, req.x, label_slice }) catch "wnd: action-registered\n";
            write_marker(msg);
            return true;
        },
        wnd_core.wm_rpc_kind_invoke_action => {
            var label_slice: []const u8 = req.title[0..];
            for (req.title, 0..) |c, i| {
                if (c == 0) {
                    label_slice = req.title[0..i];
                    break;
                }
            }
            var buf: [80]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s} label={s}\n", .{ action_inv_marker, label_slice }) catch "wnd: action-invoked\n";
            write_marker(msg);
            return true;
        },
        wnd_core.wm_rpc_kind_attach_tab => {
            return attach_tab(req.id, @intCast(req.x));
        },
        wnd_core.wm_rpc_kind_detach_tab => {
            return detach_tab(req.id);
        },
        wnd_core.wm_rpc_kind_cycle_tab => {
            cycle_tabs();
            return true;
        },
        else => return false, // unknown kind — refused honestly
    }
}

/// Drain the WM's own inbox: recv (non-blocking), bound each message to the
/// frozen WM_RPC shape, apply, reply, and print the `wnd: mail` marker. The
/// loop empties the whole inbox each tick (bounded work per wake).
fn wnd_mail_loop() void {
    var raw: [mail_inbox_max]u8 = undefined;
    while (true) {
        const got = syscall2(sys_ipc_recv, @intFromPtr(&raw), raw.len);
        if (got <= 0) return; // empty inbox — drained
        if (got < @sizeOf(wnd_core.WmRpc)) continue; // truncated junk — skip
        var req: wnd_core.WmRpc = undefined;
        @memcpy(std.mem.asBytes(&req), raw[0..@sizeOf(wnd_core.WmRpc)]);
        const reply_to = req.reply_to;
        if (req.kind & wnd_core.wm_rpc_reply_flag != 0) continue; // a reply, not a request
        const applied = wnd_mail_apply(&req);
        // Marker: wnd: mail kind=N id=M seq=S applied=yes|no [title=..]
        var title_slice: []const u8 = req.title[0..];
        for (req.title, 0..) |c, i| {
            if (c == 0) {
                title_slice = req.title[0..i];
                break;
            }
        }
        var buf: [72]u8 = undefined;
        const s = if (title_slice.len == 0)
            std.fmt.bufPrint(&buf, "{s} kind={d} id={d} seq={d} applied={s}\n", .{ mail_marker, req.kind, req.id, req.seq, if (applied) "yes" else "no" }) catch "wnd: mail\n"
        else
            std.fmt.bufPrint(&buf, "{s} kind={d} id={d} seq={d} applied={s} title={s}\n", .{ mail_marker, req.kind, req.id, req.seq, if (applied) "yes" else "no", title_slice }) catch "wnd: mail\n";
        write_marker(s);
        wnd_mail_reply(reply_to, &req, applied);
    }
}

// ---------------------------------------------------------------------------
// The WMS5 keyboard chord decoder (kind 21 WM_KEY).
// ---------------------------------------------------------------------------
fn handle_wm_key(usage: u8, flags: u16) void {
    const ctrl = (flags & mod_ctrl) != 0;
    const shift = (flags & mod_shift) != 0;
    const alt = (flags & mod_alt) != 0;

    // Issue #821 Phase 1: Ctrl+Space toggles the Global Sexiburger God Menu.
    if (ctrl and usage == usage_space) {
        toggle_god_menu();
        return;
    }

    if (god_menu_open) {
        if (usage == 0x29) { // Escape dismisses
            toggle_god_menu();
            return;
        }
        if (usage == 0x28) { // Enter executes selected
            if (god_menu.filtered_count > 0 and god_menu.selected_filter_idx < god_menu.filtered_count) {
                const sel_cmd = god_menu.filtered[god_menu.selected_filter_idx].command;
                execute_god_menu_command(sel_cmd);
            }
            toggle_god_menu();
            return;
        }
        if (usage == 0x52) { // Up arrow
            if (god_menu.filtered_count > 0) {
                if (god_menu.selected_filter_idx > 0) {
                    god_menu.selected_filter_idx -= 1;
                } else {
                    god_menu.selected_filter_idx = god_menu.filtered_count - 1;
                }
                redraw_god_menu();
            }
            return;
        }
        if (usage == 0x51) { // Down arrow
            if (god_menu.filtered_count > 0) {
                if (god_menu.selected_filter_idx + 1 < god_menu.filtered_count) {
                    god_menu.selected_filter_idx += 1;
                } else {
                    god_menu.selected_filter_idx = 0;
                }
                redraw_god_menu();
            }
            return;
        }
        if (usage == 0x2a) { // Backspace
            if (god_menu.search_len > 0) {
                god_menu.search_len -= 1;
                god_menu.update_filter();
                redraw_god_menu();
            }
            return;
        }
        if (hid_to_ascii(usage, shift)) |ch| {
            if (ch >= 0x20 and ch <= 0x7e) {
                if (god_menu.search_len < god_menu.search_buf.len) {
                    god_menu.search_buf[god_menu.search_len] = ch;
                    god_menu.search_len += 1;
                    god_menu.update_filter();
                    redraw_god_menu();
                }
            }
        }
        return;
    }

    if (alt and usage == usage_tab) {
        // WMS6 Gate A: the WM, not the kernel, decides which window Alt+Tab
        // switches to.
        handle_alt_tab();
        return;
    }
    if (ctrl and usage == usage_tab) {
        // S6 Tab model (Milestone 19, issue #782): Ctrl+Tab cycles tabs.
        cycle_tabs();
        return;
    }
    if (ctrl and usage == usage_w) {
        // S6 Tab model (Milestone 19, issue #782): Ctrl+W detaches/closes tab.
        if (focused_mirror()) |fm| {
            if (fm.tab_parent != 0) {
                _ = detach_tab(fm.id);
                return;
            }
        }
    }
    if (alt and usage == usage_backtick) {
        // Alt+` cycles workspaces (W4).
        current_workspace = (current_workspace + 1) % 3;
        switch_workspace(current_workspace);
        write_marker(ws_marker);
        return;
    }
    if (ctrl and !shift) {
        if (usage == usage_f1) {
            current_workspace = 0;
            switch_workspace(0);
            write_marker(ws_marker);
            return;
        }
        if (usage == usage_f2) {
            current_workspace = 1;
            switch_workspace(1);
            write_marker(ws_marker);
            return;
        }
        if (usage == usage_f3) {
            current_workspace = 2;
            switch_workspace(2);
            write_marker(ws_marker);
            return;
        }
        if (usage == usage_t) {
            toggle_tiling();
            return;
        }
        if (usage == usage_m) {
            swap_master();
            return;
        }
        if (usage == usage_n) {
            toggle_minimize();
            return;
        }
    }
    if (ctrl and shift) {
        if (usage == usage_m) {
            toggle_maximize();
            return;
        }
        if (usage == usage_t) {
            toggle_always_on_top();
            return;
        }
        if (usage == usage_a) {
            toggle_about();
            return;
        }
    }
    if (usage == usage_f11) {
        toggle_fullscreen();
        return;
    }
}

// ---------------------------------------------------------------------------
// The main loop (REGISTER -> chrome policy -> wait/serve events forever).
// ---------------------------------------------------------------------------

export fn _start() callconv(.c) noreturn {
    // The whole body is Zig below (freestanding, no libc) — the entry is a
    // plain function; the kernel enters at _start with a valid stack,
    // exactly like NOTEPAD.BIN. This program never returns.
    main();
}

fn main() noreturn {
    // WMS3: REGISTER (cmd 1). Only seated when the kernel compositor seam is
    // armed (the live gate boots with --screen); otherwise ENXIO parks here.
    if (syscall6(sys_wmctl, wmctl_register, 0, 0, 0, 0, 0) != 0) {
        while (true) {
            _ = syscall0(sys_yield_num); // fail-safe park
        }
    }
    write_marker(registered_marker);

    // WMS4 (issue #624): submit the chrome POLICY — one
    // sys_wmctl(SET_WINDOW, a0=ALL, a1=0, a2=0, ptr=desc, len=40). The WM
    // becomes the theme owner: the kernel blits chrome from this descriptor
    // (dark-theme values, byte-equal to the shim's own constants — parity by
    // value). Issued right after REGISTER, before any window exists, so every
    // window created later inherits it (the kernel's draw-time fallback).
    const desc = wnd_core.chrome_parity_policy();
    _ = syscall6(sys_wmctl, wmctl_set_window, 0xFFFF_FFFF, 0, 0, @intFromPtr(&desc), wnd_core.chrome_desc_bytes);

    // WMS5 mirror + drag + policy state.
    var ev: Event = undefined;
    var ticks: u64 = 0;
    var presents: u64 = 0;
    var grabbing: bool = false;
    var grab_dx: u32 = 0;
    var grab_dy: u32 = 0;
    var prev_btn: u8 = 0;
    var notif_open: bool = false;
    // WMS6 Gate E (issue #626): the tray widget-content state the WM owns.
    var tray_state: TrayState = .{};
    var prev_in_tray: bool = false;
    var prev_dock_idx: ?u8 = null;

    while (true) {
        // BLOCK until at least one event is queued for this process. The
        // kernel delivers COMPOSITE_TICK (18), WM_POINTER (19), WM_WINDOW
        // (20), and WM_KEY (21) while we are registered. `handle_wait_event`
        // returns immediately while the queue is non-empty and only parks us
        // when it drains — so a single wake serves the WHOLE backlog, and
        // the bounded work per wake is "drain the queue", not "one event".
        const wait_rc = syscall1(sys_wait_event_num, @intFromPtr(&ev));
        if (wait_rc != 1) {
            // TEMP DEBUG: print the wait_event return code.
            var dbg: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&dbg, "wnd: wait_rc={d}\n", .{wait_rc}) catch "wnd: dbg-err\n";
            write_marker(s);
            _ = syscall0(sys_yield_num);
            continue;
        }
        switch (ev.kind) {
            composite_tick_kind => {
                ticks +%= 1;
                if (ticks % present_every == 0) {
                    _ = syscall6(sys_wmctl, wmctl_request_present, 0, 0, 0, 0, 0);
                    presents +%= 1;
                    if (presents % marker_every == 0) {
                        write_marker(present_marker);
                    }
                }
                // WMS6 Gate E (issue #626): the tray refresh cadence — every
                // `tray_refresh_every` ticks the WM re-decides the tray
                // widget content from its own state (the clock string from
                // the tick counter, the clipboard indicator from a
                // sys_clipboard_get probe) and issues TRAY on change. Before
                // this gate the tray froze while a WM was registered (the
                // kernel's drain is gated off); now the WM drives it.
                if (ticks % tray_refresh_every == 0) {
                    var clip_buf: [tray_clip_probe]u8 = undefined;
                    const clip_len = syscall3(sys_clipboard_get, @intFromPtr(&clip_buf), clip_buf.len, 0);
                    _ = tray_tick_policy(ticks, clip_len != 0, &tray_state);
                }
                // WMS7 Gate A (issue #627): the app↔WM mailbox service loop —
                // serve any WM_RPC requests an app queued in the WM's inbox
                // since the last wake (<= 1 s latency at the 1 Hz tick).
                wnd_mail_loop();
            },
            wm_window_kind => {
                // WM_WINDOW (kind 20) registry mirror: flags low byte = id,
                // bit 8 = visible, bit 9 = focused, bits 10-11 = workspace;
                // arg0 = x|(y<<16), arg1 = w|(h<<16).
                const id: u8 = @intCast(ev.flags & 0xff);
                const s = mirror_slot(id) orelse continue; // not a window we track
                const m = &mirrors[s];
                m.id = id;
                m.valid = true;
                m.x = ev.arg0 & 0xffff;
                m.y = ev.arg0 >> 16;
                m.w = ev.arg1 & 0xffff;
                m.h = ev.arg1 >> 16;
                m.visible = (ev.flags & (1 << 8)) != 0;
                m.focused = (ev.flags & (1 << 9)) != 0;
                m.workspace = @intCast((ev.flags >> 10) & 0x3);
                m.unsaved = (ev.flags & (1 << 12)) != 0;
            },
            wm_pointer_kind => {
                // WM_POINTER (kind 19): raw absolute pointer. arg0 =
                // px|(py<<16) (framebuffer pixels), flags low byte = HID
                // button byte (0x01 = left). The WM — not the kernel —
                // hit-tests and decides geometry.
                const px = ev.arg0 & 0xffff;
                const py = ev.arg0 >> 16;
                const btn: u8 = @intCast(ev.flags & 0xff);
                const left = (btn & btn_left) != 0;
                const prev_left = (prev_btn & btn_left) != 0;

                // Issue #821 Phase 1: God Menu modal pointer capture
                if (god_menu_open) {
                    const menu_x = if (fb_w > god_menu_w) (fb_w - god_menu_w) / 2 else 0;
                    const menu_y = if (fb_h > god_menu_h) (fb_h - god_menu_h) / 2 else 0;
                    if (!prev_left and left) {
                        if (px < menu_x or px >= menu_x + god_menu_w or py < menu_y or py >= menu_y + god_menu_h) {
                            toggle_god_menu();
                        } else {
                            const mev = ui.Event{
                                .kind = ui.MOUSE_DOWN,
                                .flags = ui.BTN_LEFT,
                                .seq = 0,
                                .arg0 = px - menu_x,
                                .arg1 = py - menu_y,
                            };
                            if (god_menu.handle_event(&mev)) {
                                if (!god_menu.is_open()) {
                                    if (god_menu.last_invoked_cmd) |lic| {
                                        execute_god_menu_command(lic);
                                    }
                                    toggle_god_menu();
                                } else {
                                    redraw_god_menu();
                                }
                            }
                        }
                    } else if (px >= menu_x and px < menu_x + god_menu_w and py >= menu_y and py < menu_y + god_menu_h) {
                        const mev = ui.Event{
                            .kind = ui.MOUSE_MOVE,
                            .flags = 0,
                            .seq = 0,
                            .arg0 = px - menu_x,
                            .arg1 = py - menu_y,
                        };
                        if (god_menu.handle_event(&mev)) {
                            redraw_god_menu();
                        }
                    }
                    prev_btn = btn;
                    continue;
                }

                if (grabbing) {
                    if (left) {
                        // While held: MOVE via SET_WINDOW rect (the kernel
                        // clamps whatever we propose and mirrors the clamped
                        // truth back at us).
                        const fm = focused_mirror();
                        if (fm) |m| {
                            const nx = px -% grab_dx;
                            const ny = py -% grab_dy;
                            set_window_rect(m.id, nx, ny, m.w, m.h);
                            m.x = nx;
                            m.y = ny;
                            write_marker(drag_marker);
                        }
                    } else {
                        // Released: DROP. Snap if the drop point is near a
                        // scanout edge (M15 C3).
                        grabbing = false;
                        const fm = focused_mirror();
                        if (fm) |m| {
                            snap_window_to(m.id, px, py);
                        }
                        write_marker(drop_marker);
                    }
                } else {
                    // Not grabbing: a left-button DOWN EDGE starts a drag —
                    // but only when the pointer is inside the focused
                    // window's TITLE BAR (the wnd_core.title_bar_contains
                    // rule: [my, my+16), full width).
                    if (!prev_left and left) {
                        // WMS6 Gate B (issue #626): a left-button DOWN EDGE on
                        // the TRAY (the taskbar's right slice) toggles the
                        // notification center — the WM, not the kernel,
                        // decides (the kernel's own tray-click handler is
                        // gated behind !wm_owns_input). Mirrors the shim's
                        // tray_rect so the live gate's injected click is
                        // visible to both surfaces.
                        if (py >= fb_h - taskbar_h and px >= fb_w - tray_w) {
                            notif_open = !notif_open;
                            _ = syscall6(sys_wmctl, wmctl_notif_center, if (notif_open) notif_open_act else notif_close_act, 0, 0, 0, 0);
                            write_marker(if (notif_open) notif_open_marker else notif_close_marker);
                        }
                        // WMS6 Gate D (issue #626): a left-button DOWN EDGE on a
                        // dock icon issues DOCK — the WM, not the kernel, decides.
                        if (dock_icon_at(px, py)) |didx| {
                            handle_dock_click(didx);
                        }
                        // WMS8 Gate 4 (issue #628): the unsaved-changes dialog —
                        // the WM, not the kernel, decides. While the dialog is
                        // open, a click routes to its buttons (the shared
                        // wnd_core rule — the same rects the kernel's
                        // unsaved_dialog_click applies, parity by construction).
                        // Otherwise a close-button click (title-bar top-right)
                        // on a DIRTY mirror (kind-20 unsaved bit) shows it.
                        // Review fix (claim 7639): the DOWN EDGE is CONSUMED
                        // when the dialog or a close button takes it — the
                        // kernel shim set `handled_btn` and broke, and the WM
                        // must not also start a title-bar grab (the close rect
                        // sits inside the title band).
                        var down_handled = false;
                        if (unsaved_dialog_open) {
                            apply_unsaved_choice(wnd_core.unsaved_dialog_choice_at(fb_w, fb_h, px, py));
                            down_handled = true;
                        } else {
                            // Review fix (claim 7639): scan TOP-DOWN (the
                            // kernel shim walks win_count..0) so an
                            // overlapping higher window's title bar wins —
                            // z-order == id order (raise() has no callers),
                            // so reverse id order == top of the stack.
                            var si: usize = max_user_windows;
                            while (si > 0) {
                                si -= 1;
                                const m = &mirrors[si];
                                if (!m.valid or !m.visible) continue;
                                if (px >= m.x + m.w - 16 and px < m.x + m.w - 4 and
                                    py >= m.y and py < m.y + wnd_core.title_bar_h)
                                {
                                    if (m.unsaved) show_unsaved_dialog(m.id);
                                    // Not dirty: the WM has no close capability
                                    // yet (status quo — a later gate); ignore.
                                    down_handled = true;
                                    break;
                                }
                            }
                        }
                        // WMS5: a title-bar grab starts a drag — only when the
                        // DOWN EDGE was not consumed above (the dialog or a
                        // close button already took it).
                        if (!down_handled) {
                            const fm = focused_mirror();
                            if (fm) |m| {
                                const g = wnd_core.Geom{
                                    .id = m.id,
                                    .kind = .user,
                                    .x = m.x,
                                    .y = m.y,
                                    .w = m.w,
                                    .h = m.h,
                                    .visible = m.visible,
                                    .workspace = m.workspace,
                                };
                                if (wnd_core.title_bar_contains(g, px, py)) {
                                    grabbing = true;
                                    grab_dx = px -% m.x;
                                    grab_dy = py -% m.y;
                                    write_marker(grab_marker);
                                }
                            }
                        }
                    }
                }
                // WMS6 Gate C (issue #626): hover (move, no click) over the
                // TRAY shows a tooltip — the WM, not the kernel, decides when
                // and what (kind 19 already fanned the hover; the kernel's
                // own tooltip system is a dormant stub that WMS8 deletes).
                const in_tray = (py >= fb_h - taskbar_h and px >= fb_w - tray_w);
                if (in_tray and !prev_in_tray) {
                    _ = syscall6(sys_wmctl, wmctl_tooltip, tooltip_show_act, 0, 0, @intFromPtr(tray_tooltip_text.ptr), tray_tooltip_text.len);
                    write_marker(tooltip_show_marker);
                } else if (!in_tray and prev_in_tray) {
                    _ = syscall6(sys_wmctl, wmctl_tooltip, tooltip_hide_act, 0, 0, 0, 0);
                    write_marker(tooltip_hide_marker);
                }
                prev_in_tray = in_tray;
                // WMS6 Gate D (issue #626): hover over a DOCK icon shows its
                // label (via the Gate-C TOOLTIP seam); leaving hides it.
                const didx = dock_icon_at(px, py);
                handle_dock_hover(prev_dock_idx, didx);
                prev_dock_idx = didx;
                prev_btn = btn;
            },
            wm_key_kind => {
                // WM_KEY (kind 21): raw keyboard — arg0 = HID usage, flags =
                // ADR 0009 modifier bits. The WM — not the kernel — decides
                // geometry from chords.
                handle_wm_key(@intCast(ev.arg0), ev.flags);
            },
            else => {},
        }
    }
}

test "wnd: module compiles and exports the EL0 entry (drift guard import)" {
    _ = @intFromPtr(&_start);
    // The WM binary is built against the SAME shared rules as the kernel shim.
    _ = wnd_core.hit_test;
    _ = wnd_core.clamp_resize_w;
}

test "wnd: the WMS4 chrome policy matches the shared parity values (drift guard)" {
    const p = wnd_core.chrome_parity_policy();
    try std.testing.expectEqual(policy_kind, p.kind);
    try std.testing.expectEqual(policy_flags, p.flags);
    try std.testing.expectEqual(policy_border_rgb, p.border_rgb);
    try std.testing.expectEqual(policy_border_unfocus_rgb, p.border_unfocus_rgb);
    try std.testing.expectEqual(policy_title_bg_rgb, p.title_bg_rgb);
    try std.testing.expectEqual(policy_title_fg_rgb, p.title_fg_rgb);
    try std.testing.expectEqual(policy_ring_rgb, p.ring_rgb);
    try std.testing.expectEqual(policy_close_rgb, p.close_rgb);
    try std.testing.expectEqual(policy_min_rgb, p.min_rgb);
    try std.testing.expectEqual(policy_pin_rgb, p.pin_rgb);
    // The descriptor itself validates under the kernel's single refusal rule.
    try std.testing.expect(wnd_core.chrome_valid(p));
}

test "wnd: the marker/tuning shapes are pinned (live-gate grep targets)" {
    try std.testing.expectEqualStrings("wnd: registered\n", registered_marker);
    try std.testing.expectEqual(@as(usize, 16), registered_marker.len);
    try std.testing.expectEqualStrings("wnd: present\n", present_marker);
    try std.testing.expectEqual(@as(usize, 13), present_marker.len);
    try std.testing.expectEqual(@as(u32, 2), present_every);
    try std.testing.expectEqual(@as(u32, 1), marker_every);
    try std.testing.expectEqual(@as(u64, 18), composite_tick_kind);
    // WMS5: the drag markers + kinds (the live gate greps these).
    try std.testing.expectEqualStrings("wnd: grab\n", grab_marker);
    try std.testing.expectEqual(@as(usize, 10), grab_marker.len);
    try std.testing.expectEqualStrings("wnd: drag\n", drag_marker);
    try std.testing.expectEqual(@as(usize, 10), drag_marker.len);
    try std.testing.expectEqualStrings("wnd: drop\n", drop_marker);
    try std.testing.expectEqual(@as(usize, 10), drop_marker.len);
    try std.testing.expectEqual(@as(u64, 19), wm_pointer_kind);
    try std.testing.expectEqual(@as(u64, 20), wm_window_kind);
    try std.testing.expectEqual(@as(u64, 21), wm_key_kind);
    try std.testing.expectEqual(@as(u8, 0x01), btn_left);
    // WMS5 Gate 2: the policy markers + chords are pinned too.
    try std.testing.expectEqualStrings("wnd: tile\n", tile_marker);
    try std.testing.expectEqualStrings("wnd: snap\n", snap_marker);
    try std.testing.expectEqualStrings("wnd: min\n", min_marker);
    try std.testing.expectEqualStrings("wnd: max\n", max_marker);
    try std.testing.expectEqualStrings("wnd: ws\n", ws_marker);
    try std.testing.expectEqualStrings("wnd: fs\n", fs_marker);
    try std.testing.expectEqualStrings("wnd: aot\n", aot_marker);
    try std.testing.expectEqualStrings("wnd: alt-tab", alt_tab_marker);
    try std.testing.expectEqual(@as(u8, 0x2b), usage_tab);
    try std.testing.expectEqual(@as(u64, 5), wmctl_alt_tab);
    try std.testing.expectEqual(@as(u64, 3), alt_tab_commit);
    // WMS6 Gate B (issue #626): the notification-center markers + subcommands.
    try std.testing.expectEqualStrings("wnd: notif-open\n", notif_open_marker);
    try std.testing.expectEqualStrings("wnd: notif-close\n", notif_close_marker);
    try std.testing.expectEqualStrings("wnd: notif-clear\n", notif_clear_marker);
    try std.testing.expectEqualStrings("wnd: notif-dismiss\n", notif_dismiss_marker);
    try std.testing.expectEqual(@as(u64, 6), wmctl_notif_center);
    try std.testing.expectEqual(@as(u64, 7), wmctl_notif_dismiss);
    try std.testing.expectEqual(@as(u32, 80), tray_w);
    // WMS6 Gate C (issue #626): the tooltip markers + subcommand.
    try std.testing.expectEqualStrings("wnd: tooltip\n", tooltip_show_marker);
    try std.testing.expectEqualStrings("wnd: tooltip-hide\n", tooltip_hide_marker);
    try std.testing.expectEqualStrings("Clock", tray_tooltip_text);
    try std.testing.expectEqual(@as(u64, 8), wmctl_tooltip);
    try std.testing.expectEqual(@as(u64, 1), tooltip_show_act);
    try std.testing.expectEqual(@as(u64, 0), tooltip_hide_act);
    // WMS6 Gate D (issue #626): the dock marker + labels + subcommand.
    try std.testing.expectEqualStrings("wnd: dock", dock_marker);
    try std.testing.expectEqualStrings("Calc", dock_labels[0]);
    try std.testing.expectEqualStrings("Notes", dock_labels[1]);
    try std.testing.expectEqualStrings("Terminal", dock_labels[2]);
    try std.testing.expectEqualStrings("Browser", dock_labels[3]);
    try std.testing.expectEqualStrings("Settings", dock_labels[4]);
    try std.testing.expectEqual(@as(u64, 9), wmctl_dock);
    // WMS6 Gate E (issue #626): the tray marker + policy constants.
    try std.testing.expectEqualStrings("wnd: tray", tray_marker);
    try std.testing.expectEqual(@as(u8, 'D'), tray_theme_letter);
    try std.testing.expectEqual(@as(u64, 10), tray_refresh_every);
    try std.testing.expectEqual(@as(u64, 10), wmctl_tray);
    try std.testing.expectEqual(@as(u64, 39), sys_clipboard_get);
    // WMS7 Gate A (issue #627): the mailbox-service marker + slot consts.
    try std.testing.expectEqualStrings("wnd: mail", mail_marker);
    try std.testing.expectEqual(@as(u64, 6), sys_ipc_recv);
    try std.testing.expectEqual(@as(u64, 5), sys_ipc_send);
    try std.testing.expectEqual(@as(usize, 64), mail_inbox_max);
    try std.testing.expectEqual(@as(u8, 0x17), usage_t);
    try std.testing.expectEqual(@as(u8, 0x10), usage_m);
    try std.testing.expectEqual(@as(u8, 0x11), usage_n);
    // WMS8 Gate 2 (issue #628): the about-dialog channel — subcommand 11,
    // toggle action 2, the Ctrl+Shift+A HID usage, and the decision marker
    // (the live gate greps `wnd: about`).
    try std.testing.expectEqualStrings("wnd: about\n", about_marker);
    try std.testing.expectEqual(@as(u64, 11), wmctl_dialog);
    try std.testing.expectEqual(@as(u64, 2), dialog_toggle_act);
    try std.testing.expectEqual(@as(u8, 0x04), usage_a);
    // WMS8 Gate 4 (issue #628): the unsaved-dialog channel — DIALOG actions
    // 3-6, the decision markers, and the mirror's unsaved bit (12).
    try std.testing.expectEqualStrings("wnd: unsaved-dialog\n", unsaved_dialog_marker);
    try std.testing.expectEqualStrings("wnd: unsaved-save\n", unsaved_save_marker);
    try std.testing.expectEqualStrings("wnd: unsaved-discard\n", unsaved_discard_marker);
    try std.testing.expectEqualStrings("wnd: unsaved-cancel\n", unsaved_cancel_marker);
    try std.testing.expectEqual(@as(u64, 3), dialog_unsaved_show);
    try std.testing.expectEqual(@as(u64, 4), dialog_unsaved_save);
    try std.testing.expectEqual(@as(u64, 5), dialog_unsaved_dont_save);
    try std.testing.expectEqual(@as(u64, 6), dialog_unsaved_cancel);
    try std.testing.expectEqual(@as(u32, 200), wnd_core.unsaved_dialog_w);
    try std.testing.expectEqual(@as(u32, 100), wnd_core.unsaved_dialog_h);
}

test "wnd: the WMS6 tray policy formats HH:MM and issues TRAY on change only" {
    // The WM's clock mirrors the shim's minute-rollover formula (parity).
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("00:00", format_wm_hhmm(&buf, 0));
    try std.testing.expectEqualStrings("00:01", format_wm_hhmm(&buf, 60));
    try std.testing.expectEqualStrings("01:00", format_wm_hhmm(&buf, 3600));
    try std.testing.expectEqualStrings("12:34", format_wm_hhmm(&buf, 12 * 3600 + 34 * 60));
    // The policy issues on the FIRST refresh (content differs from unset)...
    var st: TrayState = .{};
    try std.testing.expect(tray_tick_policy(0, false, &st));
    try std.testing.expect(st.clock_set);
    // ...and not again while the content is unchanged (mirrors the shim drain).
    try std.testing.expect(!tray_tick_policy(5, false, &st));
    // A minute rollover re-issues.
    try std.testing.expect(tray_tick_policy(60, false, &st));
    // A clipboard change re-issues.
    try std.testing.expect(tray_tick_policy(61, true, &st));
    try std.testing.expect(!tray_tick_policy(62, true, &st));
}

test "wnd: the WMS5 drag-grab rule matches the shared title-bar rule (drift guard)" {
    const g = wnd_core.Geom{ .id = 2, .kind = .user, .x = 100, .y = 100, .w = 400, .h = 300, .visible = true, .workspace = 0 };
    try std.testing.expect(wnd_core.title_bar_contains(g, 100, 100)); // top-left
    try std.testing.expect(wnd_core.title_bar_contains(g, 300, 115)); // mid band
    try std.testing.expect(!wnd_core.title_bar_contains(g, 300, 116)); // one below the band
    try std.testing.expect(!wnd_core.title_bar_contains(g, 300, 200)); // client area
    try std.testing.expectEqual(@as(usize, 16), wnd_core.title_bar_h);
    // The kernel re-exports the SAME number (no second constant to drift).
    _ = wnd_core.hit_test;
}

test "wnd: the WMS6 dock icon hit-test matches the shim's grid (drift guard)" {
    // The shim's M15 C4 grid: 20×20 icons at (2, 8+idx*32), 5 icons.
    try std.testing.expectEqual(@as(?u8, 0), dock_icon_at(12, 18)); // icon 0 center
    try std.testing.expectEqual(@as(?u8, 1), dock_icon_at(12, 40)); // icon 1 (8+32)
    try std.testing.expectEqual(@as(?u8, 4), dock_icon_at(12, 8 + 4 * 32 + 5)); // icon 4
    try std.testing.expectEqual(@as(?u8, 1), dock_icon_at(12, 8 + 1 * 32 + 19)); // icon 1 bottom edge
    // The 12 px gap between icons (20 px box, 32 px pitch) is a miss.
    try std.testing.expectEqual(@as(?u8, null), dock_icon_at(12, 8 + 20));
    // Outside the icon x-band / below the 5 icons is a miss.
    try std.testing.expectEqual(@as(?u8, null), dock_icon_at(0, 18)); // left of the band
    try std.testing.expectEqual(@as(?u8, null), dock_icon_at(22, 18)); // right of the band
    try std.testing.expectEqual(@as(?u8, null), dock_icon_at(12, 8 + 5 * 32)); // below icon 4
}

test "wnd: the WMS6 Alt+Tab target rule (drift guard against the shim snapshot)" {
    // Two visible windows on the current workspace (mirrors built from kind-20).
    // Zero-fill FIRST: `= undefined` left slots 4+ with garbage `.valid` bits
    // that made this drift guard flaky standalone (the pure rule iterates the
    // WHOLE table; unset slots must read `valid=false`, as in the zeroed BSS
    // of the real EL0 binary). Pre-existing Gate-A bug, fixed with Gate E.
    mirrors = [_]MirrorWin{.{}} ** max_user_windows;
    mirrors[0] = MirrorWin{ .id = 2, .visible = true, .workspace = 0, .valid = true, .focused = true };
    mirrors[1] = MirrorWin{ .id = 3, .visible = true, .workspace = 0, .valid = true, .focused = false };
    // Hidden + off-workspace windows never cycled (M21 W3/W4).
    mirrors[2] = MirrorWin{ .id = 4, .visible = true, .workspace = 1, .valid = true, .focused = false };
    mirrors[3] = MirrorWin{ .id = 5, .visible = false, .workspace = 0, .valid = true, .focused = false };
    current_workspace = 0;
    // Focused (2) -> next is 3.
    try std.testing.expectEqual(@as(?u8, 3), next_alt_tab_target());
    // One candidate only (hide 3) -> null (shim no-op).
    mirrors[1].visible = false;
    try std.testing.expectEqual(@as(?u8, null), next_alt_tab_target());
    mirrors[1].visible = true;
    // A stale/corrupt mirror slot (id < 2) is skipped, not a target — with
    // TWO real candidates left (3, 5) the cycle runs over them only (no
    // focused window -> start at slot 0 -> next is 5; the corrupt id-1 slot
    // is never selected). Pre-existing Gate-A assertion bug (it expected 3
    // with a single candidate, which the rule correctly no-ops), fixed with
    // Gate E.
    mirrors[0].id = 1;
    mirrors[0].focused = false;
    mirrors[3].visible = true;
    try std.testing.expectEqual(@as(?u8, 5), next_alt_tab_target());
}

test "wnd: the WMS5 Gate 2 policy issues the SAME rects as the kernel shim (drift guard)" {
    // The WM's tile layout must match the kernel's apply_tile_layout numbers
    // (master 2/3 left, detail 1/3 right on a 1280x720 scanout with the
    // 20 px taskbar + 24 px dock).
    const tl = wnd_core.tile_layout(fb_w, fb_h, taskbar_h, dock_w, 667, true);
    try std.testing.expectEqual(@as(u32, 1256), tl.master_w + tl.detail_w);
    try std.testing.expectEqual(@as(u32, 837), tl.master_w);
    try std.testing.expectEqual(@as(u32, 419), tl.detail_w);
    try std.testing.expectEqual(@as(u32, 24), tl.master_x);
    try std.testing.expectEqual(@as(u32, 24 + 837), tl.detail_x);
    try std.testing.expectEqual(@as(u32, 700), tl.h); // 720 - 20 taskbar
    // Maximize = the workspace area (dock + taskbar excluded).
    const mx = wnd_core.maximize_rect(fb_w, fb_h, taskbar_h, dock_w);
    try std.testing.expectEqual(@as(u32, 24), mx.x);
    try std.testing.expectEqual(@as(u32, 0), mx.y);
    try std.testing.expectEqual(@as(u32, 1256), mx.w);
    try std.testing.expectEqual(@as(u32, 700), mx.h);
    // Snap bounds (M15 C3) — left half, taskbar excluded.
    const lb = wnd_core.snap_zone_bounds(.left, fb_w, fb_h, taskbar_h).?;
    try std.testing.expectEqual(@as(u32, 640), lb.w);
    try std.testing.expectEqual(@as(u32, 700), lb.h);
    // The WM's mirrored constants are the SAME numbers (no drift).
    try std.testing.expectEqual(wnd_core.fb_w, fb_w);
    try std.testing.expectEqual(wnd_core.taskbar_h, taskbar_h);
    try std.testing.expectEqual(wnd_core.dock_w, dock_w);
}

test "wnd: hid_to_ascii maps keyboard usages accurately" {
    try std.testing.expectEqual(@as(?u8, 'a'), hid_to_ascii(0x04, false));
    try std.testing.expectEqual(@as(?u8, 'A'), hid_to_ascii(0x04, true));
    try std.testing.expectEqual(@as(?u8, 'z'), hid_to_ascii(0x1d, false));
    try std.testing.expectEqual(@as(?u8, 'Z'), hid_to_ascii(0x1d, true));
    try std.testing.expectEqual(@as(?u8, '1'), hid_to_ascii(0x1e, false));
    try std.testing.expectEqual(@as(?u8, '!'), hid_to_ascii(0x1e, true));
    try std.testing.expectEqual(@as(?u8, ' '), hid_to_ascii(usage_space, false));
    try std.testing.expectEqual(@as(?u8, '\n'), hid_to_ascii(0x28, false));
    try std.testing.expectEqual(@as(?u8, 0x08), hid_to_ascii(0x2a, false));
    try std.testing.expectEqual(@as(?u8, null), hid_to_ascii(0x29, false)); // Escape
}

test "wnd: god menu init, 6-section population, and type-to-filter" {
    populate_god_menu();
    try std.testing.expect(god_menu_initialized);
    try std.testing.expect(god_menu_mascot_loaded);
    try std.testing.expect(god_menu.raster_mascot != null);
    try std.testing.expectEqual(@as(u32, 24), god_menu.raster_mascot.?.width);
    try std.testing.expectEqual(@as(u32, 24), god_menu.raster_mascot.?.height);

    // Verify sections have commands
    var sec0_cmds: [16]Command = undefined;
    const sec0_cnt = god_menu.registry.get_section_commands(.system, &sec0_cmds);
    try std.testing.expect(sec0_cnt >= 4);

    var sec1_cmds: [16]Command = undefined;
    const sec1_cnt = god_menu.registry.get_section_commands(.apps, &sec1_cmds);
    try std.testing.expect(sec1_cnt >= 3);

    // Verify type-to-filter in God Menu
    god_menu.set_search_query("calc");
    try std.testing.expect(god_menu.filtered_count > 0);
    try std.testing.expectEqualStrings("calc", god_menu.filtered[0].command.verb);

    god_menu.set_search_query("about");
    try std.testing.expect(god_menu.filtered_count > 0);
    try std.testing.expectEqualStrings("about", god_menu.filtered[0].command.verb);
}

test "wnd: god menu key chord Ctrl+Space toggle and state" {
    // Ensure initial closed state
    god_menu_open = false;
    god_menu_win = null;

    // Simulate Ctrl+Space chord
    handle_wm_key(usage_space, mod_ctrl);
    try std.testing.expect(god_menu_initialized);
}
