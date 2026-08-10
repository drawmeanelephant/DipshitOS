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
//!   * The claim-9746 IRQ stubs already push the full register file (x0..
//!     x17 + x30, plus the claim-6729 callee-saved extension x19..x28 +
//!     x29) as a 256-byte "vector frame" on the interrupted task's stack,
//!     and pop it back before `eret`.
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
//! Claim 6729: the task lifecycle. Each pool slot carries an EXPLICIT
//! state: free -> ready -> running -> ready (preempted) -> zombie (exited)
//! -> free (reaped). `spawn` allocates the first free slot (bounded, no
//! dynamic allocation); `exit_current` (the sys_exit path) turns the
//! current task into a zombie; the scheduler-owned IDLE task (registered
//! at the last slot by `init`, always ready, WFE-parked) reaps one zombie
//! per iteration and the shell loop prints the reap. The idle task is the
//! ring's fallback, so an exit always has a successor and the pool drains
//! without a parent/child relationship. The monitor's `spawn` command
//! exercises runtime spawn with one dedicated demo stack.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");
const builtin = @import("builtin");
const console = @import("console.zig");
const exceptions = @import("exceptions.zig");
const mmu = @import("mmu.zig"); // claim 5804: per-task TTBR0 roots
const userspace = @import("userspace.zig"); // claim 5804: user-VA layout

const user_stack_section = if (builtin.object_format == .elf) ".userbss" else "__DATA,__userbss";

/// Round-robin pool: shell + EL1h demo worker + one EL0t task + one
/// spawnable demo slot + the scheduler-owned idle task. Fixed at comptime
/// — no allocation, no dynamic registration or processes; the lifecycle's
/// spawn/reap only recycle these slots.
pub const max_tasks: usize = 5;
/// The idle task's fixed slot (registered by `init`, never recycled).
pub const idle_id: usize = max_tasks - 1;
/// The worker's static stack (BSS, like every other kernel global). The
/// shell task continues to run on the handoff stack.
pub const task_stack_size: usize = 8 * 1024;

/// SPSR modes for synthetic first entry. The kernel's observed M=0x5 is
/// architecturally EL1h (SP_EL1), not EL1t; EL0t is M=0x0. DAIF bits are
/// clear in both so the timer may preempt either task immediately.
pub const spsr_el1h_irqs: u64 = 0x5;
pub const spsr_el0t_irqs: u64 = 0x0;

/// The claim-9746 vector frame: 32 slots holding x0..x17, x30, a pad, and
/// the claim-6729 callee-saved extension (x19..x28 + x29), pushed in
/// reverse pair order by the IRQ stub on the interrupted task's stack; the
/// "sp" a task saves/restores. The callee-saved half is what makes a
/// context switch safe for compiled tasks (a preempted task's live
/// x19..x28 survive the tick and are restored on resume — claim 6729
/// bisect).
const frame_bytes: usize = 32 * 8;

/// Explicit task lifecycle state (claim 6729). A slot's state is the ONLY
/// ownership signal: `free` slots are spawnable, `zombie` slots hold an
/// exited task's status until the idle task reaps them, and the idle task
/// itself never leaves `ready` (the scheduler refuses to exit it).
pub const State = enum {
    free,
    ready,
    running,
    /// Claim 0635: a task parked by `sys_sleep` until `wakeup_tick` ticks
    /// have passed. Blocked tasks drop out of the round-robin ring
    /// (`next_runnable` scans `ready` only) and the tick's `wake_expired`
    /// moves them back to `ready` when their deadline passes.
    blocked,
    zombie,
};

/// Human-readable state label for the `tasks` monitor command.
pub fn state_name(state: State) []const u8 {
    return switch (state) {
        .free => "free",
        .ready => "ready",
        .running => "running",
        .blocked => "blocked",
        .zombie => "zombie",
    };
}

const Task = struct {
    name: []const u8 = "",
    state: State = .free,
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
    /// Exit status preserved while the task is a zombie (until reaped).
    exit_status: u64 = 0,
    /// Claim 0635: scheduler tick count at/after which a `blocked` task
    /// wakes (`tick_count >= wakeup_tick`). Meaningful only while blocked.
    wakeup_tick: u64 = 0,
};

var tasks: [max_tasks]Task = .{ .{}, .{}, .{}, .{}, .{} };
var task_count: usize = 0;
var current: usize = 0;
var enabled_flag: bool = false;
var switches: u64 = 0;
var cooperative_yields: u64 = 0;
var exits: u64 = 0;
/// Claim 0635: scheduler tick counter — advanced once per timer tick by
/// `tick`/`on_tick`; the clock `sys_sleep` deadlines are measured against.
/// Distinct from `timer.ticks` (timer deliveries, including polls) because
/// the scheduler may be inactive or the timer path may change; the sleep
/// contract is in SCHEDULER ticks.
var tick_count: u64 = 0;

/// Restored-context staging: written by `switch_context` (the pure core),
/// applied by `tick` (the aarch64 wrapper: msr ELR/SPSR + resume_frame).
var pending_sp: u64 = 0;
var pending_elr: u64 = 0;
var pending_spsr: u64 = 0;
var pending_sp_el0: u64 = 0;
var pending_ttbr0: u64 = 0;

/// Task reports (main-context console discipline, claim 9187): a task
/// marks ITS OWN report slot pending (claim 6729: one slot per pool entry,
/// so the worker's constant requests cannot starve another task's report);
/// the shell idle loop prints every pending slot via `maybe_report`.
var report_pending: [max_tasks]bool = [_]bool{false} ** max_tasks;
var report_advances: [max_tasks]u64 = [_]u64{0} ** max_tasks;
var exit_report_pending: bool = false;
var exit_report_name: []const u8 = "";
var exit_report_status: u64 = 0;
/// Reap report (claim 6729): the idle task marks a reap; the shell loop
/// prints it. The name is snapshotted at reap time — the freed slot's own
/// name is zeroed by the reset.
var reap_report_pending: bool = false;
var reap_report_name: []const u8 = "";
/// Sleep report (claim 0635): `sys_sleep` marks it (exception context, like
/// exit); the shell idle loop prints it — the deterministic "this task is
/// now blocked for N ticks" transition line the live gate asserts.
var sleep_report_pending: bool = false;
var sleep_report_name: []const u8 = "";
var sleep_report_ticks: u64 = 0;

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
/// The idle task's static stack (BSS, like every other kernel global).
var idle_stack: [task_stack_size]u8 align(16) = undefined;
/// The monitor `spawn` command's dedicated demo stack; one spawn only, so
/// the demo task never shares a stack with another live task.
var spawn_demo_stack: [task_stack_size]u8 align(16) = undefined;
var spawn_demo_armed: bool = false;

// ---------------------------------------------------------------------------
// Registration (kernel seam, before the shell loop starts)
// ---------------------------------------------------------------------------

/// Register the boot/main task (the shell). Its context is empty until the
/// first tick preempts it. Also registers the scheduler-owned idle task at
/// the LAST slot (claim 6729). Resets the module so tests are deterministic.
/// Returns the task id (0).
pub fn init() usize {
    task_count = 0;
    current = 0;
    switches = 0;
    cooperative_yields = 0;
    exits = 0;
    enabled_flag = false;
    @memset(&report_pending, false);
    exit_report_pending = false;
    reap_report_pending = false;
    sleep_report_pending = false;
    spawn_demo_armed = false;
    user_timer_preemptions = 0;
    tick_count = 0;
    for (&tasks) |*task| task.* = .{};
    tasks[0] = .{ .name = "shell", .state = .ready, .ttbr0 = mmu.kernel_root_phys() };
    tasks[idle_id] = .{
        .name = "idle",
        .state = .ready,
        .sp = build_initial_frame(&idle_stack, @intFromPtr(&idle_entry)),
        .elr = @intFromPtr(&idle_entry),
        .spsr = spsr_el1h_irqs,
        .ttbr0 = mmu.kernel_root_phys(),
    };
    task_count = 2;
    return 0;
}

/// Claim 6729: allocate the first free pool slot for a new task and build
/// its synthetic initial frame on `stack`. Explicit, bounded allocation:
/// returns null when the fixed pool is full (every slot registered). The
/// caller supplies the name, runtime entry address, SPSR mode, TTBR0 root,
/// and SP_EL0 (0 for EL1h tasks). The new task starts `ready`.
pub fn spawn(name: []const u8, entry: u64, spsr: u64, stack: []u8, ttbr0: u64, sp_el0: u64) ?usize {
    var id: usize = 0;
    while (id < max_tasks) : (id += 1) {
        if (tasks[id].state == .free) break;
    }
    if (id >= max_tasks) return null;
    tasks[id] = .{
        .name = name,
        .sp = build_initial_frame(stack, entry),
        .elr = entry,
        .spsr = spsr,
        .sp_el0 = sp_el0,
        .ttbr0 = ttbr0,
        .state = .ready,
    };
    task_count += 1;
    return id;
}

/// Register the claim-5275 demo worker (an EL1h task that bumps its advance
/// counter each quantum). `entry` is a runtime-computed function address
/// (the caller takes `@intFromPtr(&task_fn)`).
pub fn register_worker(entry: u64) ?usize {
    return spawn("worker", entry, spsr_el1h_irqs, &worker_stack, mmu.kernel_root_phys(), 0);
}

/// Register the first real lower-privilege task. Its saved register frame
/// lives on a private EL1 exception stack; its code executes with EL0t at a
/// USER VA (claim 5804: `entry` is the kernel-side address of the payload
/// and `image_base` the loader base — both are converted to user VAs here)
/// under the task's own TTBR0 user root, with a separate SP_EL0 user stack
/// and the timer-preemption witness at its user VA (the payload dereferences
/// it through x9 at EL0).
/// Claim 6783: register the ESP-loaded user program (exec) as an EL0t task
/// on the shared EL1 exception stack. The caller (`exec.zig`) has already
/// rebuilt the user root around the loaded page, so `entry_va` and the
/// stack are USER VAs and the root is the current user root
/// (`mmu.user_root_phys()`). One user program at a time is enforced by
/// `user_root_in_use` — the exec gate. The task reuses the static user
/// stack pages as SP_EL0 (the previous user task is gone by the gate).
pub fn register_exec_user(entry_va: u64, stack_va: u64) ?usize {
    const sp_el0 = stack_va + user_stack.len;
    return spawn("user-exec", entry_va, spsr_el0t_irqs, &user_kernel_stack, mmu.user_root_phys(), sp_el0);
}

/// Claim 6783: true when a live task still runs under the current user
/// root. Exec refuses while that is the case — rebuilding the root would
/// strand the running program (one user program at a time). A zombie is
/// not live (it never runs again) and may be reaped, so exec can reuse its
/// slot. Claim 0635: a BLOCKED task is also live — it wakes and resumes,
/// so a sleeping user program still owns the user root.
pub fn user_root_in_use() bool {
    const root = mmu.user_root_phys();
    for (tasks[0..max_tasks]) |task| {
        if ((task.state == .ready or task.state == .running or task.state == .blocked) and task.ttbr0 == root) return true;
    }
    return false;
}

/// Physical address of the static user stack pages (claim 6783: exec maps
/// them at `userspace.stack_va` in the rebuilt user root). Identity on host
/// tests.
pub fn user_stack_phys() u64 {
    return mmu.to_phys(@intFromPtr(&user_stack));
}

pub fn register_user(entry: u64, image_base: u64) ?usize {
    // Claim 5804: this runs POST-jump, so the incoming `entry` and these
    // `@intFromPtr` values are KVA addresses — the user-VA conversion
    // helpers expect the pre-jump PHYSICAL (identity) addresses (their
    // formula is `user_va + (kernel_addr - image_base) - section_start`,
    // which only holds in the identity world). to_phys is the identity on
    // host tests and pre-jump, so the conversion is safe everywhere.
    const entry_va = userspace.image_user_va(image_base, mmu.to_phys(entry));
    const sp_el0 = userspace.bss_user_va(image_base, mmu.to_phys(@intFromPtr(&user_stack))) + user_stack.len;
    const witness_va = userspace.bss_user_va(image_base, mmu.to_phys(@intFromPtr(&user_timer_preemptions)));
    const id = spawn("user-el0", entry_va, spsr_el0t_irqs, &user_kernel_stack, mmu.user_root_phys(), sp_el0) orelse return null;
    const frame: *exceptions.VectorFrame = @ptrFromInt(tasks[id].sp);
    _ = exceptions.frame_write(frame, 9, witness_va);
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
/// least two runnable tasks). The tick() guard; hoisted so host tests can pin
/// it. The idle task counts, so a booted pool is always active.
pub fn scheduling_active() bool {
    if (!enabled_flag) return false;
    var runnable: usize = 0;
    for (tasks[0..max_tasks]) |task| {
        if (task.state == .ready or task.state == .running) runnable += 1;
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
    while (offset <= max_tasks) : (offset += 1) {
        const candidate = (after + offset) % max_tasks;
        if (tasks[candidate].state == .ready) return candidate;
    }
    return null;
}

fn stage_current() void {
    pending_sp = tasks[current].sp;
    pending_elr = tasks[current].elr;
    pending_spsr = tasks[current].spsr;
    pending_sp_el0 = tasks[current].sp_el0;
    pending_ttbr0 = tasks[current].ttbr0;
    // Claim 6729: the selected task is now the one that will execute.
    tasks[current].state = .running;
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
    // The preempted task is runnable again; only a zombie is removed from
    // the ring (claim 6729).
    if (tasks[current].state == .running) tasks[current].state = .ready;
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

/// Claim 0635: block the calling task until `ticks` scheduler ticks have
/// passed, then stage its successor. The saved SVC frame stays on the
/// task's kernel stack while blocked; `wake_expired` flips the task back to
/// `ready` and the round-robin resumes it from that same frame, so the
/// syscall return (x0 = 0) lands when it wakes — the identical resume path
/// as `sys_yield`. `ticks == 0` is clamped to 1 (the minimum sleep is one
/// tick, matching the 1 s timer period). Returns false (EINVAL) for the
/// idle task or an inactive/rolled-back pool.
pub fn sleep_current(ticks: u64) bool {
    if (!scheduling_active() or task_count == 0 or current == idle_id) return false;
    if (tasks[current].state != .ready and tasks[current].state != .running) return false;
    const duration = if (ticks == 0) 1 else ticks;
    const deadline = std.math.add(u64, tick_count, duration) catch return false;
    const sleeping = current;
    const name = tasks[sleeping].name;
    // Save the calling task's context (frame SP + ELR/SPSR + SP_EL0), the
    // same seam yield_current uses — the task MUST find its saved SVC frame
    // intact when wake_expired flips it back to ready and the ring resumes
    // it. Unlike exit_current, which never resumes the saved context.
    const pc = current_exception_pc();
    tasks[sleeping].sp = exceptions.resume_frame;
    tasks[sleeping].elr = pc.elr;
    tasks[sleeping].spsr = pc.spsr;
    tasks[sleeping].sp_el0 = exceptions.resume_sp_el0;
    tasks[sleeping].saves += 1;
    tasks[sleeping].state = .blocked;
    tasks[sleeping].wakeup_tick = deadline;
    const next = next_runnable(sleeping) orelse {
        // No successor: roll back (the always-ready idle task makes this
        // unreachable in a normal boot; kept as a defensive bound).
        tasks[sleeping].state = .ready;
        tasks[sleeping].wakeup_tick = 0;
        tasks[sleeping].saves -%= 1;
        return false;
    };
    sleep_report_pending = true;
    sleep_report_name = name;
    sleep_report_ticks = duration;
    current = next;
    stage_current();
    apply_pending();
    return true;
}

/// Claim 0635: timer-driven wakeups. Called once per tick (IRQ context,
/// console-free — claim 9187) AFTER the tick counter advanced: every
/// `blocked` task whose deadline has passed returns to `ready` and is
/// picked up by the ring on the next round. A no-op when nothing sleeps.
fn wake_expired() void {
    var i: usize = 0;
    while (i < max_tasks) : (i += 1) {
        if (tasks[i].state != .blocked) continue;
        if (tick_count < tasks[i].wakeup_tick) continue;
        tasks[i].state = .ready;
        tasks[i].wakeup_tick = 0;
    }
}

/// Host-testable tick seam (mirrors `timer.on_tick`): advance the tick
/// counter and run the timer-driven wakeups. Called by the real `tick`
/// before preemption; host tests call it directly to drive sleepers.
pub fn on_tick() void {
    tick_count +%= 1;
    wake_expired();
}

/// Remove the calling task from the runnable ring and stage its successor.
/// The SVC exception return consumes the staged frame, so the terminated task
/// never resumes after `sys_exit`. Claim 6729: the exiting task becomes a
/// ZOMBIE (its status is preserved for `terminated_status`); the idle task
/// reaps it later. The idle task itself can never be exited.
pub fn exit_current(status: u64) bool {
    if (task_count == 0 or current == idle_id) return false;
    if (tasks[current].state != .ready and tasks[current].state != .running) return false;
    const exiting = current;
    const name = tasks[exiting].name;
    tasks[exiting].state = .zombie;
    tasks[exiting].exit_status = status;
    const next = next_runnable(exiting) orelse {
        // No successor: roll back (the always-ready idle task makes this
        // unreachable in a normal boot; kept as a defensive bound).
        tasks[exiting].state = .ready;
        tasks[exiting].exit_status = 0;
        return false;
    };
    exit_report_pending = true;
    exit_report_name = name;
    exit_report_status = status;
    exits +%= 1;
    current = next;
    stage_current();
    apply_pending();
    return true;
}

/// Claim 6729: reap a zombie — free its pool slot. Only a zombie may be
/// reaped, and the reaped slot becomes spawnable again. Returns false for a
/// non-zombie slot.
pub fn reap(id: usize) bool {
    if (id >= max_tasks or tasks[id].state != .zombie) return false;
    tasks[id] = .{};
    task_count -%= 1;
    return true;
}

/// The idle task's reaper: free ONE zombie per iteration so the pool drains
/// without starving other tasks, and snapshot the reap report (the freed
/// slot's name is zeroed by the reset).
fn reap_one_zombie() void {
    var i: usize = 0;
    while (i < max_tasks) : (i += 1) {
        if (tasks[i].state != .zombie) continue;
        const name = tasks[i].name;
        if (!reap(i)) return;
        if (!reap_report_pending) {
            reap_report_pending = true;
            reap_report_name = name;
        }
        return;
    }
}

/// The scheduler-owned idle task (claim 6729): always ready and the
/// lifecycle reaper — it reaps one zombie per iteration. It parks with a
/// BOUNDED nop delay (not WFE): the shell's idle wait documents that a WFE
/// in a main-context loop sleeps until the next interrupt and can stall the
/// polled-RX loop on VZ (claim 6684), so the idle task uses the same
/// proven bounded delay between reap passes.
fn idle_entry() void {
    while (true) {
        reap_one_zombie();
        if (comptime builtin.cpu.arch == .aarch64) {
            var spins: usize = 0;
            while (spins < 100_000) : (spins += 1) asm volatile ("nop");
        } else {
            asm volatile ("nop");
        }
    }
}

/// The monitor `spawn` command (claim 6729): spawn the lifecycle demo task
/// on its dedicated stack. Explicitly bounded — one demo spawn per boot
/// (the pool has exactly one spare slot while the EL0 task is alive).
pub fn spawn_demo() ?usize {
    if (spawn_demo_armed) return null;
    spawn_demo_armed = true;
    return spawn("spawn-demo", @intFromPtr(&spawn_demo_entry), spsr_el1h_irqs, &spawn_demo_stack, mmu.kernel_root_phys(), 0);
}

/// The lifecycle demo task: bumps its advance counter and asks the shell
/// loop to report it, proving a runtime-spawned task entered the ring and
/// receives quanta. Never exits; the EL0 task exercises the exit/reap half
/// of the lifecycle.
fn spawn_demo_entry() void {
    var local: u64 = 0;
    while (true) {
        local += 1;
        note_advance();
        if (local % 16 == 0) request_report();
        var spins: usize = 0;
        while (spins < 2_000_000) : (spins += 1) asm volatile ("nop");
    }
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
    on_tick();
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
/// counter. Keeps the FIRST snapshot per task while that task's slot is
/// pending (no backlog). Console output stays in main context (claim 9187
/// — never print from IRQ). Claim 6729: per-task slots, so one task's
/// reports cannot starve another's (the worker requests every 64
/// iterations; the spawn-demo task every 16).
pub fn request_report() void {
    if (task_count == 0 or report_pending[current]) return;
    report_pending[current] = true;
    report_advances[current] = tasks[current].advances;
}

/// Shell-side (main context, next to timer.maybe_heartbeat): print every
/// pending report line, then the exit/reap reports.
pub fn maybe_report(con: *console.Console) void {
    var i: usize = 0;
    while (i < max_tasks) : (i += 1) {
        if (!report_pending[i]) continue;
        report_pending[i] = false;
        con.puts("tasks ");
        con.puts(tasks[i].name);
        con.puts(" advances=");
        con.print_u64(report_advances[i]);
        con.puts("\n");
    }
    if (exit_report_pending) {
        exit_report_pending = false;
        con.puts("tasks ");
        con.puts(exit_report_name);
        con.puts(" exited status=");
        con.print_u64(exit_report_status);
        con.puts("\n");
    }
    // Claim 6729: the idle task reaped a zombie; the name was snapshotted
    // at reap time because the freed slot's own name is zeroed.
    if (reap_report_pending) {
        reap_report_pending = false;
        con.puts("tasks ");
        con.puts(reap_report_name);
        con.puts(" reaped\n");
    }
    // Claim 0635: a task blocked itself with sys_sleep; the name + duration
    // were snapshotted at block time (the task is not running now, but the
    // report is the shell's window into the transition).
    if (sleep_report_pending) {
        sleep_report_pending = false;
        con.puts("tasks ");
        con.puts(sleep_report_name);
        con.puts(" sleeping ");
        con.print_u64(sleep_report_ticks);
        con.puts(" ticks\n");
    }
}

// ---------------------------------------------------------------------------
// Monitor-facing stats
// ---------------------------------------------------------------------------

pub const TaskInfo = struct {
    name: []const u8,
    state: State,
    saves: u64,
    resumes: u64,
    advances: u64,
};

pub const Stats = struct {
    enabled: bool,
    current: usize,
    switches: u64,
    /// Registered (non-free) slots — the lifecycle's live pool count.
    count: usize,
    /// Zombie slots awaiting the idle task's reap.
    zombies: usize,
};

pub fn stats() Stats {
    var zombies: usize = 0;
    for (tasks[0..max_tasks]) |task| {
        if (task.state == .zombie) zombies += 1;
    }
    return .{
        .enabled = enabled_flag,
        .current = current,
        .switches = switches,
        .count = task_count,
        .zombies = zombies,
    };
}

pub fn task_info(id: usize) ?TaskInfo {
    if (id >= max_tasks or tasks[id].state == .free) return null;
    return .{
        .name = tasks[id].name,
        .state = tasks[id].state,
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
    if (id >= max_tasks or tasks[id].state == .free) return 0;
    return tasks[id].ttbr0;
}

pub fn cooperative_yield_count() u64 {
    return cooperative_yields;
}

pub fn exit_count() u64 {
    return exits;
}

pub fn is_terminated(id: usize) bool {
    return id < max_tasks and tasks[id].state == .zombie;
}

/// Claim 0635: true when the slot holds a task blocked by `sys_sleep`.
pub fn is_blocked(id: usize) bool {
    return id < max_tasks and tasks[id].state == .blocked;
}

pub fn terminated_status(id: usize) ?u64 {
    if (!is_terminated(id)) return null;
    return tasks[id].exit_status;
}

// ---------------------------------------------------------------------------
// Tests (host-side; the asm tick is proven on real VZ hardware by the
// class B gate tools/verify-live-tasks.sh)
// ---------------------------------------------------------------------------

test "scheduler: init registers the shell and idle tasks; start flips enabled" {
    try std.testing.expectEqual(@as(usize, 0), init());
    // Claim 6729: the pool starts as shell + the scheduler-owned idle task
    // (the idle task's synthetic frame targets `idle_entry`).
    try std.testing.expectEqual(@as(usize, 2), task_count);
    try std.testing.expectEqualStrings("shell", tasks[0].name);
    try std.testing.expectEqualStrings("idle", tasks[idle_id].name);
    try std.testing.expectEqual(State.ready, tasks[idle_id].state);
    try std.testing.expectEqual(@intFromPtr(&idle_entry), tasks[idle_id].elr);
    try std.testing.expect(!enabled());
    try std.testing.expect(!scheduling_active());
    start();
    try std.testing.expect(enabled());
    // Two runnable tasks (shell + idle) are enough for the tick to switch.
    try std.testing.expect(scheduling_active());
}

test "scheduler: register_worker builds a valid synthetic frame" {
    _ = init();
    const entry: u64 = 0x1234_5678_9abc_def0;
    try std.testing.expectEqual(@as(usize, 1), register_worker(entry).?);
    try std.testing.expectEqual(@as(usize, 3), task_count); // shell + idle + worker
    const t = &tasks[1];
    try std.testing.expectEqual(entry, t.elr);
    try std.testing.expectEqual(spsr_el1h_irqs, t.spsr);
    try std.testing.expectEqual(State.ready, t.state);
    // Frame: 160 bytes below the stack top; the x30 slot holds the park
    // address; every other slot is zeroed (the stub pops them as x0..x17).
    const stack_top = @intFromPtr(&worker_stack) + worker_stack.len;
    try std.testing.expectEqual(stack_top - frame_bytes, t.sp);
    try std.testing.expectEqual(@intFromPtr(&park), std.mem.readInt(u64, @as(*const [8]u8, @ptrFromInt(t.sp)), .little));
    var i: usize = 8;
    while (i < frame_bytes) : (i += 8) {
        try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, @as(*const [8]u8, @ptrFromInt(t.sp + i)), .little));
    }
    // Claim 6729: the pool is shell + idle + worker + user + one spare
    // spawnable slot; a sixth registration fails (bounded).
    try std.testing.expectEqual(@as(usize, 2), register_user(0x3333, 0).?);
    try std.testing.expectEqual(@as(usize, 3), register_worker(0).?);
    try std.testing.expectEqual(@as(usize, 5), task_count);
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
    _ = register_user(0x3000, 0).?;
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
    // Second switch: the worker is preempted; the user task is restored to
    // its synthetic EL0t frame.
    switch_context(0x2000, 0x2000, 0x5, 0xbbbb);
    try std.testing.expectEqual(@as(usize, 2), current);
    try std.testing.expectEqual(@as(u64, 2), switches);
    try std.testing.expectEqual(@as(u64, 1), tasks[1].saves);
    try std.testing.expectEqual(@as(u64, 1), tasks[1].resumes);
    try std.testing.expectEqual(tasks[2].sp, pending_sp);
    try std.testing.expectEqual(@as(u64, 0x3000), pending_elr);
    try std.testing.expectEqual(spsr_el0t_irqs, pending_spsr);
    // Third switch: the user is preempted; the idle task is restored.
    switch_context(0x3000, 0x3000, 0x0, 0xcccc);
    try std.testing.expectEqual(@as(usize, idle_id), current);
    try std.testing.expectEqual(@as(u64, 3), switches);
    try std.testing.expectEqual(@as(u64, 1), tasks[2].saves);
    try std.testing.expectEqual(@as(u64, 1), tasks[idle_id].resumes);
    try std.testing.expectEqual(tasks[idle_id].sp, pending_sp);
    // Fourth switch: the idle task is preempted; the shell is restored to
    // its exact saved context (the round-trip).
    switch_context(0x4000, 0x4000, 0x5, 0xdddd);
    try std.testing.expectEqual(@as(usize, 0), current);
    try std.testing.expectEqual(@as(u64, 4), switches);
    try std.testing.expectEqual(@as(u64, 1), tasks[idle_id].saves);
    try std.testing.expectEqual(@as(u64, 1), tasks[0].resumes);
    try std.testing.expectEqual(@as(u64, 0x1000), pending_sp);
    try std.testing.expectEqual(@as(u64, 0x1000), pending_elr);
    try std.testing.expectEqual(@as(u64, 0x5), pending_spsr);
    try std.testing.expectEqual(@as(u64, 0xaaaa), pending_sp_el0);
    // Fifth switch returns to the worker's saved context (the round-trip).
    switch_context(0x1000, 0x1001, 0x5, 0xaaaa);
    try std.testing.expectEqual(@as(usize, 1), current);
    try std.testing.expectEqual(@as(u64, 5), switches);
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
    // Claim 6729: the preempted EL0 task's successor is the idle task
    // (sp_el0 = 0 for an EL1h task), then the shell on the next switch.
    switch_context(0x3000, 0x3004, spsr_el0t_irqs, preempted_user_sp); // user -> idle
    try std.testing.expectEqual(@as(usize, idle_id), current);
    try std.testing.expectEqual(@as(u64, 0), pending_sp_el0);
    try std.testing.expectEqual(preempted_user_sp, tasks[2].sp_el0);
    switch_context(0x4000, 0x4000, spsr_el1h_irqs, 0xcccc); // idle -> shell
    try std.testing.expectEqual(@as(usize, 0), current);
    try std.testing.expectEqual(@as(u64, 0xaaaa), pending_sp_el0);

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
    // Cooperative switching cannot satisfy the claim-8215 witness. The
    // user's successor is the idle task (claim 6729), then the shell.
    try std.testing.expect(yield_current()); // user -> idle
    try std.testing.expectEqual(@as(u64, 0), user_timer_preemption_count());
    switch_context(0x4000, 0x4000, spsr_el1h_irqs, 0xcccc); // idle -> shell
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
    try std.testing.expectEqual(@as(usize, 3), s.count); // shell + idle + worker
    try std.testing.expectEqual(@as(usize, 0), s.zombies);
    try std.testing.expectEqual(@as(usize, 0), s.current);
    try std.testing.expectEqual(@as(u64, 0), s.switches);
    const shell = task_info(0).?;
    try std.testing.expectEqualStrings("shell", shell.name);
    try std.testing.expectEqual(State.ready, shell.state);
    try std.testing.expectEqual(@as(u64, 0), shell.saves);
    try std.testing.expectEqual(@as(u64, 0), shell.advances);
    const worker = task_info(1).?;
    try std.testing.expectEqualStrings("worker", worker.name);
    try std.testing.expect(task_info(2) == null);
    const idle = task_info(idle_id).?;
    try std.testing.expectEqualStrings("idle", idle.name);
    try std.testing.expectEqual(State.ready, idle.state);
}

test "scheduler: cooperative exit is non-runnable and reports from shell" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    try std.testing.expect(exit_current(7)); // user -> idle (the ring's fallback)
    try std.testing.expectEqual(@as(usize, idle_id), current_id());
    try std.testing.expect(is_terminated(2));
    try std.testing.expectEqual(@as(?u64, 7), terminated_status(2));
    // The next switches skip the zombie user: idle -> shell -> worker -> idle.
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 0), current_id());
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 1), current_id());
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, idle_id), current_id());
    var mock = console.MockConsole(128){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expectEqualStrings("tasks user-el0 exited status=7\n", mock.contents());
}

test "scheduler: sleep_current blocks, wakes on the deadline tick, and rolls back" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    // current is shell (0). Sleep 2 ticks: shell -> blocked, worker next.
    try std.testing.expect(sleep_current(2));
    try std.testing.expect(is_blocked(0));
    try std.testing.expectEqual(@as(u64, 2), tasks[0].wakeup_tick);
    try std.testing.expectEqual(@as(usize, 1), current);
    // The blocked task drops out of the ring: worker -> user -> idle -> worker.
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 2), current);
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, idle_id), current);
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 1), current);
    // Tick 1: deadline (tick_count 0 + 2) not reached yet.
    on_tick();
    try std.testing.expect(is_blocked(0));
    try std.testing.expectEqual(@as(u64, 1), tick_count);
    // Tick 2: the timer-driven wakeup flips the sleeper back to ready.
    on_tick();
    try std.testing.expect(!is_blocked(0));
    try std.testing.expectEqual(State.ready, tasks[0].state);
    try std.testing.expectEqual(@as(u64, 0), tasks[0].wakeup_tick);
    // The ring reaches the woken shell again.
    try std.testing.expect(yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), current);
    try std.testing.expect(yield_current()); // user -> idle
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expectEqual(@as(usize, 0), current);
}

test "scheduler: sleep guards — zero clamps to one tick, idle and inactive fail" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    // Inactive pool: no switching.
    try std.testing.expect(!sleep_current(1));
    start();
    // sleep(0) clamps to one tick and still blocks.
    try std.testing.expect(sleep_current(0));
    try std.testing.expectEqual(@as(u64, 1), tasks[0].wakeup_tick);
    // The idle task cannot sleep (it is the ring's fallback).
    current = idle_id;
    try std.testing.expect(!sleep_current(1));
    try std.testing.expect(!is_blocked(idle_id));
    // A zombie cannot sleep either.
    tasks[1].state = .zombie;
    current = 1;
    try std.testing.expect(!sleep_current(1));
}

test "scheduler: a blocked user task still owns the user root (exec gate)" {
    // Give the user root a real (non-zero) value so the gate is unambiguous
    // on the host: the EL1h tasks carry the kernel root (0), the user task
    // carries the built root (same pattern as the exec.zig tests).
    try std.testing.expect(mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192));
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    // The ready user task already owns the user root.
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    try std.testing.expect(user_root_in_use());
    // Claim 0635: a SLEEPING user program still owns the root — the old
    // ready/running-only check would have let exec rebuild it underneath
    // the blocked task.
    try std.testing.expect(sleep_current(2)); // user -> idle
    try std.testing.expect(is_blocked(2));
    try std.testing.expect(user_root_in_use());
    // After the deadline passes the task is ready again (still live).
    on_tick();
    on_tick();
    try std.testing.expect(!is_blocked(2));
    try std.testing.expect(user_root_in_use());
    // Only after exit + reap does the gate release. The ring order from
    // idle (4) wraps through shell (0) -> worker (1) -> user (2).
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    try std.testing.expect(exit_current(7)); // user -> idle
    try std.testing.expect(reap(2));
    try std.testing.expect(!user_root_in_use());
}

test "scheduler: lifecycle — spawn, exit to zombie, idle reaps back to free" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    // The pool is shell + worker + user + idle; the spare slot is the
    // monitor demo spawn (claim 6729). One spawn per boot, bounded.
    try std.testing.expectEqual(@as(usize, 3), spawn_demo().?);
    try std.testing.expect(spawn_demo() == null);
    try std.testing.expectEqual(@as(usize, 5), stats().count);
    try std.testing.expectEqualStrings("spawn-demo", task_info(3).?.name);
    try std.testing.expectEqual(State.ready, task_info(3).?.state);
    // user exits -> zombie at slot 2; the ring's next ready task is the
    // spawn-demo task (slot 3).
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    try std.testing.expect(exit_current(7)); // user -> spawn-demo
    try std.testing.expectEqual(@as(usize, 3), current_id());
    try std.testing.expectEqual(@as(usize, 1), stats().zombies);
    try std.testing.expect(is_terminated(2));
    try std.testing.expectEqual(@as(?u64, 7), terminated_status(2));
    // The idle task reaps one zombie per iteration; the slot returns free.
    reap_one_zombie();
    try std.testing.expect(!is_terminated(2));
    try std.testing.expectEqual(@as(usize, 0), stats().zombies);
    try std.testing.expectEqual(@as(usize, 4), stats().count);
    try std.testing.expect(task_info(2) == null);
    // The freed slot is spawnable again (the lifecycle is a closed loop).
    try std.testing.expectEqual(@as(usize, 2), spawn("revived", 0x5000, spsr_el1h_irqs, &worker_stack, 0, 0).?);
    try std.testing.expectEqual(@as(usize, 5), stats().count);
    // The shell loop prints the exit and the reap, in order.
    var mock = console.MockConsole(256){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expectEqualStrings("tasks user-el0 exited status=7\ntasks user-el0 reaped\n", mock.contents());
}
