//! DipshitOS process abstraction (milestone four, card 3 — claim 3848).
//!
//! The task pool (scheduler.zig) is the EXECUTOR: context, TTBR0 switch,
//! quantum bookkeeping, zombie/reap. This module is the unit that owns the
//! PROGRAM — the loaded image, the address space it runs in, its lifecycle
//! state, and its exit status. A fixed BSS registry, no allocation:
//! `max_processes` descriptors recycle like the pool slots do.
//!
//! What the process adds over the task:
//!   * The image descriptor (entry VA + content length) and the address
//!     space (root phys, text/stack VAs) travel WITH the process instead of
//!     living in exec's module globals.
//!   * The exit status is snapshotted at exit time and survives the task
//!     slot's reap — `procs` (and the exit report) can still show why a
//!     program died after the idle task freed its executor.
//!   * Per-process identity: every `exec` creates a NEW process descriptor,
//!     so `loaded()` and the table never hold a stale "last program".
//!   * The boot-time static EL0 payload registers as a process too, so one
//!     table shows both the payload's and the exec'd program's lifecycles.
//!
//! Lifecycle: free -> created (loaded, not yet bound) -> running (bound to
//! a live task) -> exited (the bound task became a zombie; status kept) ->
//! free (reaped). `create` takes the first free slot; when the registry is
//! full it recycles the OLDEST exited process (never a created/running
//! one). The scheduler's `exit_current` notifies this module (pure writes,
//! exception-context safe — the same report-pending pattern as the task
//! exit report); the shell idle loop drains the report via
//! `take_exit_report`.
//!
//! No libc, no POSIX, no allocation, no scheduler import (the dependency
//! is one-way: scheduler -> process).

const std = @import("std");
const alloc = @import("alloc.zig"); // claim 0826: the process owns its pages (text/stack/kernel-stack) from the physical allocator
const memmap = @import("memmap.zig"); // host-test fixture view (page-ownership tests arm the allocator)

/// Bounded process registry size (fixed BSS array). Milestone sixteen C3
/// (claim 0339): grew 8 -> 16 — at the new 8-program concurrency the
/// registry saturated at 8/8 (the boot payload's exited slot recycled, no
/// headroom), and "8+ apps on the desktop" (desktop launcher + 8 apps)
/// needs room for nine live processes plus exited history before the
/// oldest exited descriptor is recycled.
pub const max_processes: usize = 16;
/// Process-name buffer bound (the FAT 8.3 file name or a task-style name
/// like "user-el0").
pub const name_max: usize = 16;

/// Explicit process lifecycle state (claim 3848 — the process-level mirror
/// of scheduler.State). A descriptor's state is the ONLY ownership signal:
/// `created` is loaded-but-unbound, `running` is bound to a live task slot,
/// `exited` keeps its status until reaped or recycled.
pub const State = enum {
    free,
    created,
    running,
    exited,
};

/// Human-readable state label for `procs` / tests.
pub fn state_name(state: State) []const u8 {
    return switch (state) {
        .free => "free",
        .created => "created",
        .running => "running",
        .exited => "exited",
    };
}

/// The loaded program's image descriptor (the part of the DSK1 file that
/// executes at EL0).
pub const Image = struct {
    /// User VA the process enters at.
    entry_va: u64 = 0,
    /// Content bytes (image minus the DSK1 header).
    content_len: u64 = 0,
};

/// The address space a process runs in (what its TTBR0 user root maps).
/// Claim 0826: the process OWNS the backing pages for exec'd programs —
/// the allocator-backed text/user-stack phys + page counts (0 counts = the
/// backing is static, e.g. the boot payload's `.usertext`/`.userbss`,
/// which is never freed).
pub const AddrSpace = struct {
    /// Physical root of the task's user TTBR0 tables.
    root_phys: u64 = 0,
    /// User VA + length of the mapped text (W^X, EL0-executable).
    text_va: u64 = 0,
    text_len: u64 = 0,
    /// Physical text pages the process owns (allocator-backed; 0 = static).
    text_phys: u64 = 0,
    text_pages: u64 = 0,
    /// User VA + length of the mapped DATA region (EL0 RW, non-executable
    /// — the segmented image's `.data` + zeroed `.bss`, claim 3805).
    data_va: u64 = 0,
    data_len: u64 = 0,
    /// Physical data+bss pages the process owns (allocator-backed;
    /// 0 = no data segment / static).
    data_phys: u64 = 0,
    data_pages: u64 = 0,
    /// User VA + length of the mapped stack (EL0 RW, non-executable).
    stack_va: u64 = 0,
    stack_len: u64 = 0,
    /// Physical user-stack pages the process owns (allocator-backed;
    /// 0 = static `.userbss`).
    stack_phys: u64 = 0,
    stack_pages: u64 = 0,
};

/// Kernel-side resources the process owns with its program (freed at
/// reap/recycle like the address-space pages): the executor task's EL1
/// exception stack. Claim 0826: two live EL0t tasks cannot share ONE
/// static `user_kernel_stack` — a second task's exception frame would
/// clobber the first task's saved vector frame — so every exec'd process
/// allocates its own 8 KiB EL1 stack. 0 pages = the static boot stack.
pub const KernelStack = struct {
    phys: u64 = 0,
    pages: u64 = 0,
};

const Process = struct {
    /// Owned copy of the program's name (the FAT file name for exec'd
    /// programs, "user-el0" for the boot static payload) — the caller's
    /// slice (e.g. the monitor's token buffer) does not outlive the call.
    name_buf: [name_max]u8 = [_]u8{0} ** name_max,
    name_len: usize = 0,
    state: State = .free,
    image: Image = .{},
    addr_space: AddrSpace = .{},
    /// Claim 0826: the executor's EL1 exception stack (allocator-backed
    /// for exec'd programs, the static boot stack for the payload).
    kernel_stack: KernelStack = .{},
    /// The pool slot currently executing this process; null once exited
    /// AND the executor slot has been reaped (the lifecycle reap reads it
    /// to free the exited process's owned pages, claim 4613). Before the
    /// reap, an exited process still names its last executor slot — the
    /// `procs` command prints `task=reaped` for exited rows regardless.
    task_id: ?usize = null,
    /// Exit status, snapshotted at exit so it survives the task reap.
    exit_status: u64 = 0,
    /// Arc5 issue #246: per-process resource limits.
    /// mem_limit: max pages (0 = unlimited). cpu_limit: max ticks (0 = unlimited).
    /// mem_usage: current page count (text + data + stack). cpu_usage: tick counter.
    mem_limit: u64 = 0,
    cpu_limit: u64 = 0,
    mem_usage: u64 = 0,
    cpu_usage: u64 = 0,
};

var processes: [max_processes]Process = [_]Process{.{}} ** max_processes;
var registry_count: usize = 0;
/// The most recently created process (the "current" program — what
/// `exec.loaded()` reports).
var current_id: ?usize = null;
/// Card 3d (claim 1014): the process exit reports are a bounded FIFO, not
/// a single first-wins flag — N exits in one idle-loop window produce N
/// `procs <name> exited status=N` lines IN ORDER instead of collapsing to
/// one. The name is snapshotted at exit (the descriptor may be recycled
/// before the shell prints it). Overflow (a full ring) drops the OLDEST
/// entry to admit the newest — documented and host-tested.
pub const exit_report_max: usize = 4;
var exit_report_names: [exit_report_max][name_max]u8 = [_][name_max]u8{[_]u8{0} ** name_max} ** exit_report_max;
var exit_report_lens: [exit_report_max]usize = [_]usize{0} ** exit_report_max;
var exit_report_statuses: [exit_report_max]u64 = [_]u64{0} ** exit_report_max;
var exit_report_head: usize = 0;
var exit_report_count: usize = 0;

/// Reset the registry (boot + host tests; called by `scheduler.init` so
/// every pool reset also clears the process layer).
pub fn init() void {
    for (&processes) |*p| p.* = .{};
    registry_count = 0;
    current_id = null;
    exit_report_head = 0;
    exit_report_count = 0;
}

/// Free the allocator-backed pages a process's address space + kernel
/// stack own (no-op for the static boot payload's pages and when the
/// allocator is unarmed — host tests). Only ever called for a non-live
/// process (reap / recycle of `exited`/`created`), so a running program's
/// pages are never freed under it. Claim 4613: also called at the task-
/// level reap (`release_pages_on_reap`) — the freed page fields are
/// zeroed there so a later `release_resources` is a no-op.
fn release_resources(p: *Process) void {
    if (p.addr_space.text_pages > 0) _ = alloc.free_pages(p.addr_space.text_phys, p.addr_space.text_pages);
    if (p.addr_space.data_pages > 0) _ = alloc.free_pages(p.addr_space.data_phys, p.addr_space.data_pages);
    if (p.addr_space.stack_pages > 0) _ = alloc.free_pages(p.addr_space.stack_phys, p.addr_space.stack_pages);
    if (p.kernel_stack.pages > 0) _ = alloc.free_pages(p.kernel_stack.phys, p.kernel_stack.pages);
}

/// Create a process for a loaded program: `name` is copied into the
/// descriptor (the caller's slice need not outlive the call); `addr_space`
/// and `kernel_stack` record the pages the process owns. Takes the first
/// free slot; when the registry is full, recycles the OLDEST exited
/// process (never a created/running one) and frees its owned pages.
/// Returns null only when every slot holds a live (created/running)
/// process.
pub fn create(
    name: []const u8,
    image: Image,
    addr_space: AddrSpace,
    kernel_stack: KernelStack,
) ?usize {
    var id: usize = 0;
    var oldest_exited: ?usize = null;
    while (id < max_processes) : (id += 1) {
        if (processes[id].state == .free) break;
        if (processes[id].state == .exited and oldest_exited == null) oldest_exited = id;
    }
    if (id >= max_processes) {
        // Registry full: recycle the oldest exited descriptor (never a
        // live process — a live one still owns its program). Its
        // allocator-backed pages are freed with it.
        const recycled = oldest_exited orelse return null;
        release_resources(&processes[recycled]);
        processes[recycled] = .{};
        registry_count -%= 1;
        id = recycled;
    }
    const take = @min(name.len, name_max);
    @memcpy(processes[id].name_buf[0..take], name[0..take]);
    processes[id].name_len = take;
    processes[id].image = image;
    processes[id].addr_space = addr_space;
    processes[id].kernel_stack = kernel_stack;
    processes[id].state = .created;
    registry_count +%= 1;
    current_id = id;
    return id;
}

/// Bind a created process to its executor task slot (state -> running).
/// Returns false for an invalid id or a process that is not `created`.
pub fn bind(id: usize, task_id: usize) bool {
    if (id >= max_processes or processes[id].state != .created) return false;
    processes[id].state = .running;
    processes[id].task_id = task_id;
    return true;
}

/// Free a process descriptor. Only a non-running process may be reaped:
/// `created` (the exec rollback path — spawn failed after create) or
/// `exited` (the lifecycle reap / registry recycle). Returns false for an
/// invalid id or a live (running) process. The process's allocator-backed
/// pages (text/stack/kernel-stack) are freed with it.
pub fn reap(id: usize) bool {
    if (id >= max_processes) return false;
    if (processes[id].state == .free or processes[id].state == .running) return false;
    if (current_id == id) current_id = null;
    release_resources(&processes[id]);
    processes[id] = .{};
    registry_count -%= 1;
    return true;
}

/// Notify the registry that the task in slot `task_id` exited with
/// `status` (called from the scheduler's `exit_current` — exception
/// context, so this must stay console-free and allocation-free): the bound
/// process becomes `exited`, snapshots its status, and marks the exit
/// report pending (first one wins while undrained). Claim 4613: the
/// binding to the executor slot is KEPT until the lifecycle reap frees the
/// exited process's pages (`release_pages_on_reap`), so a `procs` read
/// between exit and reap still shows the executor slot as `task=reaped`.
/// A no-op (returns null) when no process is bound to that slot (kernel
/// demo tasks never exit; user programs do). Card 4c (claim 9946): the
/// returned pid lets the scheduler's exit path wake every task blocked in
/// `sys_wait` on this process.
pub fn on_task_exit(task_id: usize, status: u64) ?usize {
    var id: usize = 0;
    while (id < max_processes) : (id += 1) {
        if (processes[id].state != .running) continue;
        if (processes[id].task_id != task_id) continue;
        processes[id].state = .exited;
        processes[id].exit_status = status;
        // Claim 4613: keep the executor slot on the exited process so the
        // lifecycle reap can find it and free its owned pages (the slot
        // itself is a zombie until the idle task reaps it). Cleared by
        // `release_pages_on_reap`.
        // Card 3d (claim 1014): EVERY exit is queued — two exits in one
        // idle-loop window print as two lines in order (the old
        // first-wins-while-undrained flag collapsed them). A full ring
        // drops the oldest to admit the newest.
        push_exit_report(processes[id].name_buf[0..processes[id].name_len], status);
        return id;
    }
    return null;
}

/// Free the allocator-backed pages of the exited process that last ran on
/// executor slot `task_id` — called by the scheduler's idle-task reap
/// (claim 4613): the program is dead and its executor slot is being
/// recycled, so its text/stack/exception-stack pages return to the
/// physical allocator NOW, while the exited descriptor (name, status,
/// stack VA) STAYS in the `procs` table for the claim-3848 exit record.
/// The page fields are zeroed so a later registry recycle's
/// `release_resources` is a no-op. Returns false when no exited process
/// is bound to that slot (already reaped, or the descriptor was recycled
/// by `create`).
pub fn release_pages_on_reap(task_id: usize) bool {
    var id: usize = 0;
    while (id < max_processes) : (id += 1) {
        if (processes[id].state != .exited) continue;
        if (processes[id].task_id != task_id) continue;
        release_resources(&processes[id]);
        processes[id].addr_space.text_phys = 0;
        processes[id].addr_space.text_pages = 0;
        processes[id].addr_space.data_phys = 0;
        processes[id].addr_space.data_pages = 0;
        processes[id].addr_space.stack_phys = 0;
        processes[id].addr_space.stack_pages = 0;
        processes[id].kernel_stack = .{};
        processes[id].task_id = null;
        return true;
    }
    return false;
}

/// The most recently created process id (what `exec.loaded()` reports);
/// null before any process exists.
pub fn current() ?usize {
    return current_id;
}

/// The process currently bound to pool slot `task_id`, if any.
pub fn find_by_task(task_id: usize) ?usize {
    var id: usize = 0;
    while (id < max_processes) : (id += 1) {
        if (processes[id].state != .running) continue;
        if (processes[id].task_id == task_id) return id;
    }
    return null;
}

/// Non-free descriptor count.
pub fn count() usize {
    return registry_count;
}

/// A copy of a process descriptor's public view (the name slice points at
/// the registry's owned buffer and stays valid until the process is
/// reaped).
pub const ProcessInfo = struct {
    id: usize,
    name: []const u8,
    state: State,
    task_id: ?usize,
    entry_va: u64,
    content_len: u64,
    root_phys: u64,
    text_phys: u64,
    text_pages: u64,
    data_va: u64,
    data_len: u64,
    data_phys: u64,
    data_pages: u64,
    stack_va: u64,
    stack_len: u64,
    stack_phys: u64,
    stack_pages: u64,
    kernel_stack_phys: u64,
    kernel_stack_pages: u64,
    exit_status: u64,
    /// Arc5 #246 usage counter (scheduler tick increments; M22 D6 exposes
    /// it in the ps table's CPU column).
    cpu_usage: u64 = 0,
};

// ---------------------------------------------------------------------------
// Card 4a (claim 5799): the bounded EL0-readable process snapshot
// ---------------------------------------------------------------------------

/// Fixed width of one snapshot row (40 bytes): `u64 pid` (LE) at 0, `u64`
/// state code at 8 (the `State` enum value: 1=created, 2=running,
/// 3=exited), `u64 exit_status` at 16 (0 unless exited), `name` (16 bytes,
/// NUL-padded — the `name_max` bound) at 24. Fixed width is what makes
/// `sys_procs`'s `max`-byte truncation honest: `max` floors to WHOLE rows.
pub const snapshot_row_bytes: usize = 40;
/// The name field's width inside a row (the registry's `name_max`).
pub const snapshot_name_bytes: usize = name_max;

/// Marshal every NON-FREE descriptor (created/running/exited — free rows
/// are skipped) into `dst` as fixed-width rows, in id order. Returns the
/// row count. The caller (the syscall layer) passes a fixed BSS scratch of
/// at least `max_processes * snapshot_row_bytes` bytes — no allocation
/// anywhere. The exit status column is only meaningful for exited rows
/// (the status is snapshotted at exit and survives the reap — claim
/// 3848), so an EL0 reader can tell a live peer from a dead one.
pub fn snapshot(dst: []u8) usize {
    var rows: usize = 0;
    var id: usize = 0;
    while (id < max_processes) : (id += 1) {
        if (processes[id].state == .free) continue;
        const row = dst[rows * snapshot_row_bytes ..][0..snapshot_row_bytes];
        std.mem.writeInt(u64, row[0..8], id, .little);
        std.mem.writeInt(u64, row[8..16], @intFromEnum(processes[id].state), .little);
        std.mem.writeInt(u64, row[16..24], processes[id].exit_status, .little);
        @memset(row[24..snapshot_row_bytes], 0);
        const take = @min(processes[id].name_len, snapshot_name_bytes);
        const name_start: usize = 24;
        const name_end: usize = name_start + take;
        @memcpy(row[name_start..name_end], processes[id].name_buf[0..take]);
        rows += 1;
    }
    return rows;
}

pub fn info(id: usize) ?ProcessInfo {
    if (id >= max_processes or processes[id].state == .free) return null;
    const p = &processes[id];
    return .{
        .id = id,
        .name = p.name_buf[0..p.name_len],
        .state = p.state,
        .task_id = p.task_id,
        .entry_va = p.image.entry_va,
        .content_len = p.image.content_len,
        .root_phys = p.addr_space.root_phys,
        .text_phys = p.addr_space.text_phys,
        .text_pages = p.addr_space.text_pages,
        .data_va = p.addr_space.data_va,
        .data_len = p.addr_space.data_len,
        .data_phys = p.addr_space.data_phys,
        .data_pages = p.addr_space.data_pages,
        .stack_va = p.addr_space.stack_va,
        .stack_len = p.addr_space.stack_len,
        .stack_phys = p.addr_space.stack_phys,
        .stack_pages = p.addr_space.stack_pages,
        .kernel_stack_phys = p.kernel_stack.phys,
        .kernel_stack_pages = p.kernel_stack.pages,
        .exit_status = p.exit_status,
        .cpu_usage = p.cpu_usage,
    };
}

/// The pending process exit reports, drained IN ORDER by the shell idle
/// loop (which prints `procs <name> exited status=<n>` per entry). Returns
/// null when nothing is pending.
pub const ExitReport = struct {
    name: []const u8,
    status: u64,
};

/// Queue one exit report (exception/idle context — pure BSS writes).
/// Overflow drops the OLDEST entry (documented + host-tested).
fn push_exit_report(name: []const u8, status: u64) void {
    if (exit_report_count == exit_report_max) {
        exit_report_head = (exit_report_head + 1) % exit_report_max;
        exit_report_count -= 1;
    }
    const index = (exit_report_head + exit_report_count) % exit_report_max;
    const take = @min(name.len, name_max);
    @memcpy(exit_report_names[index][0..take], name[0..take]);
    exit_report_lens[index] = take;
    exit_report_statuses[index] = status;
    exit_report_count += 1;
}

pub fn take_exit_report() ?ExitReport {
    if (exit_report_count == 0) return null;
    const index = exit_report_head;
    exit_report_head = (exit_report_head + 1) % exit_report_max;
    exit_report_count -= 1;
    return .{
        .name = exit_report_names[index][0..exit_report_lens[index]],
        .status = exit_report_statuses[index],
    };
}

// ---------------------------------------------------------------------------
// Arc5 issue #246: per-process resource limits
// ---------------------------------------------------------------------------

/// Set a per-process resource limit. type 0 = memory pages, type 1 = CPU ticks.
/// Returns true on success, false on invalid type or process not found.
pub fn setrlimit(id: usize, rtype: u64, value: u64) bool {
    if (id >= max_processes or processes[id].state == .free) return false;
    const p = &processes[id];
    switch (rtype) {
        0 => p.mem_limit = value,
        1 => p.cpu_limit = value,
        else => return false,
    }
    return true;
}

/// Get current resource usage for a process. Returns total pages and cpu ticks.
pub fn getrusage(id: usize) ?struct { mem_usage: u64, cpu_usage: u64, mem_limit: u64, cpu_limit: u64 } {
    if (id >= max_processes or processes[id].state == .free) return null;
    const p = &processes[id];
    return .{
        .mem_usage = p.mem_usage,
        .cpu_usage = p.cpu_usage,
        .mem_limit = p.mem_limit,
        .cpu_limit = p.cpu_limit,
    };
}

/// Update memory usage for a process (called when pages are mapped/unmapped).
pub fn update_mem_usage(id: usize, delta: u64) void {
    if (id >= max_processes or processes[id].state == .free) return;
    if (delta > 0) {
        processes[id].mem_usage +%= delta;
    } else {
        const abs = -delta;
        if (abs >= processes[id].mem_usage) {
            processes[id].mem_usage = 0;
        } else {
            processes[id].mem_usage -= abs;
        }
    }
}

/// Increment CPU tick counter for a process. Returns true if the limit is exceeded.
pub fn inc_cpu_ticks(id: usize) bool {
    if (id >= max_processes or processes[id].state == .free) return false;
    const p = &processes[id];
    p.cpu_usage += 1;
    if (p.cpu_limit != 0 and p.cpu_usage > p.cpu_limit) return true;
    return false;
}

/// Check if a process exceeds its memory limit. Returns true if exceeded.
pub fn check_mem_limit(id: usize) bool {
    if (id >= max_processes or processes[id].state == .free) return false;
    const p = &processes[id];
    if (p.mem_limit != 0 and p.mem_usage > p.mem_limit) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Tests (host-side; the live lifecycle is proven on real VZ hardware by
// tools/verify-live-procs.sh, class B)
// ---------------------------------------------------------------------------

test "process: init starts empty and create binds a full descriptor" {
    init();
    try std.testing.expectEqual(@as(usize, 0), count());
    try std.testing.expect(current() == null);
    const id = create("USER.BIN", .{ .entry_va = 0x400000, .content_len = 0xea }, .{
        .root_phys = 0x1234_0000,
        .text_va = 0x400000,
        .text_len = 0xea,
        .stack_va = 0x1a400000,
        .stack_len = 8192,
    }, .{}).?;
    try std.testing.expectEqual(@as(usize, 0), id);
    try std.testing.expectEqual(@as(usize, 1), count());
    try std.testing.expectEqual(@as(?usize, 0), current());
    const info0 = info(id).?;
    try std.testing.expectEqualStrings("USER.BIN", info0.name);
    try std.testing.expectEqual(State.created, info0.state);
    try std.testing.expectEqual(@as(u64, 0x400000), info0.entry_va);
    try std.testing.expectEqual(@as(u64, 0xea), info0.content_len);
    try std.testing.expectEqual(@as(u64, 0x1234_0000), info0.root_phys);
    try std.testing.expectEqual(@as(u64, 0x1a400000), info0.stack_va);
    try std.testing.expect(info0.task_id == null);
    try std.testing.expectEqual(@as(u64, 0), info0.exit_status);
    // The name is OWNED: a caller slice does not outlive the call.
    const short = "A";
    _ = create(short, .{}, .{}, .{});
    try std.testing.expectEqualStrings("A", info(1).?.name);
}

test "process: lifecycle created -> running -> exited -> reaped" {
    init();
    const id = create("USER.BIN", .{ .entry_va = 0x400000, .content_len = 0xea }, .{}, .{}).?;
    // A created process cannot be reaped from running (no binding yet)...
    // bind it to executor slot 2 and run.
    try std.testing.expect(bind(id, 2));
    try std.testing.expectEqual(State.running, info(id).?.state);
    try std.testing.expectEqual(@as(?usize, 2), info(id).?.task_id);
    // bind again is rejected (not created anymore).
    try std.testing.expect(!bind(id, 3));
    // A running process cannot be reaped.
    try std.testing.expect(!reap(id));
    // The executor task exits with status 43: the process snapshots it.
    _ = on_task_exit(2, 43);
    try std.testing.expectEqual(State.exited, info(id).?.state);
    try std.testing.expectEqual(@as(u64, 43), info(id).?.exit_status);
    // Claim 4613: the exited process keeps its executor slot until the
    // lifecycle reap frees its pages (the procs row prints task=reaped).
    try std.testing.expectEqual(@as(?usize, 2), info(id).?.task_id);
    // The report is pending and drains exactly once.
    const r = take_exit_report().?;
    try std.testing.expectEqualStrings("USER.BIN", r.name);
    try std.testing.expectEqual(@as(u64, 43), r.status);
    try std.testing.expect(take_exit_report() == null);
    // Reap frees the exited descriptor.
    try std.testing.expect(reap(id));
    try std.testing.expect(info(id) == null);
    try std.testing.expectEqual(@as(usize, 0), count());
}

test "process: exit status survives the executor task's reuse" {
    init();
    const p0 = create("BOOTED", .{ .entry_va = 0x400000, .content_len = 1 }, .{}, .{}).?;
    _ = bind(p0, 2);
    // The executor exits (status 7) and its slot is REUSED by another
    // task — but the process keeps the status.
    _ = on_task_exit(2, 7);
    _ = take_exit_report();
    try std.testing.expectEqual(@as(u64, 7), info(p0).?.exit_status);
    try std.testing.expectEqual(State.exited, info(p0).?.state);
    // A second exec creates a NEW process (per-process identity), not a
    // mutated "last program".
    const p1 = create("USER.BIN", .{ .entry_va = 0x400000, .content_len = 0xea }, .{}, .{}).?;
    try std.testing.expectEqual(@as(usize, 1), p1);
    try std.testing.expectEqualStrings("USER.BIN", info(p1).?.name);
    // The old process still reports its own exit status.
    try std.testing.expectEqual(@as(u64, 7), info(p0).?.exit_status);
    try std.testing.expectEqual(@as(?usize, 1), current());
}

test "process: bounded registry recycles the oldest exited, never a live one" {
    init();
    // Fill the registry: 8 created processes.
    var ids: [max_processes]usize = undefined;
    var i: usize = 0;
    while (i < max_processes) : (i += 1) {
        ids[i] = create("P", .{ .entry_va = @intCast(i), .content_len = 1 }, .{}, .{}).?;
    }
    try std.testing.expectEqual(@as(usize, max_processes), count());
    // All live (created) -> the 9th create fails.
    try std.testing.expect(create("FULL", .{}, .{}, .{}) == null);
    // Exit the OLDEST (id 0): now the next create recycles it.
    _ = bind(ids[0], 9);
    _ = on_task_exit(9, 1);
    _ = take_exit_report();
    const recycled = create("NEW", .{}, .{}, .{}).?;
    try std.testing.expectEqual(@as(usize, 0), recycled); // the oldest exited
    try std.testing.expectEqualStrings("NEW", info(0).?.name);
    try std.testing.expectEqual(@as(usize, max_processes), count());
    // A running process is never recycled.
    _ = bind(ids[1], 10);
    _ = create("RUNNING-KEPT", .{}, .{}, .{});
    try std.testing.expectEqualStrings("P", info(ids[1]).?.name);
}

test "process: on_task_exit is a no-op for unbound slots and find_by_task" {
    init();
    try std.testing.expect(find_by_task(2) == null);
    _ = on_task_exit(2, 9); // no process bound -> no report, no crash
    try std.testing.expect(take_exit_report() == null);
    const id = create("USER.BIN", .{}, .{}, .{}).?;
    try std.testing.expect(find_by_task(2) == null); // not yet bound
    _ = bind(id, 5);
    try std.testing.expectEqual(@as(?usize, id), find_by_task(5));
    try std.testing.expect(find_by_task(6) == null);
    _ = on_task_exit(6, 1); // wrong slot -> no-op
    try std.testing.expectEqual(State.running, info(id).?.state);
    _ = on_task_exit(5, 42);
    try std.testing.expectEqual(State.exited, info(id).?.state);
}

test "process: reap guards and name truncation" {
    init();
    // Over-long names are truncated to the owned buffer.
    const id = create("A VERY LONG PROGRAM NAME", .{}, .{}, .{}).?;
    try std.testing.expect(info(id).?.name.len <= name_max);
    // reaping an invalid id / a running process fails.
    try std.testing.expect(!reap(max_processes));
    _ = bind(id, 1);
    try std.testing.expect(!reap(id));
    // reaping a created (unbound) process is allowed (exec's rollback).
    const id2 = create("ROLLBACK", .{}, .{}, .{}).?;
    try std.testing.expectEqual(State.created, info(id2).?.state);
    try std.testing.expect(reap(id2));
    try std.testing.expect(info(id2) == null);
}

test "process: allocator-backed resources are freed at reap and recycle" {
    // Arm the module allocator with a small fixture map so page ownership
    // is real on the host (the exec path arms it the same way).
    const descriptors = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 512, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&descriptors), @sizeOf(memmap.MemoryDescriptor), descriptors.len);
    try std.testing.expect(alloc.init(view, &.{}));
    const free_before = alloc.stats().free_pages;
    init();
    // An exec'd process owns its text + user-stack + kernel-stack pages.
    const text_phys = alloc.alloc_pages(1).?;
    const stack_phys = alloc.alloc_pages(2).?;
    const kstack_phys = alloc.alloc_pages(2).?;
    const id = create("USER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = 0x1234_0000,
        .text_va = 0x400000,
        .text_len = 64,
        .text_phys = text_phys,
        .text_pages = 1,
        .stack_va = 0x1a400000,
        .stack_len = 8192,
        .stack_phys = stack_phys,
        .stack_pages = 2,
    }, .{ .phys = kstack_phys, .pages = 2 }).?;
    const pinfo = info(id).?;
    try std.testing.expectEqual(text_phys, pinfo.text_phys);
    try std.testing.expectEqual(@as(u64, 1), pinfo.text_pages);
    try std.testing.expectEqual(stack_phys, pinfo.stack_phys);
    try std.testing.expectEqual(@as(u64, 2), pinfo.stack_pages);
    try std.testing.expectEqual(kstack_phys, pinfo.kernel_stack_phys);
    try std.testing.expectEqual(@as(u64, 2), pinfo.kernel_stack_pages);
    // Exit then reap: the owned pages return to the pool.
    _ = bind(id, 1);
    _ = on_task_exit(1, 3);
    _ = take_exit_report();
    try std.testing.expect(reap(id));
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);
    // The create-recycle path frees the recycled process's pages too. The
    // registry must be FULL (only then does create recycle the oldest
    // exited), so fill all 8 slots with page-owning processes.
    init();
    var ids: [max_processes]usize = undefined;
    for (0..max_processes) |i| {
        ids[i] = create("P", .{}, .{ .text_phys = alloc.alloc_pages(1).?, .text_pages = 1 }, .{}).?;
    }
    // All live (created) -> no free slot and nothing exited: create fails.
    try std.testing.expect(create("FULL", .{}, .{}, .{}) == null);
    // Exit the OLDEST (id 0): its page stays allocated (exited, not yet
    // recycled). The next create recycles it and frees the page.
    _ = bind(ids[0], 9);
    _ = on_task_exit(9, 1);
    _ = take_exit_report();
    const free_after_exit = alloc.stats().free_pages;
    const recycled = create("NEW", .{}, .{}, .{}).?;
    try std.testing.expectEqual(@as(usize, 0), recycled); // the oldest exited
    try std.testing.expectEqual(free_after_exit + 1, alloc.stats().free_pages); // its page came back
    // A live (created) slot is never recycled.
    _ = bind(ids[1], 10);
    try std.testing.expectEqualStrings("P", info(ids[1]).?.name);
}

test "process: exited pages return at the lifecycle reap; the procs row stays" {
    // Arm the module allocator with a small fixture map so page ownership
    // is real on the host (the exec path arms it the same way).
    const descriptors = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 512, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&descriptors), @sizeOf(memmap.MemoryDescriptor), descriptors.len);
    try std.testing.expect(alloc.init(view, &.{}));
    const free_before = alloc.stats().free_pages;
    init();
    // An exec'd program owns 5 pages (1 text + 2 user stack + 2 EL1 stack).
    const id = create("USER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = 0x1234_0000,
        .text_va = 0x400000,
        .text_len = 64,
        .text_phys = alloc.alloc_pages(1).?,
        .text_pages = 1,
        .stack_va = 0x1a400000,
        .stack_len = 8192,
        .stack_phys = alloc.alloc_pages(2).?,
        .stack_pages = 2,
    }, .{ .phys = alloc.alloc_pages(2).?, .pages = 2 }).?;
    _ = bind(id, 3);
    // The task exits (status 43): the process becomes exited and STILL
    // names its executor slot (claim 4613 — the lifecycle reap must be
    // able to find it to free the pages).
    _ = on_task_exit(3, 43);
    _ = take_exit_report();
    try std.testing.expectEqual(State.exited, info(id).?.state);
    try std.testing.expectEqual(@as(?usize, 3), info(id).?.task_id);
    // No page is freed yet: the exited process holds its memory until the
    // scheduler's reap releases it (the procs row keeps the exit record).
    try std.testing.expectEqual(free_before - 5, alloc.stats().free_pages);
    // The lifecycle reap (scheduler.reap -> release_pages_on_reap) frees
    // the exited process's pages NOW, while the descriptor stays.
    try std.testing.expect(release_pages_on_reap(3));
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);
    const pinfo = info(id).?;
    try std.testing.expectEqual(State.exited, pinfo.state);
    try std.testing.expectEqual(@as(u64, 43), pinfo.exit_status);
    try std.testing.expectEqual(@as(u64, 0x1a400000), pinfo.stack_va); // kept
    try std.testing.expectEqual(@as(u64, 0), pinfo.text_pages);
    try std.testing.expectEqual(@as(u64, 0), pinfo.stack_pages);
    try std.testing.expectEqual(@as(u64, 0), pinfo.kernel_stack_pages);
    try std.testing.expect(pinfo.task_id == null);
    // A second release is a no-op (the slot was already reaped): no
    // double free can inflate the free count.
    try std.testing.expect(!release_pages_on_reap(3));
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);
}

test "process: exit reports are a FIFO — two exits print two lines in order" {
    // Card 3d (claim 1014): N exits in one idle-loop window produce N
    // `procs <name> exited status=<n>` reports IN ORDER (the old single
    // first-wins flag collapsed them).
    init();
    const a = create("USER.BIN", .{}, .{}, .{}).?;
    const b = create("COUNTER.BIN", .{}, .{}, .{}).?;
    _ = bind(a, 2);
    _ = bind(b, 3);
    // Two exits in one window, never drained in between.
    _ = on_task_exit(2, 43);
    _ = on_task_exit(3, 137);
    const r1 = take_exit_report().?;
    try std.testing.expectEqualStrings("USER.BIN", r1.name);
    try std.testing.expectEqual(@as(u64, 43), r1.status);
    const r2 = take_exit_report().?;
    try std.testing.expectEqualStrings("COUNTER.BIN", r2.name);
    try std.testing.expectEqual(@as(u64, 137), r2.status);
    try std.testing.expect(take_exit_report() == null);
}

test "process: exit report FIFO overflow drops the OLDEST" {
    // Card 3d: a full 4-slot ring evicts the oldest entry (honestly
    // reported) — the four newest exits drain, in order.
    init();
    var ids: [exit_report_max + 1]usize = undefined;
    for (0..exit_report_max + 1) |i| {
        var name: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&name, "P{d}", .{i});
        ids[i] = create(s, .{}, .{}, .{}).?;
        _ = bind(ids[i], i + 1);
        _ = on_task_exit(i + 1, @intCast(i));
    }
    // The oldest (P0, status 0) was dropped; the four newest drain in order.
    for (1..exit_report_max + 1) |i| {
        const r = take_exit_report().?;
        var name: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&name, "P{d}", .{i});
        try std.testing.expectEqualStrings(s, r.name);
        try std.testing.expectEqual(@as(u64, @intCast(i)), r.status);
    }
    try std.testing.expect(take_exit_report() == null);
}

test "process: the static boot payload owns no allocator pages" {
    init();
    const id = create("user-el0", .{ .entry_va = 0x400000, .content_len = 64 }, .{
        .root_phys = 0x1234_0000,
        .text_va = 0x400000,
        .text_len = 64,
        .stack_va = 0x80000000,
        .stack_len = 8192,
    }, .{}).?; // zero pages everywhere: static backing, never freed
    const pinfo = info(id).?;
    try std.testing.expectEqual(@as(u64, 0), pinfo.text_pages);
    try std.testing.expectEqual(@as(u64, 0), pinfo.stack_pages);
    try std.testing.expectEqual(@as(u64, 0), pinfo.kernel_stack_pages);
}

test "process: snapshot marshals non-free rows in id order with the fixed 40-byte shape" {
    // Card 4a (claim 5799): the `sys_procs` snapshot — free descriptors
    // are skipped, every other row carries pid / state code / exit status
    // / NUL-padded name at the documented offsets.
    init();
    var scratch: [max_processes * snapshot_row_bytes]u8 = [_]u8{0xaa} ** (max_processes * snapshot_row_bytes);
    // Empty registry: zero rows.
    try std.testing.expectEqual(@as(usize, 0), snapshot(&scratch));

    const boot = create("user-el0", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    _ = bind(boot, 2);
    _ = on_task_exit(2, 7); // exited with status 7
    _ = take_exit_report();
    const peer = create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    _ = bind(peer, 3);

    try std.testing.expectEqual(@as(usize, 2), snapshot(&scratch));
    // Row 0 (pid 0, user-el0, exited): pid at 0, state code at 8, the
    // snapshotted status at 16, the NUL-padded name at 24.
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, scratch[0..8], .little));
    try std.testing.expectEqual(@as(u64, @intFromEnum(State.exited)), std.mem.readInt(u64, scratch[8..16], .little));
    try std.testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, scratch[16..24], .little));
    try std.testing.expectEqualStrings("user-el0", scratch[24 .. 24 + 8]);
    for (scratch[24 + 8 .. 40]) |byte| try std.testing.expectEqual(@as(u8, 0), byte); // NUL-padded
    // Row 1 (pid 1, PEER.BIN, running): a full row is exactly 40 bytes.
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, scratch[40..48], .little));
    try std.testing.expectEqual(@as(u64, @intFromEnum(State.running)), std.mem.readInt(u64, scratch[48..56], .little));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, scratch[56..64], .little)); // running: no status
    try std.testing.expectEqualStrings("PEER.BIN", scratch[64 .. 64 + 8]);

    // A recycled (reaped) descriptor leaves the snapshot (the row count
    // drops) and a NEW process takes the freed slot — the snapshot always
    // reflects the live registry.
    try std.testing.expect(reap(boot));
    try std.testing.expectEqual(@as(usize, 1), snapshot(&scratch));
    const third = create("COUNTER.BIN", .{}, .{}, .{}).?;
    try std.testing.expectEqual(@as(usize, 2), snapshot(&scratch));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, scratch[0..8], .little)); // COUNTER reuses pid 0
    try std.testing.expectEqualStrings("COUNTER.BIN", scratch[24 .. 24 + 11]);
    // The recycled slot is pid 0 again (the freed descriptor's id is
    // reused), so `third` is 0 — the snapshot reflects the live registry.
    try std.testing.expectEqual(@as(usize, 0), third);
}
