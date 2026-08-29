//! DipshitOS WMS7 Gate A test app — WMRPC.BIN (issue #627).
//!
//! The app-facing half of the app↔WM mailbox protocol. It discovers the
//! registered WM server and its OWN pid by reading `sys_procs` (slot 7 —
//! the process name + `running` state, the same EL0 table-read the
//! `peer: sees` IPC probe uses), opens a user window, then sends TWO WM_RPC
//! requests to the WM over the per-process mailbox (`sys_ipc_send`, slot 5;
//! `sys_ipc_recv`, slot 6): a `WIN_RAISE` for the target window (the WM
//! focuses+raises it via the ALT_TAB-commit path) and a `WIN_CONFIG` that
//! moves/resizes it (the SET_WINDOW-rect path) with a bounded title — both
//! "ask the WM" instead of "syscall the desktop". For each request it polls
//! its own inbox for the WM's ack reply and prints a pinned marker, so the
//! live gate can prove the request round-tripped AND applied.
//!
//! Back-compat mode: when no WM server is running the app finds no
//! `WND.BIN` in the process table, prints `wmrpc: no-wm` and parks — an app
//! that can't reach a WM does nothing harmful (the frozen syscalls are
//! untouched; the protocol is additive).
//!
//! Never exits (a long-lived peer, like WND.BIN/PEER.BIN). Real EL0 Zig,
//! freestanding, no libc; the WM_RPC wire format (WmRpc) is single-sourced
//! in `kernel/src/wnd_core.zig` so this app and the server cannot drift.
//!
//! Invocation:  exec WMRPC.BIN <target-window-id> [wm-name]
//!   argv[0] = the window id to raise/config (NOTEPAD is id 2 in the gate),
//!   argv[1] = the WM server's process name (default WND.BIN). The app finds
//!   its OWN pid by scanning `sys_procs` for its own name (the gate runs one
//!   instance).

const std = @import("std");
const wnd_core = @import("wnd_core");

// Syscall slots (ADR 0007). The same freestanding svc ABI as wnd.zig.
const sys_write: u64 = 1;
const sys_sleep: u64 = 4;
const sys_ipc_send: u64 = 5;
const sys_ipc_recv: u64 = 6;
const sys_procs: u64 = 7;
const sys_win_open: u64 = 12;
const sys_yield_num: u64 = 2;

/// The procs snapshot row the kernel marshals (u64 pid, u64 state, u64 exit,
/// 16-byte NUL-padded name — 40 bytes). The state code for RUNNING is 2
/// (process.State order — the same value peer.zig's naked asm compares).
pub const ProcsRow = extern struct {
    pid: u64,
    state: u64,
    exit: u64,
    name: [16]u8,
};
pub const procs_row_bytes: usize = 40;
pub const procs_state_running: u64 = 2;
/// The snapshot buffer bound (16 rows × 40 B — plenty for the boot payload +
/// WND + NOTEPAD + this app).
pub const procs_buf_bytes: usize = 16 * 40;

// ---------------------------------------------------------------------------
// Pinned markers (the live gate's grep targets; host-tested so they cannot
// drift from the payload).
// ---------------------------------------------------------------------------
pub const ready_marker: []const u8 = "wmrpc: wm";
pub const own_marker: []const u8 = "wmrpc: own-id=";
pub const raise_ack_marker: []const u8 = "wmrpc: raise-ack";
pub const config_ack_marker: []const u8 = "wmrpc: config-ack";
pub const done_marker: []const u8 = "wmrpc: done";
pub const no_wm_marker: []const u8 = "wmrpc: no-wm";
/// The config title the app sends (the WM_RPC payload carries it within 64 B).
pub const config_title: []const u8 = "wm-rpc";
/// The WIN_CONFIG target rect (the gate asserts the dui row reflects it).
pub const config_x: u16 = 40;
pub const config_y: u16 = 40;
pub const config_w: u16 = 360;
pub const config_h: u16 = 260;
/// The app's own window open rect (the second window, so a raise is visible).
pub const own_x: u32 = 400;
pub const own_y: u32 = 60;
pub const own_w: u32 = 256;
pub const own_h: u32 = 192;

export fn _start(argc: u64, argv_va: u64) callconv(.c) noreturn {
    main(@intCast(argc), argv_va);
}

// --- freestanding syscall wrappers (svc #0, the fixed-register ABI) --------
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

/// Write a marker line to the serial console (fd 1) — the gate's grep target.
fn write_marker(msg: []const u8) void {
    _ = syscall3(sys_write, 1, @intFromPtr(msg.ptr), msg.len);
}

// --- argv (the claim-4636 entry contract: 32-byte NUL-terminated slots) ----
fn argv_slot(argv_va: u64, index: usize) []const u8 {
    const base: [*]const u8 = @ptrFromInt(argv_va + index * 32);
    var n: usize = 0;
    while (n < 32 and base[n] != 0) : (n += 1) {}
    return base[0..n];
}

/// Parse a leading decimal id from an argv slot (0 on garbage).
fn parse_id(s: []const u8) u8 {
    var result: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        result = result * 10 + (c - '0');
        if (result > 0xff) return 0;
    }
    return @intCast(result);
}

/// Scan the sys_procs snapshot for a RUNNING process whose name equals
/// `want`. Returns its pid, or null.
fn find_pid(want: []const u8) ?u8 {
    var rows: [procs_buf_bytes]u8 align(8) = undefined;
    // sys_procs returns the ROW COUNT (take_bytes / 40, the claim-5799
    // contract), not bytes — dividing by procs_row_bytes again would zero
    // the loop and misreport every WM as absent.
    const got = syscall2(sys_procs, @intFromPtr(&rows), rows.len);
    if (got <= 0) return null;
    const count: usize = @intCast(got);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const r: *const ProcsRow = @ptrCast(@alignCast(&rows[i * procs_row_bytes]));
        if (r.state != procs_state_running) continue;
        if (std.mem.eql(u8, std.mem.sliceTo(&r.name, 0), want)) {
            return @intCast(r.pid);
        }
    }
    return null;
}

/// Send one WM_RPC request to the WM. Returns the ipc_send result.
fn send_request(wm_pid: u8, req: *const wnd_core.WmRpc) void {
    const bytes = std.mem.asBytes(req);
    _ = syscall3(sys_ipc_send, wm_pid, @intFromPtr(bytes.ptr), bytes.len);
}

/// Poll the app's OWN inbox for the WM's ack reply matching `seq`. After a
/// short sleep (the WM serves at its 1 Hz tick) the reply is queued; the
/// bounded poll drains it. Returns the reply's `applied` byte, or 0xff on
/// timeout (the gate would then fail honestly — no fake success).
fn await_ack(seq: u8) u8 {
    _ = syscall1(sys_sleep, 2); // let the WM serve the request
    var raw: [wnd_core.wm_rpc_max]u8 = undefined;
    var tries: u32 = 0;
    while (tries < 20000) : (tries += 1) {
        const got = syscall2(sys_ipc_recv, @intFromPtr(&raw), raw.len);
        if (got >= @sizeOf(wnd_core.WmRpc)) {
            var rep: wnd_core.WmRpc = undefined;
            @memcpy(std.mem.asBytes(&rep), raw[0..@sizeOf(wnd_core.WmRpc)]);
            if (rep.kind & wnd_core.wm_rpc_reply_flag != 0 and rep.seq == seq) {
                return rep.applied;
            }
        }
        _ = syscall0(sys_yield_num);
    }
    return 0xff; // timeout
}

fn make_request(kind: u8, id: u8, seq: u8, reply_to: u8) wnd_core.WmRpc {
    return .{
        .kind = kind,
        .id = id,
        .seq = seq,
        .reply_to = reply_to,
        .applied = 0,
        .pad = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .h = 0,
        .title = [_]u8{0} ** wnd_core.wm_rpc_title_max,
    };
}

fn main(argc: usize, argv_va: u64) noreturn {
    var target: u8 = 0;
    var wm_name: []const u8 = "WND.BIN";
    if (argc >= 1 and argv_va != 0) {
        target = parse_id(argv_slot(argv_va, 0));
    }
    if (argc >= 2 and argv_va != 0) {
        const n = argv_slot(argv_va, 1);
        if (n.len != 0) wm_name = n;
    }

    // Discover the WM + our own pid (both must be running rows).
    const wm_pid = find_pid(wm_name) orelse {
        write_marker(no_wm_marker);
        park();
    };
    const self_pid = find_pid("WMRPC.BIN") orelse wm_pid; // reply target (self)
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} pid={d} self={d} target={d}\n", .{ ready_marker, wm_pid, self_pid, target }) catch "wmrpc: wm\n";
    write_marker(s);

    // Open our own window (a SECOND user window, so the raise is observable:
    // opening focuses id 3; WIN_RAISE for `target` must move focus back).
    const own_id = syscall4(sys_win_open, own_x, own_y, own_w, own_h);
    var buf2: [48]u8 = undefined;
    const s2 = std.fmt.bufPrint(&buf2, "{s}{d}\n", .{ own_marker, own_id }) catch "wmrpc: own-id=0\n";
    write_marker(s2);

    // WIN_RAISE the target window (the WM focuses+raises via ALT_TAB commit).
    {
        var req = make_request(wnd_core.wm_rpc_kind_raise, target, 1, self_pid);
        send_request(wm_pid, &req);
        const applied = await_ack(1);
        var b: [56]u8 = undefined;
        const m = std.fmt.bufPrint(&b, "{s} applied={s}\n", .{ raise_ack_marker, if (applied == 1) "yes" else "no" }) catch "wmrpc: raise-ack\n";
        write_marker(m);
    }
    // WIN_CONFIG the target window (the WM clamps+applies a new rect + title).
    {
        var req = make_request(wnd_core.wm_rpc_kind_config, target, 2, self_pid);
        req.x = config_x;
        req.y = config_y;
        req.w = config_w;
        req.h = config_h;
        @memcpy(req.title[0..@min(config_title.len, wnd_core.wm_rpc_title_max)], config_title[0..@min(config_title.len, wnd_core.wm_rpc_title_max)]);
        send_request(wm_pid, &req);
        const applied = await_ack(2);
        var b: [56]u8 = undefined;
        const m = std.fmt.bufPrint(&b, "{s} applied={s}\n", .{ config_ack_marker, if (applied == 1) "yes" else "no" }) catch "wmrpc: config-ack\n";
        write_marker(m);
    }

    write_marker(done_marker);
    park();
}

fn park() noreturn {
    while (true) {
        _ = syscall0(sys_yield_num);
    }
}

// ---------------------------------------------------------------------------
// Host tests — pins + pure discovery logic (the EL0 payload itself can't run
// a host test; these lock the markers + the WM_RPC fit so the gate's grep
// targets and the 64-B bound cannot drift).
// ---------------------------------------------------------------------------
test "wmrpc: the pinned markers are the live gate's grep targets" {
    try std.testing.expectEqualStrings("wmrpc: wm", ready_marker);
    try std.testing.expectEqualStrings("wmrpc: own-id=", own_marker);
    try std.testing.expectEqualStrings("wmrpc: raise-ack", raise_ack_marker);
    try std.testing.expectEqualStrings("wmrpc: config-ack", config_ack_marker);
    try std.testing.expectEqualStrings("wmrpc: done", done_marker);
    try std.testing.expectEqualStrings("wmrpc: no-wm", no_wm_marker);
    try std.testing.expectEqualStrings("wm-rpc", config_title);
    // The config rect the gate asserts on the dui window row.
    try std.testing.expectEqual(@as(u16, 40), config_x);
    try std.testing.expectEqual(@as(u16, 360), config_w);
    try std.testing.expectEqual(@as(u16, 260), config_h);
}

test "wmrpc: the WM_RPC request fits the frozen 64-byte mailbox slot" {
    // The ADR 0015 size decision: NO message_max growth — the compact fixed
    // layout (with the bounded title) must fit wnd_core.wm_rpc_max.
    try std.testing.expect(@sizeOf(wnd_core.WmRpc) <= wnd_core.wm_rpc_max);
    try std.testing.expectEqual(@as(usize, 64), wnd_core.wm_rpc_max);
    const req = make_request(wnd_core.wm_rpc_kind_config, 2, 7, 3);
    try std.testing.expectEqual(@as(u8, 2), req.kind);
    try std.testing.expectEqual(@as(u8, 7), req.seq);
    try std.testing.expectEqual(@as(u8, 3), req.reply_to);
    // The procs row layout + running code (must match process.State order).
    try std.testing.expectEqual(@as(usize, 40), procs_row_bytes);
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(ProcsRow));
    try std.testing.expectEqual(@as(u64, 2), procs_state_running);
}
