//! VirelaiOS M37 DQ2 tab-strip live-gate holder (TABHOLD.BIN, issue #840).
//!
//! Opens a user window, attaches it as a tab of window 2 (NOTEPAD — the
//! gate boots NOTEPAD first), prints `tabhold: attached parent=2`, then
//! parks in a yield loop HOLDING the attachment so the gate can snapshot
//! the kernel-painted strip. SEXITEST.BIN stays untouched as the M19
//! fixture (it attaches, cycles, and detaches immediately — no hold),
//! and the holder reuses DQ3's future click target for free.

const std = @import("std");
const wnd_core = @import("wnd_core");
const ui = @import("lib/ui.zig");

const sys_write: u64 = 1;
const sys_win_open: u64 = 12;

pub const ready_marker: []const u8 = "tabhold: ready\n";
pub const attached_marker: []const u8 = "tabhold: attached parent=2\n";
pub const cycled_marker: []const u8 = "tabhold: cycled\n";
pub const done_marker: []const u8 = "tabhold: done\n";
pub const no_wm_marker: []const u8 = "tabhold: no-wm\n";
pub const attach_fail_marker: []const u8 = "tabhold: attach-failed\n";
pub const cycle_fail_marker: []const u8 = "tabhold: cycle-failed\n";

export fn _start(argc: u64, argv_va: u64) callconv(.c) noreturn {
    main(@intCast(argc), argv_va);
}

fn syscall0(num: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
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

fn syscall4(num: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
          [arg3] "{x3}" (arg3),
        : .{ .memory = true });
    return res;
}

fn write_marker(msg: []const u8) void {
    _ = syscall3(sys_write, 1, @intFromPtr(msg.ptr), msg.len);
}

fn park() noreturn {
    while (true) {
        _ = syscall0(ui.sys_yield_num);
    }
}

fn main(argc: usize, argv_va: u64) noreturn {
    _ = argc;
    _ = argv_va;
    _ = wnd_core.tab_bar_height; // drift guard: holder builds on the shared rules

    write_marker(ready_marker);

    const own_id = syscall4(sys_win_open, 200, 200, 320, 240);
    if (own_id < 0) park();

    // Self-driving: the gate execs us in the boot burst alongside NOTEPAD,
    // so window 2 / the WM may not exist yet. Retry attach until it lands
    // (bounded: 40 × 2s ≈ 80s — NOTEPAD opens in ~15-30s). No script-phase
    // triggers needed, which dodges the phase-2 delivery flake (issue #843).
    var attached = false;
    var tries: usize = 0;
    while (!attached and tries < 40) : (tries += 1) {
        if (ui.wm_find_pid("WND.BIN") != 0) {
            attached = ui.wm_attach_tab(@intCast(own_id), 2, "TABHOLD.BIN");
        }
        if (!attached) ui.sleep_ticks(2);
    }
    if (!attached) {
        write_marker(attach_fail_marker);
        park();
    }
    write_marker(attached_marker);
    // Cycle twice (2→3→2): the group ends on NOTEPAD visible+focused with
    // this window attached-but-hidden — the canonical tabbed state the
    // strip paint reads. Either cycle failing leaves a held-but-unfocused
    // group; the gate snapshots whatever is, honestly.
    if (!ui.wm_cycle_tab("TABHOLD.BIN") or !ui.wm_cycle_tab("TABHOLD.BIN")) {
        write_marker(cycle_fail_marker);
        park();
    }
    write_marker(cycled_marker);
    // Hold the attachment across the snapshot stream (~25s by the chrome
    // gate's calibration), then print done so the gate's expect can fire
    // with zero further script phases.
    ui.sleep_ticks(60);
    write_marker(done_marker);
    park();
}
