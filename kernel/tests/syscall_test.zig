//! VirelaiOS syscall decoupled unit tests (M41 TS3, #954).
//!
//! Host unit test suite extracted from kernel/src/syscall.zig.
//! Tests system call registration, argument decoding/marshaling,
//! permission checks, EFAULT bounds, service routing, and lifecycle events.

const std = @import("std");
const syscall = @import("syscall");
const helpers = @import("helpers");
const task_mock = helpers.task;

// Re-export syscall types and constants
const Args = syscall.Args;
const NetStats = syscall.NetStats;
const alloc = syscall.alloc;
const app_timers = syscall.app_timers;
const arp = syscall.arp;
const call_count = syscall.call_count;
const clipboard = syscall.clipboard;
const console = syscall.console;
const dispatch = syscall.dispatch;
const driving_award = syscall.driving_award;
const ensure_table = syscall.ensure_table;
const entry_info = syscall.entry_info;
const error_result = syscall.error_result;
const events = syscall.events;
const exceptions = syscall.exceptions;
const file_table = syscall.file_table;
const handle_svc = syscall.handle_svc;
const handle_win_close = syscall.handle_win_close;
const init = syscall.init;
const m33_surf_scan_tag = syscall.m33_surf_scan_tag;
const m33_surf_win_tag = syscall.m33_surf_win_tag;
const mailbox = syscall.mailbox;
const memmap = syscall.memmap;
const mmu = syscall.mmu;
const net_stats_bytes = syscall.net_stats_bytes;
const process = syscall.process;
const report = syscall.report;
const scheduler = syscall.scheduler;
const set_user_regions = syscall.set_user_regions;
const shared_mmap = syscall.shared_mmap;
const shared_region = syscall.shared_region;
const slot_count = syscall.slot_count;
const svc_immediate = syscall.svc_immediate;
const sys_audio_info = syscall.sys_audio_info;
const sys_audio_mute = syscall.sys_audio_mute;
const sys_audio_play = syscall.sys_audio_play;
const sys_audio_volume = syscall.sys_audio_volume;
const sys_clipboard_get = syscall.sys_clipboard_get;
const sys_clipboard_set = syscall.sys_clipboard_set;
const sys_dir_list = syscall.sys_dir_list;
const sys_drag_read = syscall.sys_drag_read;
const sys_exec = syscall.sys_exec;
const sys_exit = syscall.sys_exit;
const sys_file_close = syscall.sys_file_close;
const sys_file_delete = syscall.sys_file_delete;
const sys_file_free = syscall.sys_file_free;
const sys_file_open = syscall.sys_file_open;
const sys_file_read = syscall.sys_file_read;
const sys_file_rename = syscall.sys_file_rename;
const sys_file_truncate = syscall.sys_file_truncate;
const sys_file_write = syscall.sys_file_write;
const sys_font_size = syscall.sys_font_size;
const sys_ipc_recv = syscall.sys_ipc_recv;
const sys_ipc_send = syscall.sys_ipc_send;
const sys_kill = syscall.sys_kill;
const sys_mmap = syscall.sys_mmap;
const sys_munmap = syscall.sys_munmap;
const sys_net_stats = syscall.sys_net_stats;
const sys_notify = syscall.sys_notify;
const sys_ping = syscall.sys_ping;
const sys_ping_poll = syscall.sys_ping_poll;
const sys_ping_send = syscall.sys_ping_send;
const sys_pipe_read = syscall.sys_pipe_read;
const sys_pipe_write = syscall.sys_pipe_write;
const sys_poll_event = syscall.sys_poll_event;
const sys_procs = syscall.sys_procs;
const sys_sleep = syscall.sys_sleep;
const sys_tcp_close = syscall.sys_tcp_close;
const sys_tcp_connect = syscall.sys_tcp_connect;
const sys_tcp_recv = syscall.sys_tcp_recv;
const sys_tcp_send = syscall.sys_tcp_send;
const sys_timer_cancel = syscall.sys_timer_cancel;
const sys_timer_set = syscall.sys_timer_set;
const sys_udp_listen = syscall.sys_udp_listen;
const sys_udp_recv = syscall.sys_udp_recv;
const sys_udp_send = syscall.sys_udp_send;
const sys_wait = syscall.sys_wait;
const sys_wait_event = syscall.sys_wait_event;
const sys_win_close = syscall.sys_win_close;
const sys_win_fill = syscall.sys_win_fill;
const sys_win_fill_batch = syscall.sys_win_fill_batch;
const sys_win_get = syscall.sys_win_get;
const sys_win_lower_back = syscall.sys_win_lower_back;
const sys_win_move = syscall.sys_win_move;
const sys_win_open = syscall.sys_win_open;
const sys_win_present = syscall.sys_win_present;
const sys_win_query = syscall.sys_win_query;
const sys_win_raise = syscall.sys_win_raise;
const sys_win_raise_front = syscall.sys_win_raise_front;
const sys_win_resize = syscall.sys_win_resize;
const sys_win_set_title = syscall.sys_win_set_title;
const sys_win_set_unsaved = syscall.sys_win_set_unsaved;
const sys_win_set_visible = syscall.sys_win_set_visible;
const sys_wmctl = syscall.sys_wmctl;
const sys_write = syscall.sys_write;
const sys_yield = syscall.sys_yield;
const tcp = syscall.tcp;
const timer = syscall.timer;
const uaccess = syscall.uaccess;
const udp = syscall.udp;
const userspace = syscall.userspace;
const virtio_file = syscall.virtio_file;
const virtio_gpu = syscall.virtio_gpu;
const virtio_net = syscall.virtio_net;
const virtio_snd = syscall.virtio_snd;
const win_query_bytes = syscall.win_query_bytes;
const win_rect_bytes = syscall.win_rect_bytes;
const wm_server = syscall.wm_server;
const wnd_core = syscall.wnd_core;
const write_cap = syscall.write_cap;

// Shared test helper from helpers.task_mock
const fresh_frame = task_mock.fresh_frame;

var test_write_buffer: [write_cap]u8 = undefined;
var test_write_len: usize = 0;

fn test_writer(bytes: []const u8) void {
    @memcpy(test_write_buffer[test_write_len..][0..bytes.len], bytes);
    test_write_len += bytes.len;
}

var test_marshaled_args: Args = [_]u64{0} ** 6;
fn capture_marshaled_args(args: Args, _: *exceptions.VectorFrame) u64 {
    test_marshaled_args = args;
    return 0xcafe;
}

test "syscall: runtime table has 128 slots and sixty-six unique implemented rows" {
    init(test_writer);
    const table = ensure_table();
    try std.testing.expectEqual(@as(usize, 128), table.len);
    var seen: [slot_count]bool = [_]bool{false} ** slot_count;
    var implemented: usize = 0;
    for (table, 0..) |entry, number| {
        if (entry.handler != null) {
            try std.testing.expect(!seen[number]);
            seen[number] = true;
            implemented += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 66), implemented);
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
    try std.testing.expectEqualStrings("sys_net_stats", entry_info(sys_net_stats).?.name);
    try std.testing.expectEqualStrings("sys_mmap", entry_info(sys_mmap).?.name);
    try std.testing.expectEqualStrings("sys_munmap", entry_info(sys_munmap).?.name);
    // M32 WMS2 (issue #622): slot 65 is the render-server register.
    try std.testing.expectEqualStrings("sys_wmctl", entry_info(sys_wmctl).?.name);
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

    // Unimplemented in-range slots still return ENOSYS (previously this
    // example used 65; that slot is now sys_wmctl, M32 WMS2 — use 67/66,
    // which remain genuinely unregistered).
    try std.testing.expect(exceptions.frame_write(&frame, 8, 67));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(error_result(.enosys), exceptions.frame_read(&frame, 0));
    try std.testing.expectEqual(@as(u64, 1), call_count(67));

    try std.testing.expect(exceptions.frame_write(&frame, 8, 66));
    try std.testing.expect(handle_svc(&frame, svc_immediate));
    try std.testing.expectEqual(error_result(.enosys), exceptions.frame_read(&frame, 0));
}

test "syscall: handle_svc marshals every x0-x5 argument before replacing x0" {
    init(test_writer);
    _ = ensure_table();
    const saved = syscall.table_storage[65];
    defer syscall.table_storage[65] = saved;
    syscall.table_storage[65] = .{ .name = "test_capture", .handler = capture_marshaled_args };
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
    try std.testing.expect(exceptions.frame_write(&frame, 8, 65));
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
    try std.testing.expect(exceptions.resume_frame[0] != @intFromPtr(&frame));
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
    exceptions.resume_frame[0] = @intFromPtr(&caller);
    try std.testing.expect(handle_svc(&caller, svc_immediate));
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(&caller, 0));
    try std.testing.expect(exceptions.resume_frame[0] != @intFromPtr(&caller));
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

test "syscall: sys_net_stats marshals a whole snapshot and pins the layout" {
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // process 0
    scheduler.start();
    var frame = fresh_frame();

    // Pin the layout — the userland mirror (user/src/lib/netstats.zig)
    // must match every offset or this test fails loudly.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(NetStats, "mac"));
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(NetStats, "own_ip"));
    try std.testing.expectEqual(@as(usize, 10), @offsetOf(NetStats, "gateway"));
    try std.testing.expectEqual(@as(usize, 14), @offsetOf(NetStats, "dhcp_state"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(NetStats, "lease_secs"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(NetStats, "tcp_state"));
    try std.testing.expectEqual(@as(usize, 33), @offsetOf(NetStats, "tcp_peer_ip"));
    try std.testing.expectEqual(@as(usize, 38), @offsetOf(NetStats, "tcp_peer_port"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(NetStats, "udp_count"));
    // The whole struct must stay well under the 512-byte scratch budget.
    try std.testing.expect(net_stats_bytes <= 256);

    // Mutate some state so the snapshot demonstrably carries it (restore
    // the previous values on the way out — host tests share globals).
    const saved_own_ip = arp.own_ip;
    const saved_peer_ip = tcp.peer_ip;
    const saved_peer_port = tcp.peer_port;
    defer arp.own_ip = saved_own_ip;
    defer tcp.peer_ip = saved_peer_ip;
    defer tcp.peer_port = saved_peer_port;
    arp.own_ip = .{ 10, 0, 0, 2 };
    tcp.peer_ip = .{ 10, 0, 0, 9 };
    tcp.peer_port = 8080;

    var buf: [net_stats_bytes]u8 = undefined;
    set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&buf), .len = buf.len },
    );
    // Too-small buffer: honest truncation — 0 bytes, no copy.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_net_stats, .{ @intFromPtr(&buf), net_stats_bytes - 1, 0, 0, 0, 0 }, &frame));
    // Full snapshot: returns the byte count; the state round-trips.
    const rc = dispatch(sys_net_stats, .{ @intFromPtr(&buf), buf.len, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, net_stats_bytes), rc);
    const snap: *align(1) const NetStats = @ptrCast(&buf);
    try std.testing.expectEqualSlices(u8, &arp.own_ip, &snap.own_ip); // the mutation round-trips
    try std.testing.expectEqual(@as(u16, 8080), snap.tcp_peer_port);
    try std.testing.expectEqualSlices(u8, &tcp.peer_ip, &snap.tcp_peer_ip);
    // A bad user pointer is EFAULT (nothing copied).
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_net_stats, .{ uaccess.diagnostic_unmapped, buf.len, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 3), call_count(sys_net_stats));
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
    exceptions.resume_frame[0] = @intFromPtr(&caller);
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
    // Re-open (id 2 reused), then open the remaining slots (ids 3..9):
    // the full-registry ENOSPC split now holds at the 8-slot WM1 bound,
    // and the caller owns all eight.
    try std.testing.expectEqual(@as(u64, 2), dispatch(sys_win_open, .{ 64, 64, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 3), dispatch(sys_win_open, .{ 320, 64, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 4), dispatch(sys_win_open, .{ 576, 64, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 5), dispatch(sys_win_open, .{ 64, 288, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 6), dispatch(sys_win_open, .{ 576, 288, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 7), dispatch(sys_win_open, .{ 832, 64, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 8), dispatch(sys_win_open, .{ 832, 288, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 9), dispatch(sys_win_open, .{ 320, 288, 256, 192, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enospc), dispatch(sys_win_open, .{ 0, 0, 10, 10, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(2));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(3));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(4));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(5));
    try std.testing.expectEqual(@as(?usize, win_pid), driving_award.user_owner(9));
    // Error mapping in the OWNING context: invalid geometry, out-of-bounds
    // rects, unknown ids, and the fixed windows are all EINVAL. WM1: the
    // 512×424 buffer cap is gone — 425-tall and 385-tall both fit the
    // scanout now, so with the full registry they map to ENOSPC (geometry
    // is no longer EINVAL); past-scanout sizes stay EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_open, .{ 0, 0, 0, 10, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enospc), dispatch(sys_win_open, .{ 0, 0, 10, 425, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enospc), dispatch(sys_win_open, .{ 0, 0, 10, 385, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_open, .{ 0, 0, 10, 721, 0, 0 }, &frame));
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
    // all eight of its windows (ids 2..9) are released with NO sys_win_close
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

test "syscall: win open maps pool exhaustion to ENOMEM (WM1, claim 919)" {
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
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expect(scheduler.yield_current()); // user -> WIN.BIN (3)
    // Shrink the pool to a single page: a 256×192 window needs 12.
    var desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 1, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&desc), @sizeOf(memmap.MemoryDescriptor), desc.len);
    _ = alloc.init(view, &.{});
    // Geometry fits the scanout, slots are free — the failure is the pool.
    try std.testing.expectEqual(error_result(.enomem), dispatch(sys_win_open, .{ 64, 64, 256, 192, 0, 0 }, &frame));
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
        "syscalls: slots=64 implemented=66\n" ++
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
            "  61 sys_win_set_title calls=0\n" ++
            "  62 sys_net_stats calls=0\n" ++
            "  63 sys_mmap calls=0\n" ++
            "  64 sys_munmap calls=0\n" ++
            "  65 sys_wmctl calls=0\n",
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
    // No host file channel — exec_file reports no_disk honestly (HF6: the
    // ESP disk is gone; the share is the only app source).
    virtio_file.set_test_share(null);
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process), sys_exec returns EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exec, .{ 0x1000, 8, 0, 0, 0, 0 }, &frame));
    // Empty path and an over-long path are EINVAL (checked before uaccess)
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exec, .{ 0x1000, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_exec, .{ 0x1000, virtio_file.path_max + 1, 0, 0, 0, 0 }, &frame));

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

test "syscall: sys_wmctl (slot 65) enforces the render-server register contract" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();

    // In task 0 (shell, not a registered process) REGISTER is EINVAL — an
    // EL1h task can never be the WM (non-process caller).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_register, 0, 0, 0, 0, 0 }, &frame));

    // Drive to the caller (task 2, pid 0).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expectEqual(@as(usize, 0), process.find_by_task(2).?);

    // No WM registered, no GPU (host test):
    //   REGISTER -> ENXIO (no gpu / unarmed compositor)
    //   SET_WINDOW / REQUEST_PRESENT -> ENOSYS (the ADR 0007 "no WM" case)
    //   unknown cmd -> EINVAL
    try std.testing.expectEqual(error_result(.enxio), dispatch(sys_wmctl, .{ wm_server.wmctl_register, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_request_present, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ 99, 0, 0, 0, 0, 0 }, &frame));

    // The slot is counted like every other implemented row.
    try std.testing.expectEqual(@as(u64, 5), call_count(sys_wmctl));

    // Seed the WM as pid 0; the registrant drives the seam:
    try std.testing.expect(wm_server.register(0));
    try std.testing.expectEqual(@as(u64, 0), wm_server.info().present_count);
    //   REQUEST_PRESENT from the WM -> 0, and the present counter advanced.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_request_present, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().present_count);
    //   A second REGISTER while the seat is taken -> EACCES.
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_wmctl, .{ wm_server.wmctl_register, 0, 0, 0, 0, 0 }, &frame));
    //   SET_WINDOW (WMS4): a valid descriptor from the WM is accepted and
    //   stored; every malformed submission is refused honestly.
    var desc: wnd_core.ChromeDesc = wnd_core.chrome_parity_policy();
    const desc_ptr = @intFromPtr(&desc);
    set_user_regions(.{ .base = desc_ptr, .len = wnd_core.chrome_desc_bytes }, .{ .base = 0, .len = 0 });
    // Broadcast (ALL): accepted, the policy is stored, submissions counted.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, wnd_core.chrome_window_all, 0, 0, desc_ptr, wnd_core.chrome_desc_bytes }, &frame));
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().set_window_count);
    try std.testing.expectEqual(@as(u32, 0x7f), driving_award.wm_chrome_policy_kind());
    // Per-window id with no such window -> EINVAL (the broadcast always
    // succeeds; a specific id must exist).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, 7, 0, 0, desc_ptr, wnd_core.chrome_desc_bytes }, &frame));
    // Bad length (not the frozen 40) -> EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, wnd_core.chrome_window_all, 0, 0, desc_ptr, 39 }, &frame));
    // WMS5 (issue #625): the ALL broadcast stays chrome-only — nonzero
    // rect on the broadcast -> EINVAL (geometry is per-window).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, wnd_core.chrome_window_all, 1, 0, desc_ptr, wnd_core.chrome_desc_bytes }, &frame));
    // Unknown kind bit -> EINVAL (the single wnd_core refusal rule).
    const bad = wnd_core.ChromeDesc{ .kind = wnd_core.chrome_kind_all | 0x80, .flags = 0, .border_rgb = 0, .border_unfocus_rgb = 0, .title_bg_rgb = 0, .title_fg_rgb = 0, .ring_rgb = 0, .close_rgb = 0, .min_rgb = 0, .pin_rgb = 0 };
    const bad_ptr = @intFromPtr(&bad);
    set_user_regions(.{ .base = bad_ptr, .len = wnd_core.chrome_desc_bytes }, .{ .base = 0, .len = 0 });
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, wnd_core.chrome_window_all, 0, 0, bad_ptr, wnd_core.chrome_desc_bytes }, &frame));
    // Bad descriptor pointer (no readable region) -> EFAULT.
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = 0, .len = 0 });
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, wnd_core.chrome_window_all, 0, 0, 0x1000, wnd_core.chrome_desc_bytes }, &frame));

    // Seed a DIFFERENT pid as the WM; pid 0 becomes an outsider:
    wm_server.init();
    try std.testing.expect(wm_server.register(1));
    //   REGISTER -> EACCES (seat taken); SET_WINDOW / REQUEST_PRESENT ->
    //   EACCES (the ADR 0007 WM-exclusive refusal).
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_wmctl, .{ wm_server.wmctl_register, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_wmctl, .{ wm_server.wmctl_set_window, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_wmctl, .{ wm_server.wmctl_request_present, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 0, 0, 0, 0, 0 }, &frame));
    // WMS5: the input seam is part of the register contract — registering
    // hands the raw pointer stream + window mirrors to the WM (kind 19/20);
    // teardown restores shim input consumption. Tear down so the aggregated
    // test binary does not leak input ownership into later tests.
    try std.testing.expect(driving_award.wm_owns_input);
    try std.testing.expect(wm_server.unregister(1));
    try std.testing.expect(!driving_award.wm_owns_input);
}

test "syscall: SET_STATE (cmd 4, claim 4278) applies visibility/workspace/ws-switch with the seam refusals" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)

    // No WM registered: SET_STATE -> ENOSYS (the ADR 0007 "no WM" case).
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 2, 0, 0, 0, 0 }, &frame));

    // Seed the WM as pid 0 and arm the compositor state for window tests.
    try std.testing.expect(wm_server.register(0));
    // No such window -> EINVAL (id validated even with no visible change).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 9, 2, 0, 0, 0 }, &frame));
    // Out-of-range workspace (bits 8-15 >= workspace_max and not 0xff) -> EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 2, 0x0900, 0, 0, 0 }, &frame));
    // The ALL broadcast with an OUT-OF-RANGE workspace -> EINVAL (the
    // global ws-switch validates its target; ws 0 IS valid, 3 is not —
    // `switch_workspace` refuses `>= workspace_max`, and the handler
    // validates before the call so the refusal is an honest EINVAL).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, wnd_core.chrome_window_all, 0x0300, 0, 0, 0 }, &frame));

    // Open a real user window (id 2), then drive the seam from the WM:
    const open_res = driving_award.user_open(64, 64, 512, 384, 0);
    try std.testing.expectEqual(@as(u8, 2), open_res.opened); // window id 2
    //   GLOBAL workspace switch (a0 = ALL, bits 8-15 = 1): current ws moves.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, wnd_core.chrome_window_all, 0x0100, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u8, 1), driving_award.current_workspace);
    //   Per-window hide (minimize): visible -> false, counter advanced.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 2, 0, 0, 0, 0 }, &frame));
    const w2 = driving_award.find_user_window(2).?;
    try std.testing.expect(!w2.visible);
    //   Per-window show (restore): visible -> true.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 2, 1, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.find_user_window(2).?.visible);
    //   Per-window workspace move (bits 8-15 = 2): w.workspace -> 2.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 2, 0x0200, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u8, 2), driving_award.find_user_window(2).?.workspace);
    //   Always-on-top toggle (bit 16): the flag flips.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_set_state, 2, (1 << 16) | 2, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.find_user_window(2).?.always_on_top);
    // The counter observed every accepted call (global + 4 per-window).
    try std.testing.expectEqual(@as(u64, 5), wm_server.info().set_state_count);

    // Teardown: no leaked input ownership into the aggregated binary.
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
    _ = driving_award.user_close(2);
}

test "syscall: ALT_TAB (cmd 5, claim 4510) drives the overlay from the WM's chosen id" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)

    // No WM registered: ALT_TAB -> ENOSYS (the ADR 0007 "no WM" case).
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_alt_tab, 2, wm_server.alt_tab_commit, 0, 0, 0 }, &frame));

    // Seed the WM as pid 0 + open two real user windows.
    try std.testing.expect(wm_server.register(0));
    const o2 = driving_award.user_open(64, 64, 400, 300, 0);
    const o3 = driving_award.user_open(200, 100, 400, 300, 0);
    try std.testing.expectEqual(@as(u8, 2), o2.opened);
    try std.testing.expectEqual(@as(u8, 3), o3.opened);
    // The WM proposes focus on window 3; the kernel focuses/raises + dismisses,
    // and the submission is counted.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_alt_tab, 3, wm_server.alt_tab_commit, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u8, 3), driving_award.focused_window_id());
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().alt_tab_apply_count);
    // activate highlights the WM's chosen id in the overlay snapshot.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_alt_tab, 2, wm_server.alt_tab_activate, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.alt_tab_is_active());
    try std.testing.expectEqual(@as(u8, 2), driving_award.alt_tab_selected_id().?);
    // dismiss drops the overlay.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_alt_tab, 0, wm_server.alt_tab_dismiss, 0, 0, 0 }, &frame));
    try std.testing.expect(!driving_award.alt_tab_is_active());
    try std.testing.expectEqual(@as(u64, 3), wm_server.info().alt_tab_apply_count);
    // A commit to a window that does not exist -> EINVAL (kernel clamps).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_alt_tab, 9, wm_server.alt_tab_commit, 0, 0, 0 }, &frame));
    // A malformed action -> EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_alt_tab, 2, 77, 0, 0, 0 }, &frame));
    // The counter only counted the accepted calls.
    try std.testing.expectEqual(@as(u64, 3), wm_server.info().alt_tab_apply_count);

    // Teardown: no leaked input ownership into the aggregated binary.
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
    _ = driving_award.user_close(2);
    _ = driving_award.user_close(3);
}

test "syscall: NOTIF_CENTER / NOTIF_DISMISS (cmd 6/7, claim 7557) drive the center from the WM's decision" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)

    // No WM registered: NOTIF_CENTER -> ENOSYS (the ADR 0007 "no WM" case).
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_notif_center, 1, 0, 0, 0, 0 }, &frame));

    // Seed the WM as pid 0.
    try std.testing.expect(wm_server.register(0));
    // Open -> notif_center_open true.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_notif_center, 1, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.notif_center_open);
    // Close -> false.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_notif_center, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!driving_award.notif_center_open);
    // Clear-all is accepted with no notifications.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_notif_center, 2, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 3), wm_server.info().notif_center_count);
    // Dismissing an out-of-range row -> EINVAL (honest, no silent no-op).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_notif_dismiss, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), wm_server.info().notif_dismiss_count);
    // A malformed NOTIF_CENTER action -> EINVAL, not counted.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_notif_center, 9, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 3), wm_server.info().notif_center_count);

    // Teardown: no leaked input ownership into the aggregated binary.
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
}

test "syscall: TOOLTIP (cmd 8, claim 6154) shows/hides the tooltip from the WM's text" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)

    // No WM registered: TOOLTIP -> ENOSYS (the ADR 0007 "no WM" case).
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_tooltip, 1, 0, 0, 0, 3 }, &frame));

    // Seed the WM as pid 0.
    try std.testing.expect(wm_server.register(0));
    // A valid text pointer (registered region) shows the tooltip immediately.
    var txt: [5]u8 = "Clock".*;
    const txt_ptr = @intFromPtr(&txt);
    set_user_regions(.{ .base = txt_ptr, .len = 5 }, .{ .base = 0, .len = 0 });
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_tooltip, 1, 0, 0, txt_ptr, 5 }, &frame));
    try std.testing.expect(driving_award.tooltip_visible);
    try std.testing.expectEqual(@as(u8, 5), driving_award.tooltip_text_len);
    try std.testing.expectEqualStrings("Clock", driving_award.tooltip_text[0..5]);
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().tooltip_count);
    // Hide (a0 = 0) clears it.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_tooltip, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!driving_award.tooltip_visible);
    try std.testing.expectEqual(@as(u8, 0), driving_award.tooltip_text_len);
    try std.testing.expectEqual(@as(u64, 2), wm_server.info().tooltip_count);
    // Over-length (> 32) / zero-length text -> EINVAL, not counted.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_tooltip, 1, 0, 0, txt_ptr, 33 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_tooltip, 1, 0, 0, txt_ptr, 0 }, &frame));
    // A bad text pointer -> EFAULT.
    set_user_regions(.{ .base = 0, .len = 0 }, .{ .base = 0, .len = 0 });
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_wmctl, .{ wm_server.wmctl_tooltip, 1, 0, 0, 0x2000, 5 }, &frame));
    // A malformed action -> EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_tooltip, 9, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 2), wm_server.info().tooltip_count);

    // Teardown: no leaked input ownership into the aggregated binary.
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
}

test "syscall: DOCK (cmd 9, claim 9197) restores/focuses through the WM's icon decision" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)

    // No WM registered: DOCK -> ENOSYS (the ADR 0007 "no WM" case).
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_dock, 0, 0, 0, 0, 0 }, &frame));

    // Seed the WM as pid 0 and open a real user window.
    try std.testing.expect(wm_server.register(0));
    const o2 = driving_award.user_open(64, 64, 400, 300, 0);
    try std.testing.expectEqual(@as(u8, 2), o2.opened);
    // Minimize it — the dock restore chain's target.
    var w2 = driving_award.find_user_window(2).?;
    w2.minimized = true;
    w2.visible = false;
    // The WM's DOCK decision (icon 0) restores + focuses it.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dock, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!w2.minimized);
    try std.testing.expect(w2.visible);
    try std.testing.expectEqual(@as(u8, 2), driving_award.focused_window_id());
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().dock_count);
    // An out-of-range icon (the bar has 5) -> EINVAL, not counted.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_dock, 5, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().dock_count);

    // Teardown: no leaked input ownership into the aggregated binary.
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
    _ = driving_award.user_close(2);
}

test "syscall: TRAY (cmd 10, claim 3744) stores the WM's tray widget content" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)

    // No WM registered: TRAY -> ENOSYS (the ADR 0007 "no WM" case).
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_tray, 0b111, 0, 0, 0, 0 }, &frame));

    // Seed the WM as pid 0.
    try std.testing.expect(wm_server.register(0));
    // The WM's TRAY decision: clock "12:34" packed little-endian, theme 'D',
    // clipboard filled. a0 = flags 0b111 (all three), a1 = packed clock,
    // a2 = 'D' | (1 << 8).
    const clock_packed = @as(u64, '1') | (@as(u64, '2') << 8) | (@as(u64, ':') << 16) | (@as(u64, '3') << 24) | (@as(u64, '4') << 32);
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_tray, 0b111, clock_packed, @as(u64, 'D') | (@as(u64, 1) << 8), 0, 0 }, &frame));
    try std.testing.expect(driving_award.wm_tray_clock_set);
    try std.testing.expectEqualStrings("12:34", driving_award.wm_tray_clock_text[0..5]);
    try std.testing.expect(driving_award.wm_tray_theme_set);
    try std.testing.expectEqual(@as(u8, 'D'), driving_award.wm_tray_theme);
    try std.testing.expect(driving_award.wm_tray_clip_set);
    try std.testing.expect(driving_award.wm_tray_clip);
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().tray_count);
    // A partial decision (clock only) leaves the other widgets untouched.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_tray, 0b001, clock_packed, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.wm_tray_theme_set); // unchanged (still set)
    try std.testing.expectEqual(@as(u64, 2), wm_server.info().tray_count);
    // Unknown flag bits -> EINVAL, not counted.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_tray, 0b1000, 0, 0, 0, 0 }, &frame));
    // A non-HH:MM clock char -> EINVAL ('Z' in slot 0).
    const bad2 = (@as(u64, 'Z') << 0) | (@as(u64, '1') << 8);
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_tray, 0b001, bad2, 0, 0, 0 }, &frame));
    // A theme letter outside D/L/A -> EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_tray, 0b010, 0, 'Z', 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 2), wm_server.info().tray_count);

    // Teardown: no leaked input ownership into the aggregated binary, and the
    // WM's tray content dies with it (clear_wm_chrome resets the _set flags).
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
    try std.testing.expect(!driving_award.wm_tray_clock_set);
    try std.testing.expect(!driving_award.wm_tray_theme_set);
    try std.testing.expect(!driving_award.wm_tray_clip_set);
}

test "syscall: DIALOG (cmd 11, claim 9980) applies the WM's about-dialog decision" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)

    // No WM registered: DIALOG -> ENOSYS (the ADR 0007 "no WM" case).
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 2, 0, 0, 0, 0 }, &frame));

    // Seed the WM as pid 0.
    try std.testing.expect(wm_server.register(0));
    try std.testing.expect(!driving_award.about_dialog_open);
    // The WM's DIALOG decision: a0=1 OPEN opens the about dialog.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 1, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.about_dialog_open);
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().dialog_count);
    // a0=2 TOGGLE closes it (was open) — parity with the shim's self-toggle.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 2, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!driving_award.about_dialog_open);
    try std.testing.expectEqual(@as(u64, 2), wm_server.info().dialog_count);
    // a0=0 CLOSE is a no-op when already closed but still counted (an applied
    // decision), and a0=9 is EINVAL (not counted).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 3), wm_server.info().dialog_count);
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 9, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 3), wm_server.info().dialog_count);

    // Teardown: no leaked input ownership into the aggregated binary.
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
    try std.testing.expect(!driving_award.about_dialog_open); // teardown restores
}

test "syscall: DIALOG (cmd 11, claim 6155) applies the WM's unsaved-dialog decision" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)

    // Seed the WM as pid 0, arm the compositor seam, and open a real user
    // window (id 2) — arm() makes this test standalone (the dock test relies
    // on a prior test having armed it).
    driving_award.arm();
    try std.testing.expect(wm_server.register(0));
    const o2 = driving_award.user_open(64, 64, 400, 300, 0);
    try std.testing.expectEqual(@as(u8, 2), o2.opened);
    const id2: u8 = 2;

    // No WM -> ENOSYS is covered by the about test; here a0=3 SHOW opens the
    // unsaved dialog for the target window (a WM decision, applied).
    try std.testing.expect(!driving_award.unsaved_dialog_is_open());
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 3, id2, 0, 0, 0 }, &frame));
    try std.testing.expect(driving_award.unsaved_dialog_is_open());
    // A show for an unknown window -> EINVAL, not counted.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 3, 99, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 1), wm_server.info().dialog_count);
    // a0=5 DONT_SAVE closes the target window (the WM's discard decision).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 5, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!driving_award.unsaved_dialog_is_open());
    try std.testing.expect(driving_award.find_user_window(id2) == null);
    try std.testing.expectEqual(@as(u64, 2), wm_server.info().dialog_count);
    // Review fix (claim 7639): with the dialog CLOSED, the button actions
    // 4/5/6 are EINVAL (the stale BSS-zero target stays unreachable) and are
    // NOT counted — the shim's click path returned `.none` first.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 6, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 5, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 2), wm_server.info().dialog_count);
    // a0=4 SAVE posts WIN_UNSAVED to the owner and leaves the window open.
    const o3 = driving_award.user_open(64, 64, 400, 300, 0);
    // The freed slot is reused, so the second open gets id 2 again.
    try std.testing.expectEqual(@as(u8, 2), o3.opened);
    const id3: u8 = o3.opened;
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 3, id3, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_dialog, 4, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!driving_award.unsaved_dialog_is_open());
    try std.testing.expect(driving_award.find_user_window(id3) != null); // save keeps the window
    try std.testing.expectEqual(@as(u64, 4), wm_server.info().dialog_count);

    // Teardown: no leaked input ownership into the aggregated binary.
    try std.testing.expect(wm_server.unregister(0));
    try std.testing.expect(!driving_award.wm_owns_input);
}

test "syscall: sys_wmctl tab subcommands (cmd 18/19/20, issue #782) validate IDs and record decisions" {
    userspace.init();
    init(test_writer);
    wm_server.init();
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();
    var frame = fresh_frame();
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)

    // No WM registered: returns ENOSYS
    try std.testing.expectEqual(error_result(.enosys), dispatch(sys_wmctl, .{ wm_server.wmctl_attach_tab, 2, 3, 0, 0, 0 }, &frame));

    // Register WM as pid 0
    try std.testing.expect(wm_server.register(0));

    // Valid attach: child 2, parent 3
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_attach_tab, 2, 3, 0, 0, 0 }, &frame));
    // Invalid attach: same id or out of bounds
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_attach_tab, 2, 2, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_attach_tab, 0x100, 3, 0, 0, 0 }, &frame));

    // Valid activate: tab 2
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_activate_tab, 2, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_activate_tab, 0x100, 0, 0, 0, 0 }, &frame));

    // Valid detach: tab 2
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_wmctl, .{ wm_server.wmctl_detach_tab, 2, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_wmctl, .{ wm_server.wmctl_detach_tab, 0x100, 0, 0, 0, 0 }, &frame));

    // M37 DQ2 (issue #840): the recording hooks mirror validated calls
    // into driving_award without changing validation — unknown ids are
    // defensive no-ops (no phantom grouping state).
    try std.testing.expectEqual(@as(u8, 0), driving_award.tab_parent_of(2));
    try std.testing.expectEqual(@as(u8, 0), driving_award.tab_parent_of(3));

    // Teardown
    try std.testing.expect(wm_server.unregister(0));
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
    exceptions.resume_frame[0] = @intFromPtr(&caller);

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

fn test_net_read8(_: u32) u8 {
    return 0;
}
fn test_net_read16(_: u32) u16 {
    return 0;
}
fn test_net_read32(_: u32) u32 {
    return 0;
}
fn test_net_write8(_: u32, _: u8) void {}
fn test_net_write16(_: u32, _: u16) void {}
fn test_net_write32(_: u32, _: u32) void {}
fn test_net_notify(q: u16) void {
    _ = q;
    virtio_net.net_dev.tx_used.idx = virtio_net.net_dev.tx_avail.idx;
}
fn test_net_to_phys(va: usize) u64 {
    return va;
}
fn test_net_clean(_: usize, _: usize) void {}
fn test_net_invalidate(_: usize, _: usize) void {}

fn test_net_ops() virtio_net.Ops {
    return .{
        .dev_read32 = test_net_read32,
        .cfg_read8 = test_net_read8,
        .cfg_read16 = test_net_read16,
        .cfg_read32 = test_net_read32,
        .cfg_write8 = test_net_write8,
        .cfg_write16 = test_net_write16,
        .cfg_write32 = test_net_write32,
        .notify = test_net_notify,
        .to_phys = test_net_to_phys,
        .clean = test_net_clean,
        .invalidate = test_net_invalidate,
    };
}

test "syscall: sys_tcp_connect timeout aborts cleanly and increments timed_out" {
    userspace.init();
    init(test_writer);
    var frame = fresh_frame();

    const saved_ops = virtio_net.net_ops;
    virtio_net.net_ops = test_net_ops();
    defer virtio_net.net_ops = saved_ops;

    virtio_net.net_ready = true;
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    virtio_net.arp.upsert(.{ 10, 0, 0, 2 }, .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 });
    tcp.reset();
    const initial_timeouts = tcp.timed_out;

    // Connect to peer that never responds in test mode
    const rc = dispatch(sys_tcp_connect, .{ 0x0a000002, 80, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(error_result(.einval), rc);
    try std.testing.expectEqual(tcp.State.idle, tcp.state);
    try std.testing.expectEqual(initial_timeouts + 1, tcp.timed_out);

    tcp.reset();
    virtio_net.net_ready = false;
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
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

test "syscall: sys_mmap and sys_munmap anonymous allocation and teardown" {
    mmu.reset();
    alloc.reset_refcounts();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)
    scheduler.start();

    var frame = fresh_frame();

    // In task 0 (shell), calls return EINVAL
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ 0, 4096, 3, 0x22, 0, 0 }, &frame));

    // Yield to user task (task 2, pid 0)
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user (2)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());

    // mmap 8192 bytes
    const mapped_va = dispatch(sys_mmap, .{ 0, 8192, 3, 0x22, 0, 0 }, &frame);
    try std.testing.expect(mapped_va >= 0x1000_0000);
    try std.testing.expectEqual(@as(u64, 2), call_count(sys_mmap));

    // munmap the region
    const unmap_res = dispatch(sys_munmap, .{ mapped_va, 8192, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 0), unmap_res);
    try std.testing.expectEqual(@as(u64, 1), call_count(sys_munmap));

    // Invalid munmap (unaligned addr)
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_munmap, .{ mapped_va + 1, 4096, 0, 0, 0, 0 }, &frame));
}

test "syscall: shared anon mmap — two EL0 roots map one region; owner RW, WM RO; munmap revokes the peer seat" {
    mmu.reset();
    alloc.reset_refcounts();
    shared_region.reset(); // the region table is global — a fresh table per test
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)

    // Arm the physical allocator (SB2's create allocates its pages eagerly).
    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    // Two REAL TTBR0 roots: the owner renders into its shared surface; the WM
    // peer reads it EL0-RO from ITS OWN root at ITS OWN va.
    const owner_root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const peer_root = mmu.build_user_root(userspace.text_va, 0x3000, 64, userspace.stack_va, 0x4000, 8192).?;
    var kstack1: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack2: [scheduler.task_stack_size]u8 align(16) = undefined;
    const owner_pid = process.create("OWNER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = owner_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const peer_pid = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = peer_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const owner_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack1, 0, 0).?;
    const peer_task = scheduler.register_exec_user(userspace.text_va, 0x5000_0000, 100, 0x9000_0000, 8192, &kstack2, 0, 0).?;
    _ = process.bind(owner_pid, owner_task);
    _ = process.bind(peer_pid, peer_task);
    scheduler.start();

    var frame = fresh_frame();
    // Drive the ring to the OWNER's task.
    var guard: usize = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());

    // --- Owner creates the shared surface (1 page, RW, MAP_ANON|M33_MAP_SHARED).
    const owner_va = dispatch(sys_mmap, .{ 0, 4096, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(owner_va >= 0x1000_0000);
    const h: u32 = 1; // first kernel-issued handle
    const r = shared_region.info(h).?;
    try std.testing.expectEqual(@as(u64, owner_pid), r.owner_pid);
    try std.testing.expectEqual(@as(u32, 1), r.page_count);
    try std.testing.expectEqual(owner_va, r.owner_va);
    const pa_base: u64 = r.pa_base; // captured BEFORE teardown (the descriptor is zeroed on drop)
    try std.testing.expect(pa_base != 0);
    // The owner's leaf is WRITABLE (AP=0b01), maps the region's pa, no sw_cow.
    const owner_leaf = mmu.get_user_leaf(owner_root, owner_va).?.*;
    try std.testing.expectEqual(r.pa_base, owner_leaf & 0x0000_ffff_ffff_f000);
    try std.testing.expectEqual(@as(u64, 1), (owner_leaf >> 6) & 3); // EL0 RW
    try std.testing.expect((owner_leaf & mmu.sw_cow) == 0);
    // The OWNER attaching by handle keeps its writable surface (never maps a
    // redundant COW view of itself — the SB1 review duty).
    try std.testing.expectEqual(owner_va, dispatch(sys_mmap, .{ h, 4096, 1, 0x20 | 0x10000, 0, 0 }, &frame));

    // Drive the ring to the PEER's task.
    guard = 0;
    while (scheduler.current_id() != peer_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(peer_task, scheduler.current_id());

    // --- A stranger (the peer, pre-WM) cannot attach by handle: EACCES.
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_mmap, .{ h, 4096, 1, 0x20 | 0x10000, 0, 0 }, &frame));

    // --- A writable peer request is EINVAL (D2: peers are read-only).
    _ = wm_server.register(peer_pid);
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ h, 4096, 3, 0x20 | 0x10000, 0, 0 }, &frame));

    // --- The WM attaches RO by handle: its OWN root, EL0-RO + sw_cow, SAME pa.
    const peer_va = dispatch(sys_mmap, .{ h, 4096, 1, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(peer_va >= 0x1000_0000);
    const peer_leaf = mmu.get_user_leaf(peer_root, peer_va).?.*;
    try std.testing.expectEqual(r.pa_base, peer_leaf & 0x0000_ffff_ffff_f000); // SAME physical page
    try std.testing.expectEqual(@as(u64, 3), (peer_leaf >> 6) & 3); // EL0 RO
    try std.testing.expect((peer_leaf & mmu.sw_cow) != 0);
    // Roots are independent: the peer's va may even coincide with the owner's
    // (both va allocators start at 0x1000_0000). The OWNER's leaf at that va,
    // if present, must never be the peer's RO/COW view.
    if (mmu.get_user_leaf(owner_root, peer_va)) |ol| {
        try std.testing.expect((ol.* & mmu.sw_cow) == 0);
    }
    // The peer seat + read ref were recorded.
    try std.testing.expectEqual(@as(u32, 1), shared_region.read_count(h));
    try std.testing.expectEqual(@as(u64, peer_pid), shared_region.info(h).?.peer_pid);
    // Re-attach is idempotent (keeps the existing seat).
    try std.testing.expectEqual(peer_va, dispatch(sys_mmap, .{ h, 4096, 1, 0x20 | 0x10000, 0, 0 }, &frame));

    // Drive back to the OWNER's task for teardown.
    guard = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());

    // --- A PARTIAL munmap of the shared surface is refused: EINVAL.
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_munmap, .{ owner_va, 8192, 0, 0, 0, 0 }, &frame));

    // --- Owner munmap revokes the peer seat: peer leaf unmapped, descriptor
    // gone, pages freed; the owner's own leaf is unmapped too.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_munmap, .{ owner_va, 4096, 0, 0, 0, 0 }, &frame));
    // A revoked leaf is value-zeroed (the intermediate table may remain — mmu
    // unmap semantics), so "gone" means the leaf is absent OR zero; a second
    // unmap of a zeroed leaf returns null (the honest probe).
    try std.testing.expect(mmu.unmap_user_page(peer_root, peer_va) == null);
    try std.testing.expect(mmu.unmap_user_page(owner_root, owner_va) == null);
    try std.testing.expect(shared_region.info(h) == null);
    // The physical page is FREED: a second free attempt returns false (the
    // allocator bit is already clear, and no shared_pages entry remains).
    try std.testing.expect(!alloc.unref_page(pa_base));
    // A stale handle re-attach is EFAULT (.gone).
    try std.testing.expectEqual(error_result(.efault), dispatch(sys_mmap, .{ h, 4096, 1, 0x20 | 0x10000, 0, 0 }, &frame));

    // --- ENOSPC: fill the shared_region table, then a syscall create refuses.
    var n: u32 = 0;
    while (n < shared_region.max_shared_regions) : (n += 1) {
        const hh = shared_region.create(@as(u64, owner_pid));
        try std.testing.expect(hh != 0);
    }
    try std.testing.expectEqual(error_result(.enospc), dispatch(sys_mmap, .{ 0, 4096, 3, 0x20 | 0x10000, 0, 0 }, &frame));

    // Cleanup: unregister the WM seat — a leftover registration would hand
    // later tests (the input routing test uses pid 2) the driving_award
    // window/input hooks and cross-deliver events.
    _ = wm_server.unregister(peer_pid);
}

test "syscall: shared anon revoke-on-exit — owner exit revokes the peer seat; WM exit detaches only its seat" {
    mmu.reset();
    alloc.reset_refcounts();
    shared_region.reset(); // the region table is global — a fresh table per test
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0); // task 2 = process 0 (boot payload)

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const owner_root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const peer_root = mmu.build_user_root(userspace.text_va, 0x3000, 64, userspace.stack_va, 0x4000, 8192).?;
    var kstack1: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack2: [scheduler.task_stack_size]u8 align(16) = undefined;
    const owner_pid = process.create("OWNER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = owner_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const peer_pid = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = peer_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const owner_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack1, 0, 0).?;
    const peer_task = scheduler.register_exec_user(userspace.text_va, 0x5000_0000, 100, 0x9000_0000, 8192, &kstack2, 0, 0).?;
    _ = process.bind(owner_pid, owner_task);
    _ = process.bind(peer_pid, peer_task);
    scheduler.start();

    var frame = fresh_frame();
    var guard: usize = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());

    const owner_va = dispatch(sys_mmap, .{ 0, 4096, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(owner_va >= 0x1000_0000);
    const h: u32 = 1;
    const pa_base = shared_region.info(h).?.pa_base;

    guard = 0;
    while (scheduler.current_id() != peer_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(peer_task, scheduler.current_id());
    _ = wm_server.register(peer_pid);
    const peer_va = dispatch(sys_mmap, .{ h, 4096, 1, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(peer_va >= 0x1000_0000);
    // Owner (1) + peer (1): the page is 2-ref'd while both roots map it.
    try std.testing.expectEqual(@as(u16, 2), alloc.page_refcount(pa_base));

    // --- The WM (peer) exits first: only ITS seat detaches. The region and
    // the owner's writable leaf survive; the page drops back to the owner's
    // single ref. (This is scheduler's revoke_peer_role at exit.)
    _ = shared_mmap.revoke_peer_role(peer_pid);
    try std.testing.expect(mmu.unmap_user_page(peer_root, peer_va) == null); // peer RO leaf gone
    try std.testing.expect(shared_region.info(h) != null); // region survives
    try std.testing.expectEqual(@as(u32, 0), shared_region.read_count(h));
    try std.testing.expectEqual(@as(u64, 0), shared_region.info(h).?.peer_pid); // seat cleared
    try std.testing.expectEqual(@as(u16, 1), alloc.page_refcount(pa_base));
    // The owner's writable leaf is untouched.
    try std.testing.expect(mmu.unmap_user_page(owner_root, owner_va) != null); // still mapped (probe returns its pa)

    // --- The owner exits: the region dies; the page is only held by the
    // owner's dynamic_pages list now (1) — the reap unrefs it to 0 (free).
    _ = shared_mmap.revoke_owner(owner_pid);
    try std.testing.expect(shared_region.info(h) == null);
    try std.testing.expectEqual(@as(u16, 1), alloc.page_refcount(pa_base));
    // Simulate the reap's release_resources unref of the owner's dynamic page.
    // The reap's release_resources unref frees the page (1 -> 0); a second
    // free attempt then does nothing (the honest "already freed" probe).
    try std.testing.expect(alloc.unref_page(pa_base));
    try std.testing.expect(!alloc.unref_page(pa_base));

    // Cleanup: unregister the WM seat (see the sibling test's note).
    _ = wm_server.unregister(peer_pid);
}

test "syscall: M33 SB3 — window surface handoff; bind records the surface, WM mirror aliases RO, unmigrated stays frozen" {
    mmu.reset();
    alloc.reset_refcounts();
    shared_region.reset();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    driving_award.arm();

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 256, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const owner_root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const wm_root = mmu.build_user_root(userspace.text_va, 0x3000, 64, userspace.stack_va, 0x4000, 8192).?;
    var kstack1: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack2: [scheduler.task_stack_size]u8 align(16) = undefined;
    const owner_pid = process.create("APP.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = owner_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const wm_pid = process.create("WM.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = wm_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const owner_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack1, 0, 0).?;
    const wm_task = scheduler.register_exec_user(userspace.text_va, 0x5000_0000, 100, 0x9000_0000, 8192, &kstack2, 0, 0).?;
    _ = process.bind(owner_pid, owner_task);
    _ = process.bind(wm_pid, wm_task);
    scheduler.start();

    var frame = fresh_frame();
    // Drive to the OWNER's task.
    var guard: usize = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(owner_task, scheduler.current_id());

    // Register the WM BEFORE the bind so the surface auto-mirrors RO.
    _ = wm_server.register(wm_pid);

    // --- The app opens a user window (frozen slot 12, unchanged), unmigrated.
    const wid = dispatch(sys_win_open, .{ 64, 64, 128, 96, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 2), wid);
    try std.testing.expect(!driving_award.user_is_surface_backed(@intCast(wid)));

    // --- Bind a shared surface AS the window's back-buffer via the sys_mmap
    // window-tag (SB3 handoff). Surface must hold the 128×96×4 back-buffer.
    const surf_len: u64 = 128 * 96 * 4; // 49152 = exactly 12 pages
    const owner_va = dispatch(sys_mmap, .{ m33_surf_win_tag | wid, surf_len, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(owner_va >= 0x1000_0000);
    try std.testing.expect(driving_award.user_is_surface_backed(@intCast(wid)));
    const r = shared_region.info(1).?; // first kernel-issued handle
    try std.testing.expectEqual(@as(u64, owner_pid), r.owner_pid);
    try std.testing.expectEqual(@as(u32, 12), r.page_count); // window back-buffer
    const pa_base: u64 = r.pa_base;
    try std.testing.expect(pa_base != 0);

    // The owner's WRITABLE leaf maps the surface (no sw_cow).
    const owner_leaf = mmu.get_user_leaf(owner_root, owner_va).?.*;
    try std.testing.expectEqual(pa_base, owner_leaf & 0x0000_ffff_ffff_f000);
    try std.testing.expectEqual(@as(u64, 1), (owner_leaf >> 6) & 3); // EL0 RW
    try std.testing.expect((owner_leaf & mmu.sw_cow) == 0);

    // The window now reports the surface identity (composite's direct source).
    const surf = driving_award.user_surface(@intCast(wid)).?;
    try std.testing.expectEqual(@as(u32, 1), surf.handle);
    try std.testing.expectEqual(pa_base, surf.pa_base);

    // --- The WM's RO mirror was auto-granted: peer seat filled, maps the
    // SAME physical region EL0-RO sw_cow in the WM's OWN root.
    try std.testing.expectEqual(@as(u64, wm_pid), shared_region.info(1).?.peer_pid);
    const wm_va = shared_region.info(1).?.peer_va;
    const wm_leaf = mmu.get_user_leaf(wm_root, wm_va).?.*;
    try std.testing.expectEqual(pa_base, wm_leaf & 0x0000_ffff_ffff_f000); // SAME pages
    try std.testing.expectEqual(@as(u64, 3), (wm_leaf >> 6) & 3); // EL0 RO
    try std.testing.expect((wm_leaf & mmu.sw_cow) != 0);

    // The owner's leaf stays writable while the WM's is RO — independent
    // roots, one shared region (the composite + WM compose read the SAME pa).
    try std.testing.expect(mmu.get_user_leaf(owner_root, owner_va) != null);

    // --- OWNER re-attach by handle keeps its writable surface (D2 keep), and
    // a re-bind of the SAME window is EINVAL (one surface per window).
    try std.testing.expectEqual(owner_va, dispatch(sys_mmap, .{ 1, surf_len, 3, 0x20 | 0x10000, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ m33_surf_win_tag | wid, surf_len, 3, 0x20 | 0x10000, 0, 0 }, &frame));

    // --- Frozen fill/present/open unchanged for unmigrated ids: present on
    // the migrated window still returns 0 (it marks dirty), fill on an
    // unknown id is still EINVAL, and a migrated fill RO's the shared surface
    // in the same B8G8R8X8 encoding as the old path (same fill_rect; the byte
    // parity is exercised by the live VZ gate where real physical pages hold
    // the writes).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_win_present, .{ wid, 0, 0, 0, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_win_fill, .{ 99, 0, 0, 10, 10, 0 }, &frame));

    // Owner teardown: munmap the surface revokes the WM mirror (D2).
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_munmap, .{ owner_va, surf_len, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(mmu.unmap_user_page(wm_root, wm_va) == null); // peer leaf gone
    try std.testing.expect(shared_region.info(1) == null);

    // Cleanup: unregister the WM seat (see the sibling test's note).
    _ = wm_server.unregister(wm_pid);
}

test "syscall: M33 SB5 — the scanout grant is WM-only, full-frame, writable, idempotent, and tears down (claim 7397)" {
    mmu.reset();
    alloc.reset_refcounts();
    shared_region.reset();
    process.init();
    userspace.init();
    init(test_writer);
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    driving_award.arm();

    const map_desc = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 256, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&map_desc), @sizeOf(memmap.MemoryDescriptor), map_desc.len);
    try std.testing.expect(alloc.init(view, &.{}));

    const owner_root = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192).?;
    const wm_root = mmu.build_user_root(userspace.text_va, 0x3000, 64, userspace.stack_va, 0x4000, 8192).?;
    var kstack1: [scheduler.task_stack_size]u8 align(16) = undefined;
    var kstack2: [scheduler.task_stack_size]u8 align(16) = undefined;
    const owner_pid = process.create("APP.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = owner_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const wm_pid = process.create("WM.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = wm_root,
        .text_va = userspace.text_va,
        .text_len = 64,
        .stack_va = userspace.stack_va,
        .stack_len = 8192,
    }, .{}).?;
    const owner_task = scheduler.register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack1, 0, 0).?;
    const wm_task = scheduler.register_exec_user(userspace.text_va, 0x5000_0000, 100, 0x9000_0000, 8192, &kstack2, 0, 0).?;
    _ = process.bind(owner_pid, owner_task);
    _ = process.bind(wm_pid, wm_task);
    scheduler.start();

    var frame = fresh_frame();
    // Register the WM (the syscall seat check needs it) and fake a
    // framebuffer physical base — the test only inspects leaves, never the
    // pages themselves, so an out-of-the-way fake PA is safe.
    _ = wm_server.register(wm_pid);
    const fb_pa: u64 = 0x9000_0000;
    const saved_fb_phys = virtio_gpu.gpu_fb_phys;
    virtio_gpu.gpu_fb_phys = fb_pa;
    defer {
        virtio_gpu.gpu_fb_phys = saved_fb_phys;
        _ = wm_server.unregister(wm_pid);
    }
    const fb_len: u64 = virtio_gpu.fb_size;

    // --- A NON-WM process is refused EACCES (the seat is the privilege).
    var guard: usize = 0;
    while (scheduler.current_id() != owner_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(error_result(.eacces), dispatch(sys_mmap, .{ m33_surf_scan_tag, fb_len, 3, 0x20 | 0x10000, 0, 0 }, &frame));

    // --- The WM: wrong geometry refused (partial frame EINVAL; RO prot EINVAL).
    guard = 0;
    while (scheduler.current_id() != wm_task and guard < scheduler.max_tasks) : (guard += 1) {
        try std.testing.expect(scheduler.yield_current());
    }
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ m33_surf_scan_tag, fb_len - 4096, 3, 0x20 | 0x10000, 0, 0 }, &frame));
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_mmap, .{ m33_surf_scan_tag, fb_len, 1, 0x20 | 0x10000, 0, 0 }, &frame));

    // --- The WM binds the full framebuffer WRITABLE into ITS OWN root.
    const scan_va = dispatch(sys_mmap, .{ m33_surf_scan_tag, fb_len, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(scan_va >= 0x1000_0000);
    try std.testing.expect(wm_server.scanout_bound(wm_pid));
    // Each leaf aliases the GPU framebuffer's physical pages, EL0 RW, no sw_cow.
    {
        const leaf = mmu.get_user_leaf(wm_root, scan_va).?.*;
        try std.testing.expectEqual(fb_pa, leaf & 0x0000_ffff_ffff_f000);
        try std.testing.expectEqual(@as(u64, 1), (leaf >> 6) & 3); // EL0 RW
        try std.testing.expect((leaf & mmu.sw_cow) == 0);
        // The last page too (full-frame).
        const last_va = scan_va + (fb_len - 4096);
        const leaf_last = mmu.get_user_leaf(wm_root, last_va).?.*;
        try std.testing.expectEqual(fb_pa + fb_len - 4096, leaf_last & 0x0000_ffff_ffff_f000);
    }

    // --- Idempotent re-bind returns the SAME va (no second mapping).
    try std.testing.expectEqual(scan_va, dispatch(sys_mmap, .{ m33_surf_scan_tag, fb_len, 3, 0x20 | 0x10000, 0, 0 }, &frame));

    // --- The kernel did NOT ref-count the GPU pages (they are kernel-owned):
    // no dynamic page was recorded, so teardown must never unref them.
    // (probe: the mapped pa is NOT in the WM's dynamic list — the syscall
    // path records dynamic pages for OWNER surfaces only.)

    // --- Full-frame munmap unbinds: leaves unmapped WITHOUT unref.
    try std.testing.expectEqual(@as(u64, 0), dispatch(sys_munmap, .{ scan_va, fb_len, 0, 0, 0, 0 }, &frame));
    try std.testing.expect(!wm_server.scanout_bound(wm_pid));
    // The leaves were unmapped (probe: unmap finds no valid leaf anymore).
    try std.testing.expect(mmu.unmap_user_page(wm_root, scan_va) == null);
    // Re-bind (a fresh grant): a new va, full-frame only enforced again.
    const scan_va2 = dispatch(sys_mmap, .{ m33_surf_scan_tag, fb_len, 3, 0x20 | 0x10000, 0, 0 }, &frame);
    try std.testing.expect(scan_va2 >= 0x1000_0000);
    try std.testing.expect(scan_va2 != scan_va);
    // Partial munmap of the scanout is refused (full-frame only).
    try std.testing.expectEqual(error_result(.einval), dispatch(sys_munmap, .{ scan_va2, 4096, 0, 0, 0, 0 }, &frame));

    // --- WM unregister tears the grant down too (the exit path).
    try std.testing.expect(wm_server.scanout_bound(wm_pid));
    _ = wm_server.unregister(wm_pid);
    try std.testing.expect(!wm_server.scanout_bound(wm_pid));
    try std.testing.expect(mmu.unmap_user_page(wm_root, scan_va2) == null);
    // The user layer ownership went back to the kernel shim.
    try std.testing.expect(!driving_award.wm_owns_user_layer);
}
