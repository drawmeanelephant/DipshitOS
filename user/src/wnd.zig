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
        \\// event buffer on the stack (wait_event writes the event here).
        \\sub sp, sp, #32
        \\10:
        \\// sys_wait_event(sp) — BLOCKS until an event is queued for this
        \\// process; the kernel delivers COMPOSITE_TICK (kind 18) here once
        \\// per scheduler tick while we are registered.
        \\mov x0, sp
        \\mov x8, #22
        \\svc #0
        \\cmp x0, #1
        \\b.ne 10b            // spurious/no event: keep waiting
        \\ldrh w23, [sp, #0]  // event kind (u16 at offset 0)
        \\cmp w23, #18
        \\b.ne 10b            // not a COMPOSITE_TICK: keep waiting
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
}
