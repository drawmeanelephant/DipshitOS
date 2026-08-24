//! DipshitOS milestone-three syscall ABI (claim 3594).
//!
//! The claim-8215 EL0 boundary owns exception entry and return. This module
//! layers a fixed numbered contract on that seam: x8 is the syscall number,
//! x0..x5 are arguments, `svc #0` is reserved, and x0 receives the result.
//! The 64-slot function-pointer table is built at runtime in BSS (ADR 0005):
//! the flat kernel loader applies no relocations, so a const table would hold
//! invalid link-time function addresses at the runtime-selected image base.
//!
//! No allocation, libc, POSIX, or address-space work lives here (the
//! process registry is only READ — the mailbox is keyed by process id and
//! the recv path resolves the calling task's process). `sys_write` copies
//! user bytes through the claim-6120 uaccess layer (`uaccess.copy_in`),
//! which enforces the ADR 0007 `EFAULT` (-3) contract for bad user
//! pointers (out-of-region, overflow, unmapped, permission) without
//! letting them crash EL1.
//!
//! Card 3f (claim 5965): slots 5/6 — `sys_ipc_send(target, buf, len)` and
//! `sys_ipc_recv(buf, max)` — move bytes between processes through the
//! bounded per-process mailbox (`mailbox.zig`): send copy_in's the
//! caller's region into the TARGET's ring (full → `ENOSPC` -5), recv
//! copies the caller's OWN ring out (empty → 0), and every byte crosses
//! the uaccess window in both directions. The recv path peeks → uaccess
//! copy_out → drops, so a bad recv buffer (`EFAULT`) never loses the
//! message.
//!
//! Card N6 (claim 1384): slots 9/10/11 — `sys_udp_listen(port)`,
//! `sys_udp_send(ip, port, buf, len)` and `sys_udp_recv(port, buf, max)`
//! — expose the milestone-five UDP layer (`udp.zig` / `net_udp_send`) to
//! EL0 through the claim-6120 uaccess window: bind a port on the bounded
//! kernel listen table, send ONE datagram (own-IP → the N5 LOOPBACK
//! path, a peer → the ARP-resolved TX path; fixed source port 7000), and
//! receive the oldest datagram (peek → copy_out → pop — the ipc recv
//! EFAULT-preservation contract). The table is kernel-global: any EL0
//! task may bind or receive on any port (no per-process ownership —
//! honest bound, the ADR 0007 amendment). No protocol logic lives here
//! (the N5 layer owns UDP); these handlers marshal args, copy bytes, and
//! call through.
//!
//! Card G6 (claim 0487): slots 12/13/14 — `sys_win_open` / `sys_win_fill` /
//! `sys_win_present` — expose the G5 window manager's user-window surface
//! to EL0: open a bounded kernel-owned window (id 2..5, fixed BSS
//! back-buffer), fill rects in its back-buffer, and present it (mark dirty
//! for the shell idle loop's compositor). Follow-ons add slot 15
//! `sys_win_close` (teardown), per-process ownership (auto-close on exit +
//! owner-restricted fill/present/close), and slots 16/17 `sys_win_move` /
//! `sys_win_raise` (reposition + restack the caller's window), slot 18
//! `sys_win_get` (copy the caller's window rect out through uaccess — the
//! read-back seam after a clamped move), slot 19 `sys_win_query` (copy the
//! FULL window state — rect + z-order rank + focus/visible/dirty flags), and
//! slot 20 `sys_win_set_visible` (hide/show the caller's window). Those two
//! pointer-taking win slots are the only uaccess users; everything else is
//! plain numbers — the kernel owns the buffers; an EL0 program never touches
//! them directly — no allocation.

const std = @import("std");
const console = @import("console.zig");
const exceptions = @import("exceptions.zig");
const mailbox = @import("mailbox.zig"); // claim 5965: per-process rings
const process = @import("process.zig"); // claim 5965: target/current-process lookup
const scheduler = @import("scheduler.zig");
const udp = @import("udp.zig"); // claim 1384 (card N6): the milestone-five UDP layer
const virtio_net = @import("virtio_net.zig"); // claim 1384 (card N6): net_udp_send (TX + loopback)
const uaccess = @import("uaccess.zig"); // claim 6120: fault-safe copy-in
const userspace = @import("userspace.zig");
const driving_award = @import("driving_award.zig"); // claim 1543/0487 (cards G5/G6): the window manager this seam renders into
const events = @import("events.zig"); // Milestone 9 (claim 1016): application event queues
const file_table = @import("file_table.zig"); // Milestone 10 (claim 3570): userland storage ABI
const esp_exec = @import("exec.zig"); // Claim 6359 (ADR 0007 slot 28): the EL0 exec seam — reuse the EL1h loader
const esp = @import("esp.zig"); // Claim 6359: the ESP name bound for the path check
const tcp = @import("tcp.zig"); // Milestone 12 (claim 7483): TCP client seam
const csprng = @import("csprng.zig"); // ISN generation for TCP connect
const clipboard = @import("clipboard.zig"); // Milestone 14 (claim 0169): the shared kernel clipboard
const pipe = @import("pipe.zig"); // M19 P1 (issue #290): the bounded pipe buffer behind slots 56/57
const app_timers = @import("app_timers.zig"); // Milestone 14 (claim 7323): the per-process app timer facility
const virtio_snd = @import("virtio_snd.zig"); // Milestone 15 (claim 7636): the virtio-snd playback path behind sys_audio_*
const fbtext = @import("text.zig"); // M20-U1 (claim 5127): sys_font_size's terminal font state

pub const slot_count: usize = 64;
/// 56 through M18 + slot 58 `sys_font_size` (M20-U1); 56/57 are Lane A's
/// reserved pipe slots (M19) — the gap is intentional, see
/// docs/agent-concurrency-plan.md §8.
/// M19 P1 (issue #290): slots 56/57 are the bounded pipe.
/// M26 N1 (issue #399): slots 59/60 are ping send/poll.
pub const implemented_count: usize = 62;
/// Card G6 (claim 0487) follow-on (slot 18): the fixed `sys_win_get` shape —
/// four u32 LE words (x, y, w, h), 16 bytes, marshaled per call and copy_out'd
/// through uaccess (the procs snapshot pattern).
/// Card G6 (claim 0487) follow-on (slot 19): the fixed `sys_win_query` shape —
/// eight u32 LE words (x, y, w, h, z, focused, visible, dirty), 32 bytes.
pub const write_cap: u64 = 256;
pub const svc_immediate: u16 = 0;

pub const sys_ping: u64 = 0;
pub const sys_write: u64 = 1;
pub const sys_yield: u64 = 2;
pub const sys_exit: u64 = 3;
pub const sys_sleep: u64 = 4;
/// Card 3f (claim 5965): the IPC mailbox slots — the ONLY ABI amendment
/// in the follow-on 3 card set (ADR 0007 stays otherwise frozen).
pub const sys_ipc_send: u64 = 5;
pub const sys_ipc_recv: u64 = 6;
/// Card 4a (claim 5799): process introspection — slot 7, the ONE ABI
/// change in the follow-on 4 card set's first card (ADR 0007 amendment;
/// every existing syscall number 0–6 stays frozen).
pub const sys_procs: u64 = 7;
/// Card 4c (claim 9946): exit-status propagation to a peer — slot 8, the
/// follow-on 4 card set's second ABI change (ADR 0007 slots 7/8 amendment;
/// every existing syscall number 0–7 stays frozen). `sys_wait(target)`
/// blocks the caller until the target process exits and returns its
/// status — bounded, kernel-owned; NOT POSIX wait (no zombies, no fds).
pub const sys_wait: u64 = 8;
/// Card N6 (claim 1384): the UDP syscall seam — slots 9/10/11, the card's
/// ONE ABI change (the ipc slots-5/6 precedent; every existing syscall
/// number 0–8 stays frozen). `sys_udp_listen(port)` binds the bounded
/// kernel listen table; `sys_udp_send(ip, port, buf, len)` transmits ONE
/// datagram (fixed src port 7000, own-IP loopback or the ARP-resolved TX
/// path); `sys_udp_recv(port, buf, max)` copies the oldest datagram out.
pub const sys_udp_listen: u64 = 9;
pub const sys_udp_send: u64 = 10;
pub const sys_udp_recv: u64 = 11;
/// Card G6 (claim 0487): the draw/window syscall seam — slots 12/13/14, the
/// card's ONE ABI change (the ipc slots-5/6, slots-7/8, and udp slots-9/10/11
/// precedents; every existing syscall number 0–11 stays frozen).
/// `sys_win_open(x, y, w, h)` opens a kernel-owned user window (id 2..5) in
/// the G5 window registry; `sys_win_fill(id, x, y, w, h, rgb)` fills a rect
/// in its back-buffer; `sys_win_present(id)` marks it dirty for the
/// compositor. Plain numbers only — no uaccess; the kernel owns the buffers.
pub const sys_win_open: u64 = 12;
pub const sys_win_fill: u64 = 13;
pub const sys_win_present: u64 = 14;
/// Card G6 (claim 0487) follow-on: `sys_win_close(id)` releases a user
/// window (the EL0 half of the teardown seam — the monitor's `win close`
/// is the EL1h half; both call `driving_award.user_close`).
pub const sys_win_close: u64 = 15;
/// Card G6 (claim 0487) follow-on: `sys_win_move(id, x, y)` repositions the
/// caller's window (clamped on-scanout) and `sys_win_raise(id)` raises it to
/// the top — the window manager's move/restack surface from EL0, owner-
/// restricted like fill/present/close.
pub const sys_win_move: u64 = 16;
pub const sys_win_raise: u64 = 17;
/// Card G6 (claim 0487) follow-on: `sys_win_get(id, buf)` copies the CALLER'S
/// user window's geometry (x, y, w, h as four u32 LE words — 16 bytes) OUT
/// through uaccess, so an EL0 program can read its window's rect back after a
/// CLAMPED move (`sys_win_move` clamps silently; this is the read-back seam).
/// The ONE pointer-taking win slot.
pub const sys_win_get: u64 = 18;
pub const win_rect_bytes: usize = 16;
/// Card G6 (claim 0487) follow-on: `sys_win_query(id, buf)` copies the
/// CALLER'S user window's FULL state (x, y, w, h, z, focused, visible, dirty
/// as eight u32 LE words — 32 bytes) OUT through uaccess, so an EL0 program
/// can introspect its window end to end (z-order rank + focus + flags), not
/// just the rect.
pub const sys_win_query: u64 = 19;
pub const win_query_bytes: usize = 32;
/// Card G6 (claim 0487) follow-on: `sys_win_set_visible(id, visible)` hides
/// (0) or shows (1) the CALLER'S user window — the window manager's
/// visibility surface from EL0, owner-restricted like fill/present/close.
/// Plain numbers, no uaccess.
pub const sys_win_set_visible: u64 = 20;
/// Milestone 9 (claim 1016): `sys_poll_event(buf)` non-blocking event poll.
pub const sys_poll_event: u64 = 21;
/// Milestone 9 (claim 1016): `sys_wait_event(buf)` blocking event wait.
pub const sys_wait_event: u64 = 22;
/// Milestone 10 (claim 3570): userland storage ABI slots 23–27.
pub const sys_file_open: u64 = 23;
pub const sys_file_read: u64 = 24;
pub const sys_file_write: u64 = 25;
pub const sys_file_close: u64 = 26;
pub const sys_dir_list: u64 = 27;
/// Claim 6359: `sys_exec(path_ptr, path_len)` — the EL0 exec seam. Copies
/// the `.BIN` name through uaccess and runs the EL1h loader
/// (`exec.exec_file`) to load the program from the ESP into a fresh
/// process slot and spawn it at EL0 — so an EL0 launcher (DESKTOP.BIN)
/// actually launches apps. Returns the new process's pid on success.
pub const sys_exec: u64 = 28;
/// Claim 7604: `sys_kill(target_pid)` — the EL0 termination seam. Arms the
/// target process's executor through the claim-7786 kill
/// (`scheduler.request_kill`): the ring converts the target's NEXT
/// selection into the existing exit path with the reserved status 137 —
/// the OS, not the program, owns process lifetime. Returns 0 once armed;
/// EINVAL for every refusal.
pub const sys_kill: u64 = 29;
/// Milestone 12 (claim 7483): `sys_tcp_connect(ip, port)` — slot 30.
pub const sys_tcp_connect: u64 = 30;
/// Milestone 12 (claim 7483): `sys_tcp_send(buf, len)` — slot 31.
pub const sys_tcp_send: u64 = 31;
/// Milestone 12 (claim 7483): `sys_tcp_recv(buf, max)` — slot 32.
pub const sys_tcp_recv: u64 = 32;
/// Milestone 12 (claim 7483): `sys_tcp_close()` — slot 33.
pub const sys_tcp_close: u64 = 33;
/// Milestone 13 (claim 5801): `sys_file_delete(path_ptr, path_len)` — slot 34.
pub const sys_file_delete: u64 = 34;
/// Milestone 13 (claim 5801): `sys_file_rename(old_ptr, old_len, new_ptr, new_len)` — slot 35.
pub const sys_file_rename: u64 = 35;
/// Milestone 13 (claim 5801): `sys_file_truncate(handle, size)` — slot 36.
pub const sys_file_truncate: u64 = 36;
/// Milestone 13 (claim 5801): `sys_file_free(volume)` — slot 37.
pub const sys_file_free: u64 = 37;
/// Milestone 14 (claim 0169): `sys_clipboard_set(buf_ptr, len)` — slot 38.
pub const sys_clipboard_set: u64 = 38;
/// Milestone 14 (claim 0169): `sys_clipboard_get(buf_ptr, max)` — slot 39.
pub const sys_clipboard_get: u64 = 39;
/// Milestone 14 (claim 7323): `sys_timer_set(delay_ticks)` — slot 40.
pub const sys_timer_set: u64 = 40;
/// Milestone 14 (claim 7323): `sys_timer_cancel()` — slot 41.
pub const sys_timer_cancel: u64 = 41;
/// Milestone 15 (claim 7636): `sys_audio_info(out_ptr)` — slot 42.
pub const sys_audio_info: u64 = 42;
/// Milestone 15 (claim 7636): `sys_audio_play(ptr, len)` — slot 43.
pub const sys_audio_play: u64 = 43;
/// M15 follow-up (claim 9297): `sys_audio_volume(vol)` — slot 44.
pub const sys_audio_volume: u64 = 44;
/// M15 follow-up (claim 9297): `sys_audio_mute(muted)` — slot 45.
pub const sys_audio_mute: u64 = 45;
/// Step 2 (Issue #205): `sys_win_fill_batch(buf_ptr, buf_len)` — slot 46.
pub const sys_win_fill_batch: u64 = 46;
/// Arc2 W1 (claim 3589, ADR 0013 D1): `sys_win_resize(id, w, h)` — slot 47.
pub const sys_win_resize: u64 = 47;
/// Arc4 #238 (ADR 0013 D1): `sys_win_raise_front(id)` — slot 49.
pub const sys_win_raise_front: u64 = 49;
/// Arc4 #238 (ADR 0013 D1): `sys_win_lower_back(id)` — slot 50.
pub const sys_win_lower_back: u64 = 50;
/// Arc4 #240 (ADR 0013 D1): `sys_notify(text_ptr, text_len, level)` — slot 51.
pub const sys_notify: u64 = 51;
/// Arc4 #242 (ADR 0013 D1): `sys_win_set_unsaved(id, flag)` — slot 53.
pub const sys_win_set_unsaved: u64 = 53;
/// M21 W12 (ADR 0013 D1): `sys_win_set_title(id, text_ptr, text_len)` — slot 61.
pub const sys_win_set_title: u64 = 61;
/// Arc4 #237 (ADR 0013 D1): `sys_drag_read(buf_ptr, max_len)` — slot 55.
pub const sys_drag_read: u64 = 55;
pub const sys_pipe_read: u64 = 56;
pub const sys_pipe_write: u64 = 57;
/// M20-U1 (claim 5127): `sys_font_size(window_id, size)` — slot 58.
/// size 0=8×8 small, 1=16×16 medium, 2=24×24 large; EINVAL for anything
/// else. Only window 0 (the terminal) renders through the kernel text
/// layer today; other ids get EINVAL.
pub const sys_font_size: u64 = 58;
/// M26 N1 (issue #399): `sys_ping_send(ip)` — slot 59. Send one ICMP echo
/// request to `ip` (low 32 bits network order). Returns 0 on success;
/// EINVAL for no peer / no IP / not ready.
pub const sys_ping_send: u64 = 59;
/// M26 N1 (issue #399): `sys_ping_poll()` — slot 60. Drain RX and report
/// whether a pong has landed since the last send. Returns the last echo
/// reply sequence (u16) if a pong was observed, else 0.
pub const sys_ping_poll: u64 = 60;

pub const ErrorCode = enum(i64) {
    einval = -1,
    ebadf = -2,
    efault = -3,
    enosys = -4,
    enospc = -5,
    enoent = -6,
    eacces = -7,
    enametoolong = -8,
    enxio = -9, // "no such device" — the sys_audio_* seam's honest no-device refusal
};

pub fn error_result(code: ErrorCode) u64 {
    return @bitCast(@intFromEnum(code));
}

pub const Args = [6]u64;
pub const Writer = *const fn ([]const u8) void;
const Handler = *const fn (Args, *exceptions.VectorFrame) u64;

const Entry = struct {
    name: []const u8 = "",
    handler: ?Handler = null,
};

pub const EntryInfo = struct {
    number: u64,
    name: []const u8,
    calls: u64,
};

var table_storage: [slot_count]Entry = undefined;
var table_ready = false;
var call_counts: [slot_count]u64 = [_]u64{0} ** slot_count;
var write_fn: ?Writer = null;
/// M22 D5 (issue #328): when set, dispatch() prints one line per syscall
/// issued by that pid. Armed by the monitor's `strace` command around an
/// exec; cleared by `strace off`.
pub var strace_pid: ?usize = null;
/// Card 4a (claim 5799): fixed BSS scratch for the process snapshot —
/// `max_processes` rows × 40 bytes, marshaled per call, no allocation.
var procs_scratch: [process.max_processes * process.snapshot_row_bytes]u8 = undefined;
/// Card N6 (claim 1384): fixed BSS scratch for the UDP send payload and
/// the recv peek — `payload_max` / `datagram_max` bytes, marshaled per
/// call, no allocation (the ipc staging pattern).
var udp_send_staging: [udp.payload_max]u8 = undefined;
var udp_recv_scratch: [udp.datagram_max]u8 = undefined;
/// Milestone 12 (claim 7483): fixed BSS scratch for TCP send payload.
var tcp_send_staging: [tcp.payload_max]u8 = undefined;
/// Milestone 14 (claim 0169): fixed BSS scratch for the clipboard (set
/// staging + get read-back), marshaled per call, no allocation.
var clipboard_staging: [clipboard.capacity]u8 = undefined;

/// Initialize the writer seam, reset counters and the uaccess regions. The
/// table remains a runtime-built BSS object; rebuilding is unnecessary once
/// its PC-relative addresses have been materialized at the current image
/// base.
pub fn init(writer: Writer) void {
    write_fn = writer;
    @memset(&call_counts, 0);
    uaccess.init();
    clipboard.init();
    _ = ensure_table();
}

/// Configure the two claim-8215 apertures already mapped for EL0 (user text
/// read-only, user stack read-write). Delegated to the claim-6120 uaccess
/// layer, which owns the EFAULT contract and the fault-recovery window.
pub fn set_user_regions(text: userspace.Region, stack: userspace.Region) void {
    uaccess.set_regions(
        .{ .base = text.base, .len = text.len },
        .{ .base = stack.base, .len = stack.len },
    );
}

fn ensure_table() *const [slot_count]Entry {
    if (!table_ready) {
        for (&table_storage) |*entry| entry.* = .{};
        table_storage[sys_ping] = .{ .name = "sys_ping", .handler = handle_ping };
        table_storage[sys_write] = .{ .name = "sys_write", .handler = handle_write };
        table_storage[sys_yield] = .{ .name = "sys_yield", .handler = handle_yield };
        table_storage[sys_exit] = .{ .name = "sys_exit", .handler = handle_exit };
        table_storage[sys_sleep] = .{ .name = "sys_sleep", .handler = handle_sleep };
        table_storage[sys_ipc_send] = .{ .name = "sys_ipc_send", .handler = handle_ipc_send };
        table_storage[sys_ipc_recv] = .{ .name = "sys_ipc_recv", .handler = handle_ipc_recv };
        table_storage[sys_procs] = .{ .name = "sys_procs", .handler = handle_procs };
        table_storage[sys_wait] = .{ .name = "sys_wait", .handler = handle_wait };
        table_storage[sys_udp_listen] = .{ .name = "sys_udp_listen", .handler = handle_udp_listen };
        table_storage[sys_udp_send] = .{ .name = "sys_udp_send", .handler = handle_udp_send };
        table_storage[sys_udp_recv] = .{ .name = "sys_udp_recv", .handler = handle_udp_recv };
        table_storage[sys_win_open] = .{ .name = "sys_win_open", .handler = handle_win_open };
        table_storage[sys_win_fill] = .{ .name = "sys_win_fill", .handler = handle_win_fill };
        table_storage[sys_win_present] = .{ .name = "sys_win_present", .handler = handle_win_present };
        table_storage[sys_win_close] = .{ .name = "sys_win_close", .handler = handle_win_close };
        table_storage[sys_win_move] = .{ .name = "sys_win_move", .handler = handle_win_move };
        table_storage[sys_win_raise] = .{ .name = "sys_win_raise", .handler = handle_win_raise };
        table_storage[sys_win_get] = .{ .name = "sys_win_get", .handler = handle_win_get };
        table_storage[sys_win_query] = .{ .name = "sys_win_query", .handler = handle_win_query };
        table_storage[sys_win_set_visible] = .{ .name = "sys_win_set_visible", .handler = handle_win_set_visible };
        table_storage[sys_poll_event] = .{ .name = "sys_poll_event", .handler = handle_poll_event };
        table_storage[sys_wait_event] = .{ .name = "sys_wait_event", .handler = handle_wait_event };
        table_storage[sys_file_open] = .{ .name = "sys_file_open", .handler = handle_file_open };
        table_storage[sys_file_read] = .{ .name = "sys_file_read", .handler = handle_file_read };
        table_storage[sys_file_write] = .{ .name = "sys_file_write", .handler = handle_file_write };
        table_storage[sys_file_close] = .{ .name = "sys_file_close", .handler = handle_file_close };
        table_storage[sys_dir_list] = .{ .name = "sys_dir_list", .handler = handle_dir_list };
        table_storage[sys_exec] = .{ .name = "sys_exec", .handler = handle_exec };
        table_storage[sys_kill] = .{ .name = "sys_kill", .handler = handle_kill };
        table_storage[sys_tcp_connect] = .{ .name = "sys_tcp_connect", .handler = handle_tcp_connect };
        table_storage[sys_tcp_send] = .{ .name = "sys_tcp_send", .handler = handle_tcp_send };
        table_storage[sys_tcp_recv] = .{ .name = "sys_tcp_recv", .handler = handle_tcp_recv };
        table_storage[sys_tcp_close] = .{ .name = "sys_tcp_close", .handler = handle_tcp_close };
        table_storage[sys_file_delete] = .{ .name = "sys_file_delete", .handler = handle_file_delete };
        table_storage[sys_file_rename] = .{ .name = "sys_file_rename", .handler = handle_file_rename };
        table_storage[sys_file_truncate] = .{ .name = "sys_file_truncate", .handler = handle_file_truncate };
        table_storage[sys_file_free] = .{ .name = "sys_file_free", .handler = handle_file_free };
        table_storage[sys_clipboard_set] = .{ .name = "sys_clipboard_set", .handler = handle_clipboard_set };
        table_storage[sys_clipboard_get] = .{ .name = "sys_clipboard_get", .handler = handle_clipboard_get };
        table_storage[sys_timer_set] = .{ .name = "sys_timer_set", .handler = handle_timer_set };
        table_storage[sys_timer_cancel] = .{ .name = "sys_timer_cancel", .handler = handle_timer_cancel };
        table_storage[sys_audio_info] = .{ .name = "sys_audio_info", .handler = handle_audio_info };
        table_storage[sys_audio_play] = .{ .name = "sys_audio_play", .handler = handle_audio_play };
        table_storage[sys_audio_volume] = .{ .name = "sys_audio_volume", .handler = handle_audio_volume };
        table_storage[sys_audio_mute] = .{ .name = "sys_audio_mute", .handler = handle_audio_mute };
        table_storage[sys_win_fill_batch] = .{ .name = "sys_win_fill_batch", .handler = handle_win_fill_batch };
        table_storage[sys_win_resize] = .{ .name = "sys_win_resize", .handler = handle_win_resize };
        // Arc4 #237: slot 48 — sys_drag_start.
        table_storage[48] = .{ .name = "sys_drag_start", .handler = handle_drag_start };
        table_storage[sys_win_raise_front] = .{ .name = "sys_win_raise_front", .handler = handle_win_raise_front };
        table_storage[sys_win_lower_back] = .{ .name = "sys_win_lower_back", .handler = handle_win_lower_back };
        table_storage[sys_notify] = .{ .name = "sys_notify", .handler = handle_notify };
        table_storage[sys_drag_read] = .{ .name = "sys_drag_read", .handler = handle_drag_read };
        // ADR 0013 reserved slots 52–54 (not yet implemented). Stubs.
        table_storage[sys_pipe_read] = .{ .name = "sys_pipe_read", .handler = handle_pipe_read };
        table_storage[sys_pipe_write] = .{ .name = "sys_pipe_write", .handler = handle_pipe_write };
        table_storage[52] = .{ .name = "sys_win_move_to_workspace", .handler = handle_win_move_to_workspace };
        table_storage[sys_win_set_unsaved] = .{ .name = "sys_win_set_unsaved", .handler = handle_win_set_unsaved };
        table_storage[sys_win_set_title] = .{ .name = "sys_win_set_title", .handler = handle_win_set_title };
        table_storage[54] = .{ .name = "sys_setrlimit", .handler = handle_setrlimit };
        // M20-U1 (claim 5127): slot 58 — sys_font_size.
        table_storage[sys_font_size] = .{ .name = "sys_font_size", .handler = handle_font_size };
        // M26 N1 (issue #399): slots 59/60 — ping send/poll.
        table_storage[sys_ping_send] = .{ .name = "sys_ping_send", .handler = handle_ping_send };
        table_storage[sys_ping_poll] = .{ .name = "sys_ping_poll", .handler = handle_ping_poll };
        table_ready = true;
    }
    return &table_storage;
}

pub fn entry_info(number: u64) ?EntryInfo {
    if (number >= slot_count) return null;
    const entry = ensure_table()[number];
    if (entry.handler == null) return null;
    return .{ .number = number, .name = entry.name, .calls = call_counts[number] };
}

pub fn call_count(number: u64) u64 {
    if (number >= slot_count) return 0;
    return call_counts[number];
}

/// Dispatch one already-decoded syscall. In-range reserved slots are counted
/// and return ENOSYS; numbers beyond the fixed namespace return ENOSYS without
/// indexing the table. The caller writes this result into saved x0.
pub fn dispatch(number: u64, args: Args, frame: *exceptions.VectorFrame) u64 {
    if (number >= slot_count) return error_result(.enosys);
    call_counts[number] +%= 1;
    const handler = ensure_table()[number].handler orelse return error_result(.enosys);
    // M22 D5: sys_exit never returns from its handler (the scheduler
    // stages another task), so its trace line must be printed BEFORE the
    // call — with an em-dash result, the convention for "no return value".
    if (tracing_current()) {
        if (number == sys_exit) {
            var buf: [96]u8 = undefined;
            var pos: usize = append_trace_str(buf[0..], "[strace ");
            pos += append_trace_dec(buf[pos..], @intCast(traced_pid_for_current()));
            pos += append_trace_str(buf[pos..], "] sys_exit(");
            pos += append_trace_hex(buf[pos..], args[0]);
            pos += append_trace_str(buf[pos..], ") = \xe2\x80\x94\n");
            if (write_fn) |wp| wp(buf[0..pos]);
        }
    }
    const result = handler(args, frame);
    maybe_trace(number, args, result);
    return result;
}

fn tracing_current() bool {
    const target = strace_pid orelse return false;
    const pid = process.find_by_task(scheduler.current_id()) orelse return false;
    return pid == target;
}

fn traced_pid_for_current() usize {
    return process.find_by_task(scheduler.current_id()) orelse 0;
}

/// M22 D5 (issue #328): synchronous per-syscall trace line for the traced
/// pid — `[strace 3] sys_write(0x1, 0x400100, 0xc) = 0xc`. Runs in SVC
/// context; the kernel is single-threaded so a direct console write is
/// safe (the same path tombstones use).
fn maybe_trace(number: u64, args: Args, result: u64) void {
    const target = strace_pid orelse return;
    const w = write_fn orelse return;
    const pid = process.find_by_task(scheduler.current_id()) orelse return;
    if (pid != target) return;
    var buf: [112]u8 = undefined;
    var pos: usize = 0;
    pos += append_trace_str(buf[pos..], "[strace ");
    pos += append_trace_dec(buf[pos..], @intCast(pid));
    pos += append_trace_str(buf[pos..], "] ");
    pos += append_trace_str(buf[pos..], ensure_table()[number].name);
    pos += append_trace_str(buf[pos..], "(");
    pos += append_trace_hex(buf[pos..], args[0]);
    pos += append_trace_str(buf[pos..], ", ");
    pos += append_trace_hex(buf[pos..], args[1]);
    pos += append_trace_str(buf[pos..], ", ");
    pos += append_trace_hex(buf[pos..], args[2]);
    pos += append_trace_str(buf[pos..], ") = ");
    pos += append_trace_hex(buf[pos..], result);
    if (pos < buf.len) {
        buf[pos] = '\n';
        pos += 1;
    }
    w(buf[0..pos]);
}

fn append_trace_str(buf: []u8, s: []const u8) usize {
    const take = @min(s.len, buf.len);
    @memcpy(buf[0..take], s[0..take]);
    return take;
}

fn append_trace_dec(buf: []u8, v_in: u64) usize {
    var v = v_in;
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    if (v == 0) {
        tmp[0] = '0';
        n = 1;
    }
    while (v > 0) : (v /= 10) {
        tmp[n] = @intCast('0' + v % 10);
        n += 1;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = tmp[n - 1 - i];
    return n;
}

fn append_trace_hex(buf: []u8, v: u64) usize {
    const digits = "0123456789abcdef";
    buf[0] = '0';
    buf[1] = 'x';
    if (v == 0) {
        buf[2] = '0';
        return 3;
    }
    var tmp: [16]u8 = undefined;
    var n: usize = 0;
    var vv = v;
    while (vv > 0) : (vv /= 16) {
        tmp[n] = digits[@intCast(vv % 16)];
        n += 1;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) buf[2 + i] = tmp[n - 1 - i];
    return 2 + n;
}

/// Adapter registered through claim 8215's `set_svc_dispatcher` seam.
///
/// Claim 0826 (concurrent processes): arm the uaccess regions from the
/// CURRENT task's TCB at every SVC entry, so `sys_write` bounds always
/// follow the task that actually issued the call — with two live user
/// processes, the module-global regions set by the last root rebuild would
/// otherwise validate one process's stack against another's. EL1h tasks
/// never SVC, so their zero regions are inert. The ABI is untouched.
pub fn handle_svc(frame: *exceptions.VectorFrame, immediate: u16) bool {
    const regions = scheduler.current_user_regions();
    if (regions.text.len != 0 or regions.stack.len != 0) {
        set_user_regions(regions.text, regions.stack);
    }
    var args: Args = undefined;
    for (&args, 0..) |*arg, reg| arg.* = exceptions.frame_read(frame, @intCast(reg));
    const number = exceptions.frame_read(frame, 8);
    const result = if (immediate == svc_immediate)
        dispatch(number, args, frame)
    else
        error_result(.enosys);
    _ = exceptions.frame_write(frame, 0, result);
    return true;
}

/// Stub for reserved-but-unimplemented slots (ADR 0013). Returns
/// ENOSYS so the dispatch table can include forward-reserved rows
/// without crashing the `syscalls` report.
fn handle_enosys(_: Args, _: *exceptions.VectorFrame) u64 {
    return error_result(.enosys);
}

/// Arc5 issue #246: sys_setrlimit(type, value) — slot 54.
/// type 0 = memory pages limit, type 1 = CPU ticks limit.
/// Returns 0 on success, -1 on error.
fn handle_setrlimit(args: Args, _: *exceptions.VectorFrame) u64 {
    const rtype = args[0];
    const value = args[1];
    const current_pid = process.current() orelse return error_result(.eacces);
    if (process.setrlimit(current_pid, rtype, value)) {
        return 0;
    }
    return error_result(.einval);
}

fn handle_ping(args: Args, _: *exceptions.VectorFrame) u64 {
    return userspace.ping(args[0]);
}

fn handle_write(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] != 1) return error_result(.ebadf);
    const address = args[1];
    const len = args[2];
    if (len > write_cap) return error_result(.einval);
    if (len == 0) return 0;
    // Claim 6120: copy the user bytes into a kernel staging buffer through
    // the uaccess layer. A bad user pointer (out-of-region, overflow,
    // unmapped, permission) returns EFAULT without crashing EL1; the writer
    // never touches user memory directly.
    var buf: [write_cap]u8 = undefined;
    if (uaccess.copy_in(&buf, address, @intCast(len)) != .ok) return error_result(.efault);
    const writer = write_fn orelse return error_result(.einval);
    writer(buf[0..@intCast(len)]);
    return len;
}

fn handle_yield(_: Args, _: *exceptions.VectorFrame) u64 {
    _ = scheduler.yield_current();
    return 0;
}

fn handle_sleep(args: Args, _: *exceptions.VectorFrame) u64 {
    // Claim 0635: block the calling task for `args[0]` scheduler ticks. On
    // success the scheduler has parked this task (state=blocked) and staged
    // another task's frame, so the SVC exception return resumes the NEXT
    // task; the caller's own frame stays on its kernel stack and the
    // syscall return (0) lands when `wake_expired` moves it back to ready
    // and the ring resumes it — the same resume path as sys_yield.
    if (!scheduler.sleep_current(args[0])) return error_result(.einval);
    return 0;
}

fn handle_exit(args: Args, _: *exceptions.VectorFrame) u64 {
    // Returning from this Zig function is only kernel control flow. On
    // success the scheduler has removed the caller from the runnable set and
    // staged another task's frame, so the SVC exception return never returns
    // to the terminated EL0 task.
    if (!scheduler.exit_current(args[0])) return error_result(.einval);
    return 0;
}

// ---------------------------------------------------------------------------
// Card 3f (claim 5965): the IPC mailbox — slots 5/6
// ---------------------------------------------------------------------------

/// `sys_ipc_send(target, buf, len)`: copy `len` bytes (≤ `mailbox.message_max`;
/// longer is truncated to the slot bound — documented + host-tested) from
/// the caller's region through uaccess into process `target`'s ring.
///
/// Error precedence: a zero-length send is a no-op returning 0; a target
/// outside the registry, free, or exited is `EINVAL` (a process can only
/// reach a LIVE process's mailbox); a bad user pointer is `EFAULT`; a full
/// ring is `ENOSPC` (-5) — checked before any bytes are copied so the
/// refusal never touches user memory. Returns the sent length on success
/// (the sys_write-style positive result).
fn handle_ipc_send(args: Args, _: *exceptions.VectorFrame) u64 {
    const target = args[0];
    const address = args[1];
    var len = args[2];
    if (len == 0) return 0;
    if (len > mailbox.message_max) len = mailbox.message_max; // documented truncation
    if (target >= process.max_processes) return error_result(.einval);
    const target_info = process.info(@intCast(target)) orelse return error_result(.einval);
    if (target_info.state == .exited) return error_result(.einval); // dead processes have no mailbox
    if (mailbox.pending(@intCast(target)) == mailbox.max_messages) return error_result(.enospc);
    var staging: [mailbox.message_max]u8 = undefined;
    if (uaccess.copy_in(&staging, address, @intCast(len)) != .ok) return error_result(.efault);
    switch (mailbox.send(@intCast(target), staging[0..@intCast(len)])) {
        .ok => return len,
        // Defensive: the full check above makes this unreachable; the ring
        // may only fill between the check and the enqueue if a concurrent
        // sender ran — impossible in this single-core, IRQ-masked SVC.
        .full => return error_result(.enospc),
    }
}

/// `sys_ipc_recv(buf, max)`: copy the caller's OWN oldest message out
/// through uaccess. `max` > `mailbox.message_max` is clamped to it
/// (documented); `max` shorter than the message copies that many bytes and
/// consumes the message (documented truncation). Empty → 0 (nothing
/// copied). The caller's process is resolved from the CURRENT task's
/// binding; an EL1h task (never a process) is `EINVAL`. The message is
/// peeked, copied out, and only then dropped — a bad recv buffer
/// (`EFAULT`) leaves the message queued.
fn handle_ipc_recv(args: Args, _: *exceptions.VectorFrame) u64 {
    const address = args[0];
    var max = args[1];
    if (max == 0) return 0;
    if (max > mailbox.message_max) max = mailbox.message_max; // documented clamp
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (mailbox.pending(pid) == 0) return 0; // empty result
    var staging: [mailbox.message_max]u8 = undefined;
    const got = mailbox.peek(pid, &staging, @intCast(max)) orelse return 0;
    if (uaccess.copy_out(address, staging[0..got], got) != .ok) return error_result(.efault);
    mailbox.drop(pid);
    return got;
}

// ---------------------------------------------------------------------------
// Card 4a (claim 5799): process introspection — slot 7
// ---------------------------------------------------------------------------

/// `sys_procs(buf, max)`: copy a bounded snapshot of the process table
/// (id, name, state, exit status where set — one fixed 40-byte row per
/// NON-FREE descriptor, in id order) OUT into the caller's region through
/// uaccess. A read-only view — there is no write path. `max` truncates to
/// WHOLE rows (`floor(max / 40)`, the documented truncation result like
/// the ipc recv path): a partial row is never copied. `max == 0` → 0
/// rows. Returns the row count written; `EFAULT` for a bad `buf` (the
/// claim-6120 contract — the copy is validated before any state is
/// touched). The snapshot is marshaled into a fixed BSS scratch, so no
/// allocation and no caller-identity requirement (any EL0 task may read
/// the table).
fn handle_procs(args: Args, _: *exceptions.VectorFrame) u64 {
    const address = args[0];
    const max = args[1];
    if (max == 0) return 0;
    const rows = process.snapshot(&procs_scratch);
    if (rows == 0) return 0;
    const full_bytes = rows * process.snapshot_row_bytes;
    // Floor the requested byte count to whole rows (honest truncation).
    const take_bytes = @min(full_bytes, @as(usize, @intCast(max))) / process.snapshot_row_bytes * process.snapshot_row_bytes;
    if (take_bytes == 0) return 0;
    if (uaccess.copy_out(address, procs_scratch[0..take_bytes], take_bytes) != .ok) return error_result(.efault);
    return take_bytes / process.snapshot_row_bytes;
}

// ---------------------------------------------------------------------------
// Card 4c (claim 9946): exit-status propagation — slot 8
// ---------------------------------------------------------------------------

/// `sys_wait(target)`: block the calling process until the process with id
/// `target` exits, then return its exit status. The caller must itself be
/// a process (an EL1h task is `EINVAL`); the target must exist and must
/// not be the caller (`EINVAL` — a process waiting on itself would never
/// exit while blocked; the kernel refuses the deadlock). A target that is
/// ALREADY exited returns its stored status immediately (no block); a
/// RUNNING target parks the caller via `scheduler.wait_current`, and the
/// exit path (`wake_waiters`) patches the observed status into the
/// caller's saved frame, so the syscall return lands with the status when
/// the ring resumes it — the same resume path as `sys_sleep`. A `created`
/// (loaded, not yet running) target is `EINVAL`: it has not started and
/// may never run (the exec rollback would leave a waiter blocked
/// forever), so the wait contract is live-or-already-exited only — never
/// a hang. Bounded, kernel-owned: no zombies, no fds, no POSIX wait
/// semantics; the status is a plain kernel-recorded number.
fn handle_wait(args: Args, _: *exceptions.VectorFrame) u64 {
    const target = args[0];
    if (target >= process.max_processes) return error_result(.einval);
    const target_info = process.info(@intCast(target)) orelse return error_result(.einval);
    const caller = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (caller == target) return error_result(.einval);
    if (target_info.state == .exited) return target_info.exit_status;
    if (target_info.state == .created) return error_result(.einval);
    if (!scheduler.wait_current(@intCast(target))) return error_result(.einval);
    // Placeholder: the caller's frame is saved and the next task staged;
    // `wake_waiters` overwrites this slot with the real status at exit.
    return 0;
}

// ---------------------------------------------------------------------------
// Card N6 (claim 1384): the UDP syscall seam — slots 9/10/11
// ---------------------------------------------------------------------------

/// `sys_udp_listen(port)`: bind the bounded kernel listen table
/// (`udp.listen_port` — the SAME table the monitor's `net udp listen`
/// uses) to `port`. Port 0 or > 65535 → EINVAL; a duplicate or full
/// table → EINVAL (the N5 layer's honest bool). Returns 0 on success.
/// No uaccess. Kernel-global: any EL0 task may bind any port (honest
/// bound, documented in the ADR 0007 amendment).
fn handle_udp_listen(args: Args, _: *exceptions.VectorFrame) u64 {
    const port = args[0];
    if (port == 0 or port > 0xffff) return error_result(.einval);
    if (!udp.listen_port(@truncate(port))) return error_result(.einval);
    return 0;
}

/// `sys_udp_send(ip, port, buf, len)`: send ONE UDP datagram to
/// `ip:port` from the FIXED source port 7000 (`udp.default_src_port` —
/// deterministic, the N5 shape). `ip` is the 4 octets in NETWORK byte
/// order in the low 32 bits of x0 (e.g. 10.0.0.2 = 0x0a000002 — the
/// kernel extracts the bytes explicitly, never a bitcast: AArch64 is
/// little-endian). `len` bytes (≤ `udp.payload_max`, truncated honestly
/// at the bound — the ipc send shape) are copied from `buf` through
/// uaccess into a fixed BSS staging buffer, then `net_udp_send` runs the
/// N5 path: an own-IP send takes the LOOPBACK path (no device round
/// trip), a peer send needs its MAC in the ARP table (`.no_peer` /
/// `.not_ready` / `.timeout` → EINVAL — the caller resolves the peer
/// first via `net arp <ip>` and may retry; the seam does NOT resolve
/// ARP). Port 0 → EINVAL. Bad `buf` → EFAULT. Zero length is a no-op
/// returning 0 (the ipc send shape). Returns the payload length sent.
fn handle_udp_send(args: Args, _: *exceptions.VectorFrame) u64 {
    const ip_raw = args[0];
    const dst_port = args[1];
    const address = args[2];
    var len = args[3];
    if (dst_port == 0 or dst_port > 0xffff) return error_result(.einval);
    if (len == 0) return 0;
    if (len > udp.payload_max) len = udp.payload_max; // documented truncation
    const ip: [4]u8 = .{
        @truncate(ip_raw >> 24),
        @truncate(ip_raw >> 16),
        @truncate(ip_raw >> 8),
        @truncate(ip_raw),
    };
    if (uaccess.copy_in(&udp_send_staging, address, @intCast(len)) != .ok) return error_result(.efault);
    var out_len: usize = 0;
    switch (virtio_net.net_udp_send(ip, @truncate(dst_port), udp_send_staging[0..@intCast(len)], &out_len)) {
        .ok => return len,
        .not_ready, .no_peer, .timeout => return error_result(.einval),
    }
}

/// `sys_udp_recv(port, buf, max)`: copy the oldest datagram for the
/// listener on `port` OUT through uaccess — the full 8-byte UDP header
/// + payload (the caller parses the header for the src port; the src IP
/// is not kept — honest bound, documented). Returns the copied length;
/// 0 when the ring is empty; EINVAL when not listening on `port`. `max`
/// clamps to `udp.datagram_max` (72); shorter copies truncate and
/// CONSUME (the ipc recv shape). The datagram is PEEKED, copied out, and
/// only then popped — a bad recv buffer (`EFAULT`) leaves it queued
/// (the claim-5965 contract). The device is DRAINED FIRST (the
/// claim-6076 polled-drain contract — the net device's used-buffer IRQ
/// is unobserved): a recv pulls any waiting frame device → ring
/// synchronously, so an EL0 polling loop is self-sufficient without the
/// shell idle loop (the monitor's drain-before-read pattern — observed
/// live: without the drain the answer sat in the device queue until a
/// `net` command drained it, and the program's poll starved).
fn handle_udp_recv(args: Args, _: *exceptions.VectorFrame) u64 {
    const port = args[0];
    const address = args[1];
    var max = args[2];
    if (max == 0) return 0;
    if (max > udp.datagram_max) max = udp.datagram_max; // documented clamp
    if (port == 0 or port > 0xffff) return error_result(.einval);
    virtio_net.net_rx_drain(); // the polled-drain contract (no-op unarmed)
    if (!udp.is_listening(@truncate(port))) return error_result(.einval);
    const d = udp.peek(@truncate(port)) orelse return 0; // empty ring
    const take = @min(@as(usize, @intCast(max)), d.len);
    if (uaccess.copy_out(address, d.bytes[0..take], take) != .ok) return error_result(.efault);
    _ = udp.pop(@truncate(port)); // consume (the EFAULT path preserved it)
    return @intCast(take);
}

// ---------------------------------------------------------------------------
// Card G6 (claim 0487): the draw/window syscall seam — slots 12/13/14
// ---------------------------------------------------------------------------

/// `sys_win_open(x, y, w, h)`: open a user window (the G5 window registry)
/// at screen position (x, y) with a back-buffer w×h (≤
/// `driving_award.user_buf_w` × `user_buf_h`), OWNED by the calling
/// process. Returns the window id (2..5); `EINVAL` for a coordinate/word-
/// size outside u32, geometry outside the back-buffer/scanout bounds, an
/// unarmed manager (no gpu — the default VM), or a non-process caller (the
/// syscall is only reachable from an EL0 program); `ENOSPC` (-5) when all
/// four user slots are already open. The window auto-closes when the owning
/// process exits (the scheduler's exit path calls `driving_award.close_owner`).
/// No uaccess: plain numbers.
fn handle_win_open(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u32) or args[1] > std.math.maxInt(u32) or args[2] > std.math.maxInt(u32) or args[3] > std.math.maxInt(u32)) {
        return error_result(.einval);
    }
    const owner = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    return switch (driving_award.user_open(@truncate(args[0]), @truncate(args[1]), @truncate(args[2]), @truncate(args[3]), owner)) {
        .opened => |id| id,
        .invalid => error_result(.einval),
        .full => error_result(.enospc),
    };
}

/// `sys_win_fill(id, x, y, w, h, rgb)`: fill a rect (local coordinates) in
/// the CALLER'S user window's back-buffer with the 24-bit 0xRRGGBB color,
/// marking it dirty. Returns 0 on success; `EINVAL` for an unknown id, a
/// window the caller does NOT own (per-process ownership — a process can
/// only render into its own window), an out-of-range word, or a rect
/// outside the window bounds. No uaccess (the kernel owns the buffer; the
/// program never touches it directly).
fn handle_win_fill(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8) or args[1] > std.math.maxInt(u32) or args[2] > std.math.maxInt(u32) or args[3] > std.math.maxInt(u32) or args[4] > std.math.maxInt(u32) or args[5] > 0xffffff) {
        return error_result(.einval);
    }
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_fill(@truncate(args[0]), @truncate(args[1]), @truncate(args[2]), @truncate(args[3]), @truncate(args[4]), @truncate(args[5]))) {
        return error_result(.einval);
    }
    return 0;
}

/// Step 2 (Issue #205): `sys_win_fill_batch(buf_ptr, buf_len)` — slot 46.
/// Processes a packed array of fill rects in ONE SVC entry. Each rect is
/// 24 bytes: {id: u8, _pad: [3]u8, x: u32, y: u32, w: u32, h: u32, rgb: u32}.
/// Max 32 rects per batch (768 B). Returns the number of rects processed;
/// negative error on bad pointer or oversized batch.
fn handle_win_fill_batch(args: Args, _: *exceptions.VectorFrame) u64 {
    const buf_ptr = args[0];
    const buf_len = args[1];
    // Each rect is 24 bytes; max 32 rects (768 B).
    const rect_size: u64 = 24;
    const max_rects: u64 = 32;
    if (buf_len == 0 or buf_len > max_rects * rect_size or (buf_len % rect_size) != 0) {
        return error_result(.einval);
    }
    const num_rects = buf_len / rect_size;
    // Stack buffer for the batch (32 × 24 = 768 B).
    var batch: [32 * 24]u8 = undefined;
    const copy_len: usize = @intCast(buf_len);
    if (uaccess.copy_in(@ptrCast(&batch), buf_ptr, copy_len) == .fault) return error_result(.efault);
    var processed: u64 = 0;
    var i: u64 = 0;
    while (i < num_rects) : (i += 1) {
        const off = i * rect_size;
        const id = batch[off];
        if (id > std.math.maxInt(u8)) continue;
        const x = std.mem.readInt(u32, batch[off + 4 ..][0..4], .little);
        const y = std.mem.readInt(u32, batch[off + 8 ..][0..4], .little);
        const w = std.mem.readInt(u32, batch[off + 12 ..][0..4], .little);
        const h = std.mem.readInt(u32, batch[off + 16 ..][0..4], .little);
        const rgb = std.mem.readInt(u32, batch[off + 20 ..][0..4], .little);
        if (!win_owned_by_caller(id)) continue;
        if (driving_award.user_fill(id, x, y, w, h, rgb)) {
            processed += 1;
        }
    }
    return processed;
}

/// Arc2 W1 (claim 3589, ADR 0013 D1): `sys_win_resize(id, w, h)` — slot 47.
/// Resize the CALLER'S owned user window to (w, h), clamped to
/// 128×64..512×384 and on-scanout (the `user_resize` clamp), and emit
/// `WIN_RESIZE` (kind 10) to the owning pid. Returns 0 on success;
/// `EINVAL` for an unknown id, a non-user window, a window the caller does
/// NOT own, or an out-of-range word. Plain numbers, no uaccess.
fn handle_win_resize(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8) or args[1] > std.math.maxInt(u32) or args[2] > std.math.maxInt(u32)) {
        return error_result(.einval);
    }
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_resize(@truncate(args[0]), @truncate(args[1]), @truncate(args[2]))) {
        return error_result(.einval);
    }
    return 0;
}

/// `sys_win_present(id)`: mark the CALLER'S user window dirty so the
/// compositor blits its back-buffer on the next idle-loop pass (the
/// deferred-present discipline — the syscall never touches the gpu
/// directly; the shell idle loop's `driving_award.drain` composites).
/// Returns 0 on success; `EINVAL` for an unknown id or a window the caller
/// does NOT own.
fn handle_win_present(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_present(@truncate(args[0]))) return error_result(.einval);
    return 0;
}

/// `sys_win_close(id)`: release a user window OWNED BY THE CALLER (the EL0
/// teardown seam — the monitor's `dui close` is the EL1h PRIVILEGED
/// equivalent that closes any user window; the EL0 syscall is
/// owner-restricted). Returns 0 on success; `EINVAL` for an unknown id, a
/// non-user window (the terminal + clock are fixed), or a window the
/// caller does NOT own.
fn handle_win_close(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_close(@truncate(args[0]))) return error_result(.einval);
    return 0;
}

/// `sys_win_move(id, x, y)`: move the CALLER'S user window's top-left corner
/// to (x, y), CLAMPED inside the scanout (`driving_award.user_move` — a
/// window never moves off-screen). Returns 0 on success; `EINVAL` for an
/// unknown id, a window the caller does NOT own, an out-of-range word, or
/// an unarmed manager. No uaccess (plain numbers).
fn handle_win_move(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8) or args[1] > std.math.maxInt(u32) or args[2] > std.math.maxInt(u32)) {
        return error_result(.einval);
    }
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_move(@truncate(args[0]), @truncate(args[1]), @truncate(args[2]))) {
        return error_result(.einval);
    }
    return 0;
}

/// `sys_win_raise(id)`: raise the CALLER'S user window to the top of the
/// z-order (focus unchanged — tracked by id, the G5 discipline). Returns 0
/// on success; `EINVAL` for an unknown id or a window the caller does NOT
/// own.
fn handle_win_raise(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_raise(@truncate(args[0]))) return error_result(.einval);
    return 0;
}

/// Arc4 #238 (slot 49): `sys_win_raise_front(id)` — raise the CALLER'S
/// user window to the top of the z-order (focus unchanged). Owner-
/// restricted; refused on fixed layers. Returns 0; EINVAL for unknown id,
/// non-user window, or a window the caller does NOT own.
fn handle_win_raise_front(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_raise_front(@truncate(args[0]))) return error_result(.einval);
    return 0;
}

/// Arc4 #238 (slot 50): `sys_win_lower_back(id)` — lower the CALLER'S
/// user window to the bottom of the z-order (above fixed windows, below
/// all other user windows). Owner-restricted; refused on fixed layers.
/// Returns 0; EINVAL for unknown id, non-user window, or a window the
/// caller does NOT own.
fn handle_win_lower_back(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_lower_back(@truncate(args[0]))) return error_result(.einval);
    return 0;
}

/// Arc4 #240 (slot 51): `sys_notify(text_ptr, text_len, level)` — post a
/// desktop notification toast. `level` 0=info, 1=warning, 2=error.
/// Copies up to 280 bytes through uaccess into the bounded notification
/// FIFO (4 entries, drop-oldest). Returns 0; EINVAL for a non-process
/// caller or level > 2; EFAULT for a bad pointer.
fn handle_notify(args: Args, _: *exceptions.VectorFrame) u64 {
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    _ = pid;
    const text_addr = args[0];
    const text_len = args[1];
    const level: u8 = @truncate(args[2]);
    if (level > 2) return error_result(.einval);
    if (text_len > driving_award.notify_text_max) return error_result(.einval);
    if (text_len == 0) {
        // Empty notification is a no-op (honest).
        return 0;
    }
    // Copy text through uaccess.
    var buf: [driving_award.notify_text_max]u8 = undefined;
    const copy_len: usize = @min(text_len, driving_award.notify_text_max);
    if (uaccess.copy_in(buf[0..copy_len], text_addr, copy_len) != .ok) return error_result(.efault);
    driving_award.notify_push(buf[0..copy_len], level);
    return 0;
}

/// Arc4 #237 (slot 48): `sys_drag_start(buf_ptr, buf_len)` — store a drag
/// payload (up to 512 B) from the caller through uaccess. The compositor
/// delivers DRAG_ENTER/LEAVE/DROP events as the pointer crosses windows.
fn handle_drag_start(args: Args, _: *exceptions.VectorFrame) u64 {
    const owner = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const buf_addr = args[0];
    const buf_len: usize = @min(args[1], driving_award.drag_payload_max);
    if (buf_len == 0) return error_result(.einval);
    var buf: [driving_award.drag_payload_max]u8 = undefined;
    if (uaccess.copy_in(buf[0..buf_len], buf_addr, buf_len) != .ok) return error_result(.efault);
    driving_award.drag_start(buf[0..buf_len], owner);
    return 0;
}

/// M19 P1 (slot 56): sys_pipe_read — copy unread pipe bytes OUT through
/// uaccess. max_len clamped to capacity; empty pipe → 0; bad buffer → EFAULT.
fn handle_pipe_read(args: Args, _: *exceptions.VectorFrame) u64 {
    const buf_addr = args[0];
    const max_len: usize = @min(args[1], pipe.pipe_capacity);
    if (max_len == 0) return 0;
    const avail = pipe.available();
    if (avail == 0) return 0;
    const take = @min(avail, max_len);
    if (uaccess.copy_out(buf_addr, pipe.unread_slice()[0..take], take) != .ok) return error_result(.efault);
    pipe.advance_read(take);
    return @intCast(take);
}

/// M19 P1 (slot 57): sys_pipe_write — copy bytes into pipe through uaccess.
/// ENOSPC when full; EFAULT for bad buffer; EINVAL for oversized write.
fn handle_pipe_write(args: Args, _: *exceptions.VectorFrame) u64 {
    const buf_addr = args[0];
    const len = args[1];
    if (len == 0) return 0;
    if (len > pipe.pipe_capacity) return error_result(.einval);
    const room = pipe.capacity_left();
    if (len > room) return error_result(.enospc);
    if (uaccess.copy_in(pipe.append_slice()[0..@intCast(len)], buf_addr, @intCast(len)) != .ok) return error_result(.efault);
    pipe.advance_write(@intCast(len));
    return len;
}

/// M20-U1 (claim 5127, slot 58): `sys_font_size(window_id, size)` —
/// switch the terminal text layer between 8×8/16×16/24×24 and repaint.
/// EINVAL for any window other than the terminal (0) or a bad size.
fn handle_font_size(args: Args, _: *exceptions.VectorFrame) u64 {
    const win_id: u64 = args[0];
    const size: u64 = args[1];
    if (win_id != 0) return error_result(.einval);
    const s: fbtext.FontSize = switch (size) {
        0 => .small,
        1 => .medium,
        2 => .large,
        else => return error_result(.einval),
    };
    fbtext.set_font_size(s);
    driving_award.mark_terminal_dirty();
    _ = driving_award.composite();
    return 0;
}

/// M26 N1 (issue #399, slot 59): `sys_ping_send(ip)` — send one ICMP echo
/// request to `ip` (low 32 bits network order, e.g. 10.0.0.2 = 0x0a000002).
/// Uses the same `net_ping_request` path as the monitor's `net ping`
/// (ARP-resolved, own-IP check, `net_ready` guard). Returns 0 on success;
/// EINVAL when no IP set / peer not in ARP / transport not ready (the
/// caller should `net arp <ip>` first).
fn handle_ping_send(args: Args, _: *exceptions.VectorFrame) u64 {
    const ip_raw = args[0];
    const ip: [4]u8 = .{
        @truncate(ip_raw >> 24),
        @truncate(ip_raw >> 16),
        @truncate(ip_raw >> 8),
        @truncate(ip_raw),
    };
    var out_len: usize = 0;
    switch (virtio_net.net_ping_request(ip, &out_len)) {
        .ok => {
            virtio_net.ipv4.requests_sent += 1;
            virtio_net.ipv4.ping_seq +%= 1;
            return 0;
        },
        .not_ready, .no_peer => return error_result(.einval),
        .timeout => return error_result(.einval),
    }
}

/// M26 N1 (issue #399, slot 60): `sys_ping_poll()` — drain RX and report
/// whether a pong has landed. Returns the last echo reply sequence
/// (`ipv4.last_seq`, u16) if `pongs_observed > 0`, else 0. The caller
/// sends one ping and polls until the expected sequence appears.
fn handle_ping_poll(_: Args, _: *exceptions.VectorFrame) u64 {
    virtio_net.net_rx_drain();
    if (virtio_net.ipv4.pongs_observed == 0) return 0;
    return virtio_net.ipv4.last_seq;
}

/// Arc4 #237 (slot 55): `sys_drag_read(buf_ptr, max_len)` — copy the drag
/// payload OUT to the caller after receiving a DROP event. Consumes the
/// payload (one read only). Returns bytes copied, 0 if no payload.
fn handle_drag_read(args: Args, _: *exceptions.VectorFrame) u64 {
    const buf_addr = args[0];
    const max_len: usize = @min(args[1], driving_award.drag_payload_max);
    if (!driving_award.drag_is_active()) return 0;
    const payload = driving_award.drag_get_payload();
    const copy_len = @min(payload.len, max_len);
    if (copy_len == 0) return 0;
    if (uaccess.copy_out(buf_addr, payload[0..copy_len], copy_len) != .ok) return error_result(.efault);
    // Consume: clear the drag state.
    driving_award.drag_cancel();
    return @intCast(copy_len);
}

/// Arc4 #241 (slot 52): `sys_win_move_to_workspace(id, ws)` — move the
/// caller's window to workspace `ws` (0..2). EINVAL for out-of-range or
/// non-user window.
fn handle_win_move_to_workspace(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    const id: u8 = @truncate(args[0]);
    if (!win_owned_by_caller(id)) return error_result(.einval);
    const ws: u8 = @truncate(args[1]);
    if (ws >= driving_award.workspace_max) return error_result(.einval);
    if (!driving_award.user_move_to_workspace(id, ws)) return error_result(.einval);
    return 0;
}

/// `sys_win_set_title(id, text_ptr, text_len)`: set the dynamic title of
/// the caller's user window. Up to 63 bytes are copied from `text_ptr` into
/// the window's title buffer; the title is then visible in the taskbar and
/// Alt+Tab overlay. Returns 0; `EINVAL` for bad id or non-owner; `EFAULT`
/// for bad `text_ptr`.
fn handle_win_set_title(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    const id: u8 = @truncate(args[0]);
    if (!win_owned_by_caller(id)) return error_result(.einval);
    const ptr = args[1];
    const len = args[2];
    if (len > 64) return error_result(.einval);
    if (len > 0 and ptr == 0) return error_result(.einval);
    var buf: [64]u8 = undefined;
    if (len > 0) {
        if (uaccess.copy_in(&buf, ptr, @intCast(len)) != .ok) return error_result(.efault);
    }
    if (!driving_award.set_window_title(id, buf[0..len])) return error_result(.einval);
    return 0;
}

/// `sys_win_set_unsaved(id, flag)`: mark or clear the unsaved-changes flag
/// on the caller's window. When the flag is set and the user clicks the
/// close button, the compositor shows a Save/Don't Save/Cancel dialog
/// instead of closing immediately. `flag` 0 = clear, 1 = set.
fn handle_win_set_unsaved(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (args[1] > 1) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_set_unsaved(@truncate(args[0]), args[1] != 0)) return error_result(.einval);
    return 0;
}

/// `sys_win_get(id, buf)`: copy the CALLER'S user window's geometry
/// (x, y, w, h as four u32 LE words — `win_rect_bytes` 16) OUT through
/// uaccess, so an EL0 program can read its window's rect back after a
/// CLAMPED move (`sys_win_move` clamps silently; this is the read-back
/// seam). Returns 0; `EINVAL` for an unknown id, a non-user window (the
/// terminal + clock are fixed), or a window the caller does NOT own;
/// `EFAULT` for a bad `buf` (the claim-6120 contract — validated before
/// any bytes are written). The first pointer-taking win slot.
fn handle_win_get(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    const rect = driving_award.user_rect(@truncate(args[0])) orelse return error_result(.einval);
    var buf: [win_rect_bytes]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], rect.x, .little);
    std.mem.writeInt(u32, buf[4..8], rect.y, .little);
    std.mem.writeInt(u32, buf[8..12], rect.w, .little);
    std.mem.writeInt(u32, buf[12..16], rect.h, .little);
    if (uaccess.copy_out(args[1], buf[0..win_rect_bytes], win_rect_bytes) != .ok) return error_result(.efault);
    return 0;
}

/// `sys_win_query(id, buf)`: copy the CALLER'S user window's FULL state
/// (x, y, w, h, z, focused, visible, dirty as eight u32 LE words —
/// `win_query_bytes` 32) OUT through uaccess, so an EL0 program can
/// introspect its window end to end (z-order rank + focus + flags), not
/// just the rect. Returns 0; `EINVAL` for an unknown id, a non-user window
/// (the terminal + clock are fixed), or a window the caller does NOT own;
/// `EFAULT` for a bad `buf`. The second pointer-taking win slot.
fn handle_win_query(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    const q = driving_award.user_query(@truncate(args[0])) orelse return error_result(.einval);
    var buf: [win_query_bytes]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], q.x, .little);
    std.mem.writeInt(u32, buf[4..8], q.y, .little);
    std.mem.writeInt(u32, buf[8..12], q.w, .little);
    std.mem.writeInt(u32, buf[12..16], q.h, .little);
    std.mem.writeInt(u32, buf[16..20], q.z, .little);
    std.mem.writeInt(u32, buf[20..24], q.focused, .little);
    std.mem.writeInt(u32, buf[24..28], q.visible, .little);
    std.mem.writeInt(u32, buf[28..32], q.dirty, .little);
    if (uaccess.copy_out(args[1], buf[0..win_query_bytes], win_query_bytes) != .ok) return error_result(.efault);
    return 0;
}

/// `sys_win_set_visible(id, visible)`: hide (`visible` 0) or show (`visible`
/// 1) the CALLER'S user window — the window manager's visibility surface
/// from EL0 (`driving_award.user_set_visible`, owner-restricted like
/// fill/present/close). Hiding marks the terminal dirty so the next
/// composite repaints over the hidden window; showing marks the window
/// dirty so it reappears. Returns 0; `EINVAL` for an unknown id, a non-user
/// window (the terminal + clock are fixed), a window the caller does NOT
/// own, or a `visible` flag that is not 0/1. Plain numbers, no uaccess.
fn handle_win_set_visible(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (args[1] > 1) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_set_visible(@truncate(args[0]), args[1] != 0)) return error_result(.einval);
    return 0;
}

/// True when the window `id` exists AND is owned by the process currently
/// making the syscall (the per-process ownership check behind fill/present/
/// close). False for an unknown id, a fixed (terminal/clock) window, or a
/// non-process caller.
fn win_owned_by_caller(id: u8) bool {
    const owner = process.find_by_task(scheduler.current_id()) orelse return false;
    const wowner = driving_award.user_owner(id) orelse return false;
    return owner == wowner;
}

/// `sys_poll_event(buf)`: non-blocking event poll. If an event is queued for
/// the calling process, pops it, copies the 16-byte `Event` structure to `buf`
/// via `uaccess.copy_out`, and returns `1`. If the queue is empty, returns `0`.
/// Returns `EFAULT` (-3) for an invalid user buffer, `EINVAL` (-1) if the
/// calling task is not a registered process.
fn handle_poll_event(args: Args, _: *exceptions.VectorFrame) u64 {
    const address = args[0];
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (events.pending(pid) == 0) return 0;
    const ev = events.peek(pid) orelse return 0;
    const ev_bytes: *const [events.event_bytes]u8 = @ptrCast(&ev);
    if (uaccess.copy_out(address, ev_bytes, events.event_bytes) != .ok) {
        return error_result(.efault);
    }
    events.drop(pid);
    return 1;
}

/// `sys_wait_event(buf)`: blocking event wait. If an event is queued for the
/// calling process, pops it, copies 16 bytes to `buf` via `uaccess.copy_out`,
/// and returns `1`. If the queue is empty, blocks the calling task in the
/// scheduler via `scheduler.wait_event_current` (rewinding PC so SVC re-runs on
/// wakeup). Returns `EFAULT` (-3) or `EINVAL` (-1).
fn handle_wait_event(args: Args, _: *exceptions.VectorFrame) u64 {
    const address = args[0];
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (events.pending(pid) == 0) {
        if (!scheduler.wait_event_current(pid)) return error_result(.einval);
        return 0; // Staged next task; will restart upon wakeup
    }
    const ev = events.peek(pid) orelse return 0;
    const ev_bytes: *const [events.event_bytes]u8 = @ptrCast(&ev);
    if (uaccess.copy_out(address, ev_bytes, events.event_bytes) != .ok) {
        return error_result(.efault);
    }
    events.drop(pid);
    return 1;
}

/// Milestone 10 (claim 3570): slot 23 — sys_file_open(path_ptr, path_len, flags)
fn handle_file_open(args: Args, _: *exceptions.VectorFrame) u64 {
    const path_ptr = args[0];
    const path_len = args[1];
    const flags: u32 = @truncate(args[2]);
    if (path_len == 0 or path_len > file_table.max_path_len) return error_result(.einval);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);

    var path_buf: [file_table.max_path_len]u8 = undefined;
    if (uaccess.copy_in(&path_buf, path_ptr, @intCast(path_len)) != .ok) return error_result(.efault);

    const res = file_table.open(pid, path_buf[0..path_len], flags);
    if (res < 0) {
        return @bitCast(res);
    }
    return @intCast(res);
}

/// Milestone 10 (claim 3570): slot 24 — sys_file_read(fd, buf_ptr, count)
fn handle_file_read(args: Args, _: *exceptions.VectorFrame) u64 {
    const fd = args[0];
    const buf_ptr = args[1];
    const count = args[2];
    if (fd >= file_table.max_handles_per_process) return error_result(.ebadf);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (count == 0) return 0;

    const take_count = @min(count, 2048);
    var read_staging: [2048]u8 = undefined;
    const res = file_table.read(pid, fd, read_staging[0..take_count]);
    if (res < 0) {
        return @bitCast(res);
    }
    const bytes_read: usize = @intCast(res);
    if (bytes_read > 0) {
        if (uaccess.copy_out(buf_ptr, read_staging[0..bytes_read], bytes_read) != .ok) return error_result(.efault);
    }
    return @intCast(bytes_read);
}

/// Milestone 10 (claim 3570): slot 25 — sys_file_write(fd, buf_ptr, count)
fn handle_file_write(args: Args, _: *exceptions.VectorFrame) u64 {
    const fd = args[0];
    const buf_ptr = args[1];
    const count = args[2];
    if (fd >= file_table.max_handles_per_process) return error_result(.ebadf);
    if (count > 2048) return error_result(.enospc);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (count == 0) return 0;

    var write_staging: [2048]u8 = undefined;
    if (uaccess.copy_in(&write_staging, buf_ptr, @intCast(count)) != .ok) return error_result(.efault);

    const res = file_table.write(pid, fd, write_staging[0..count]);
    if (res < 0) {
        return @bitCast(res);
    }
    return @intCast(res);
}

/// Milestone 10 (claim 3570): slot 26 — sys_file_close(fd)
fn handle_file_close(args: Args, _: *exceptions.VectorFrame) u64 {
    const fd = args[0];
    if (fd >= file_table.max_handles_per_process) return error_result(.ebadf);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const res = file_table.close(pid, fd);
    if (res < 0) {
        return @bitCast(res);
    }
    return 0;
}

/// Milestone 10 (claim 3570): slot 27 — sys_dir_list(path_ptr, path_len, buf_ptr, max_entries)
fn handle_dir_list(args: Args, _: *exceptions.VectorFrame) u64 {
    const path_ptr = args[0];
    const path_len = args[1];
    const buf_ptr = args[2];
    const max_entries = args[3];
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (max_entries == 0) return 0;

    var path_buf: [file_table.max_path_len]u8 = undefined;
    if (path_len > 0) {
        if (path_len > file_table.max_path_len) return error_result(.enametoolong);
        if (uaccess.copy_in(&path_buf, path_ptr, @intCast(path_len)) != .ok) return error_result(.efault);
    }

    const take_entries = @min(max_entries, 16);
    var entries_staging: [16]file_table.DirEntry = undefined;
    const res = file_table.dir_list(pid, if (path_len == 0) "" else path_buf[0..path_len], entries_staging[0..take_entries]);
    if (res < 0) {
        return @bitCast(res);
    }
    const populated: usize = @intCast(res);
    if (populated > 0) {
        const bytes_to_copy = populated * @sizeOf(file_table.DirEntry);
        const raw_bytes: [*]const u8 = @ptrCast(&entries_staging);
        if (uaccess.copy_out(buf_ptr, raw_bytes[0..bytes_to_copy], bytes_to_copy) != .ok) return error_result(.efault);
    }
    return @intCast(populated);
}

/// Milestone 13 (claim 5801): slot 34 — sys_file_delete(path_ptr, path_len)
fn handle_file_delete(args: Args, _: *exceptions.VectorFrame) u64 {
    const path_ptr = args[0];
    const path_len = args[1];
    if (path_len == 0 or path_len > file_table.max_path_len) return error_result(.einval);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    var path_buf: [file_table.max_path_len]u8 = undefined;
    if (uaccess.copy_in(&path_buf, path_ptr, @intCast(path_len)) != .ok) return error_result(.efault);
    const res = file_table.delete(pid, path_buf[0..path_len]);
    if (res < 0) return @bitCast(res);
    return 0;
}

/// Milestone 13 (claim 5801): slot 35 — sys_file_rename(old_ptr, old_len, new_ptr, new_len)
fn handle_file_rename(args: Args, _: *exceptions.VectorFrame) u64 {
    const old_ptr = args[0];
    const old_len = args[1];
    const new_ptr = args[2];
    const new_len = args[3];
    if (old_len == 0 or old_len > file_table.max_path_len or new_len == 0 or new_len > file_table.max_path_len) return error_result(.einval);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    var old_buf: [file_table.max_path_len]u8 = undefined;
    var new_buf: [file_table.max_path_len]u8 = undefined;
    if (uaccess.copy_in(&old_buf, old_ptr, @intCast(old_len)) != .ok) return error_result(.efault);
    if (uaccess.copy_in(&new_buf, new_ptr, @intCast(new_len)) != .ok) return error_result(.efault);
    const res = file_table.rename(pid, old_buf[0..old_len], new_buf[0..new_len]);
    if (res < 0) return @bitCast(res);
    return 0;
}

/// Milestone 13 (claim 5801): slot 36 — sys_file_truncate(handle, size)
fn handle_file_truncate(args: Args, _: *exceptions.VectorFrame) u64 {
    const handle = args[0];
    const size: u32 = @truncate(args[1]);
    if (handle >= file_table.max_handles_per_process) return error_result(.ebadf);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const res = file_table.truncate(pid, handle, size);
    if (res < 0) return @bitCast(res);
    return 0;
}

/// Milestone 13 (claim 5801): slot 37 — sys_file_free(volume)
fn handle_file_free(args: Args, _: *exceptions.VectorFrame) u64 {
    const volume: u32 = @truncate(args[0]);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const res = file_table.free_space(pid, volume);
    if (res < 0) return @bitCast(res);
    return @intCast(res);
}

/// Milestone 14 (claim 0169): slot 38 — sys_clipboard_set(buf_ptr, len)
fn handle_clipboard_set(args: Args, _: *exceptions.VectorFrame) u64 {
    const buf_ptr = args[0];
    const raw_len = args[1];
    _ = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (raw_len == 0) {
        _ = clipboard.set("");
        return 0;
    }
    const take: usize = @min(@as(usize, @intCast(raw_len)), clipboard.capacity);
    if (uaccess.copy_in(clipboard_staging[0..take], buf_ptr, take) != .ok) return error_result(.efault);
    return @intCast(clipboard.set(clipboard_staging[0..take]));
}

/// Milestone 14 (claim 0169): slot 39 — sys_clipboard_get(buf_ptr, max)
fn handle_clipboard_get(args: Args, _: *exceptions.VectorFrame) u64 {
    const buf_ptr = args[0];
    const raw_max = args[1];
    _ = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (raw_max == 0) return 0;
    const take: usize = @min(@as(usize, @intCast(raw_max)), clipboard.capacity);
    const n = clipboard.get(clipboard_staging[0..take]);
    if (n > 0) {
        if (uaccess.copy_out(buf_ptr, clipboard_staging[0..n], n) != .ok) return error_result(.efault);
    }
    return @intCast(n);
}

/// Milestone 14 (claim 7323): slot 40 — sys_timer_set(delay_ticks)
/// Arm the CALLING process's app timer to fire ONE TIMER event (kind 9)
/// into its ADR 0009 queue after `delay_ticks` scheduler ticks. Zero
/// clamps to 1 (the sys_sleep minimum) and an over-long delay truncates
/// honestly at app_timers.max_delay_ticks — both documented. Re-arming
/// replaces any pending timer. Returns 0; EINVAL for a non-process caller.
fn handle_timer_set(args: Args, _: *exceptions.VectorFrame) u64 {
    const delay = args[0];
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    _ = app_timers.set(pid, delay);
    return 0;
}

/// Milestone 14 (claim 7323): slot 41 — sys_timer_cancel()
/// Disarm the calling process's app timer. Returns 1 if a pending timer
/// was canceled, 0 if none was armed; EINVAL for a non-process caller.
fn handle_timer_cancel(args: Args, _: *exceptions.VectorFrame) u64 {
    _ = args;
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    return if (app_timers.cancel(pid)) 1 else 0;
}

/// Milestone 15 (claim 7636): slot 42 — sys_audio_info(out_ptr)
/// Copy the device's negotiated playback state out through uaccess as a
/// 24-byte `AudioInfo` struct {ready, format, rate, channels, period_bytes,
/// max_len}. The app learns the format/rate/channels it must synthesize
/// in (FLOAT 19 / 48000 7 / stereo 2 on the observed VZ device). Returns
/// 0; `EINVAL` for a non-process caller, `EFAULT` for a bad buffer.
fn handle_audio_info(args: Args, _: *exceptions.VectorFrame) u64 {
    const out_ptr = args[0];
    _ = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const info = virtio_snd.snd_audio_info();
    const bytes = std.mem.asBytes(&info);
    if (uaccess.copy_out(out_ptr, bytes, bytes.len) != .ok) return error_result(.efault);
    return 0;
}

/// Milestone 15 (claim 7636): slot 43 — sys_audio_play(ptr, len)
/// Copy the caller's PCM samples in through uaccess in bounded periods
/// (4096 B — the A2 period buffer, zero heap), run the proven control
/// flow (PCM_INFO → SET_PARAMS → PREPARE → START → submit/drain per
/// period → STOP → RELEASE), and return the bytes played. Errors: `EINVAL`
/// for a non-process caller or a zero length, `ENAMETOOLONG` over
/// `audio_max_len`, `EFAULT` for a bad pointer, `ENXIO` when no sound
/// device is attached (the default VM) or a device-level refusal.
fn handle_audio_play(args: Args, _: *exceptions.VectorFrame) u64 {
    const ptr = args[0];
    const raw_len = args[1];
    _ = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (raw_len == 0) return error_result(.einval);
    if (raw_len > virtio_snd.audio_max_len) return error_result(.enametoolong);
    if (!virtio_snd.snd_ready) return error_result(.enxio);
    const len: usize = @intCast(raw_len);
    const st = virtio_snd.snd_audio_start();
    if (st != virtio_snd.S_OK) return error_result(.enxio);
    var off: usize = 0;
    while (off < len) {
        const chunk: usize = @min(len - off, @as(usize, virtio_snd.beep_period_bytes));
        if (uaccess.copy_in(virtio_snd.beep_buf[4..][0..chunk], ptr + off, chunk) != .ok) {
            _ = virtio_snd.snd_audio_stop();
            return error_result(.efault);
        }
        if (virtio_snd.snd_audio_submit(@intCast(chunk)) != virtio_snd.S_OK) {
            _ = virtio_snd.snd_audio_stop();
            return error_result(.enxio);
        }
        off += chunk;
    }
    if (virtio_snd.snd_audio_stop() != virtio_snd.S_OK) return error_result(.enxio);
    return @intCast(len);
}

/// M15 follow-up (claim 9297): slot 44 — sys_audio_volume(vol)
/// Set the bounded kernel-side stream gain (0..100 percent) that
/// `sys_audio_play` applies to every period at submit time. Pure kernel
/// state — it works without a device (a later --sound attach inherits
/// it). Returns the volume on success; `EINVAL` for a non-process caller
/// or an out-of-range value (honest refusal, no silent clamping).
fn handle_audio_volume(args: Args, _: *exceptions.VectorFrame) u64 {
    const vol = args[0];
    _ = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (vol > 100) return error_result(.einval);
    return virtio_snd.snd_set_volume(@intCast(vol));
}

/// M15 follow-up (claim 9297): slot 45 — sys_audio_mute(muted)
/// Set the kernel-side mute state (1 = silent). Same contract as slot 44:
/// pure kernel state, applied at the submit choke point. Returns 0 on
/// success; `EINVAL` for a non-process caller or a value that is not 0/1.
fn handle_audio_mute(args: Args, _: *exceptions.VectorFrame) u64 {
    const muted = args[0];
    _ = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (muted > 1) return error_result(.einval);
    _ = virtio_snd.snd_set_mute(muted == 1);
    return 0;
}

/// Claim 6359 (ADR 0007 slot 28): `sys_exec(path_ptr, path_len)` — the
/// EL0 exec seam. Marshals the path through the claim-6120 uaccess window
/// (the `sys_file_open` pattern), requires a process caller, and reuses
/// the EL1h loader `exec.exec_file` to load the named `.BIN` from the ESP
/// into a fresh process slot and spawn it at EL0. Returns the new
/// process's pid on success (via `exec.last_exec_pid`); the caller may
/// hand it to `sys_wait` or a future `sys_kill`. Errors: `EINVAL` for a
/// non-process caller, an empty/over-long path, or a loader refusal
/// (no disk, bad DSK1 image, oversize, no args room); `EFAULT` for a bad
/// path pointer; `ENOENT` when the file is absent; `ENOSPC` when a
/// capacity gate refuses (pool, page allocator, page-table carve-out,
/// process registry).
fn handle_exec(args: Args, _: *exceptions.VectorFrame) u64 {
    const path_ptr = args[0];
    const path_len = args[1];
    if (path_len == 0 or path_len > esp.name_max) return error_result(.einval);
    // The caller must be a process (an EL1h task cannot exec from EL0).
    _ = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);

    var path_buf: [esp.name_max]u8 = undefined;
    if (uaccess.copy_in(&path_buf, path_ptr, @intCast(path_len)) != .ok) return error_result(.efault);

    const res = esp_exec.exec_file(path_buf[0..path_len], &.{});
    return switch (res) {
        .ok => blk: {
            // The pid is set at the loader's success point; a missing
            // value (unreachable in practice) degrades to 0.
            break :blk @as(u64, if (esp_exec.last_exec_pid()) |new_pid| @intCast(new_pid) else 0);
        },
        .no_disk, .too_large, .bad_magic, .bad_entry, .no_args_room, .too_many_args => error_result(.einval),
        // M22 D1 (issue #324): ELF refusals are the caller's bad image.
        .bad_elf, .unsupported_arch, .no_pt_load, .too_many_segments, .segment_too_large => error_result(.einval),
        .not_found => error_result(.enoent),
        .pool_full, .out_of_memory, .table_full, .process_full => error_result(.enospc),
    };
}

/// Claim 7604 (ADR 0007 slot 29): `sys_kill(target_pid)` — the EL0
/// termination seam. Requires a process caller, validates the target
/// through the process registry (range, free, exited, no executor), and
/// arms the kill through the claim-7786 seam (`scheduler.request_kill` —
/// a pure TCB write, safe from SVC context). The target exits with the
/// reserved status 137 at its next ring selection, flowing through the
/// real exit → zombie → idle-reap → page-return lifecycle. Returns 0 once
/// armed; `EINVAL` for every refusal (the `sys_wait` precedent for numeric
/// targets). Self-kill is allowed (the monitor's `kill` is equally
/// general); a permanently blocked target keeps the EL1h kill's
/// documented bound — the arm applies at the target's next selection.
fn handle_kill(args: Args, _: *exceptions.VectorFrame) u64 {
    const target = args[0];
    // The caller must be a process (an EL1h task cannot kill from EL0).
    _ = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (target >= process.max_processes) return error_result(.einval);
    const info = process.info(@as(usize, @intCast(target))) orelse return error_result(.einval);
    if (info.state == .exited) return error_result(.einval);
    const task_id = info.task_id orelse return error_result(.einval);
    return switch (scheduler.request_kill(task_id)) {
        .ok => 0,
        .not_found, .already_exited, .refused => error_result(.einval),
    };
}

/// True when the process currently making the syscall owns the single
/// global TCP connection (`tcp.owner_pid` matches the caller's pid). False
/// for a non-process caller or when another process owns it. The connection
/// is process-owned once established — a second process is refused EACCES
/// (the M14 S4 ownership audit; the connection auto-closes on owner exit
/// via `tcp.close_owner`).
fn tcp_owned_by_caller() bool {
    const owner = process.find_by_task(scheduler.current_id()) orelse return false;
    const current = tcp.owner_pid orelse return false;
    return owner == current;
}

/// Slot 30: `sys_tcp_connect(ip, port)`: Connect to target IPv4:port.
fn handle_tcp_connect(args: Args, _: *exceptions.VectorFrame) u64 {
    const ip_raw = args[0];
    const dst_port = args[1];
    if (dst_port == 0 or dst_port > 0xffff) return error_result(.einval);
    if (!virtio_net.net_ready) return error_result(.einval);
    if (!virtio_net.arp.ip_set()) return error_result(.einval);
    const ip: [4]u8 = .{
        @truncate(ip_raw >> 24),
        @truncate(ip_raw >> 16),
        @truncate(ip_raw >> 8),
        @truncate(ip_raw),
    };
    if (std.mem.eql(u8, &ip, &virtio_net.arp.own_ip)) return error_result(.einval);

    if (tcp.state == .closed) {
        tcp.reset();
    }
    if (tcp.state != .idle) {
        if (tcp.state == .established and std.mem.eql(u8, &ip, &tcp.peer_ip) and dst_port == tcp.peer_port) {
            // Idempotent re-connect to the SAME peer is only allowed for
            // the connection's owner (a second process is refused EACCES).
            if (!tcp_owned_by_caller()) return error_result(.eacces);
            return 0;
        }
        return error_result(.einval);
    }

    virtio_net.net_rx_drain();
    const peer_mac = virtio_net.arp.lookup(ip) orelse return error_result(.einval);
    const isn: u32 = @truncate(csprng.random_u64());
    tcp.start(ip, @truncate(dst_port), isn, peer_mac);
    if (process.find_by_task(scheduler.current_id())) |pid| {
        tcp.owner_pid = pid;
    }

    var out_len: usize = 0;
    switch (virtio_net.net_tcp_send(tcp.msg[0..tcp.msg_len], &out_len)) {
        .ok => {
            tcp.syn_sent += 1;
            tcp.advance_snd(1);
            tcp.record_pending();
        },
        else => {
            tcp.state = .idle;
            return error_result(.einval);
        },
    }

    var iterations: usize = 0;
    while (tcp.state == .syn_sent and iterations < 1000000) : (iterations += 1) {
        virtio_net.net_rx_drain();
        if (tcp.ack_pending) {
            var ack_len: usize = 0;
            if (virtio_net.net_tcp_send(tcp.msg[0..tcp.msg_len], &ack_len) == .ok) {
                tcp.ack_pending = false;
                tcp.ack_sent += 1;
            }
        }
        if (tcp.state == .established) return 0;
        if (tcp.state == .closed) return error_result(.einval);
        if (tcp.connect_timed_out()) {
            tcp.abort_timeout();
            return error_result(.einval);
        }
    }

    if (tcp.state == .established) return 0;
    return error_result(.einval);
}

/// Slot 31: `sys_tcp_send(buf, len)`: Send up to payload_max (64) bytes.
fn handle_tcp_send(args: Args, _: *exceptions.VectorFrame) u64 {
    const address = args[0];
    var len = args[1];
    if (len == 0) return 0;
    if (len > tcp.payload_max) len = tcp.payload_max;
    if (tcp.state != .established) return error_result(.einval);
    if (!tcp_owned_by_caller()) return error_result(.eacces);

    if (uaccess.copy_in(&tcp_send_staging, address, @intCast(len)) != .ok) return error_result(.efault);

    tcp.build_data_msg(tcp_send_staging[0..@intCast(len)]);
    var out_len: usize = 0;
    switch (virtio_net.net_tcp_send(tcp.msg[0..tcp.msg_len], &out_len)) {
        .ok => {
            tcp.data_sent += 1;
            tcp.advance_snd(@intCast(len));
            tcp.record_pending();
            return len;
        },
        else => return error_result(.einval),
    }
}

/// Slot 32: `sys_tcp_recv(buf, max)`: Receive up to max bytes into user buffer.
fn handle_tcp_recv(args: Args, _: *exceptions.VectorFrame) u64 {
    const address = args[0];
    var max = args[1];
    if (max == 0) return 0;
    if (max > tcp.payload_max) max = tcp.payload_max;
    if (tcp.state != .established and tcp.state != .closed and tcp.state != .fin_sent) {
        return error_result(.einval);
    }
    if (!tcp_owned_by_caller()) return error_result(.eacces);

    virtio_net.net_rx_drain();

    if (tcp.ack_pending) {
        var out_len: usize = 0;
        if (virtio_net.net_tcp_send(tcp.msg[0..tcp.msg_len], &out_len) == .ok) {
            tcp.ack_pending = false;
            tcp.ack_sent += 1;
        }
    }

    if (!tcp.rx_pending) return 0;

    const take = @min(@as(usize, @intCast(max)), tcp.rx_len);
    if (uaccess.copy_out(address, tcp.rx_payload[0..take], take) != .ok) return error_result(.efault);
    _ = tcp.take_rx();
    return @intCast(take);
}

/// Slot 33: `sys_tcp_close()`: Initiate client FIN teardown.
fn handle_tcp_close(_: Args, _: *exceptions.VectorFrame) u64 {
    if (tcp.state == .idle) return 0;
    if (!tcp_owned_by_caller()) return error_result(.eacces);
    if (tcp.state == .established) {
        tcp.build_fin_msg();
        var out_len: usize = 0;
        if (virtio_net.net_tcp_send(tcp.msg[0..tcp.msg_len], &out_len) == .ok) {
            tcp.fin_sent += 1;
            tcp.advance_snd(1);
            tcp.record_pending();
            tcp.state = .fin_sent;
        }
    }

    var iterations: usize = 0;
    while (tcp.state == .fin_sent and iterations < 100000) : (iterations += 1) {
        virtio_net.net_rx_drain();
    }

    if (tcp.ack_pending or tcp.state == .closed) {
        if (tcp.ack_pending) {
            var out_len: usize = 0;
            if (virtio_net.net_tcp_send(tcp.msg[0..tcp.msg_len], &out_len) == .ok) {
                tcp.ack_pending = false;
                tcp.ack_sent += 1;
            }
        }
        tcp.state = .idle;
    }

    tcp.owner_pid = null;
    return 0;
}

/// Deterministic monitor output for the implemented rows and their counters.
pub fn report(con: *console.Console) void {
    var live: usize = 0;
    for (ensure_table()) |e| {
        if (e.handler != null) live += 1;
    }
    con.puts("syscalls: slots=64 implemented=");
    con.print_u64(live);
    con.puts("\n");
    // Slots are no longer contiguous (58 is live, 56/57 are Lane A
    // reservations), so walk the whole namespace and skip holes.
    var number: u64 = 0;
    while (number < slot_count) : (number += 1) {
        const info = entry_info(number) orelse continue;
        con.puts("  ");
        con.print_u64(info.number);
        con.puts(" ");
        con.puts(info.name);
        con.puts(" calls=");
        con.print_u64(info.calls);
        con.puts("\n");
    }
}

var test_write_buffer: [write_cap]u8 = undefined;
var test_write_len: usize = 0;

fn test_writer(bytes: []const u8) void {
    @memcpy(test_write_buffer[test_write_len..][0..bytes.len], bytes);
    test_write_len += bytes.len;
}

fn fresh_frame() exceptions.VectorFrame {
    return [_]u64{0} ** exceptions.vector_frame_slots;
}

var test_marshaled_args: Args = [_]u64{0} ** 6;
fn capture_marshaled_args(args: Args, _: *exceptions.VectorFrame) u64 {
    test_marshaled_args = args;
    return 0xcafe;
}

test "syscall: runtime table has 64 slots and sixty-two unique implemented rows" {
    init(test_writer);
    const table = ensure_table();
    try std.testing.expectEqual(@as(usize, 64), table.len);
    var seen: [slot_count]bool = [_]bool{false} ** slot_count;
    var implemented: usize = 0;
    for (table, 0..) |entry, number| {
        if (entry.handler != null) {
            try std.testing.expect(!seen[number]);
            seen[number] = true;
            implemented += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 62), implemented);
    try std.testing.expectEqualStrings("sys_pipe_read", entry_info(sys_pipe_read).?.name);
    try std.testing.expectEqualStrings("sys_pipe_write", entry_info(sys_pipe_write).?.name);
    try std.testing.expectEqualStrings("sys_font_size", entry_info(sys_font_size).?.name);
    try std.testing.expectEqualStrings("sys_audio_info", entry_info(42).?.name);
    try std.testing.expectEqualStrings("sys_audio_play", entry_info(43).?.name);
    try std.testing.expectEqualStrings("sys_audio_volume", entry_info(44).?.name);
    try std.testing.expectEqualStrings("sys_audio_mute", entry_info(45).?.name);
    try std.testing.expectEqualStrings("sys_ping", entry_info(0).?.name);
    try std.testing.expectEqualStrings("sys_exit", entry_info(3).?.name);
    try std.testing.expectEqualStrings("sys_sleep", entry_info(4).?.name);
    try std.testing.expectEqualStrings("sys_ipc_send", entry_info(5).?.name);
    try std.testing.expectEqualStrings("sys_ipc_recv", entry_info(6).?.name);
    try std.testing.expectEqualStrings("sys_procs", entry_info(7).?.name);
    try std.testing.expectEqualStrings("sys_wait", entry_info(8).?.name);
    try std.testing.expectEqualStrings("sys_udp_listen", entry_info(9).?.name);
    try std.testing.expectEqualStrings("sys_udp_send", entry_info(10).?.name);
    try std.testing.expectEqualStrings("sys_udp_recv", entry_info(11).?.name);
    try std.testing.expectEqualStrings("sys_win_open", entry_info(12).?.name);
    try std.testing.expectEqualStrings("sys_win_fill", entry_info(13).?.name);
    try std.testing.expectEqualStrings("sys_win_present", entry_info(14).?.name);
    try std.testing.expectEqualStrings("sys_win_close", entry_info(15).?.name);
    try std.testing.expectEqualStrings("sys_win_move", entry_info(16).?.name);
    try std.testing.expectEqualStrings("sys_win_raise", entry_info(17).?.name);
    try std.testing.expectEqualStrings("sys_win_get", entry_info(18).?.name);
    try std.testing.expectEqualStrings("sys_win_query", entry_info(19).?.name);
    try std.testing.expectEqualStrings("sys_win_set_visible", entry_info(20).?.name);
    try std.testing.expectEqualStrings("sys_poll_event", entry_info(21).?.name);
    try std.testing.expectEqualStrings("sys_wait_event", entry_info(22).?.name);
    try std.testing.expectEqualStrings("sys_file_open", entry_info(23).?.name);
    try std.testing.expectEqualStrings("sys_file_read", entry_info(24).?.name);
    try std.testing.expectEqualStrings("sys_file_write", entry_info(25).?.name);
    try std.testing.expectEqualStrings("sys_file_close", entry_info(26).?.name);
    try std.testing.expectEqualStrings("sys_dir_list", entry_info(27).?.name);
    try std.testing.expectEqualStrings("sys_exec", entry_info(28).?.name);
    try std.testing.expectEqualStrings("sys_kill", entry_info(29).?.name);
    try std.testing.expectEqualStrings("sys_tcp_connect", entry_info(30).?.name);
    try std.testing.expectEqualStrings("sys_tcp_send", entry_info(31).?.name);
    try std.testing.expectEqualStrings("sys_tcp_recv", entry_info(32).?.name);
    try std.testing.expectEqualStrings("sys_tcp_close", entry_info(33).?.name);
    try std.testing.expectEqualStrings("sys_file_delete", entry_info(34).?.name);
    try std.testing.expectEqualStrings("sys_file_rename", entry_info(35).?.name);
    try std.testing.expectEqualStrings("sys_file_truncate", entry_info(36).?.name);
    try std.testing.expectEqualStrings("sys_file_free", entry_info(37).?.name);
    try std.testing.expectEqualStrings("sys_clipboard_set", entry_info(38).?.name);
    try std.testing.expectEqualStrings("sys_clipboard_get", entry_info(39).?.name);
    try std.testing.expectEqualStrings("sys_timer_set", entry_info(40).?.name);
    try std.testing.expectEqualStrings("sys_timer_cancel", entry_info(41).?.name);
    try std.testing.expectEqualStrings("sys_win_fill_batch", entry_info(46).?.name);
    try std.testing.expectEqualStrings("sys_win_resize", entry_info(47).?.name);
    try std.testing.expectEqualStrings("sys_drag_start", entry_info(48).?.name);
    try std.testing.expectEqualStrings("sys_win_raise_front", entry_info(49).?.name);
    try std.testing.expectEqualStrings("sys_win_lower_back", entry_info(50).?.name);
    try std.testing.expectEqualStrings("sys_notify", entry_info(51).?.name);
    try std.testing.expectEqualStrings("sys_ping_send", entry_info(sys_ping_send).?.name);
    try std.testing.expectEqualStrings("sys_ping_poll", entry_info(sys_ping_poll).?.name);
    try std.testing.expect(entry_info(63) == null);
}

test "syscall: adapter decodes x8 and x0-x5 and unknown numbers return ENOSYS" {
    userspace.init();
    init(test_writer);
    var frame = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_ping));
    try std.testing.expect(exceptions.frame_write(&frame, 0, 41));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(@as(u64, 41), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_ping));

    try std.testing.expect(exceptions.frame_write(&frame, 8, 63));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(error_result(.enosys), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(63));

    try std.testing.expect(exceptions.frame_write(&frame, 8, 64));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(error_result(.enosys), exceptions.frame_read(&frame, 0));
}

test "syscall: handle_svc marshals every x0-x5 argument before replacing x0" {
    init(test_writer);
    _ = ensure_table();
    const saved = table_storage[63];
    defer table_storage[63] = saved;
    table_storage[63] = .{ .name = "test_capture", .handler = capture_marshaled_args };
    var frame = fresh_frame();
    const expected: Args = .{
        0x0101_0101_0101_0101,
        0x1212_1212_1212_1212,
        0x2323_2323_2323_2323,
        0x3434_3434_3434_3434,
        0x4545_4545_4545_4545,
        0x5656_5656_5656_5656,
    };
    for (expected, 0..) |value, reg| try std.testing.expect(exceptions.frame_write(&frame, @intCast(reg), value));
    try std.testing.expect(exceptions.frame_write(&frame, 8, 63));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(expected, test_marshaled_args);
    try std.testing.expectEqual(@as(u64, 0xcafe), exceptions.frame_read(&frame, 0));
}

test "syscall: write validates fd, cap, and the uaccess EFAULT contract" {
    init(test_writer);
    test_write_len = 0;
    var frame = fresh_frame();
    const bytes = "write-through-mock";
    set_user_regions(
        .{ .base = @intFromPtr(bytes.ptr), .len = bytes.len },
        .{ .base = 0, .len = 0 },
    );
    var args: Args = .{ 1, @intFromPtr(bytes.ptr), bytes.len, 0, 0, 0 };
    try std.testing.expectEqual(@as(u64, bytes.len), dispatch(sys_write, args, &frame));
    try std.testing.expectEqualStrings(bytes, test_write_buffer[0..test_write_len]);

    args[0] = 2;
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_write, args, &frame));
    args[0] = 1;
    args[2] = write_cap + 1;
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_write, args, &frame));
    // Bad user pointers now return the reserved EFAULT (-3), never EINVAL:
    // arithmetic overflow, one byte before the region, one byte past it,
    // and an unmapped address above the identity blanket.
    args[1] = std.math.maxInt(u64) - 1;
    args[2] = 4;
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_write, args, &frame));
    args[1] = @intFromPtr(bytes.ptr) - 1;
    args[2] = 1;
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_write, args, &frame));
    args[1] = @intFromPtr(bytes.ptr) + bytes.len - 1;
    args[2] = 2;
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_write, args, &frame));
    args[1] = uaccess.diagnostic_unmapped;
    args[2] = 8;
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_write, args, &frame));

    // Zero length is legal even at a wild address: nothing is copied.
    test_write_len = 0;
    args[1] = uaccess.diagnostic_unmapped;
    args[2] = 0;
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_write, args, &frame));
    try std.testing.expectEqual(@as(usize, 0), test_write_len);
}

test "syscall: yield returns zero and exit removes the current task" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_yield, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), scheduler.cooperative_yield_count());
    // worker -> user, then exit the EL0 task. It is reaped from the runnable
    // ring, so the selected frame belongs to shell and can never be `frame`.
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_exit, .{ 7, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.is_terminated(2));
    try std.testing.expectEqual(@as(?u64, 7), scheduler.terminated_status(2));
    try std.testing.expectEqual(@as(u64, 1), scheduler.exit_count());
    try std.testing.expect(exceptions.resume_frame != @intFromPtr(&frame));
}

test "syscall: sleep blocks the current task and returns zero on wake" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    var frame = fresh_frame();
    // The shell (slot 0) sleeps 2 ticks: it is blocked and the worker is
    // staged; the SVC frame is untouched (the caller's x0 stays 0xdead until
    // it resumes — then the handler's 0 is written, as handle_svc does).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_sleep, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 1), scheduler.current_id());
    try std.testing.expect(scheduler.is_blocked(0));
    // A blocked task is skipped by the round-robin ring.
    try std.testing.expect(scheduler.yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.yield_current()); // user -> idle
    try std.testing.expectEqual(@as(usize, scheduler.idle_id), scheduler.current_id());
    try std.testing.expect(scheduler.yield_current()); // idle -> worker (shell still blocked)
    try std.testing.expectEqual(@as(usize, 1), scheduler.current_id());
    // One tick is not enough for a 2-tick sleep; the second tick wakes it.
    scheduler.on_tick();
    try std.testing.expect(scheduler.is_blocked(0));
    scheduler.on_tick();
    try std.testing.expect(!scheduler.is_blocked(0));
    // The ring reaches the woken shell again.
    try std.testing.expect(scheduler.yield_current()); // worker -> user
    try std.testing.expect(scheduler.yield_current()); // user -> idle
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expectEqual(@as(usize, 0), scheduler.current_id());
}

test "syscall: handle_svc writes yield result into the suspended caller frame" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    var caller = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&caller, 0, 0xdead));
    try std.testing.expect(exceptions.frame_write(&caller, 8, sys_yield));
    exceptions.resume_frame = @intFromPtr(&caller);
    try std.testing.expect(handle_svc(&caller, svc_immediate));
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(&caller, 0));
    try std.testing.expect(exceptions.resume_frame != @intFromPtr(&caller));
    try std.testing.expectEqual(@as(usize, 1), scheduler.current_id());
}

test "syscall: ipc send/recv round-trip moves bytes between two processes" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    // A second live process (the peer) on its own task slot.
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const peer_pid = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const peer_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(peer_pid, peer_task);
    scheduler.start();

    const send_bytes = "ping 1\n";
    var recv_buf: [mailbox.message_max]u8 = undefined;
    set_user_regions(
        .{ .base = @intFromPtr(send_bytes.ptr), .len = send_bytes.len },
        .{ .base = @intFromPtr(&recv_buf), .len = recv_buf.len },
    );
    var frame = fresh_frame();
    // Drive the ring to the boot payload's task (process 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (task 2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    // Process 0 sends "ping 1\n" to the peer (pid 1).
    try std.testing.expectEqual(@as(u64, send_bytes.len), dispatch(sys_ipc_send, .{ peer_pid, @intFromPtr(send_bytes.ptr), send_bytes.len, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 1), mailbox.pending(peer_pid));
    // Drive the ring to the peer's task: it recv's the SAME bytes.
    try std.testing.expect(scheduler.yield_current()); // user -> peer (task 3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, send_bytes.len), dispatch(sys_ipc_recv, .{ @intFromPtr(&recv_buf), mailbox.message_max, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings(send_bytes, recv_buf[0..send_bytes.len]);
    try std.testing.expectEqual(@as(usize, 0), mailbox.pending(peer_pid));
    const peer_info = mailbox.info(peer_pid);
    try std.testing.expectEqual(@as(u64, 1), peer_info.sent);
    try std.testing.expectEqual(@as(u64, 1), peer_info.recv);
}

test "syscall: ipc send refuses full, empty, and isolated targets exactly" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // process 0 (boot payload), task 2
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const peer_pid = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const peer_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(peer_pid, peer_task);
    scheduler.start();
    const bytes = "ping 1\n";
    set_user_regions(
        .{ .base = @intFromPtr(bytes.ptr), .len = bytes.len },
        .{ .base = 0, .len = 0 },
    );
    var frame = fresh_frame();
    // A zero-length send is a no-op returning 0.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_ipc_send, .{ peer_pid, 0, 0, 0, 0, 0 }, &frame));
    // Truncation: a 100-byte send stores the first 64 bytes and returns 64.
    const long = "x" ** 100;
    set_user_regions(.{ .base = @intFromPtr(long.ptr), .len = long.len }, .{ .base = 0, .len = 0 });
    try std.testing.expectEqual(@as(u64, mailbox.message_max), dispatch(sys_ipc_send, .{ peer_pid, @intFromPtr(long.ptr), long.len, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 1), mailbox.pending(peer_pid));
    try std.testing.expectEqual(@as(usize, mailbox.message_max), mailbox.message(peer_pid, 0).?.len);
    // Re-arm the window on `bytes` (the truncation block moved it to `long`),
    // then fill the ring: 7 more sends fill the 8 slots (card 4b, claim
    // 3179: the capacity is a data-path constant, re-derived 4 → 8); the
    // 9th is ENOSPC.
    set_user_regions(
        .{ .base = @intFromPtr(bytes.ptr), .len = bytes.len },
        .{ .base = 0, .len = 0 },
    );
    for (1..mailbox.max_messages) |_| try std.testing.expectEqual(@as(u64, 1), dispatch(sys_ipc_send, .{ peer_pid, @intFromPtr(bytes.ptr), 1, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enospc), dispatch(sys_ipc_send, .{ peer_pid, @intFromPtr(bytes.ptr), 1, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, mailbox.max_messages), mailbox.pending(peer_pid));
    // Isolation: a free pid, an out-of-range pid, and an exited pid are EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_ipc_send, .{ 7, @intFromPtr(bytes.ptr), 1, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_ipc_send, .{ process.max_processes, @intFromPtr(bytes.ptr), 1, 0, 0, 0 }, &frame));
    const gone = process.create("GONE", .{ .entry_va = 0x400000, .content_len = 1 }, .{}, .{}).?;
    _ = process.bind(gone, 99);
    _ = process.on_task_exit(99, 7);
    _ = process.take_exit_report();
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_ipc_send, .{ gone, @intFromPtr(bytes.ptr), 1, 0, 0, 0 }, &frame));
    // Error precedence: the full-ring check runs BEFORE the uaccess check,
    // so a bad pointer against a full ring is still ENOSPC (nothing is ever
    // copied into a full ring).
    try std.testing.expectEqual(error_result(.enospc), dispatch(sys_ipc_send, .{ peer_pid, uaccess.diagnostic_unmapped, 4, 0, 0, 0 }, &frame));
    // With a slot free, EFAULT: a bad user pointer is rejected before any
    // mailbox mutation.
    mailbox.drop(peer_pid);
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_ipc_send, .{ peer_pid, uaccess.diagnostic_unmapped, 4, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, mailbox.max_messages - 1), mailbox.pending(peer_pid));
}

test "syscall: ipc recv returns empty, clamps, truncates, and EFAULT keeps the message" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0
    scheduler.start();
    var frame = fresh_frame();
    var recv_buf: [mailbox.message_max]u8 = undefined;
    // An EL1h task (the shell here) is never a process: EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_ipc_recv, .{ @intFromPtr(&recv_buf), mailbox.message_max, 0, 0, 0, 0 }, &frame));
    // Drive to the boot payload's task (process 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&recv_buf), .len = recv_buf.len },
    );
    // Empty: nothing to receive -> 0.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_ipc_recv, .{ @intFromPtr(&recv_buf), mailbox.message_max, 0, 0, 0, 0 }, &frame));
    // Seed process 0's own ring directly (a sender targeted it).
    try std.testing.expectEqual(mailbox.SendResult.ok, mailbox.send(0, "ping 7\n"));
    // max > 64 clamps to 64 (still returns the full 7).
    try std.testing.expectEqual(@as(u64, 7), dispatch(sys_ipc_recv, .{ @intFromPtr(&recv_buf), 100, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("ping 7\n", recv_buf[0..7]);
    try std.testing.expectEqual(@as(usize, 0), mailbox.pending(0));
    // A message longer than max is truncated to max and consumed (documented).
    try std.testing.expectEqual(mailbox.SendResult.ok, mailbox.send(0, "ping 77\n"));
    try std.testing.expectEqual(@as(u64, 4), dispatch(sys_ipc_recv, .{ @intFromPtr(&recv_buf), 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("ping", recv_buf[0..4]);
    try std.testing.expectEqual(@as(usize, 0), mailbox.pending(0));
    // EFAULT on a bad recv buffer: the message is NOT dropped (peek ->
    // copy_out -> drop ordering).
    try std.testing.expectEqual(mailbox.SendResult.ok, mailbox.send(0, "ping 9\n"));
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_ipc_recv, .{ uaccess.diagnostic_unmapped, mailbox.message_max, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 1), mailbox.pending(0));
    // The message is still there for a correct recv.
    try std.testing.expectEqual(@as(u64, 7), dispatch(sys_ipc_recv, .{ @intFromPtr(&recv_buf), mailbox.message_max, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("ping 9\n", recv_buf[0..7]);
    try std.testing.expectEqual(@as(usize, 0), mailbox.pending(0));
    const own = mailbox.info(0);
    try std.testing.expectEqual(@as(u64, 3), own.sent);
    try std.testing.expectEqual(@as(u64, 3), own.recv);
}

test "syscall: handle_svc decodes and dispatches slots 5 and 6 via the frame" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0
    scheduler.start();
    const send_bytes = "ping 5\n";
    var recv_buf: [mailbox.message_max]u8 = undefined;
    set_user_regions(
        .{ .base = @intFromPtr(send_bytes.ptr), .len = send_bytes.len },
        .{ .base = @intFromPtr(&recv_buf), .len = recv_buf.len },
    );
    // The marshaling seam (claim 3594): x8 carries the number, x0-x5 the
    // arguments, x0 receives the result — driven through handle_svc like
    // real EL0 SVC entries. These run from the EL1h shell: its zero TCB
    // regions do not trigger claim 0826's re-arm, so the mock windows armed
    // above stay in force (the re-arm only fires for a live user task, and
    // a host-test user task's fixed VAs are not mapped). Self-send to
    // process 0, then slot 6's seam on a non-process task.
    var frame = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_ipc_send));
    try std.testing.expect(exceptions.frame_write(&frame, 0, 0)); // target = self (pid 0)
    try std.testing.expect(exceptions.frame_write(&frame, 1, @intFromPtr(send_bytes.ptr)));
    try std.testing.expect(exceptions.frame_write(&frame, 2, send_bytes.len));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(@as(u64, send_bytes.len), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_ipc_send));
    try std.testing.expectEqual(@as(usize, 1), mailbox.pending(0));
    // Slot 6's seam: the recv handler resolves the CALLING task's process;
    // the EL1h shell is never a process, so the documented EINVAL result is
    // written back through the frame (the self-send round-trip itself is
    // covered at dispatch level above, and the full live path on VZ).
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_ipc_recv));
    try std.testing.expect(exceptions.frame_write(&frame, 0, @intFromPtr(&recv_buf)));
    try std.testing.expect(exceptions.frame_write(&frame, 1, mailbox.message_max));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(error_result(.einval), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_ipc_recv));
    // The failed recv never dropped the message.
    try std.testing.expectEqual(@as(usize, 1), mailbox.pending(0));
}

test "syscall: procs snapshot reflects live registry state and marshals fixed rows" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    var buf: [process.max_processes * process.snapshot_row_bytes]u8 = undefined;
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&buf), .len = buf.len },
    );
    // The boot payload is process 0, RUNNING, named "user-el0".
    try std.testing.expectEqual(@as(u64, 1), dispatch(sys_procs, .{ @intFromPtr(&buf), buf.len, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buf[0..8], .little)); // pid 0
    try std.testing.expectEqual(@as(u64, @intFromEnum(process.State.running)), std.mem.readInt(u64, buf[8..16], .little));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buf[16..24], .little)); // no status while running
    try std.testing.expectEqualStrings("user-el0", buf[24 .. 24 + 8]);
    // The name field is NUL-padded to the full 16-byte slot.
    for (buf[24 + 8 .. 40]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    // Exit the payload: process 0 becomes exited with the status kept.
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expectEqual(@as(u64, 1), dispatch(sys_procs, .{ @intFromPtr(&buf), buf.len, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, @intFromEnum(process.State.exited)), std.mem.readInt(u64, buf[8..16], .little));
    try std.testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, buf[16..24], .little)); // the snapshotted status
    // A created (loaded, not yet bound) process joins the snapshot: two
    // rows, in id order, with the free rows skipped.
    _ = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    try std.testing.expectEqual(@as(u64, 2), dispatch(sys_procs, .{ @intFromPtr(&buf), buf.len, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buf[0..8], .little));
    try std.testing.expectEqualStrings("user-el0", buf[24 .. 24 + 8]);
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, buf[40..48], .little)); // row 2's pid
    try std.testing.expectEqual(@as(u64, @intFromEnum(process.State.created)), std.mem.readInt(u64, buf[48..56], .little));
    try std.testing.expectEqualStrings("PEER.BIN", buf[64 .. 64 + 8]);
}

test "syscall: procs truncates to whole rows, clamps max, and EFAULTs on a bad buf" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // process 0
    scheduler.start();
    var frame = fresh_frame();
    var buf: [process.max_processes * process.snapshot_row_bytes]u8 = undefined;
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&buf), .len = buf.len },
    );
    // max == 0 copies nothing (0 rows, even with a wild address).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_procs, .{ uaccess.diagnostic_unmapped, 0, 0, 0, 0, 0 }, &frame));
    // max below one whole row truncates to 0 rows (a partial row is never
    // copied — the documented truncation result).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_procs, .{ @intFromPtr(&buf), process.snapshot_row_bytes - 1, 0, 0, 0, 0 }, &frame));
    // max of exactly one row copies one row.
    try std.testing.expectEqual(@as(u64, 1), dispatch(sys_procs, .{ @intFromPtr(&buf), process.snapshot_row_bytes, 0, 0, 0, 0 }, &frame));
    // max larger than the full snapshot clamps to it.
    try std.testing.expectEqual(@as(u64, 1), dispatch(sys_procs, .{ @intFromPtr(&buf), 1_000_000, 0, 0, 0, 0 }, &frame));
    // A bad user pointer is EFAULT (the claim-6120 contract), never a
    // crash and never a partial write.
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_procs, .{ uaccess.diagnostic_unmapped, process.snapshot_row_bytes, 0, 0, 0, 0 }, &frame));
    // A read-only target (the user TEXT aperture) is EFAULT too — the
    // snapshot is a copy_out, so the caller's region must be writable.
    const text = "read-only";
    set_user_regions(
        .{ .base = @intFromPtr(text.ptr), .len = text.len },
        .{ .base = 0, .len = 0 },
    );
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_procs, .{ @intFromPtr(text.ptr), process.snapshot_row_bytes, 0, 0, 0, 0 }, &frame));
}

test "syscall: handle_svc decodes and dispatches slot 7 via the frame" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // process 0
    scheduler.start();
    var frame = fresh_frame();
    var buf: [process.snapshot_row_bytes]u8 = undefined;
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&buf), .len = buf.len },
    );
    // The marshaling seam (claim 3594): x8 carries the number (7), x0 the
    // buf, x1 the max, x0 receives the row count.
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_procs));
    try std.testing.expect(exceptions.frame_write(&frame, 0, @intFromPtr(&buf)));
    try std.testing.expect(exceptions.frame_write(&frame, 1, buf.len));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(@as(u64, 1), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_procs));
    try std.testing.expectEqualStrings("user-el0", buf[24 .. 24 + 8]);
}

test "syscall: wait returns an already-exited target's status and refuses invalid/self/EL1h targets exactly" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const target_pid = process.create("TARGET.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const target_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(target_pid, target_task);
    scheduler.start();
    var frame = fresh_frame();
    // An EL1h task (the shell here) is never a process: EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wait, .{ target_pid, 0, 0, 0, 0, 0 }, &frame));
    // Out-of-range and free pids are EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wait, .{ process.max_processes, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wait, .{ 7, 0, 0, 0, 0, 0 }, &frame));
    // Drive to the boot payload (process 0, task 2): it may not wait on
    // itself (the deadlock the kernel refuses).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wait, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!scheduler.is_blocked(2));
    // Drive to the target and exit it with status 43.
    try std.testing.expect(scheduler.yield_current()); // user -> target
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_exit, .{ 43, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(scheduler.is_terminated(3));
    // Drive back to the caller: its wait on the now-exited target returns
    // the stored status IMMEDIATELY (no block — the already-exited path).
    try std.testing.expect(scheduler.yield_current()); // idle
    try std.testing.expect(scheduler.yield_current()); // shell
    try std.testing.expect(scheduler.yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 43), dispatch(sys_wait, .{ target_pid, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!scheduler.is_blocked(2));
    // The kernel's exit record agrees (process-level, survives the reap).
    try std.testing.expectEqual(process.State.exited, process.info(target_pid).?.state);
    try std.testing.expectEqual(@as(u64, 43), process.info(target_pid).?.exit_status);
}

test "syscall: wait blocks the caller and the target's exit wakes it with the status in its saved frame" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const target_pid = process.create("TARGET.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const target_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(target_pid, target_task);
    scheduler.start();
    // Drive to the caller (process 0, task 2).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    var frame = fresh_frame();
    // Stand in for the caller's SVC frame (the yield-test seam): the
    // adapter saves it, blocks the caller, and stages the target's task.
    var caller = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&caller, 8, sys_wait));
    try std.testing.expect(exceptions.frame_write(&caller, 0, target_pid));
    exceptions.resume_frame = @intFromPtr(&caller);
    try std.testing.expect(handle_svc(&caller, svc_immediate));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_wait));
    try std.testing.expect(scheduler.is_blocked(2));
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    // The target (task 3) exits with status 43: the exit path wakes the
    // waiter and patches the status into its SAVED frame's x0 — the value
    // the caller's sys_wait return will carry when the ring resumes it.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_exit, .{ 43, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!scheduler.is_blocked(2));
    try std.testing.expectEqual(@as(u64, 43), exceptions.frame_read(&caller, 0));
    try std.testing.expectEqual(process.State.exited, process.info(target_pid).?.state);
    try std.testing.expectEqual(@as(u64, 43), process.info(target_pid).?.exit_status);
    // The ring can reach the woken caller again (3 is a zombie, skipped).
    try std.testing.expect(scheduler.yield_current()); // idle
    try std.testing.expect(scheduler.yield_current()); // shell
    try std.testing.expect(scheduler.yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    // The process-level exit report carries the status (TARGET.BIN, 43).
    const r = process.take_exit_report().?;
    try std.testing.expectEqualStrings("TARGET.BIN", r.name);
    try std.testing.expectEqual(@as(u64, 43), r.status);
}

test "syscall: handle_svc decodes and dispatches slot 8 via the frame" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const target_pid = process.create("TARGET.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const target_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(target_pid, target_task);
    scheduler.start();
    // The marshaling seam (claim 3594): x8 carries the number (8), x0 the
    // target pid, x0 receives the status. Run from the EL1h shell: its
    // zero TCB regions mean the wait is refused exactly (EINVAL — the
    // shell is never a process), written back through the frame.
    var frame = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_wait));
    try std.testing.expect(exceptions.frame_write(&frame, 0, target_pid));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(error_result(.einval), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_wait));
}

test "syscall: udp listen — ok, duplicate, full, and port-zero refusal" {
    init(test_writer);
    virtio_net.udp.reset();
    defer virtio_net.udp.reset();
    var frame = fresh_frame();
    // Port 0 is never bindable (and > 65535 is refused): EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_listen, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_listen, .{ 0x10000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_udp_listen, .{ 7000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(virtio_net.udp.is_listening(7000));
    // Duplicate: EINVAL (the N5 layer's honest bool, mapped).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_listen, .{ 7000, 0, 0, 0, 0, 0 }, &frame));
    // Fill the 4-slot table: the fifth bind is EINVAL.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_udp_listen, .{ 7001, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_udp_listen, .{ 7002, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_udp_listen, .{ 7003, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_listen, .{ 7004, 0, 0, 0, 0, 0 }, &frame));
}

test "syscall: udp send/recv — loopback round trip through the handlers" {
    init(test_writer);
    virtio_net.udp.reset();
    defer virtio_net.udp.reset();
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    defer virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    virtio_net.net_ready = false; // the loopback path must NOT need a device
    const payload = "ping";
    var recv_buf: [udp.datagram_max]u8 = undefined;
    set_user_regions(
        .{ .base = @intFromPtr(payload.ptr), .len = payload.len },
        .{ .base = @intFromPtr(&recv_buf), .len = recv_buf.len },
    );
    var frame = fresh_frame();
    // Bind 7000 through the seam, then loopback-send to OUR OWN IP
    // (10.0.0.1 = 0x0a000001 in network byte order) with the payload.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_udp_listen, .{ 7000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, payload.len), dispatch(sys_udp_send, .{ 0x0a000001, 7000, @intFromPtr(payload.ptr), payload.len, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.sent);
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.loopbacked);
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.received);
    // Recv the loopbacked datagram: the full 12-byte shape (src 7000,
    // dst 7000, len 12, checksum, payload) — the caller parses the header.
    try std.testing.expectEqual(@as(u64, 12), dispatch(sys_udp_recv, .{ 7000, @intFromPtr(&recv_buf), udp.datagram_max, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u16, 7000), (@as(u16, recv_buf[0]) << 8) | recv_buf[1]);
    try std.testing.expectEqual(@as(u16, 7000), (@as(u16, recv_buf[2]) << 8) | recv_buf[3]);
    try std.testing.expectEqual(@as(u16, 12), (@as(u16, recv_buf[4]) << 8) | recv_buf[5]);
    try std.testing.expectEqualSlices(u8, payload, recv_buf[8..12]);
    // The ring is now empty: recv returns 0 (not EINVAL — the port IS bound).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_udp_recv, .{ 7000, @intFromPtr(&recv_buf), udp.datagram_max, 0, 0, 0 }, &frame));
    // Recv on an UNBOUND port: EINVAL (distinct from the empty result).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_recv, .{ 9998, @intFromPtr(&recv_buf), udp.datagram_max, 0, 0, 0 }, &frame));
    // A bad recv buffer: EFAULT and the datagram stays QUEUED (peek ->
    // copy_out -> pop).
    try std.testing.expectEqual(@as(u64, 4), dispatch(sys_udp_send, .{ 0x0a000001, 7000, @intFromPtr(payload.ptr), payload.len, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_udp_recv, .{ 7000, uaccess.diagnostic_unmapped, udp.datagram_max, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 12), dispatch(sys_udp_recv, .{ 7000, @intFromPtr(&recv_buf), udp.datagram_max, 0, 0, 0 }, &frame));
    try std.testing.expectEqualSlices(u8, payload, recv_buf[8..12]);
}

test "syscall: udp send — EINVAL mapping, EFAULT, and the honest truncation" {
    init(test_writer);
    virtio_net.udp.reset();
    defer virtio_net.udp.reset();
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    defer virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
    defer virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
    var big: [100]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast(i & 0xff);
    set_user_regions(
        .{ .base = @intFromPtr(&big), .len = big.len },
        .{ .base = 0, .len = 0 },
    );
    var frame = fresh_frame();
    // Port 0 is refused before anything is copied.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_send, .{ 0x0a000001, 0, @intFromPtr(&big), 4, 0, 0 }, &frame));
    // A bad payload pointer: EFAULT (the uaccess contract).
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_udp_send, .{ 0x0a000001, 7000, uaccess.diagnostic_unmapped, 4, 0, 0 }, &frame));
    // No static IP (0.0.0.0): the send is refused honestly (not_ready).
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_send, .{ 0x0a000001, 7000, @intFromPtr(&big), 4, 0, 0 }, &frame));
    // Transport down, IP set: a PEER send is not_ready -> EINVAL.
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    virtio_net.net_ready = false;
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_send, .{ 0x0a000002, 9999, @intFromPtr(&big), 4, 0, 0 }, &frame));
    // Transport up, peer NOT in the ARP table: .no_peer -> EINVAL (the
    // seam does not resolve ARP — `net arp <ip>` first, then retry).
    virtio_net.net_ready = true;
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_udp_send, .{ 0x0a000002, 9999, @intFromPtr(&big), 4, 0, 0 }, &frame));
    virtio_net.net_ready = false;
    // len > 64 truncates honestly at payload_max (the ipc send shape) and
    // the send returns the WRITTEN length: 64. The loopbacked datagram is
    // 72 bytes with the first 64 payload bytes.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_udp_listen, .{ 7000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, udp.payload_max), dispatch(sys_udp_send, .{ 0x0a000001, 7000, @intFromPtr(&big), big.len, 0, 0 }, &frame));
    var recv_buf: [udp.datagram_max]u8 = undefined;
    set_user_regions(
        .{ .base = @intFromPtr(&big), .len = big.len },
        .{ .base = @intFromPtr(&recv_buf), .len = recv_buf.len },
    );
    try std.testing.expectEqual(@as(u64, udp.datagram_max), dispatch(sys_udp_recv, .{ 7000, @intFromPtr(&recv_buf), 100, 0, 0, 0 }, &frame));
    try std.testing.expectEqualSlices(u8, big[0..udp.payload_max], recv_buf[8..72]);
}

test "syscall: handle_svc decodes and dispatches slots 9/10/11 via the frame" {
    init(test_writer);
    virtio_net.udp.reset();
    defer virtio_net.udp.reset();
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    defer virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    const payload = "ping";
    var recv_buf: [udp.datagram_max]u8 = undefined;
    set_user_regions(
        .{ .base = @intFromPtr(payload.ptr), .len = payload.len },
        .{ .base = @intFromPtr(&recv_buf), .len = recv_buf.len },
    );
    // The marshaling seam (claim 3594): x8 carries the number, x0-x5 the
    // arguments, x0 receives the result — driven through handle_svc like
    // real EL0 SVC entries.
    var frame = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_udp_listen));
    try std.testing.expect(exceptions.frame_write(&frame, 0, 7000));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_udp_listen));
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_udp_send));
    try std.testing.expect(exceptions.frame_write(&frame, 0, 0x0a000001));
    try std.testing.expect(exceptions.frame_write(&frame, 1, 7000));
    try std.testing.expect(exceptions.frame_write(&frame, 2, @intFromPtr(payload.ptr)));
    try std.testing.expect(exceptions.frame_write(&frame, 3, payload.len));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(@as(u64, payload.len), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_udp_send));
    try std.testing.expect(exceptions.frame_write(&frame, 8, sys_udp_recv));
    try std.testing.expect(exceptions.frame_write(&frame, 0, 7000));
    try std.testing.expect(exceptions.frame_write(&frame, 1, @intFromPtr(&recv_buf)));
    try std.testing.expect(exceptions.frame_write(&frame, 2, udp.datagram_max));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(@as(u64, 12), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_udp_recv));
    try std.testing.expectEqualSlices(u8, payload, recv_buf[8..12]);
}

test "syscall: win open/fill/present/close round-trips with per-process ownership + auto-close" {
    init(test_writer);
    driving_award.arm();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const win_pid = process.create("WIN.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const win_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(win_pid, win_task);
    scheduler.start();
    var frame = fresh_frame();
    // Drive to the exec'd WIN.BIN (task 3).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (boot payload, 2)
    try std.testing.expect(scheduler.yield_current()); // user -> WIN.BIN (3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    // Open window 2 as WIN.BIN: the caller's pid is recorded as the owner.
    try std.testing.expectEqual(@as(u64, 2), dispatch(sys_win_open, .{ 64, 64, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_win_open));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(2));
    // Fill + present the OWN window: both return 0.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_fill, .{ 2, 8, 8, 48, 48, 0xff0000 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_present, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_win_fill));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_win_present));
    // Move (slot 16) + raise (slot 17) the OWN window: both return 0.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_move, .{ 2, 600, 100, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_raise, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_win_move));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_win_raise));
    // Close the OWN window: slot 15 releases it (0 on success).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_close, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_win_close));
    try std.testing.expectEqual(@as(usize, 4), driving_award.count());
    // A second close of the freed id is EINVAL (no such user window).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_close, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    // Re-open (id 2 reused), then open the remaining slots (ids 3..5): the
    // full-registry ENOSPC split now holds at the 4-slot bound, and the
    // caller owns all four.
    try std.testing.expectEqual(@as(u64, 2), dispatch(sys_win_open, .{ 64, 64, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 3), dispatch(sys_win_open, .{ 320, 64, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 4), dispatch(sys_win_open, .{ 576, 64, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 5), dispatch(sys_win_open, .{ 64, 288, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enospc), dispatch(sys_win_open, .{ 0, 0, 10, 10, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(2));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(3));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(4));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(5));
    // Error mapping in the OWNING context: invalid geometry, out-of-bounds
    // rects, unknown ids, and the fixed windows are all EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_open, .{ 0, 0, 0, 10, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_open, .{ 0, 0, 10, 385, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_fill, .{ 99, 0, 0, 10, 10, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_fill, .{ 2, 255, 191, 2, 2, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_present, .{ 99, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_present, .{ 1, 0, 0, 0, 0, 0 }, &frame)); // the clock is not a user window
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_move, .{ 99, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_raise, .{ 99, 0, 0, 0, 0, 0 }, &frame));
    // Drive to the boot payload (process 0, task 2): it does NOT own
    // WIN.BIN's windows, so fill/present/close are EINVAL.
    try std.testing.expect(scheduler.yield_current()); // WIN.BIN -> idle
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_fill, .{ 2, 0, 0, 10, 10, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_present, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_close, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_move, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_raise, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    // AUTO-CLOSE on exit: drive back to WIN.BIN (task 3) and exit it —
    // all four of its windows (ids 2..5) are released with NO sys_win_close
    // call.
    try std.testing.expect(scheduler.yield_current()); // user -> WIN.BIN (3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_exit, .{ 87, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.user_owner(2) == null);
    try std.testing.expect(driving_award.user_owner(3) == null);
    try std.testing.expect(driving_award.user_owner(4) == null);
    try std.testing.expect(driving_award.user_owner(5) == null);
    try std.testing.expectEqual(@as(usize, 4), driving_award.count());
    // The close counter only ever saw the THREE explicit dispatches (one
    // success + the two refusals above): the exit-path teardown is NOT a
    // syscall (it rides close_owner, never handle_win_close).
    try std.testing.expectEqual(@as(u64, 3), call_count(sys_win_close));
}

test "syscall: win get copies the clamped rect back through uaccess and enforces ownership" {
    init(test_writer);
    driving_award.arm();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const win_pid = process.create("WIN.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const win_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(win_pid, win_task);
    scheduler.start();
    var frame = fresh_frame();
    var rect_buf: [win_rect_bytes]u8 = undefined;
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&rect_buf), .len = rect_buf.len },
    );
    // Drive to WIN.BIN (task 3).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expect(scheduler.yield_current()); // user -> WIN.BIN (3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 2), dispatch(sys_win_open, .{ 64, 64, 256, 192, 0, 0 }, &frame));
    // Read back the open rect (four u32 LE words).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_get, .{ 2, @intFromPtr(&rect_buf), 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, rect_buf[0..4], .little));
    try std.testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, rect_buf[4..8], .little));
    try std.testing.expectEqual(@as(u32, 256), std.mem.readInt(u32, rect_buf[8..12], .little));
    try std.testing.expectEqual(@as(u32, 192), std.mem.readInt(u32, rect_buf[12..16], .little));
    // After a CLAMPED move the read-back reports the CLAMPED position (the
    // gate constants: 1280x720 scanout, 256-wide window -> 1024,528).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_move, .{ 2, 1200, 700, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_get, .{ 2, @intFromPtr(&rect_buf), 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u32, 1024), std.mem.readInt(u32, rect_buf[0..4], .little));
    try std.testing.expectEqual(@as(u32, 528), std.mem.readInt(u32, rect_buf[4..8], .little));
    try std.testing.expectEqual(@as(u32, 256), std.mem.readInt(u32, rect_buf[8..12], .little));
    try std.testing.expectEqual(@as(u32, 192), std.mem.readInt(u32, rect_buf[12..16], .little));
    // A bad buf is EFAULT (the claim-6120 contract), never a crash.
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_win_get, .{ 2, uaccess.diagnostic_unmapped, 0, 0, 0, 0 }, &frame));
    // Unknown + fixed ids are EINVAL (never a user window).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_get, .{ 99, @intFromPtr(&rect_buf), 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_get, .{ 1, @intFromPtr(&rect_buf), 0, 0, 0, 0 }, &frame));
    // Drive to the boot payload (process 0, task 2): it does NOT own
    // WIN.BIN's window, so win_get is EINVAL.
    try std.testing.expect(scheduler.yield_current()); // WIN.BIN -> idle
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_get, .{ 2, @intFromPtr(&rect_buf), 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 6), call_count(sys_win_get));
}

test "syscall: win query copies the full window state back and enforces ownership" {
    init(test_writer);
    driving_award.arm();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const win_pid = process.create("WIN.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const win_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(win_pid, win_task);
    scheduler.start();
    var frame = fresh_frame();
    var qbuf: [win_query_bytes]u8 = undefined;
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&qbuf), .len = qbuf.len },
    );
    // Drive to WIN.BIN (task 3).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expect(scheduler.yield_current()); // user -> WIN.BIN (3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 2), dispatch(sys_win_open, .{ 64, 64, 256, 192, 0, 0 }, &frame));
    // The full state right after open: top of the z-order (index 4 with dock, after tray migration 4 base +1), focused,
    // visible, dirty (the compositor never runs in a host test).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_query, .{ 2, @intFromPtr(&qbuf), 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, qbuf[0..4], .little));
    try std.testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, qbuf[4..8], .little));
    try std.testing.expectEqual(@as(u32, 256), std.mem.readInt(u32, qbuf[8..12], .little));
    try std.testing.expectEqual(@as(u32, 192), std.mem.readInt(u32, qbuf[12..16], .little));
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, qbuf[16..20], .little)); // z
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, qbuf[20..24], .little)); // focused
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, qbuf[24..28], .little)); // visible
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, qbuf[28..32], .little)); // dirty
    // A bad buf is EFAULT, never a crash.
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_win_query, .{ 2, uaccess.diagnostic_unmapped, 0, 0, 0, 0 }, &frame));
    // Unknown + fixed ids are EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_query, .{ 99, @intFromPtr(&qbuf), 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_query, .{ 1, @intFromPtr(&qbuf), 0, 0, 0, 0 }, &frame));
    // Drive to the boot payload (process 0, task 2): it does NOT own
    // WIN.BIN's window, so win_query is EINVAL.
    try std.testing.expect(scheduler.yield_current()); // WIN.BIN -> idle
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_query, .{ 2, @intFromPtr(&qbuf), 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 5), call_count(sys_win_query));
}

test "syscall: win set_visible hides/shows the caller's window and enforces ownership" {
    init(test_writer);
    driving_award.arm();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const win_pid = process.create("WIN.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const win_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(win_pid, win_task);
    scheduler.start();
    var frame = fresh_frame();
    // Drive to WIN.BIN (task 3).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expect(scheduler.yield_current()); // user -> WIN.BIN (3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 2), dispatch(sys_win_open, .{ 64, 64, 256, 192, 0, 0 }, &frame));
    // Hide the OWN window: 0 on success, visible flips to 0.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_set_visible, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u32, 0), driving_award.user_query(2).?.visible);
    // Show it again: 0 on success, visible flips back to 1.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_set_visible, .{ 2, 1, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u32, 1), driving_award.user_query(2).?.visible);
    // A visible flag outside 0/1 is EINVAL (no ambiguity).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_set_visible, .{ 2, 2, 0, 0, 0, 0 }, &frame));
    // Unknown + fixed ids are EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_set_visible, .{ 99, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_set_visible, .{ 1, 0, 0, 0, 0, 0 }, &frame));
    // Drive to the boot payload (process 0, task 2): it does NOT own
    // WIN.BIN's window, so set_visible is EINVAL.
    try std.testing.expect(scheduler.yield_current()); // WIN.BIN -> idle
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_set_visible, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 6), call_count(sys_win_set_visible));
}

test "syscall: counters are monotonic and report is deterministic" {
    userspace.init();
    init(test_writer);
    var frame = fresh_frame();
    _ = dispatch(sys_ping, .{ 9, 0, 0, 0, 0, 0 }, &frame);
    _ = dispatch(sys_ping, .{ 10, 0, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 2), call_count(sys_ping));
    var mock = console.MockConsole(4096){};
    var con = mock.console();
    report(&con);
    try std.testing.expectEqualStrings(
        "syscalls: slots=64 implemented=62\n" ++
            "  0 sys_ping calls=2\n" ++
            "  1 sys_write calls=0\n" ++
            "  2 sys_yield calls=0\n" ++
            "  3 sys_exit calls=0\n" ++
            "  4 sys_sleep calls=0\n" ++
            "  5 sys_ipc_send calls=0\n" ++
            "  6 sys_ipc_recv calls=0\n" ++
            "  7 sys_procs calls=0\n" ++
            "  8 sys_wait calls=0\n" ++
            "  9 sys_udp_listen calls=0\n" ++
            "  10 sys_udp_send calls=0\n" ++
            "  11 sys_udp_recv calls=0\n" ++
            "  12 sys_win_open calls=0\n" ++
            "  13 sys_win_fill calls=0\n" ++
            "  14 sys_win_present calls=0\n" ++
            "  15 sys_win_close calls=0\n" ++
            "  16 sys_win_move calls=0\n" ++
            "  17 sys_win_raise calls=0\n" ++
            "  18 sys_win_get calls=0\n" ++
            "  19 sys_win_query calls=0\n" ++
            "  20 sys_win_set_visible calls=0\n" ++
            "  21 sys_poll_event calls=0\n" ++
            "  22 sys_wait_event calls=0\n" ++
            "  23 sys_file_open calls=0\n" ++
            "  24 sys_file_read calls=0\n" ++
            "  25 sys_file_write calls=0\n" ++
            "  26 sys_file_close calls=0\n" ++
            "  27 sys_dir_list calls=0\n" ++
            "  28 sys_exec calls=0\n" ++
            "  29 sys_kill calls=0\n" ++
            "  30 sys_tcp_connect calls=0\n" ++
            "  31 sys_tcp_send calls=0\n" ++
            "  32 sys_tcp_recv calls=0\n" ++
            "  33 sys_tcp_close calls=0\n" ++
            "  34 sys_file_delete calls=0\n" ++
            "  35 sys_file_rename calls=0\n" ++
            "  36 sys_file_truncate calls=0\n" ++
            "  37 sys_file_free calls=0\n" ++
            "  38 sys_clipboard_set calls=0\n" ++
            "  39 sys_clipboard_get calls=0\n" ++
            "  40 sys_timer_set calls=0\n" ++
            "  41 sys_timer_cancel calls=0\n" ++
            "  42 sys_audio_info calls=0\n" ++
            "  43 sys_audio_play calls=0\n" ++
            "  44 sys_audio_volume calls=0\n" ++
            "  45 sys_audio_mute calls=0\n" ++
            "  46 sys_win_fill_batch calls=0\n" ++
            "  47 sys_win_resize calls=0\n" ++
            "  48 sys_drag_start calls=0\n" ++
            "  49 sys_win_raise_front calls=0\n" ++
            "  50 sys_win_lower_back calls=0\n" ++
            "  51 sys_notify calls=0\n" ++
            "  52 sys_win_move_to_workspace calls=0\n" ++
            "  53 sys_win_set_unsaved calls=0\n" ++
            "  54 sys_setrlimit calls=0\n" ++
            "  55 sys_drag_read calls=0\n" ++
            "  56 sys_pipe_read calls=0\n" ++
            "  57 sys_pipe_write calls=0\n" ++
            "  58 sys_font_size calls=0\n" ++
            "  59 sys_ping_send calls=0\n" ++
            "  60 sys_ping_poll calls=0\n" ++
            "  61 sys_win_set_title calls=0\n",
        mock.contents(),
    );
}

test "syscall: file storage slots 23..27 dispatch and fault safety" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    file_table.init();
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process), calls return EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_open, .{ 0x1000, 10, file_table.MODE_READ, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_read, .{ 0, 0x1000, 10, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_write, .{ 0, 0x1000, 10, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_close, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_dir_list, .{ 0x1000, 0, 0x2000, 10, 0, 0 }, &frame));

    // Yield to user task (task 2, pid 0)
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    var test_buf: [64]u8 = undefined;
    const test_buf_addr = @intFromPtr(&test_buf);
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = test_buf_addr, .len = test_buf.len },
    );

    // Bad user pointer on path / buffer -> EFAULT
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_file_open, .{ uaccess.diagnostic_unmapped, 8, file_table.MODE_READ, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_dir_list, .{ uaccess.diagnostic_unmapped, 5, test_buf_addr, 1, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_file_write, .{ 0, uaccess.diagnostic_unmapped, 10, 0, 0, 0 }, &frame));

    // Bad / unallocated file descriptors -> EBADF
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_read, .{ 0, test_buf_addr, 10, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_read, .{ 99, test_buf_addr, 10, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_write, .{ 0, test_buf_addr, 10, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_write, .{ 99, test_buf_addr, 10, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_close, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_close, .{ 99, 0, 0, 0, 0, 0 }, &frame));
}

test "syscall: mutating file slots 34..37 dispatch and fault safety (claim 5801)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    file_table.init();
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process), calls return EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_delete, .{ 0x1000, 8, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_rename, .{ 0x1000, 4, 0x1000, 4, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_truncate, .{ 0, 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_free, .{ 0, 0, 0, 0, 0, 0 }, &frame));

    // Yield to user task (task 2, pid 0)
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    var test_buf: [64]u8 = undefined;
    const test_buf_addr = @intFromPtr(&test_buf);
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = test_buf_addr, .len = test_buf.len },
    );

    // Bad user pointer -> EFAULT (delete + rename path copy-in)
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_file_delete, .{ uaccess.diagnostic_unmapped, 8, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_file_rename, .{ uaccess.diagnostic_unmapped, 4, test_buf_addr, 4, 0, 0 }, &frame));
    // Over-long path -> EINVAL (checked before uaccess)
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_delete, .{ 0x1000, file_table.max_path_len + 1, 0, 0, 0, 0 }, &frame));
    // truncate on an unallocated fd -> EBADF
    try std.testing.expectEqual(error_result(.ebadf), dispatch(sys_file_truncate, .{ 0, 4, 0, 0, 0, 0 }, &frame));
    // free with a bad volume -> EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_file_free, .{ 2, 0, 0, 0, 0, 0 }, &frame));
}

test "syscall: clipboard slots 38..39 dispatch and fault safety (claim 0169)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process), calls return EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_clipboard_set, .{ 0x1000, 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_clipboard_get, .{ 0x1000, 4, 0, 0, 0, 0 }, &frame));

    // Yield to the user task (task 2, pid 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    var test_buf: [64]u8 = undefined;
    const test_buf_addr = @intFromPtr(&test_buf);
    // The same region serves as the copy-in source (readable) and the
    // copy-out destination (writable).
    set_user_regions(
        .{ .base = test_buf_addr, .len = test_buf.len },
        .{ .base = test_buf_addr, .len = test_buf.len },
    );

    // Bad pointer on a non-empty set -> EFAULT (the copy-in path validates
    // before touching memory).
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_clipboard_set, .{ uaccess.diagnostic_unmapped, 4, 0, 0, 0, 0 }, &frame));

    // An EMPTY clipboard get returns 0 without validating the pointer — the
    // same empty -> 0 discipline as udp/ipc recv (no copy runs).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_clipboard_get, .{ uaccess.diagnostic_unmapped, 4, 0, 0, 0, 0 }, &frame));

    // Set copies bytes into the shared buffer and returns the stored length.
    @memcpy(test_buf[0..5], "hello");
    try std.testing.expectEqual(@as(u64, 5), dispatch(sys_clipboard_set, .{ test_buf_addr, 5, 0, 0, 0, 0 }, &frame));

    // A NON-empty get validates the pointer -> EFAULT.
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_clipboard_get, .{ uaccess.diagnostic_unmapped, 4, 0, 0, 0, 0 }, &frame));

    // Get copies them back out (non-destructive) and returns the length.
    @memset(&test_buf, 0);
    try std.testing.expectEqual(@as(u64, 5), dispatch(sys_clipboard_get, .{ test_buf_addr, 64, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("hello", test_buf[0..5]);

    // A second get returns the SAME contents (the clipboard is not consumed).
    @memset(&test_buf, 0);
    try std.testing.expectEqual(@as(u64, 5), dispatch(sys_clipboard_get, .{ test_buf_addr, 64, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqualStrings("hello", test_buf[0..5]);

    // max == 0 -> 0 without touching the buffer.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_clipboard_get, .{ test_buf_addr, 0, 0, 0, 0, 0 }, &frame));

    // An empty set clears the shared buffer.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_clipboard_set, .{ test_buf_addr, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_clipboard_get, .{ test_buf_addr, 64, 0, 0, 0, 0 }, &frame));
}

test "syscall: app timer slots 40..41 dispatch, fire through the tick, and clamp (claim 7323)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process), both calls return EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_timer_set, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_timer_cancel, .{ 0, 0, 0, 0, 0, 0 }, &frame));

    // Yield to the user task (task 2, pid 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    // Cancel with nothing armed -> 0.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_timer_cancel, .{ 0, 0, 0, 0, 0, 0 }, &frame));

    // Arm a 2-tick timer -> 0, and the module sees it armed with 2 left.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_timer_set, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(app_timers.armed_pending(0));
    try std.testing.expectEqual(@as(u64, 2), app_timers.info(0).remaining);

    // Re-arm replaces the pending countdown (back to 3).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_timer_set, .{ 3, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 3), app_timers.info(0).remaining);
    try std.testing.expectEqual(@as(u64, 2), app_timers.info(0).sets);

    // The scheduler tick drives the countdown; the timer fires exactly one
    // TIMER event into pid 0's queue after three ticks.
    scheduler.on_tick();
    scheduler.on_tick();
    try std.testing.expectEqual(@as(u64, 1), app_timers.info(0).remaining);
    try std.testing.expectEqual(@as(usize, 0), events.pending(0));
    scheduler.on_tick();
    try std.testing.expect(!app_timers.armed_pending(0));
    try std.testing.expectEqual(@as(u64, 1), app_timers.info(0).fired);
    try std.testing.expectEqual(@as(usize, 1), events.pending(0));
    const ev = events.peek(0).?;
    try std.testing.expectEqual(events.TIMER, ev.kind);
    _ = events.drop(0);

    // Zero clamps to one tick (the sys_sleep minimum); over-long truncates.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_timer_set, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), app_timers.info(0).remaining);
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_timer_set, .{ app_timers.max_delay_ticks + 1000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(app_timers.max_delay_ticks, app_timers.info(0).remaining);

    // Cancel a pending timer -> 1, and it never fires.
    try std.testing.expectEqual(@as(u64, 1), dispatch(sys_timer_cancel, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!app_timers.armed_pending(0));
    try std.testing.expectEqual(@as(u64, 1), app_timers.info(0).cancels);
    scheduler.on_tick();
    try std.testing.expectEqual(@as(usize, 0), events.pending(0));
    try std.testing.expectEqual(@as(u64, 1), app_timers.info(0).fired);
}

test "syscall: slot 28 sys_exec marshals the path and maps loader errors" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    esp.reset(); // no disk mounted — exec_file reports no_disk honestly
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process), sys_exec returns EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exec, .{ 0x1000, 8, 0, 0, 0, 0 }, &frame));
    // Empty path and an over-long path are EINVAL (checked before uaccess)
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exec, .{ 0x1000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exec, .{ 0x1000, esp.name_max + 1, 0, 0, 0, 0 }, &frame));

    // Yield to the user task (task 2, pid 0)
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(process.find_by_task(2) != null);

    var path_buf: [16]u8 = undefined;
    const path_addr = @intFromPtr(&path_buf);
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = path_addr, .len = path_buf.len },
    );

    // Bad path pointer -> EFAULT
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_exec, .{ uaccess.diagnostic_unmapped, 8, 0, 0, 0, 0 }, &frame));
    // No disk -> EINVAL (exec_file .no_disk — the loader cannot mount the ESP)
    @memcpy(path_buf[0..8], "CALC.BIN");
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exec, .{ path_addr, 8, 0, 0, 0, 0 }, &frame));
    // The slot is counted like every other implemented row
    try std.testing.expectEqual(@as(u64, 5), call_count(sys_exec));
}

test "syscall: slot 29 sys_kill arms a process target and maps refusals" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const target_pid = process.create("TARGET.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const target_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(target_pid, target_task);
    scheduler.start();
    var frame = fresh_frame();

    // In task 0 (shell, not a process), sys_kill returns EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_kill, .{ target_pid, 0, 0, 0, 0, 0 }, &frame));
    // Out-of-range and free pids are EINVAL (the sys_wait precedent).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_kill, .{ process.max_processes, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_kill, .{ 7, 0, 0, 0, 0, 0 }, &frame));

    // Drive to the caller (task 2, pid 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    // Arm the target: returns 0.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_kill, .{ target_pid, 0, 0, 0, 0, 0 }, &frame));

    // The kill lands at the target's NEXT selection: the ring walks to the
    // target (task 3), the kill branch converts the selection into the
    // existing exit path with the reserved status 137, and the ring moves
    // on — the target never resumes.
    try std.testing.expect(scheduler.yield_current()); // user -> target -> killed -> idle
    try std.testing.expectEqual(@as(usize, scheduler.idle_id), scheduler.current_id());
    try std.testing.expect(scheduler.is_terminated(target_task));
    try std.testing.expectEqual(@as(?u64, scheduler.reserved_kill_status), scheduler.terminated_status(target_task));
    const pinfo = process.info(target_pid).?;
    try std.testing.expectEqual(process.State.exited, pinfo.state);
    try std.testing.expectEqual(@as(u64, scheduler.reserved_kill_status), pinfo.exit_status);

    // The exited target is refused on the next call (back in a process
    // context — the ring returns to the caller).
    try std.testing.expect(scheduler.yield_current()); // idle
    try std.testing.expect(scheduler.yield_current()); // shell
    try std.testing.expect(scheduler.yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_kill, .{ target_pid, 0, 0, 0, 0, 0 }, &frame));
    // The slot is counted like every other implemented row.
    try std.testing.expectEqual(@as(u64, 5), call_count(sys_kill));
}

test "syscall: sys_poll_event and sys_wait_event handle events, blocking, and uaccess fault safety" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    events.init();
    events.on_event_pushed = scheduler.wake_event_waiters;
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process), syscalls return EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_poll_event, .{ 0x1000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wait_event, .{ 0x1000, 0, 0, 0, 0, 0 }, &frame));

    // Yield to user task (task 2, pid 0)
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    const pid = process.find_by_task(2).?;
    try std.testing.expectEqual(@as(usize, 0), pid);

    var ev_buf: [16]u8 align(16) = undefined;
    const buf_addr = @intFromPtr(&ev_buf);
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = buf_addr, .len = ev_buf.len },
    );

    // 1. Poll on empty queue -> returns 0
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_poll_event, .{ buf_addr, 0, 0, 0, 0, 0 }, &frame));

    // 2. Push an event to pid 0
    events.push(0, .{
        .kind = events.KEY_DOWN,
        .flags = events.MOD_SHIFT,
        .seq = 0,
        .arg0 = 0x04,
        .arg1 = 'A',
    });

    // 3. Poll with bad buffer address -> EFAULT (event is preserved in queue)
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_poll_event, .{ uaccess.diagnostic_unmapped, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 1), events.pending(0));

    // 4. Poll with valid buffer -> 1 (event copied and dropped)
    try std.testing.expectEqual(@as(u64, 1), dispatch(sys_poll_event, .{ buf_addr, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 0), events.pending(0));
    const got_kind = std.mem.readInt(u16, ev_buf[0..2], .little);
    const got_flags = std.mem.readInt(u16, ev_buf[2..4], .little);
    const got_arg0 = std.mem.readInt(u32, ev_buf[8..12], .little);
    const got_arg1 = std.mem.readInt(u32, ev_buf[12..16], .little);
    try std.testing.expectEqual(events.KEY_DOWN, got_kind);
    try std.testing.expectEqual(events.MOD_SHIFT, got_flags);
    try std.testing.expectEqual(@as(u32, 0x04), got_arg0);
    try std.testing.expectEqual(@as(u32, 'A'), got_arg1);

    // 5. sys_wait_event with queued event -> returns 1 immediately
    events.push(0, .{
        .kind = events.MOUSE_MOVE,
        .flags = 0,
        .seq = 0,
        .arg0 = 120,
        .arg1 = 80,
    });
    try std.testing.expectEqual(@as(u64, 1), dispatch(sys_wait_event, .{ buf_addr, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(usize, 0), events.pending(0));

    // 6. sys_wait_event with empty queue -> blocks task in scheduler!
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wait_event, .{ buf_addr, 0, 0, 0, 0, 0 }, &frame));
    // Task 2 is now blocked waiting for events on pid 0
    // Current task switched to idle/next
    try std.testing.expect(scheduler.current_id() != 2);

    // 7. Pushing an event to pid 0 wakes task 2!
    events.push(0, .{
        .kind = events.WIN_FOCUS,
        .flags = 0,
        .seq = 0,
        .arg0 = 2,
        .arg1 = 0,
    });

    // Task 2 should now be ready
    try std.testing.expectEqual(@as(usize, 1), events.pending(0));
}

test "syscall: wait_event block+wake preserves the event buffer across the svc re-execution (claim 6359)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = boot payload (pid 0)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    var ev_buf: [16]u8 align(16) = undefined;
    const buf_addr = @intFromPtr(&ev_buf);
    // The caller: a registered process whose TCB stack region covers the
    // host test buffer, so the re-executed svc's copy_out is both range-
    // valid and dereferenceable (register_exec_user arms the TCB regions
    // from its stack_va/stack_len arguments).
    const caller_pid = process.create("CALLER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const caller_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, buf_addr, ev_buf.len, &kstack, 0, 0).?;
    _ = process.bind(caller_pid, caller_task);
    scheduler.start();
    events.init();
    events.on_event_pushed = scheduler.wake_event_waiters;
    // Drive to the caller (task 3).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> boot payload
    try std.testing.expect(scheduler.yield_current()); // boot -> caller
    try std.testing.expectEqual(caller_task, scheduler.current_id());

    // Stand in for the caller's SVC frame: x0 = the event buffer address,
    // x8 = sys_wait_event (the svc re-execution contract).
    var caller = fresh_frame();
    try std.testing.expect(exceptions.frame_write(&caller, 8, sys_wait_event));
    try std.testing.expect(exceptions.frame_write(&caller, 0, buf_addr));
    exceptions.resume_frame = @intFromPtr(&caller);

    // 1. Empty queue: handle_svc blocks the caller. The blocking result
    // (0) is written into the SAVED frame's x0, clobbering the buffer
    // address — the pre-fix failure mode: a re-executed svc would copy the
    // event out to address 0 and EFAULT, killing every blocking GUI event
    // loop (observed live: DESKTOP.BIN `desktop: wait err=-3`).
    try std.testing.expect(handle_svc(&caller, svc_immediate));
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(&caller, 0));
    try std.testing.expect(scheduler.is_blocked(caller_task));

    // 2. An event arrives: the push hook wakes the waiter and patches the
    // saved frame's x0 back to the event-buffer address (claim 6359 fix).
    events.push(caller_pid, .{
        .kind = events.KEY_DOWN,
        .flags = 0,
        .seq = 0,
        .arg0 = 0x04,
        .arg1 = 'A',
    });
    try std.testing.expect(!scheduler.is_blocked(caller_task));
    try std.testing.expectEqual(@as(u64, buf_addr), exceptions.frame_read(&caller, 0));

    // 3. The ring resumes the caller: the svc re-executes with x0 restored
    // and the event copies out (the re-executed handler returns 1).
    try std.testing.expect(scheduler.yield_current()); // idle
    try std.testing.expect(scheduler.yield_current()); // shell
    try std.testing.expect(scheduler.yield_current()); // worker
    try std.testing.expect(scheduler.yield_current()); // boot -> caller
    try std.testing.expectEqual(caller_task, scheduler.current_id());
    try std.testing.expect(handle_svc(&caller, svc_immediate));
    try std.testing.expectEqual(@as(u64, 1), exceptions.frame_read(&caller, 0));
    try std.testing.expectEqual(@as(usize, 0), events.pending(caller_pid));
    const got_kind = std.mem.readInt(u16, ev_buf[0..2], .little);
    const got_arg0 = std.mem.readInt(u32, ev_buf[8..12], .little);
    try std.testing.expectEqual(events.KEY_DOWN, got_kind);
    try std.testing.expectEqual(@as(u32, 0x04), got_arg0);
}

test "syscall: tcp connect, send, recv, close slots 30..33 and sys_kill slot 29" {
    userspace.init();
    init(test_writer);
    var frame = fresh_frame();

    // Slot 29: sys_kill on invalid process ID returns EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_kill, .{ 999, 0, 0, 0, 0, 0 }, &frame));

    // Slot 30: sys_tcp_connect with port 0 or >0xffff returns EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tcp_connect, .{ 0x0a000002, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tcp_connect, .{ 0x0a000002, 0x10000, 0, 0, 0, 0 }, &frame));

    // Slot 31: sys_tcp_send when not connected returns EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tcp_send, .{ 0x1000, 5, 0, 0, 0, 0 }, &frame));

    // Slot 32: sys_tcp_recv when not connected returns EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_tcp_recv, .{ 0x1000, 64, 0, 0, 0, 0 }, &frame));

    // Slot 33: sys_tcp_close when idle returns 0
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_tcp_close, .{ 0, 0, 0, 0, 0, 0 }, &frame));
}

test "syscall: TCP connection is process-owned — non-owner send/recv/close/connect refused EACCES (claim 4482)" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    var kstack: [scheduler.task_stack_size]u8 align(16) = undefined;
    const peer_pid = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const peer_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    _ = process.bind(peer_pid, peer_task);
    scheduler.start();

    var test_buf: [64]u8 = undefined;
    const test_buf_addr = @intFromPtr(&test_buf);
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = test_buf_addr, .len = test_buf.len },
    );
    var frame = fresh_frame();

    // Simulate process 0 (task 2) owning an ESTABLISHED connection to
    // 10.0.0.2:9999 (the net bits so the idempotent-connect path is
    // reachable; nothing transmits on the host).
    tcp.reset();
    tcp.state = .established;
    tcp.peer_ip = .{ 10, 0, 0, 2 };
    tcp.peer_port = 9999;
    tcp.owner_pid = 0;
    virtio_net.net_ready = true;
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };

    // Drive the ring to the non-owner (task 3 = process 1).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (task 2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.yield_current()); // user -> peer (task 3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 1), peer_pid);

    // Non-owner: every connection-driving syscall is refused EACCES before
    // any state is touched (the S4 ownership audit fix).
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_tcp_send, .{ test_buf_addr, 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_tcp_recv, .{ test_buf_addr, 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_tcp_close, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    // Idempotent re-connect to the same peer is owner-only.
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_tcp_connect, .{ 0x0a000002, 9999, 0, 0, 0, 0 }, &frame));
    // The refused calls never mutated the connection.
    try std.testing.expectEqual(@as(u64, 0), tcp.owner_pid.?);

    // Drive the ring back to the owner (task 2): the idempotent re-connect
    // succeeds (returns 0, no transmit) — the ownership check passes.
    try std.testing.expect(scheduler.yield_current()); // peer -> idle
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (task 2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_tcp_connect, .{ 0x0a000002, 9999, 0, 0, 0, 0 }, &frame));

    // Restore the honest default (net absent).
    tcp.reset();
    virtio_net.net_ready = false;
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
}

test "syscall: slot 42 sys_audio_info marshals; slot 43 sys_audio_play refuses without a device" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    virtio_snd.snd_ready = false; // honest default — no --sound device in a test
    virtio_snd.ctrl_armed = false;
    virtio_snd.tx_armed = false;
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process), both audio syscalls are
    // refused EINVAL before any state is touched.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_audio_info, .{ 0x1000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_audio_play, .{ 0x1000, 8, 0, 0, 0, 0 }, &frame));

    // Yield to the user task (task 2, pid 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(process.find_by_task(2) != null);

    var info_buf: [32]u8 = @splat(0);
    const info_addr = @intFromPtr(&info_buf);
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = info_addr, .len = info_buf.len },
    );

    // Bad info buffer -> EFAULT.
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_audio_info, .{ uaccess.diagnostic_unmapped, 0, 0, 0, 0, 0 }, &frame));

    // Valid buffer: the info struct is copied out with the honest no-device
    // state (ready=0, format/rate 0xff — never guessed).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_audio_info, .{ info_addr, 0, 0, 0, 0, 0 }, &frame));
    const info: *const virtio_snd.AudioInfo = @ptrCast(@alignCast(&info_buf));
    try std.testing.expectEqual(@as(u32, 0), info.ready);
    try std.testing.expectEqual(@as(u8, 0xff), info.format);
    try std.testing.expectEqual(@as(u8, 0xff), info.rate);
    try std.testing.expectEqual(@as(u32, virtio_snd.audio_max_len), info.max_len);

    // sys_audio_play arg validation before the device check: zero length ->
    // EINVAL, over-long -> ENAMETOOLONG, then the honest no-device ENXIO.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_audio_play, .{ info_addr, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enametoolong), dispatch(sys_audio_play, .{ info_addr, virtio_snd.audio_max_len + 1, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enxio), dispatch(sys_audio_play, .{ info_addr, 8, 0, 0, 0, 0 }, &frame));

    // Restore the honest default.
    virtio_snd.snd_ready = false;
}

test "syscall: slots 44/45 — sys_audio_volume/sys_audio_mute are bounded and process-only (claim 9297)" {
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();

    // Defaults: full volume, unmuted — the honest out-of-the-box stream.
    virtio_snd.stream_volume = 100;
    virtio_snd.stream_muted = false;

    // In task 0 (shell, not a registered process), both are refused EINVAL
    // before any state is touched.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_audio_volume, .{ 50, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_audio_mute, .{ 1, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u8, 100), virtio_snd.stream_volume);
    try std.testing.expect(!virtio_snd.stream_muted);

    // Yield to the user task (task 2, pid 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(process.find_by_task(2) != null);

    // Volume: bounded — 101 is refused EINVAL (no silent clamping), the
    // in-range sets return the volume.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_audio_volume, .{ 101, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 30), dispatch(sys_audio_volume, .{ 30, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u8, 30), virtio_snd.stream_volume);
    try std.testing.expectEqual(@as(u64, 100), dispatch(sys_audio_volume, .{ 100, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u8, 100), virtio_snd.stream_volume);

    // Mute: only 0/1 — anything else is EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_audio_mute, .{ 2, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_audio_mute, .{ 1, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(virtio_snd.stream_muted);
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_audio_mute, .{ 0, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!virtio_snd.stream_muted);

    // Restore the honest default.
    virtio_snd.stream_volume = 100;
    virtio_snd.stream_muted = false;
}
