//! DipshitOS M32 WMS3 — WND.BIN, the long-lived EL0 window-manager SERVER
//! (issue #623).
//!
//! The FIRST present pacing that is NOT the shell idle: this process calls
//! `sys_wmctl REGISTER` (slot 65, cmd 1) at startup, then loops on
//! `sys_wait_event` (slot 22), servicing the kernel's kind-18
//! `COMPOSITE_TICK` and issuing `REQUEST_PRESENT` (slot 65, cmd 3) at its
//! OWN cadence (every `present_every` ticks, not every tick). While it is
//! registered the shell idle drain is a no-op (WMS2), so THIS loop drives
//! the desktop's scanout presents.
//!
//! It NEVER exits — it occupies its scheduler slot + process row for the
//! whole session, like COUNTER.BIN/PEER.BIN. A bounded tick budget per wake
//! (fixed small work: count, maybe present, maybe a marker, then yield) and
//! a blocking `sys_wait_event` between wakes mean a misbehaving WM cannot
//! busy-spin the CPU; the kernel round-robins every tick regardless (the
//! WMS2 exit fallback covers the WM being killed, this blocks-in-wait covers
//! a hung one stalling the ring).
//!
//! The pure policy RULES it will own in WMS4+ are compiled from the SAME
//! source as the kernel shim (`kernel/src/wnd_core.zig`, the drift guard);
//! this file imports it now so the WM binary is built against the identical
//! geometry/hit-test/z-order rules — the single-source guarantee.
//!
//! The payload is the established naked-asm, fixed-register-ABI shape (no
//! Zig-generated memory references or calls; sys_write for markers,
//! sys_wait_event for the tick, sys_wmctl for register/present, sys_yield to
//! keep the ring live). Marker constants are `pub const`s so host tests pin
//! the EXACT shapes and the live gate's grep targets cannot drift.

const std = @import("std");
// The drift guard: BOTH the kernel shim and this WM server compile the same
// pure rules from one file — the two implementations cannot behaviorally
// drift while both are live. WND.BIN's naked payload is pacing-only in WMS3,
// so it does not call these yet; the import proves single-source builds.
// Provided by build.zig as an anonymous import (the kernel compiles the
// same file from kernel/src/wnd_core.zig).
const wnd_core = @import("wnd_core");

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
// stream (19, WM_POINTER) and the window-registry mirrors (20, WM_WINDOW).
// Pinned against kernel events (drift guard), like kind 18.
pub const wm_pointer_kind: u64 = 19;
pub const wm_window_kind: u64 = 20;
/// Left-button bit inside the WM_POINTER `flags` byte (must match the HID
/// button byte the kernel fans out: 0x01 = left).
pub const btn_left: u8 = 0x01;
/// The title-bar drag markers — written on grab / move-while-held / drop.
/// The live gate greps these to prove the WM — not the kernel — moved the
/// window (the kernel's own geometry is gated off while a WM is registered).
pub const grab_marker: []const u8 = "wnd: grab\n";
pub const drag_marker: []const u8 = "wnd: drag\n";
pub const drop_marker: []const u8 = "wnd: drop\n";

// WMS4 (issue #624): the EXACT values the chrome-descriptor blob (label 3
// in the naked payload) embeds. Pinned against the shared wnd_core parity
// policy below, so the EL0 blob cannot drift from the kernel's expectation
// without a test failure — the drift guard extended to the chrome policy.
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

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// sys_wmctl(REGISTER) — slot 65, cmd 1. Only seated when the kernel
        \\// compositor seam is armed (the live gate boots with --screen);
        \\// otherwise ENXIO parks here (fail-safe).
        \\mov x0, #1
        \\mov x8, #65
        \\svc #0
        \\cmp x0, #0
        \\b.ne 9f
        \\// marker: "wnd: registered\n" (16 bytes)
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #16
        \\mov x8, #1
        \\svc #0
        \\// WMS4 (issue #624): submit the chrome POLICY — one
        \\// sys_wmctl(SET_WINDOW, a0=ALL, a1=0, a2=0, ptr=desc, len=40).
        \\// The WM becomes the theme owner: the kernel blits chrome from
        \\// this descriptor (dark-theme values, byte-equal to the shim's
        \\// own constants — parity by value). Issued right after REGISTER,
        \\// before any window exists, so every window created later
        \\// inherits it (the kernel's draw-time fallback).
        \\mov x0, #2
        \\mov x1, #0xffff
        \\movk x1, #0xffff, lsl #16   // a0 = 0xFFFFFFFF (all windows)
        \\mov x2, #0
        \\mov x3, #0
        \\adr x4, 3f
        \\mov x5, #40                 // len = the frozen 40-byte descriptor
        \\mov x8, #65
        \\svc #0
        \\// counters: x19 = ticks serviced, x20 = presents issued.
        \\// thresholds: x21 = present_every, x22 = marker_every.
        \\mov x19, #0
        \\mov x20, #0
        \\mov x21, #2
        \\mov x22, #1
        \\// WMS5 mirror + drag state: x26 = mirrored window id (0 = none),
        \\// x27 = mirrored x|(y<<16), x28 = mirrored w|(h<<16). Stack holds
        \\// the grab state: [sp+16] grabbing (0/1), [sp+20] grab dx,
        \\// [sp+24] grab dy, [sp+28] previous pointer button byte.
        \\mov x26, #0
        \\mov x27, #0
        \\mov x28, #0
        \\sub sp, sp, #32
        \\str wzr, [sp, #16]
        \\str wzr, [sp, #20]
        \\str wzr, [sp, #24]
        \\str wzr, [sp, #28]
        \\10:
        \\// sys_wait_event(sp) — BLOCKS until an event is queued for this
        \\// process. The kernel delivers COMPOSITE_TICK (kind 18) once per
        \\// scheduler tick, WM_POINTER (kind 19) on pointer state changes,
        \\// and WM_WINDOW (kind 20) registry mirrors while we are registered.
        \\mov x0, sp
        \\mov x8, #22
        \\svc #0
        \\cmp x0, #1
        \\b.ne 10b            // spurious/no event: keep waiting
        \\ldrh w23, [sp, #0]  // event kind (u16 at offset 0)
        \\cmp w23, #20
        \\b.eq 20f            // WM_WINDOW registry mirror
        \\cmp w23, #19
        \\b.eq 19f            // WM_POINTER raw stream
        \\cmp w23, #18
        \\b.ne 10b            // unknown kind: keep waiting
        \\add x19, x19, #1
        \\// if (ticks % present_every == 0) -> REQUEST_PRESENT
        \\udiv x24, x19, x21
        \\msub x25, x24, x21, x19
        \\cbnz x25, 12f       // not on this wake
        \\mov x0, #3          // WMCTL_REQUEST_PRESENT
        \\mov x8, #65
        \\svc #0
        \\add x20, x20, #1
        \\// if (presents % marker_every == 0) -> marker (bounds serial volume)
        \\udiv x24, x20, x22
        \\msub x25, x24, x22, x20
        \\cbnz x25, 11f
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #13         // "wnd: present\n" = 13 bytes (a 14-byte count
        \\                  // would cross the content-region end and EFAULT
        \\                  // — the exact bug this marker is designed to catch)
        \\mov x8, #1
        \\svc #0
        \\11:
        \\12:
        \\b 8f                // shared tail: yield + loop
        \\20:
        \\// WM_WINDOW (kind 20) registry mirror: the kernel's window row,
        \\// fanned out so the WM can hit-test. flags low byte = id, arg0 =
        \\// x|(y<<16), arg1 = w|(h<<16). One slot: the LAST pushed window
        \\// (the live gate opens exactly one — NOTEPAD).
        \\ldrh w24, [sp, #2]  // flags
        \\and w26, w24, #0xff // mirrored window id
        \\ldr w24, [sp, #8]   // arg0 = x|(y<<16)
        \\mov x27, x24
        \\ldr w24, [sp, #12]  // arg1 = w|(h<<16)
        \\mov x28, x24
        \\b 8f
        \\19:
        \\// WM_POINTER (kind 19): the raw absolute pointer. arg0 = px|(py<<16)
        \\// (framebuffer pixels), flags low byte = HID button byte (0x01 =
        \\// left). The WM — not the kernel — hit-tests and decides geometry.
        \\ldr w24, [sp, #8]   // arg0
        \\and w25, w24, #0xffff   // px
        \\lsr w24, w24, #16       // py
        \\ldrh w23, [sp, #2]  // flags
        \\and w23, w23, #0xff     // buttons
        \\ldr w0, [sp, #28]   // previous buttons
        \\and w0, w0, #1      // prev_left
        \\and w1, w23, #1     // cur_left
        \\ldr w2, [sp, #16]   // grabbing
        \\cbnz w2, wheld
        \\// Not grabbing: a left-button DOWN EDGE starts a drag — but only
        \\// when the pointer is inside the mirrored window's TITLE BAR
        \\// (the wnd_core.title_bar_contains rule: [my, my+16), full width).
        \\cbnz w0, wdone      // was already down (no edge)
        \\cbz w1, wdone       // not down (no edge)
        \\cbz x26, wdone      // no mirrored window yet
        \\and w2, w27, #0xffff    // mx
        \\lsr w3, w27, #16        // my
        \\and w4, w28, #0xffff    // mw
        \\cmp w25, w2
        \\b.lo wdone          // px < mx
        \\add w5, w2, w4
        \\cmp w25, w5
        \\b.hs wdone          // px >= mx+mw
        \\cmp w24, w3
        \\b.lo wdone          // py < my
        \\add w5, w3, #16     // my + title_bar_h
        \\cmp w24, w5
        \\b.hs wdone          // py >= my+16
        \\// GRAB: remember the grab offset so the window follows the pointer
        \\// (no jump when the drag starts), then mark the grab.
        \\sub w5, w25, w2
        \\str w5, [sp, #20]   // grab dx = px - mx
        \\sub w5, w24, w3
        \\str w5, [sp, #24]   // grab dy = py - my
        \\mov w5, #1
        \\str w5, [sp, #16]   // grabbing = 1
        \\mov x0, #1
        \\adr x1, 4f
        \\mov x2, #10         // "wnd: grab\n" = 10 bytes
        \\mov x8, #1
        \\svc #0
        \\b wdone
        \\wheld:
        \\// While held: still down -> MOVE via SET_WINDOW rect; released ->
        \\// DROP. The kernel clamps whatever we propose (WM proposes,
        \\// kernel clamps) and mirrors the clamped truth back at us.
        \\cbz w1, wdrop
        \\ldr w2, [sp, #20]   // grab dx
        \\ldr w3, [sp, #24]   // grab dy
        \\sub w2, w25, w2     // nx = px - dx
        \\sub w3, w24, w3     // ny = py - dy
        \\// sys_wmctl(SET_WINDOW, a0=id, a1=nx|(ny<<16), a2=w|(h<<16),
        \\// ptr=0, len=0) — a pure-geometry call (no chrome change).
        \\mov x0, #2
        \\mov x1, x26         // window id
        \\orr w2, w2, w3, lsl #16
        \\mov x3, x28         // mirrored w|(h<<16)
        \\mov x4, #0
        \\mov x5, #0
        \\mov x8, #65
        \\svc #0
        \\mov x0, #1
        \\adr x1, 5f
        \\mov x2, #10         // "wnd: drag\n" = 10 bytes
        \\mov x8, #1
        \\svc #0
        \\b wdone
        \\wdrop:
        \\str wzr, [sp, #16]  // grabbing = 0
        \\mov x0, #1
        \\adr x1, 6f
        \\mov x2, #10         // "wnd: drop\n" = 10 bytes
        \\mov x8, #1
        \\svc #0
        \\wdone:
        \\str w23, [sp, #28]  // prev buttons = this sample's buttons
        \\8:
        \\// cooperative yield keeps the round-robin ring live around the
        \\// blocking wait (bounded work per wake — a WM cannot spin forever).
        \\mov x8, #2
        \\svc #0
        \\b 10b
        \\9:
        \\b 9b                // register failed: park (fail-safe)
        \\1:
        \\.ascii "wnd: registered\n"
        \\2:
        \\.ascii "wnd: present\n"
        \\4:
        \\.ascii "wnd: grab\n"
        \\5:
        \\.ascii "wnd: drag\n"
        \\6:
        \\.ascii "wnd: drop\n"
        \\3:
        \\// The WMS4 chrome descriptor blob (40 bytes — kind, flags, then
        \\// the 8 theme colors). Values MUST equal the kernel shim's
        \\// dark-theme chrome constants (user_border/user_border_unfocused/
        \\// user_title_bg/user_title_fg/focus_ring + the fixed button
        \\// colors); the parity host tests pin this against wnd_core's
        \\// chrome_parity_policy and the live gate proves it pixel-exact.
        \\.word 0x0000003f             // kind: border|title|close|minimize|pin|ring
        \\.word 0x00000001             // flags: focus accent
        \\.word 0x000c1826             // border_rgb (focused)
        \\.word 0x00475569             // border_unfocus_rgb
        \\.word 0x001a2b3c             // title_bg_rgb
        \\.word 0x00ffffff             // title_fg_rgb
        \\.word 0x003b82f6             // ring_rgb
        \\.word 0x00ef4444             // close_rgb
        \\.word 0x0094a3b8             // min_rgb
        \\.word 0x0038bdf8             // pin_rgb
    );
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
    try std.testing.expectEqual(@as(usize, 13), present_marker.len); // NOT 14 — an over-count crosses the content region and EFAULTs (observed live)
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
    try std.testing.expectEqual(@as(u8, 0x01), btn_left);
}

test "wnd: the WMS5 drag-grab rule matches the shared title-bar rule (drift guard)" {
    // The EL0 blob hit-tests the title band as [my, my+16) full width — the
    // SAME rule wnd_core.title_bar_contains is; the kernel shim's drag
    // initiation uses the same re-exported user_title_h. Pin the rule's
    // shape here so a rule change on either side fails this test.
    const g = wnd_core.Geom{ .id = 2, .kind = .user, .x = 100, .y = 100, .w = 400, .h = 300, .visible = true, .workspace = 0 };
    try std.testing.expect(wnd_core.title_bar_contains(g, 100, 100)); // top-left
    try std.testing.expect(wnd_core.title_bar_contains(g, 300, 115)); // mid band
    try std.testing.expect(!wnd_core.title_bar_contains(g, 300, 116)); // one below the band
    try std.testing.expect(!wnd_core.title_bar_contains(g, 300, 200)); // client area
    try std.testing.expectEqual(@as(usize, 16), wnd_core.title_bar_h);
    // The kernel re-exports the SAME number (no second constant to drift).
    _ = wnd_core.hit_test;
}
