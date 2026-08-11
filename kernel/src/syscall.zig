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

const std = @import("std");
const console = @import("console.zig");
const exceptions = @import("exceptions.zig");
const mailbox = @import("mailbox.zig"); // claim 5965: per-process rings
const process = @import("process.zig"); // claim 5965: target/current-process lookup
const scheduler = @import("scheduler.zig");
const uaccess = @import("uaccess.zig"); // claim 6120: fault-safe copy-in
const userspace = @import("userspace.zig");

pub const slot_count: usize = 64;
pub const implemented_count: usize = 9;
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

pub const ErrorCode = enum(i64) {
    einval = -1,
    ebadf = -2,
    efault = -3,
    enosys = -4,
    /// Card 3f (claim 5965): the target process's mailbox is full — the
    /// bounded 8 × 64 B ring refused the send (card 4b, claim 3179: the
    /// capacity is a data-path constant, raised 4 → 8; never unbounded,
    /// never silently dropped).
    enospc = -5,
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
/// Card 4a (claim 5799): fixed BSS scratch for the process snapshot —
/// `max_processes` rows × 40 bytes, marshaled per call, no allocation.
var procs_scratch: [process.max_processes * process.snapshot_row_bytes]u8 = undefined;

/// Initialize the writer seam, reset counters and the uaccess regions. The
/// table remains a runtime-built BSS object; rebuilding is unnecessary once
/// its PC-relative addresses have been materialized at the current image
/// base.
pub fn init(writer: Writer) void {
    write_fn = writer;
    @memset(&call_counts, 0);
    uaccess.init();
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
    return handler(args, frame);
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

/// Deterministic monitor output for the nine implemented rows and their counters.
pub fn report(con: *console.Console) void {
    con.puts("syscalls: slots=64 implemented=9\n");
    var number: u64 = 0;
    while (number < implemented_count) : (number += 1) {
        const info = entry_info(number).?;
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

test "syscall: runtime table has 64 slots and nine unique implemented rows" {
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
    try std.testing.expectEqual(@as(usize, 9), implemented);
    try std.testing.expectEqualStrings("sys_ping", entry_info(0).?.name);
    try std.testing.expectEqualStrings("sys_exit", entry_info(3).?.name);
    try std.testing.expectEqualStrings("sys_sleep", entry_info(4).?.name);
    try std.testing.expectEqualStrings("sys_ipc_send", entry_info(5).?.name);
    try std.testing.expectEqualStrings("sys_ipc_recv", entry_info(6).?.name);
    try std.testing.expectEqualStrings("sys_procs", entry_info(7).?.name);
    try std.testing.expectEqualStrings("sys_wait", entry_info(8).?.name);
    try std.testing.expect(entry_info(9) == null);
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

test "syscall: counters are monotonic and report is deterministic" {
    userspace.init();
    init(test_writer);
    var frame = fresh_frame();
    _ = dispatch(sys_ping, .{ 9, 0, 0, 0, 0, 0 }, &frame);
    _ = dispatch(sys_ping, .{ 10, 0, 0, 0, 0, 0 }, &frame);
    try std.testing.expectEqual(@as(u64, 2), call_count(sys_ping));
    var mock = console.MockConsole(512){};
    var con = mock.console();
    report(&con);
    try std.testing.expectEqualStrings(
        "syscalls: slots=64 implemented=9\n" ++
            "  0 sys_ping calls=2\n" ++
            "  1 sys_write calls=0\n" ++
            "  2 sys_yield calls=0\n" ++
            "  3 sys_exit calls=0\n" ++
            "  4 sys_sleep calls=0\n" ++
            "  5 sys_ipc_send calls=0\n" ++
            "  6 sys_ipc_recv calls=0\n" ++
            "  7 sys_procs calls=0\n" ++
            "  8 sys_wait calls=0\n",
        mock.contents(),
    );
}
