//! DipshitOS tick-driven round-robin kernel task scheduler (claim 5275 —
//! the first milestone-three "tasks" card).
//!
//! Preemptive at the tick only: the claim-9187 timer PPI enters the
//! claim-9746 EL1 IRQ vector, the GIC/timer chain runs (ack -> timer
//! handle/re-arm -> scheduler tick -> EOI), and the scheduler preempts the
//! current task for the next one. Claim 8215 extends the same fixed pool
//! with one EL0t task and no allocation: the shell keeps the handoff stack,
//! the EL1h worker has a static BSS stack, and the EL0 task has distinct
//! static EL1 exception and EL0 execution stacks.
//!
//! Why the switch is tiny:
//!   * The claim-9746 IRQ stubs already push the full caller-saved
//!     register file (x0..x17 + x30) as a 160-byte "vector frame" on the
//!     interrupted task's stack, and pop it back before `eret`.
//!   * The scheduler therefore only saves/restores per task: the
//!     vector-frame pointer (sp), ELR_EL1 (interrupted PC) and SPSR_EL1
//!     (interrupted PSTATE). The frame pointer reaches the tick through
//!     `exceptions.resume_frame` (staged by `exc_dispatch` at IRQ entry);
//!     the tick rewrites that global to the NEXT task's frame and programs
//!     ELR/SPSR, and the stub's `mov sp, x0` + register restore + `eret`
//!     lands in the next task exactly as if IT had been interrupted.
//!   * Claim 8215 also saves/restores SP_EL0. The exception dispatcher
//!     stages the source task's SP_EL0 and returns the selected task's value
//!     in x1; the vector exit installs it before `eret`. That is inert for
//!     EL1h tasks and essential for an EL0t task.
//!   * Round-robin: every tick preempts the current task; the next task
//!     resumes from wherever it was preempted.
//!
//! Console discipline: the scheduler itself never touches the console (IRQ
//! context — claim 9187). Worker progress is reported from the shell idle
//! loop via `maybe_report`, the same pattern as the timer heartbeat.
//!
//! Claim 5804: every task now owns a TTBR0 root. The EL1h shell/worker
//! share the EL1-only kernel root (identity map, zero EL0 leaves — also
//! the root runtime services run under); the EL0 task gets the user root
//! (text + stack only) and its entry/SP/witness are USER VAs, not kernel
//! addresses. The switch therefore programs TTBR0 + TLB-invalidates before
//! restoring ELR/SPSR.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");
const builtin = @import("builtin");
const console = @import("console.zig");
const exceptions = @import("exceptions.zig");
const mmu = @import("mmu.zig"); // claim 5804: per-task TTBR0 roots
const userspace = @import("userspace.zig"); // claim 5804: user-VA layout

const user_stack_section = if (builtin.object_format == .elf) ".userbss" else "__DATA,__userbss";

/// Round-robin pool: shell + EL1h demo worker + one EL0t task. Fixed at
/// comptime — no allocation, no dynamic registration or processes.
pub const max_tasks: usize = 3;
/// The worker's static stack (BSS, like every other kernel global). The
/// shell task continues to run on the handoff stack.
pub const task_stack_size: usize = 8 * 1024;

/// SPSR modes for synthetic first entry. The kernel's observed M=0x5 is
/// architecturally EL1h (SP_EL1), not EL1t; EL0t is M=0x0. DAIF bits are
/// clear in both so the timer may preempt either task immediately.
pub const spsr_el1h_irqs: u64 = 0x5;
pub const spsr_el0t_irqs: u64 = 0x0;

/// The claim-9746 vector frame: 20 slots holding x0..x17, x30, and a pad,
/// pushed in reverse pair order by the IRQ stub on the interrupted task's
/// stack; the "sp" a task saves/restores.
const frame_bytes: usize = 20 * 8;

const Task = struct {
    name: []const u8 = "",
    /// Saved vector-frame pointer (the SP to restore); 0 until the task
    /// has been preempted once (the shell task's context is captured on
    /// its first preemption; the worker's frame is built at registration).
    sp: u64 = 0,
    /// Interrupted PC (ELR_EL1) to `eret` to.
    elr: u64 = 0,
    /// Interrupted PSTATE (SPSR_EL1).
    spsr: u64 = 0,
    /// Stack selected by EL0t (and EL1t, which this scheduler does not
    /// create). EL1h tasks ignore this value.
    sp_el0: u64 = 0,
    /// Physical TTBR0 root for this task's user space (claim 5804). The
    /// EL1h tasks point at the EL1-only kernel root; the EL0 task points at
    /// its text+stack-only user root. Written to TTBR0 on every switch.
    ttbr0: u64 = 0,
    /// How many times this task's context was saved by a tick.
    saves: u64 = 0,
    /// How many times this task's context was restored by a tick.
    resumes: u64 = 0,
    /// Task-side progress counter (the worker bumps it; `tasks` reports).
    advances: u64 = 0,
    registered: bool = false,
    runnable: bool = false,
    terminated: bool = false,
    exit_status: u64 = 0,
};

var tasks: [max_tasks]Task = .{ .{}, .{}, .{} };
var task_count: usize = 0;
var current: usize = 0;
var enabled_flag: bool = false;
var switches: u64 = 0;
var cooperative_yields: u64 = 0;
var exits: u64 = 0;

/// Restored-context staging: written by `switch_context` (the pure core),
/// applied by `tick` (the aarch64 wrapper: msr ELR/SPSR + resume_frame).
var pending_sp: u64 = 0;
var pending_elr: u64 = 0;
var pending_spsr: u64 = 0;
var pending_sp_el0: u64 = 0;
var pending_ttbr0: u64 = 0;

/// Worker report (main-context console discipline, claim 9187): the worker
/// marks a report pending; the shell idle loop prints it via `maybe_report`.
var report_pending: bool = false;
var report_task: usize = 0;
var report_advances: u64 = 0;
var exit_report_pending: bool = false;
var exit_report_task: usize = 0;
var exit_report_status: u64 = 0;

/// The demo worker's static stack.
var worker_stack: [task_stack_size]u8 align(16) = undefined;
/// EL1 exception stack used while the EL0 task is in an SVC or timer vector.
var user_kernel_stack: [task_stack_size]u8 align(16) = undefined;
/// Stack visible to the EL0 task itself through SP_EL0. Its dedicated linker
/// section is page-aligned so the MMU can grant this page range EL0 RW+XN
/// without exposing adjacent kernel BSS.
var user_stack: [task_stack_size]u8 align(4096) linksection(user_stack_section) = undefined;
/// EL0-visible, scheduler-written witness. The initial user frame receives its
/// address in x9; the payload waits for a non-zero value before invoking
/// sys_yield. It lives in the already-mapped user BSS aperture and exposes no
/// privileged state beyond the fact that this task was preempted by a tick.
var user_timer_preemptions: u64 align(8) linksection(user_stack_section) = 0;

// ---------------------------------------------------------------------------
// Registration (kernel seam, before the shell loop starts)
// ---------------------------------------------------------------------------

/// Register the boot/main task (the shell). Its context is empty until the
/// first tick preempts it. Resets the module so tests are deterministic.
/// Returns the task id (0).
pub fn init() usize {
    task_count = 0;
    current = 0;
    switches = 0;
    cooperative_yields = 0;
    exits = 0;
    enabled_flag = false;
    report_pending = false;
    exit_report_pending = false;
    user_timer_preemptions = 0;
    for (&tasks) |*task| task.* = .{};
    tasks[0] = .{ .name = "shell", .registered = true, .runnable = true, .ttbr0 = mmu.kernel_root_phys() };
    task_count = 1;
    return 0;
}

/// Register a second task that starts at `entry` (a runtime-computed
/// function address — the caller takes `@intFromPtr(&task_fn)`, resolved
/// PC-relatively at the kernel's runtime load base). Builds the synthetic
/// vector frame the first switch restores: x30 = the park address (the
/// task returns there if its entry ever returns), every other register 0,
/// ELR = entry, SPSR = EL1h with IRQs unmasked.
pub fn register_worker(entry: u64) ?usize {
    if (task_count >= max_tasks) return null;
    const id = task_count;
    tasks[id] = .{
        .name = "worker",
        .sp = build_initial_frame(&worker_stack, entry),
        .elr = entry,
        .spsr = spsr_el1h_irqs,
        .ttbr0 = mmu.kernel_root_phys(),
        .registered = true,
        .runnable = true,
    };
    task_count += 1;
    return id;
}

/// Register the first real lower-privilege task. Its saved register frame
/// lives on a private EL1 exception stack; its code executes with EL0t at a
/// USER VA (claim 5804: `entry` is the kernel-side address of the payload
/// and `image_base` the loader base — both are converted to user VAs here)
/// under the task's own TTBR0 user root, with a separate SP_EL0 user stack
/// and the timer-preemption witness at its user VA (the payload dereferences
/// it through x9 at EL0).
pub fn register_user(entry: u64, image_base: u64) ?usize {
    if (task_count >= max_tasks) return null;
    const id = task_count;
    // Claim 5804: this runs POST-jump, so the incoming `entry` and these
    // `@intFromPtr` values are KVA addresses — the user-VA conversion
    // helpers expect the pre-jump PHYSICAL (identity) addresses (their
    // formula is `user_va + (kernel_addr - image_base) - section_start`,
    // which only holds in the identity world). to_phys is the identity on
    // host tests and pre-jump, so the conversion is safe everywhere.
    const entry_va = userspace.image_user_va(image_base, mmu.to_phys(entry));
    const sp_el0 = userspace.bss_user_va(image_base, mmu.to_phys(@intFromPtr(&user_stack))) + user_stack.len;
    const witness_va = userspace.bss_user_va(image_base, mmu.to_phys(@intFromPtr(&user_timer_preemptions)));
    tasks[id] = .{
        .name = "user-el0",
        .sp = build_initial_frame(&user_kernel_stack, entry_va),
        .elr = entry_va,
        .spsr = spsr_el0t_irqs,
        .sp_el0 = sp_el0,
        .ttbr0 = mmu.user_root_phys(),
        .registered = true,
        .runnable = true,
    };
    const frame: *exceptions.VectorFrame = @ptrFromInt(tasks[id].sp);
    _ = exceptions.frame_write(frame, 9, witness_va);
    task_count += 1;
    return id;
}

/// Start preempting on ticks. Called only once the shell loop is the
/// running context, so boot-time printing is never preempted.
pub fn start() void {
    enabled_flag = true;
}

pub fn enabled() bool {
    return enabled_flag;
}

/// True once the scheduler would actually switch on a tick (enabled AND at
/// least two tasks). The tick() guard; hoisted so host tests can pin it.
pub fn scheduling_active() bool {
    if (!enabled_flag) return false;
    var runnable: usize = 0;
    for (tasks[0..task_count]) |task| {
        if (task.runnable) runnable += 1;
    }
    return runnable >= 2;
}

/// Build the synthetic claim-9746 vector frame at the top of `stack` and
/// return its base pointer (the SP the stub restores from). Layout matches
/// the stub's save order exactly: x30 sits at the top (popped first), then
/// x16/x17 ... x0/x1 at the bottom; every slot zeroed except x30.
fn build_initial_frame(stack: []u8, entry: u64) u64 {
    _ = entry; // ELR carries the entry; the frame only needs x30 = park
    const frame = stack[stack.len - frame_bytes ..];
    @memset(frame, 0);
    const park_addr = @intFromPtr(&park);
    std.mem.writeInt(u64, frame[0..8], park_addr, .little);
    return @intFromPtr(frame.ptr);
}

/// What a task's entry `ret`s to if it ever returns: park forever. Also
/// the x30 slot of every synthetic initial frame (belt and suspenders —
/// the worker never returns). WFE on aarch64, nop elsewhere (host tests).
fn park() noreturn {
    while (true) {
        if (comptime builtin.cpu.arch == .aarch64) {
            asm volatile ("wfe");
        } else {
            asm volatile ("nop");
        }
    }
}

// ---------------------------------------------------------------------------
// The switch (IRQ context — no console, no allocation)
// ---------------------------------------------------------------------------

/// Pure context-switch core (host-testable): save the preempted task's
/// frame pointer + ELR/SPSR into its TCB, advance round-robin, and stage
/// the next task's frame pointer + ELR/SPSR for `tick` to apply. No asm,
/// no SP manipulation: the actual register restore happens in the
/// claim-9746 stub (`mov sp, x0` + pop + `eret`) using the staged frame.
fn next_runnable(after: usize) ?usize {
    if (task_count == 0) return null;
    var offset: usize = 1;
    while (offset <= task_count) : (offset += 1) {
        const candidate = (after + offset) % task_count;
        if (tasks[candidate].registered and tasks[candidate].runnable) return candidate;
    }
    return null;
}

fn stage_current() void {
    pending_sp = tasks[current].sp;
    pending_elr = tasks[current].elr;
    pending_spsr = tasks[current].spsr;
    pending_sp_el0 = tasks[current].sp_el0;
    pending_ttbr0 = tasks[current].ttbr0;
    tasks[current].resumes += 1;
    switches += 1;
}

pub fn switch_context(frame_sp: u64, elr: u64, spsr: u64, sp_el0: u64) void {
    if (task_count == 0) return;
    tasks[current].sp = frame_sp;
    tasks[current].elr = elr;
    tasks[current].spsr = spsr;
    tasks[current].sp_el0 = sp_el0;
    tasks[current].saves += 1;
    current = next_runnable(current) orelse return;
    stage_current();
}

fn apply_pending() void {
    exceptions.resume_frame = pending_sp;
    exceptions.resume_sp_el0 = pending_sp_el0;
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    // Claim 5804: install the selected task's TTBR0 (with a full TLB
    // invalidation) before restoring its ELR/SPSR, so the eret to EL0 (or
    // the resumed EL1h instruction stream) sees the task's own user space.
    mmu.set_ttbr0(pending_ttbr0);
    asm volatile ("msr elr_el1, %[v]"
        :
        : [v] "r" (pending_elr),
    );
    asm volatile ("msr spsr_el1, %[v]"
        :
        : [v] "r" (pending_spsr),
    );
    asm volatile ("isb");
}

fn current_exception_pc() struct { elr: u64, spsr: u64 } {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) {
        return .{ .elr = tasks[current].elr, .spsr = tasks[current].spsr };
    }
    var elr: u64 = 0;
    var spsr: u64 = 0;
    asm volatile ("mrs %[v], elr_el1"
        : [v] "=r" (elr),
    );
    asm volatile ("mrs %[v], spsr_el1"
        : [v] "=r" (spsr),
    );
    return .{ .elr = elr, .spsr = spsr };
}

/// Cooperative syscall yield. The interrupted SVC frame is saved exactly as
/// an IRQ frame would be, then another runnable task is staged for `eret`.
pub fn yield_current() bool {
    if (!scheduling_active()) return false;
    const pc = current_exception_pc();
    switch_context(exceptions.resume_frame, pc.elr, pc.spsr, exceptions.resume_sp_el0);
    cooperative_yields +%= 1;
    apply_pending();
    return true;
}

/// Remove the calling task from the runnable ring and stage its successor.
/// The SVC exception return consumes the staged frame, so the terminated task
/// never resumes after `sys_exit`.
pub fn exit_current(status: u64) bool {
    if (task_count == 0 or !tasks[current].registered or !tasks[current].runnable) return false;
    const exiting = current;
    tasks[exiting].runnable = false;
    tasks[exiting].terminated = true;
    tasks[exiting].exit_status = status;
    const next = next_runnable(exiting) orelse {
        tasks[exiting].runnable = true;
        tasks[exiting].terminated = false;
        return false;
    };
    exit_report_pending = true;
    exit_report_task = exiting;
    exit_report_status = status;
    exits +%= 1;
    current = next;
    stage_current();
    apply_pending();
    return true;
}

/// IRQ-context tick (called from the kernel's irq_dispatch right after
/// timer.handle re-armed the comparator): preempt the current task and
/// round-robin to the next. The interrupted task's vector frame is on the
/// stack (`exceptions.resume_frame`); ELR_EL1/SPSR_EL1 still hold the
/// interrupted PC/PSTATE. The switch itself only programs ELR/SPSR and the
/// stub's restore frame — the stub does the register pop and eret.
pub fn tick() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (!scheduling_active()) return;
    var elr: u64 = 0;
    var spsr: u64 = 0;
    asm volatile ("mrs %[v], elr_el1"
        : [v] "=r" (elr),
    );
    asm volatile ("mrs %[v], spsr_el1"
        : [v] "=r" (spsr),
    );
    timer_switch_context(exceptions.resume_frame, elr, spsr, exceptions.resume_sp_el0);
    apply_pending();
}

/// Tick-only wrapper around the pure switch core. Keeping the source of the
/// switch explicit prevents a cooperative yield from masquerading as the
/// timer-preemption witness inherited from claim 8215.
fn timer_switch_context(frame_sp: u64, elr: u64, spsr: u64, sp_el0: u64) void {
    if ((spsr & 0xf) == spsr_el0t_irqs) user_timer_preemptions +%= 1;
    switch_context(frame_sp, elr, spsr, sp_el0);
}

pub fn user_timer_preemption_count() u64 {
    return user_timer_preemptions;
}

// ---------------------------------------------------------------------------
// Worker progress (main context only — never from the IRQ tick)
// ---------------------------------------------------------------------------

/// Task-side: bump the current task's advance counter (the worker calls
/// this in its main-context loop).
pub fn note_advance() void {
    if (task_count == 0) return;
    tasks[current].advances += 1;
}

/// Task-side: ask the shell idle loop to print the current task's advance
/// counter. Keeps the FIRST snapshot while pending (no backlog). Console
/// output stays in main context (claim 9187 — never print from IRQ).
pub fn request_report() void {
    if (task_count == 0 or report_pending) return;
    report_pending = true;
    report_task = current;
    report_advances = tasks[current].advances;
}

/// Shell-side (main context, next to timer.maybe_heartbeat): print one
/// pending report line, if any.
pub fn maybe_report(con: *console.Console) void {
    if (report_pending) {
        report_pending = false;
        con.puts("tasks ");
        con.puts(tasks[report_task].name);
        con.puts(" advances=");
        con.print_u64(report_advances);
        con.puts("\n");
    }
    if (exit_report_pending) {
        exit_report_pending = false;
        con.puts("tasks ");
        con.puts(tasks[exit_report_task].name);
        con.puts(" exited status=");
        con.print_u64(exit_report_status);
        con.puts("\n");
    }
}

// ---------------------------------------------------------------------------
// Monitor-facing stats
// ---------------------------------------------------------------------------

pub const TaskInfo = struct {
    name: []const u8,
    saves: u64,
    resumes: u64,
    advances: u64,
};

pub const Stats = struct {
    enabled: bool,
    current: usize,
    switches: u64,
    count: usize,
};

pub fn stats() Stats {
    return .{
        .enabled = enabled_flag,
        .current = current,
        .switches = switches,
        .count = task_count,
    };
}

pub fn task_info(id: usize) ?TaskInfo {
    if (id >= task_count or !tasks[id].registered) return null;
    return .{
        .name = tasks[id].name,
        .saves = tasks[id].saves,
        .resumes = tasks[id].resumes,
        .advances = tasks[id].advances,
    };
}

pub fn current_id() usize {
    return current;
}

/// The TTBR0 root (physical) a task runs under (claim 5804; the
/// `addrspaces` diagnostic prints it).
pub fn task_ttbr0(id: usize) u64 {
    if (id >= task_count or !tasks[id].registered) return 0;
    return tasks[id].ttbr0;
}

pub fn cooperative_yield_count() u64 {
    return cooperative_yields;
}

pub fn exit_count() u64 {
    return exits;
}

pub fn is_terminated(id: usize) bool {
    return id < task_count and tasks[id].terminated;
}

pub fn terminated_status(id: usize) ?u64 {
    if (!is_terminated(id)) return null;
    return tasks[id].exit_status;
}

// ---------------------------------------------------------------------------
// Tests (host-side; the asm tick is proven on real VZ hardware by the
// class B gate tools/verify-live-tasks.sh)
// ---------------------------------------------------------------------------

test "scheduler: init registers the shell task; start flips enabled" {
    try std.testing.expectEqual(@as(usize, 0), init());
    try std.testing.expectEqual(@as(usize, 1), task_count);
    try std.testing.expectEqualStrings("shell", tasks[0].name);
    try std.testing.expect(!enabled());
    try std.testing.expect(!scheduling_active());
    start();
    try std.testing.expect(enabled());
    // Two tasks are required before a tick may switch.
    try std.testing.expect(!scheduling_active());
}

test "scheduler: register_worker builds a valid synthetic frame" {
    _ = init();
    const entry: u64 = 0x1234_5678_9abc_def0;
    try std.testing.expectEqual(@as(usize, 1), register_worker(entry).?);
    try std.testing.expectEqual(@as(usize, 2), task_count);
    const t = &tasks[1];
    try std.testing.expectEqual(entry, t.elr);
    try std.testing.expectEqual(spsr_el1h_irqs, t.spsr);
    // Frame: 160 bytes below the stack top; the x30 slot holds the park
    // address; every other slot is zeroed (the stub pops them as x0..x17).
    const stack_top = @intFromPtr(&worker_stack) + worker_stack.len;
    try std.testing.expectEqual(stack_top - frame_bytes, t.sp);
    try std.testing.expectEqual(@intFromPtr(&park), std.mem.readInt(u64, @as(*const [8]u8, @ptrFromInt(t.sp)), .little));
    var i: usize = 8;
    while (i < frame_bytes) : (i += 8) {
        try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, @as(*const [8]u8, @ptrFromInt(t.sp + i)), .little));
    }
    // A third, lower-EL task fills the fixed pool; no fourth registration.
    try std.testing.expectEqual(@as(usize, 2), register_user(0x3333, 0).?);
    try std.testing.expect(register_worker(0) == null);
}

test "scheduler: register_user separates EL1 exception and EL0 stacks" {
    _ = init();
    _ = register_worker(0x2000).?;
    const entry: u64 = 0x3000;
    try std.testing.expectEqual(@as(usize, 2), register_user(entry, 0).?);
    const task = &tasks[2];
    try std.testing.expectEqualStrings("user-el0", task.name);
    try std.testing.expectEqual(entry, task.elr);
    try std.testing.expectEqual(spsr_el0t_irqs, task.spsr);
    try std.testing.expectEqual(@intFromPtr(&user_kernel_stack) + user_kernel_stack.len - frame_bytes, task.sp);
    try std.testing.expectEqual(@intFromPtr(&user_stack) + user_stack.len, task.sp_el0);
    try std.testing.expect(task.sp + frame_bytes != task.sp_el0);
    const frame: *exceptions.VectorFrame = @ptrFromInt(task.sp);
    try std.testing.expectEqual(@intFromPtr(&user_timer_preemptions), exceptions.frame_read(frame, 9));
}

test "scheduler: round-robin alternates and round-trips saved context" {
    _ = init();
    const worker_entry: u64 = 0x2000;
    _ = register_worker(worker_entry).?;
    start();
    // First switch: the shell is preempted at pc 0x1000; the worker is
    // restored to its synthetic frame.
    switch_context(0x1000, 0x1000, 0x5, 0xaaaa);
    try std.testing.expectEqual(@as(usize, 1), current);
    try std.testing.expectEqual(@as(u64, 1), switches);
    try std.testing.expectEqual(@as(u64, 1), tasks[0].saves);
    try std.testing.expectEqual(@as(u64, 0), tasks[0].resumes);
    try std.testing.expectEqual(@as(u64, 1), tasks[1].resumes);
    try std.testing.expectEqual(@as(u64, 0), tasks[1].saves);
    try std.testing.expectEqual(tasks[1].sp, pending_sp);
    try std.testing.expectEqual(worker_entry, pending_elr);
    try std.testing.expectEqual(spsr_el1h_irqs, pending_spsr);
    // Second switch: the worker is preempted; the shell is restored to its
    // exact saved context.
    switch_context(0x2000, 0x2000, 0x5, 0xbbbb);
    try std.testing.expectEqual(@as(usize, 0), current);
    try std.testing.expectEqual(@as(u64, 2), switches);
    try std.testing.expectEqual(@as(u64, 1), tasks[1].saves);
    try std.testing.expectEqual(@as(u64, 1), tasks[0].resumes);
    try std.testing.expectEqual(@as(u64, 0x1000), pending_sp);
    try std.testing.expectEqual(@as(u64, 0x1000), pending_elr);
    try std.testing.expectEqual(@as(u64, 0x5), pending_spsr);
    try std.testing.expectEqual(@as(u64, 0xaaaa), pending_sp_el0);
    // Third switch returns to the worker's saved context (the round-trip).
    switch_context(0x1000, 0x1001, 0x5, 0xaaaa);
    try std.testing.expectEqual(@as(usize, 1), current);
    try std.testing.expectEqual(@as(u64, 3), switches);
    try std.testing.expectEqual(@as(u64, 2), tasks[0].saves);
    try std.testing.expectEqual(@as(u64, 1), tasks[0].resumes);
    try std.testing.expectEqual(@as(u64, 1), tasks[1].saves);
    try std.testing.expectEqual(@as(u64, 2), tasks[1].resumes);
}

test "scheduler: mixed EL1h and EL0t round-robin restores SP_EL0" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    const initial_user_sp = tasks[2].sp_el0;

    switch_context(0x1000, 0x1000, spsr_el1h_irqs, 0xaaaa); // shell -> worker
    try std.testing.expectEqual(@as(usize, 1), current);
    switch_context(0x2000, 0x2000, spsr_el1h_irqs, 0xbbbb); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), current);
    try std.testing.expectEqual(spsr_el0t_irqs, pending_spsr);
    try std.testing.expectEqual(initial_user_sp, pending_sp_el0);

    const preempted_user_sp: u64 = initial_user_sp - 16;
    switch_context(0x3000, 0x3004, spsr_el0t_irqs, preempted_user_sp); // user -> shell
    try std.testing.expectEqual(@as(usize, 0), current);
    try std.testing.expectEqual(@as(u64, 0xaaaa), pending_sp_el0);
    try std.testing.expectEqual(preempted_user_sp, tasks[2].sp_el0);

    switch_context(0x1000, 0x1004, spsr_el1h_irqs, 0xaaaa);
    switch_context(0x2000, 0x2004, spsr_el1h_irqs, 0xbbbb);
    try std.testing.expectEqual(@as(usize, 2), current);
    try std.testing.expectEqual(preempted_user_sp, pending_sp_el0);
    try std.testing.expectEqual(@as(u64, 0x3004), pending_elr);
}

test "scheduler: only a tick preemption publishes the EL0 witness" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    switch_context(0x1000, 0x1000, spsr_el1h_irqs, 0xaaaa); // shell -> worker
    switch_context(0x2000, 0x2000, spsr_el1h_irqs, 0xbbbb); // worker -> user
    try std.testing.expectEqual(@as(u64, 0), user_timer_preemption_count());
    // Cooperative switching cannot satisfy the claim-8215 witness.
    try std.testing.expect(yield_current()); // user -> shell
    try std.testing.expectEqual(@as(u64, 0), user_timer_preemption_count());
    switch_context(0x1004, 0x1004, spsr_el1h_irqs, 0xaaaa); // shell -> worker
    switch_context(0x2004, 0x2004, spsr_el1h_irqs, 0xbbbb); // worker -> user
    timer_switch_context(0x3000, 0x3004, spsr_el0t_irqs, tasks[2].sp_el0);
    try std.testing.expectEqual(@as(u64, 1), user_timer_preemption_count());
}

test "scheduler: the worker's advance counter belongs to its own task" {
    _ = init();
    _ = register_worker(0x2000).?;
    current = 1; // pretend the worker is running
    note_advance();
    note_advance();
    note_advance();
    try std.testing.expectEqual(@as(u64, 3), tasks[1].advances);
    try std.testing.expectEqual(@as(u64, 0), tasks[0].advances);
}

test "scheduler: worker report snapshots once and prints from the shell side" {
    _ = init();
    _ = register_worker(0x2000).?;
    current = 1; // pretend the worker is running
    note_advance();
    note_advance();
    request_report();
    request_report(); // second request while pending: keeps the first snapshot
    var mock = console.MockConsole(256){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expectEqualStrings("tasks worker advances=2\n", mock.contents());
    // The flag is consumed: a second print emits nothing.
    mock.reset();
    maybe_report(&con);
    try std.testing.expectEqual(@as(usize, 0), mock.contents().len);
}

test "scheduler: stats and task_info report deterministic state" {
    _ = init();
    _ = register_worker(0x2000).?;
    start();
    const s = stats();
    try std.testing.expect(s.enabled);
    try std.testing.expectEqual(@as(usize, 2), s.count);
    try std.testing.expectEqual(@as(usize, 0), s.current);
    try std.testing.expectEqual(@as(u64, 0), s.switches);
    const shell = task_info(0).?;
    try std.testing.expectEqualStrings("shell", shell.name);
    try std.testing.expectEqual(@as(u64, 0), shell.saves);
    try std.testing.expectEqual(@as(u64, 0), shell.advances);
    const worker = task_info(1).?;
    try std.testing.expectEqualStrings("worker", worker.name);
    try std.testing.expect(task_info(2) == null);
}

test "scheduler: cooperative exit is non-runnable and reports from shell" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    try std.testing.expect(exit_current(7)); // user -> shell
    try std.testing.expectEqual(@as(usize, 0), current_id());
    try std.testing.expect(is_terminated(2));
    try std.testing.expectEqual(@as(?u64, 7), terminated_status(2));
    // The next switch skips the terminated user: shell -> worker -> shell.
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 1), current_id());
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 0), current_id());
    var mock = console.MockConsole(128){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expectEqualStrings("tasks user-el0 exited status=7\n", mock.contents());
}
