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
// Milestone four (claim 3848): the process registry — the task pool is the
// executor, the process owns the program (image + address space + lifecycle
// + exit status). One-way import: process.zig knows nothing about this
// module.
const process = @import("process.zig");
// Card 3f (claim 5965): the per-process IPC mailbox — the pool reset
// clears it and the boot payload's process registration resets its ring.
const mailbox = @import("mailbox.zig");
// Card G6 teardown follow-on (per-process window ownership): the exit path
// auto-closes the exiting process's user windows via `close_owner`. Pure
// BSS writes, safe in the exception context `exit_current` runs in.
const driving_award = @import("driving_award.zig");

const user_stack_section = if (builtin.object_format == .elf) ".userbss" else "__DATA,__userbss";

/// Round-robin pool (card 3g, claim 5795 — the pool-scale capstone):
/// shell + EL1h demo worker + FOUR EL0t user slots + the scheduler-owned
/// idle task — FOUR live user programs at once (shell + worker + 4 users +
/// idle = 7/7; the 4th user slot is the "spare" while only three are
/// live). Fixed at comptime — no allocation, no dynamic registration or
/// processes; the lifecycle's spawn/reap only recycle these slots. Every
/// prior card documented the 5-slot budget (3b/3c/3f: "5/5, NO spare");
/// the capstone deliberately raises it and re-derives the gates.
pub const max_tasks: usize = 7;
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

/// Card 3c (claim 7786): the reserved exit status a force-terminated
/// process reports. A plain number (128 + 9) — no POSIX semantics; it is
/// the counter's `exit=137` / `tasks user-exec exited status=137` in the
/// serial log and the `procs` table.
pub const reserved_kill_status: u64 = 137;

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

/// Claim 0826: the uaccess/syscall apertures a user task's syscalls
/// validate against (its OWN text + stack VAs — every live user task has
/// its own root + stack now). Zero for EL1h tasks (they never SVC).
pub const UserRegions = struct {
    text: userspace.Region = .{ .base = 0, .len = 0 },
    stack: userspace.Region = .{ .base = 0, .len = 0 },
};

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
    /// Claim 0826: the user text/stack apertures this task's syscalls
    /// validate against (armed into the syscall layer at SVC entry). Each
    /// live user task carries its own regions; EL1h tasks leave them zero.
    regions: UserRegions = .{},
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
    /// Card 4c (claim 9946): the process id this blocked task waits on via
    /// `sys_wait` (slot 8). Set by `wait_current`; cleared when
    /// `wake_waiters` returns the task to `ready` on the target's exit. An
    /// EVENT block (no deadline) — distinct from the claim-0635 time block
    /// that uses `wakeup_tick`; the tick's `wake_expired` never touches a
    /// task with this field set.
    wait_pid: ?usize = null,
    /// Card 3c (claim 7786): armed-kill flag. `kill` sets it from main
    /// context; the ring converts the task's NEXT selection into the
    /// existing exit path (status 137) instead of resuming it — the OS,
    /// not the program, owns process lifetime. Reset by the slot's reap
    /// (`.{ }` clears it).
    kill_pending: bool = false,
};

var tasks: [max_tasks]Task = .{ .{}, .{}, .{}, .{}, .{}, .{}, .{} };
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
/// Card 3d (claim 1014): the task exit + reap reports are bounded FIFOs,
/// not single first-wins flags — N exits (or reaps) in one idle-loop
/// window print N lines IN ORDER instead of collapsing to one. Task names
/// are static string literals, so the name POINTER is a safe snapshot.
/// Overflow (a full ring) drops the OLDEST entry (documented + host-tested).
pub const exit_report_max: usize = 4;
const ExitEntry = struct { name: []const u8, status: u64 };
const ReapEntry = struct { name: []const u8 };
var exit_reports: [exit_report_max]ExitEntry = [_]ExitEntry{.{ .name = "", .status = 0 }} ** exit_report_max;
var exit_report_head: usize = 0;
var exit_report_count: usize = 0;
var reap_reports: [exit_report_max]ReapEntry = [_]ReapEntry{.{ .name = "" }} ** exit_report_max;
var reap_report_head: usize = 0;
var reap_report_count: usize = 0;
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
    exit_report_head = 0;
    exit_report_count = 0;
    reap_report_head = 0;
    reap_report_count = 0;
    sleep_report_pending = false;
    spawn_demo_armed = false;
    user_timer_preemptions = 0;
    tick_count = 0;
    for (&tasks) |*task| task.* = .{};
    // Claim 3848: every pool reset also clears the process layer (the
    // boot path initializes both here; host tests get isolation). Card 3f
    // (claim 5965): the IPC mailbox rings reset with it.
    process.init();
    mailbox.init();
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
///
/// Claim 6783 + claim 0826: register the ESP-loaded user program (exec) as
/// an EL0t task. The caller (`exec.zig`) has already built the process's
/// OWN user root and allocated its OWN user stack + EL1 exception stack, so
/// every parameter is per-process: `entry_va` (user VA), `root_phys` (the
/// process's TTBR0 root — NOT the shared global), `text_len`/`stack_va`/
/// `stack_len` (the process's apertures, recorded in the TCB so the syscall
/// layer arms the right bounds at SVC entry), and `kstack` (the process's
/// EL1 exception stack — two live user tasks cannot share the static one:
/// a second task's exception frame would clobber the first's saved vector
/// frame). The pool's spare slot (the claim-6729 `spawn_demo` pattern) is
/// the second live user slot; `spawn` returning null is the capacity gate.
pub fn register_exec_user(
    entry_va: u64,
    root_phys: u64,
    text_len: u64,
    stack_va: u64,
    stack_len: u64,
    kstack: []u8,
    argc: u64,
    argv_va: u64,
) ?usize {
    const sp_el0 = stack_va + stack_len;
    const id = spawn("user-exec", entry_va, spsr_el0t_irqs, kstack, root_phys, sp_el0) orelse return null;
    tasks[id].regions = .{
        .text = .{ .base = userspace.text_va, .len = text_len },
        .stack = .{ .base = stack_va, .len = stack_len },
    };
    // Card 3e (claim 4636): the entry-contract extension — the exec'd
    // program's `_start` receives argc in x0 and the argv block VA in x1.
    // `build_initial_frame` zeroes the whole frame (x0/x1 are 0 at the
    // boot payload's entry), so write the two slots here — the same seam
    // `register_user` uses for the timer-witness VA in slot x9. A no-args
    // exec passes argc=0/argv_va=0: identical to the zeroed frame, so
    // earlier cards' no-args behavior is byte-for-byte unchanged.
    const frame: *exceptions.VectorFrame = @ptrFromInt(tasks[id].sp);
    _ = exceptions.frame_write(frame, 0, argc);
    _ = exceptions.frame_write(frame, 1, argv_va);
    return id;
}

/// Claim 0826: the pool has at least one free slot (the exec gate — a new
/// program may load and run while another is alive; only the fixed pool
/// bounds how many). The exec path checks this BEFORE allocating pages or
/// tables, so a full pool fails cheaply with `pool_full` and never leaks.
pub fn has_free_slot() bool {
    for (tasks[0..max_tasks]) |task| {
        if (task.state == .free) return true;
    }
    return false;
}

/// Card 3c (claim 7786): the result of arming a task for termination.
/// `request_kill` only ARMS — the actual exit happens at the task's next
/// ring selection (`stage_current` converts the selection into the
/// existing exit path). The refusals are clean and exact (the `kill`
/// monitor command host-tests every string).
pub const KillResult = enum {
    /// The target is armed; it will exit with `reserved_kill_status` at
    /// its next scheduled quantum (or yield/sleep wake).
    ok,
    /// No task occupies that slot (never registered or already reaped).
    not_found,
    /// The target is already a zombie (it exited and awaits the reap).
    already_exited,
    /// The shell or the scheduler-owned idle task: the console must
    /// survive (killing the shell would end the session).
    refused,
};

/// Arm pool slot `id` for termination (card 3c). The kill takes effect
/// at the target's next ring selection: `stage_current` sees
/// `kill_pending` and calls the existing `exit_current(reserved_kill_status)`
/// instead of resuming the task — the full exit → zombie → idle-reap →
/// page-return lifecycle runs, with the reserved status reported. Pure
/// TCB write, safe from the monitor's main context. Returns the exact
/// refusal for unknown/already-exited/scheduler-owned targets.
pub fn request_kill(id: usize) KillResult {
    if (id >= max_tasks or tasks[id].state == .free) return .not_found;
    if (tasks[id].state == .zombie) return .already_exited;
    // The shell (id 0) owns the console and the idle task is
    // scheduler-owned (never exits — exit_current refuses it anyway);
    // neither may be force-terminated.
    if (id == idle_id or id == 0) return .refused;
    tasks[id].kill_pending = true;
    return .ok;
}

/// The user apertures of the CURRENT task (the EL0t task about to SVC —
/// zero for EL1h tasks). The syscall layer arms these into uaccess at SVC
/// entry so `sys_write` bounds always follow the task that issued the call.
pub fn current_user_regions() UserRegions {
    return tasks[current].regions;
}

/// Physical address of the static user stack pages (claim 6783: the boot
/// payload's stack — exec'd programs now own allocator-backed stack pages
/// instead, claim 0826). Identity on host tests.
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
    const text = userspace.text_va_region();
    const stack = userspace.stack_va_region();
    const id = spawn("user-el0", entry_va, spsr_el0t_irqs, &user_kernel_stack, mmu.user_root_phys(), sp_el0) orelse return null;
    // Claim 0826: the boot payload carries its static apertures in the TCB
    // so the syscall layer can arm them at SVC entry like any user task.
    tasks[id].regions = .{ .text = text, .stack = stack };
    // Claim 3848: the boot-time static EL0 payload is a PROCESS too — the
    // one table shows both its lifecycle and the exec'd programs'. Its
    // image is the static payload (no file name) and its address space is
    // the current user root at the fixed stack placement. Best effort: a
    // full registry (impossible at boot) must not fail the payload.
    if (process.create("user-el0", .{ .entry_va = entry_va, .content_len = text.len }, .{
        .root_phys = mmu.user_root_phys(),
        .text_va = text.base,
        .text_len = text.len,
        .stack_va = stack.base,
        .stack_len = stack.len,
    }, .{})) |proc_id| {
        // Card 3f (claim 5965): the payload's process id starts with a
        // clean IPC ring (same reset the exec path applies).
        mailbox.reset(proc_id);
        _ = process.bind(proc_id, id);
    }
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
    // Card 3c (claim 7786): a selected task with a pending kill is NOT
    // resumed — the ring converts its selection into the existing exit
    // path with the reserved status (the OS owns process lifetime). The
    // task's saved frame is abandoned; `exit_current` stages the next
    // task, so the killed task never executes again. `current` is the
    // selected task and its state is `ready` (exactly what exit_current
    // accepts), so this is the real exit/reap/pages-return lifecycle, not
    // a special teardown. No switching-core change: the same frame/ELR/
    // SPSR/TTBR0 machinery that follows any exit is used.
    if (tasks[current].kill_pending) {
        tasks[current].kill_pending = false;
        _ = exit_current(reserved_kill_status);
        return;
    }
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

/// Card 4c (claim 9946): block the calling task until the PROCESS with id
/// `target_pid` exits, then stage its successor. The same seam as
/// `sleep_current` — the caller's saved SVC frame stays on its kernel
/// stack while blocked, and `wake_waiters` flips the task back to `ready`
/// the moment the target exits (the round-robin then resumes it from that
/// same frame). The exit status is unknowable at block time, so the wake
/// patches it into the saved frame's x0; the syscall return lands with the
/// status when the caller resumes. Returns false (EINVAL) for the idle
/// task or an inactive/rolled-back pool.
pub fn wait_current(target_pid: usize) bool {
    if (!scheduling_active() or task_count == 0 or current == idle_id) return false;
    if (tasks[current].state != .ready and tasks[current].state != .running) return false;
    const waiting = current;
    const pc = current_exception_pc();
    // Save the calling task's context (frame SP + ELR/SPSR + SP_EL0), the
    // same seam yield_current/sleep_current use — the task MUST find its
    // saved SVC frame intact when the target exits and the ring resumes it.
    tasks[waiting].sp = exceptions.resume_frame;
    tasks[waiting].elr = pc.elr;
    tasks[waiting].spsr = pc.spsr;
    tasks[waiting].sp_el0 = exceptions.resume_sp_el0;
    tasks[waiting].saves += 1;
    tasks[waiting].state = .blocked;
    tasks[waiting].wait_pid = target_pid;
    const next = next_runnable(waiting) orelse {
        // No successor: roll back (the always-ready idle task makes this
        // unreachable in a normal boot; kept as a defensive bound).
        tasks[waiting].state = .ready;
        tasks[waiting].wait_pid = null;
        tasks[waiting].saves -%= 1;
        return false;
    };
    current = next;
    stage_current();
    apply_pending();
    return true;
}

/// Card 4c (claim 9946): the target process just exited with `status` —
/// every task blocked in `sys_wait` on pid `pid` returns to `ready` and
/// its saved SVC frame's x0 is patched with the observed status (the
/// syscall result `handle_wait` could not know at block time). Called from
/// the EXIT path (`exit_current`, right after the registry records the
/// exit) — pure TCB + saved-frame writes, safe in the exception context
/// (no console, no allocation). Multiple waiters on one pid all wake with
/// the same status; a blocked waiter can never outlive its target (a
/// process is only reaped AFTER it exits, which wakes the waiter first).
fn wake_waiters(pid: usize, status: u64) void {
    var i: usize = 0;
    while (i < max_tasks) : (i += 1) {
        if (tasks[i].state != .blocked) continue;
        if (tasks[i].wait_pid != pid) continue;
        tasks[i].state = .ready;
        tasks[i].wait_pid = null;
        const frame: *exceptions.VectorFrame = @ptrFromInt(tasks[i].sp);
        _ = exceptions.frame_write(frame, 0, status);
    }
}

/// Claim 0635: timer-driven wakeups. Called once per tick (IRQ context,
/// console-free — claim 9187) AFTER the tick counter advanced: every
/// `blocked` task whose deadline has passed returns to `ready` and is
/// picked up by the ring on the next round. A no-op when nothing sleeps.
fn wake_expired() void {
    var i: usize = 0;
    while (i < max_tasks) : (i += 1) {
        if (tasks[i].state != .blocked) continue;
        // Card 4c (claim 9946): an event-blocked task (`sys_wait` — no
        // deadline) is woken by `wake_waiters`, never by the tick clock.
        if (tasks[i].wait_pid != null) continue;
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
    // Claim 3848: the exiting task's PROCESS (if any) becomes exited and
    // snapshots the status — the process-level exit report and `procs`
    // keep it after the slot is reaped. Pure registry writes, safe in the
    // exception context this runs in (no console, no allocation). Card 4c
    // (claim 9946): the returned pid wakes every task blocked in `sys_wait`
    // on this process — their saved frames get the observed status patched
    // into x0, so the syscall return lands when the ring resumes them.
    if (process.on_task_exit(exiting, status)) |pid| {
        wake_waiters(pid, status);
        // Per-process window ownership: the exiting process's user windows
        // are released NOW (the real teardown semantic — no window leaks
        // until reboot). Pure BSS writes (registry compaction + dirty
        // marks), safe in this exception context.
        _ = driving_award.close_owner(pid);
    }
    const next = next_runnable(exiting) orelse {
        // No successor: roll back (the always-ready idle task makes this
        // unreachable in a normal boot; kept as a defensive bound).
        tasks[exiting].state = .ready;
        tasks[exiting].exit_status = 0;
        return false;
    };
    // Card 3d (claim 1014): EVERY exit is queued (a full ring drops the
    // oldest) — N exits in one window print N lines in order.
    if (exit_report_count == exit_report_max) {
        exit_report_head = (exit_report_head + 1) % exit_report_max;
        exit_report_count -= 1;
    }
    const report_index = (exit_report_head + exit_report_count) % exit_report_max;
    exit_reports[report_index] = .{ .name = name, .status = status };
    exit_report_count += 1;
    exits +%= 1;
    current = next;
    stage_current();
    apply_pending();
    return true;
}

/// Claim 6729: reap a zombie — free its pool slot. Only a zombie may be
/// reaped, and the reaped slot becomes spawnable again. Returns false for a
/// non-zombie slot. Claim 4613: the exited process that last ran on this
/// slot has its allocator-backed pages (text/user-stack/EL1-exception-
/// stack) returned to the physical allocator at the same reap — the
/// exited descriptor (name, status, stack VA) stays in the `procs` table
/// for the claim-3848 exit record, but the memory is recycled immediately.
pub fn reap(id: usize) bool {
    if (id >= max_tasks or tasks[id].state != .zombie) return false;
    _ = process.release_pages_on_reap(id);
    tasks[id] = .{};
    task_count -%= 1;
    return true;
}

/// The idle task's reaper: free ONE zombie per iteration so the pool drains
/// without starving other tasks, and snapshot the reap report (the freed
/// slot's name is zeroed by the reset). Claim 4613: `reap` also frees the
/// exited process's allocator-backed pages, so a permanent occupant
/// (COUNTER.BIN) coexists with a steady exec → exit → reap → re-exec
/// cycle without leaking.
fn reap_one_zombie() void {
    var i: usize = 0;
    while (i < max_tasks) : (i += 1) {
        if (tasks[i].state != .zombie) continue;
        const name = tasks[i].name;
        if (!reap(i)) return;
        // Card 3d (claim 1014): EVERY reap is queued (a full ring drops
        // the oldest) — two reaps in one idle-loop window print two lines
        // in order instead of collapsing.
        if (reap_report_count == exit_report_max) {
            reap_report_head = (reap_report_head + 1) % exit_report_max;
            reap_report_count -= 1;
        }
        const report_index = (reap_report_head + reap_report_count) % exit_report_max;
        reap_reports[report_index] = .{ .name = name };
        reap_report_count += 1;
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
    // Card 3d (claim 1014): drain the task exit report FIFO IN ORDER — N
    // exits in one window print N `tasks <name> exited status=<n>` lines.
    while (exit_report_count > 0) {
        const entry = exit_reports[exit_report_head];
        exit_report_head = (exit_report_head + 1) % exit_report_max;
        exit_report_count -= 1;
        con.puts("tasks ");
        con.puts(entry.name);
        con.puts(" exited status=");
        con.print_u64(entry.status);
        con.puts("\n");
    }
    // Claim 3848: the process-level exit reports — printed from the same
    // shell idle loop, one per process exit IN ORDER, so the host sees
    // every program's exit status even after the task slots are reaped.
    while (process.take_exit_report()) |r| {
        con.puts("procs ");
        con.puts(r.name);
        con.puts(" exited status=");
        con.print_u64(r.status);
        con.puts("\n");
    }
    // Claim 6729: the idle task reaped zombies; the names were snapshotted
    // at reap time because the freed slots' own names are zeroed. Card 3d:
    // drained IN ORDER (every reap prints).
    while (reap_report_count > 0) {
        const entry = reap_reports[reap_report_head];
        reap_report_head = (reap_report_head + 1) % exit_report_max;
        reap_report_count -= 1;
        con.puts("tasks ");
        con.puts(entry.name);
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
    // Claim 0826: shell + idle leave three free slots (the capacity gate).
    try std.testing.expect(has_free_slot());
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
    // Card 3g (claim 5795): the pool is shell + idle + worker + FOUR user
    // slots (four live programs at the 7/7 budget); a registration beyond
    // the 7-slot budget fails (bounded).
    try std.testing.expectEqual(@as(usize, 2), register_user(0x3333, 0).?);
    try std.testing.expectEqual(@as(usize, 3), register_worker(0).?);
    try std.testing.expectEqual(@as(usize, 4), register_worker(0).?);
    try std.testing.expectEqual(@as(usize, 5), register_worker(0).?);
    try std.testing.expectEqual(@as(usize, 7), task_count);
    try std.testing.expect(register_worker(0) == null);
    // Claim 0826: capacity is observable — the full pool has no free slot.
    try std.testing.expect(!has_free_slot());
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

test "scheduler: register_exec_user passes argc and argv VA through the x0/x1 frame slots" {
    // Card 3e (claim 4636): the entry-contract extension — the exec'd
    // program's `_start` receives argc in x0 and the argv block VA in x1.
    // `build_initial_frame` zeroes the frame, so `register_exec_user`
    // writes the two slots (the same seam `register_user` uses for the
    // timer-witness VA in slot x9). A no-args exec passes 0/0: identical
    // to the zeroed frame, so earlier cards' no-args behavior is unchanged.
    _ = init();
    _ = register_worker(0x2000).?;
    var kstack: [task_stack_size]u8 align(16) = undefined;
    const id = register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 2, 0x4000_0064).?;
    const frame: *exceptions.VectorFrame = @ptrFromInt(tasks[id].sp);
    try std.testing.expectEqual(@as(u64, 2), exceptions.frame_read(frame, 0));
    try std.testing.expectEqual(@as(u64, 0x4000_0064), exceptions.frame_read(frame, 1));
    const id2 = register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    const frame2: *exceptions.VectorFrame = @ptrFromInt(tasks[id2].sp);
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(frame2, 0));
    try std.testing.expectEqual(@as(u64, 0), exceptions.frame_read(frame2, 1));
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
    // Claim 3848: the same exit also produced the PROCESS-level report
    // (the exited user-el0 process keeps its status past the task reap).
    try std.testing.expectEqualStrings("tasks user-el0 exited status=7\nprocs user-el0 exited status=7\n", mock.contents());
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

test "scheduler: two live user tasks coexist with their own roots and regions" {
    // Claim 0826: the exec gate is gone — a second user program loads and
    // runs while the first is alive. Give each a DISTINCT user root and
    // user stack (per-process address spaces), and pin the per-task
    // syscall regions that follow the TCB at SVC entry.
    _ = init();
    _ = register_worker(0x2000).?;
    // Build A's root FIRST (the boot payload registers against the current
    // global root, like the real boot), then B's own root for the second
    // live program.
    const root_a = (mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult);
    // Pin the boot payload's stack placement explicitly: the module-global
    // current_stack_va can be left at a rebuilt (ASLR) placement by earlier
    // exec-path tests in the same process, and register_user derives the
    // payload's stack region from it. This test pins the per-task regions
    // mechanism, not the ASLR default.
    userspace.set_stack_va(userspace.stack_va);
    const user_a = register_user(0x3000, 0).?;
    try std.testing.expectEqual(@as(usize, 2), user_a);
    const root_b = (mmu.build_user_root(userspace.text_va, 0x1000, 64, 0x1a400000, 0x3000, 8192) orelse return error.TestUnexpectedResult);
    var kstack_b_bytes: [task_stack_size]u8 align(16) = undefined;
    const kstack_b = kstack_b_bytes[0..];
    const user_b = register_exec_user(0x4000, root_b, 64, 0x1a400000, 8192, kstack_b, 0, 0).?;
    try std.testing.expectEqual(@as(usize, 3), user_b);
    // Card 3g (claim 5795): the 7-slot pool holds FOUR user tasks. Fill
    // the remaining two slots so the capacity gate is observable at the
    // new budget.
    var kstack_c_bytes: [task_stack_size]u8 align(16) = undefined;
    const kstack_c = kstack_c_bytes[0..];
    const user_c = register_exec_user(0x5000, root_b, 64, 0x1b400000, 8192, kstack_c, 0, 0).?;
    try std.testing.expectEqual(@as(usize, 4), user_c);
    var kstack_d_bytes: [task_stack_size]u8 align(16) = undefined;
    const kstack_d = kstack_d_bytes[0..];
    const user_d = register_exec_user(0x6000, root_b, 64, 0x1c400000, 8192, kstack_d, 0, 0).?;
    try std.testing.expectEqual(@as(usize, 5), user_d);
    try std.testing.expectEqual(@as(usize, 7), task_count); // shell + worker + A + B + C + D + idle
    try std.testing.expect(!has_free_slot());
    // Each task carries ITS OWN root and apertures.
    try std.testing.expect(task_ttbr0(user_a) != task_ttbr0(user_b));
    try std.testing.expectEqual(root_a, task_ttbr0(user_a));
    try std.testing.expectEqual(root_b, task_ttbr0(user_b));
    // The current-task regions follow the ring: put A current and read its
    // regions, then B.
    current = user_a;
    const ra = current_user_regions();
    try std.testing.expectEqual(userspace.text_va, ra.text.base);
    try std.testing.expectEqual(userspace.stack_va, ra.stack.base);
    current = user_b;
    const rb = current_user_regions();
    try std.testing.expectEqual(userspace.text_va, rb.text.base);
    try std.testing.expectEqual(@as(u64, 0x1a400000), rb.stack.base);
    try std.testing.expectEqual(@as(u64, 8192), rb.stack.len);
    // Restore the ring position before the round-robin exercise (the region
    // checks above moved `current` for readability).
    current = 0;
    // Both run in the ring (round-robin reaches each).
    start();
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(yield_current()); // worker -> user A
    try std.testing.expectEqual(@as(usize, user_a), current_id());
    try std.testing.expect(yield_current()); // A -> B
    try std.testing.expectEqual(@as(usize, user_b), current_id());
    // A third user program cannot load: the pool is the capacity gate.
    try std.testing.expect(register_exec_user(0x5000, root_a, 64, 0x2a400000, 8192, kstack_b, 0, 0) == null);
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
    // The shell loop prints the exit, the process-level exit report
    // (claim 3848: the exited process keeps its status past the reap) and
    // the reap, in order.
    var mock = console.MockConsole(256){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expectEqualStrings("tasks user-el0 exited status=7\nprocs user-el0 exited status=7\ntasks user-el0 reaped\n", mock.contents());
}

test "scheduler: two exits in one window report BOTH lines in order" {
    // Card 3d (claim 1014): the exit/reap reports are FIFOs, not single
    // first-wins flags — two exits in one idle-loop window print two
    // `tasks <name> exited status=` lines (and two process reports) in
    // exit order, and a second drain prints nothing (no double-print).
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    // Exit the user (slot 2, status 43), then the worker (slot 1, status
    // 9), WITHOUT draining between them.
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    try std.testing.expect(exit_current(43)); // user -> idle
    try std.testing.expectEqual(@as(usize, idle_id), current_id());
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expectEqual(@as(usize, 1), current_id());
    try std.testing.expect(exit_current(9)); // worker -> idle
    try std.testing.expectEqual(@as(usize, idle_id), current_id());
    // One drain prints BOTH exits in order, then nothing more.
    var mock = console.MockConsole(256){};
    var con = mock.console();
    maybe_report(&con);
    // The task-exit FIFO drains first (both lines, in exit order), then
    // the process FIFO (the user-el0 process's report), then the reap
    // FIFO. Every exit printed exactly once, in order, no collapse.
    try std.testing.expectEqualStrings(
        "tasks user-el0 exited status=43\n" ++
            "tasks worker exited status=9\n" ++
            "procs user-el0 exited status=43\n",
        mock.contents(),
    );
    mock.reset();
    maybe_report(&con);
    try std.testing.expectEqual(@as(usize, 0), mock.contents().len);
}

test "scheduler: two reaps in one window report BOTH reap lines in order" {
    // Card 3d: the reap report is a FIFO too — two zombies reaped before
    // the shell drains print two `tasks <name> reaped` lines.
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(yield_current()); // worker -> user
    try std.testing.expect(exit_current(43)); // user -> idle
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(exit_current(9)); // worker -> idle
    // Reap BOTH zombies before the shell drains (the idle task's
    // one-per-iteration reaper makes this the normal window).
    reap_one_zombie();
    reap_one_zombie();
    var mock = console.MockConsole(256){};
    var con = mock.console();
    maybe_report(&con);
    // Reaps scan slots lowest-first, so the worker (slot 1) is reaped
    // before the user (slot 2) — the FIFO preserves THAT order.
    try std.testing.expectEqualStrings(
        "tasks user-el0 exited status=43\n" ++
            "tasks worker exited status=9\n" ++
            "procs user-el0 exited status=43\n" ++
            "tasks worker reaped\n" ++
            "tasks user-el0 reaped\n",
        mock.contents(),
    );
}

test "scheduler: request_kill refuses unknown, exited, and scheduler-owned targets" {
    // Card 3c (claim 7786): the kill ARMS a target; the refusals are the
    // monitor command's exact error strings.
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    // The shell (0) owns the console and the idle task is scheduler-owned:
    // neither may be force-terminated.
    try std.testing.expectEqual(KillResult.refused, request_kill(0));
    try std.testing.expectEqual(KillResult.refused, request_kill(idle_id));
    // A free slot and an out-of-range id are not_found.
    try std.testing.expectEqual(KillResult.not_found, request_kill(3)); // free spare slot
    try std.testing.expectEqual(KillResult.not_found, request_kill(max_tasks));
    // Drive the user to a zombie: an exited task is already_exited.
    start();
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    try std.testing.expect(exit_current(43)); // user -> idle
    try std.testing.expectEqual(KillResult.already_exited, request_kill(2));
}

test "scheduler: a killed task exits with the reserved status at its next selection" {
    // Card 3c: `kill` arms the target's TCB (main context); the ring's
    // next selection of that task converts the selection into the EXISTING
    // exit path with the reserved status 137 — the killed task never
    // resumes, and the exit report + reap carry the reserved status.
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    // The shell arms the kill on the user task (slot 2).
    try std.testing.expectEqual(KillResult.ok, request_kill(2));
    // The next switches walk the ring; when the ring SELECTS the user, the
    // kill branch converts the selection into exit_current(137).
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expectEqual(@as(usize, 1), current_id());
    try std.testing.expect(yield_current()); // worker -> user -> killed -> idle
    try std.testing.expectEqual(@as(usize, idle_id), current_id());
    try std.testing.expect(is_terminated(2));
    try std.testing.expectEqual(@as(?u64, reserved_kill_status), terminated_status(2));
    try std.testing.expectEqual(@as(u64, 1), exit_count());
    // The process bound to the killed task reports the reserved status.
    const pinfo = process.info(0).?;
    try std.testing.expectEqual(process.State.exited, pinfo.state);
    try std.testing.expectEqual(@as(u64, reserved_kill_status), pinfo.exit_status);
    // The exit report carries 137, drained in order by the shell loop.
    var mock = console.MockConsole(128){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expectEqualStrings("tasks user-el0 exited status=137\nprocs user-el0 exited status=137\n", mock.contents());
    // The slot reaps back to free and is spawnable again (the kill flows
    // through the real lifecycle, not a special teardown).
    try std.testing.expect(reap(2));
    try std.testing.expect(task_info(2) == null);
    try std.testing.expect(has_free_slot());
    try std.testing.expectEqual(KillResult.not_found, request_kill(2)); // the freed slot is not_found
}

test "scheduler: a killed sleeping task is terminated at its wake-selection" {
    // Card 3c: a task parked by sys_sleep has NO scheduled quantum while
    // blocked; the kill takes effect when its wake flips it to ready and
    // the ring selects it — the same stage_current kill branch.
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    // The worker sleeps 4 ticks (current = worker, slot 1).
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(sleep_current(4)); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    // Arm the kill on the sleeping worker.
    try std.testing.expectEqual(KillResult.ok, request_kill(1));
    // Walk the ring (user -> idle -> shell -> ...); the blocked worker is
    // skipped until its wake. Wake it, then the next selection kills it.
    try std.testing.expect(yield_current()); // user -> idle
    on_tick();
    on_tick();
    on_tick();
    on_tick(); // tick 4: the worker's deadline passes -> ready
    try std.testing.expect(!is_blocked(1));
    // The ring reaches the woken worker's selection: killed -> 137.
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expect(yield_current()); // shell -> worker -> killed -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    try std.testing.expect(is_terminated(1));
    try std.testing.expectEqual(@as(?u64, reserved_kill_status), terminated_status(1));
}
