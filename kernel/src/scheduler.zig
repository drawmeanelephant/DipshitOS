//! VirelaiOS tick-driven round-robin kernel task scheduler (claim 5275 —
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
//!     `exceptions.resume_frame[c]` (staged by `exc_dispatch` at IRQ entry);
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
const shared_mmap = @import("shared_mmap.zig"); // M33 SB2 (claim 8878): shared-anon revoke-on-exit (ADR 0016 D2)
// Milestone four (claim 3848): the process registry — the task pool is the
// executor, the process owns the program (image + address space + lifecycle
// + exit status). One-way import: process.zig knows nothing about this
// module.
const process = @import("process.zig");
const svclock = @import("svclock.zig"); // claim 9498 follow-on: per-service-domain locks — canonical file < net < win < ev < kernel, then sched_lock
// Card 3f (claim 5965): the per-process IPC mailbox — the pool reset
// clears it and the boot payload's process registration resets its ring.
const mailbox = @import("mailbox.zig");
// Milestone 9 (claim 7670): per-process event queue
const events = @import("events.zig");
// Milestone 14 (claim 7323): per-process app timer facility — fired from
// the SAME host-testable tick seam as the sleep wakeups below.
const app_timers = @import("app_timers.zig");
// Milestone 10 (claim 9948): per-process file handle table
const file_table = @import("file_table.zig");
// Milestone 12 (claim 7483): per-process TCP connection cleanup
const tcp = @import("tcp.zig");
// Card G6 teardown follow-on (per-process window ownership): the exit path
// auto-closes the exiting process's user windows via `close_owner`. Pure
// BSS writes, safe in the exception context `exit_current` runs in.
const driving_award = @import("driving_award.zig");
// M32 WMS2 (issue #622): the render-server register. Fired from the SAME
// host-testable tick seam as app_timers; the exit path unregisters a dying
// WM so pacing falls back to the shell idle shim automatically.
const wm_server = @import("wm_server.zig");
// Arc5 issue #243: crash tombstone recording — written in the exit path
// when status is 139 (fault) or non-zero unexpected exits. Pure BSS
// writes, safe in the exception context `exit_current` runs in.
const tombstone = @import("tombstone.zig");
const serial_ring = @import("serial_ring.zig"); // Arc5 #243: serial snapshot for tombstones
const virtio_file = @import("virtio_file.zig"); // Arc5 #243: tombstone write through the host file channel (HF6: the DATA partition is gone)
const smp = @import("smp.zig");
const spinlock = @import("spinlock.zig");

const user_stack_section = if (builtin.object_format == .elf) ".userbss" else "__DATA,__userbss";

/// Round-robin pool (card 3g, claim 5795 — the pool-scale capstone;
/// milestone sixteen C3, claim 0339 — the measured growth). Card 3g set
/// the budget at 7: shell + EL1h demo worker + FOUR EL0t user slots + the
/// scheduler-owned idle task (7/7, FOUR live user programs). C3 measures
/// that the demo apps (launcher, file browser, chat, sound apps, desktop)
/// exhaust those four user slots — the exec path refuses a FIFTH
/// concurrent program with `pool_full` — and grows the pool to 11:
/// shell + worker + EIGHT EL0t user slots + idle (11/11, EIGHT live user
/// programs — the "8+ apps on the desktop" consuming experience). Fixed at
/// comptime — no allocation, no dynamic registration or processes; the
/// lifecycle's spawn/reap only recycle these slots.
pub const max_tasks: usize = 11;
/// The idle task's fixed slot (registered by `init`, never recycled).
pub const idle_id: usize = max_tasks - 1;
/// The worker's static stack (BSS, like every other kernel global). The
/// shell task continues to run on the handoff stack.
// 16 KiB (claim 8877): the EL0 file-read path stacks ~5 KiB of staging
// (read_staging + file_table staging + FAT sector buffers) on the process's
// kernel stack; at 8 KiB an overflow spilled DOWNWARD into the adjacent
// user-stack pages (exec allocates text/stack/kstack consecutively) and
// clobbered DESKTOP's AppState with FAT bytes. The user stack doubles too
// — GUI apps get more headroom at no real cost.
/// Per-task stacks. Doubled 16 → 32 KiB for M25 Lane A/B (claims
/// 0434/2539): FILE.BIN's AppState alone occupies ~7.3 KiB of its EL0
/// stack, and real feature chains (batch ops + deferred listing walks)
/// overflowed the remaining headroom — observed live as guard-page
/// status=139 faults on VZ. Cost: +16 KiB BSS per static stack (well
/// inside the verify-bss-budget headroom) and 2 extra pages per exec'd
/// process.
pub const task_stack_size: usize = 32 * 1024;

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

/// Milestone sixteen C2 (claim 8403): the reserved exit status an EL0
/// synchronous fault (a guard-page step, an unmapped access, or a
/// non-executable fetch) reports. A plain number (128 + 11) — no POSIX
/// semantics; it is the `tasks GUARD.BIN exited status=139` line the live
/// gate asserts, distinct from the kill path's 137.
pub const reserved_fault_status: u64 = 139;
/// Arc5 issue #246: per-process memory limit exceeded (killed in page fault path).
pub const reserved_mem_limit_status: u64 = 140;
/// Arc5 issue #246: per-process CPU limit exceeded (killed in scheduler tick).
pub const reserved_cpu_limit_status: u64 = 141;

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
    extra_reads: [6]userspace.Region = [_]userspace.Region{.{ .base = 0, .len = 0 }} ** 6,
    extra_read_count: usize = 0,
    extra_writes: [6]userspace.Region = [_]userspace.Region{.{ .base = 0, .len = 0 }} ** 6,
    extra_write_count: usize = 0,
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
    /// Milestone 9 (claim 1016): the process id this blocked task waits on
    /// for application events via `sys_wait_event` (slot 22). Set by
    /// `wait_event_current`; cleared when `wake_event_waiters` returns the
    /// task to `ready` upon event enqueue.
    wait_event_pid: ?usize = null,
    /// Claim 6359 (wait_event fix): the event-buffer address a woken
    /// `sys_wait_event` task's re-executed `svc` must see. The blocking
    /// result write (x0=0) in the syscall layer clobbers the saved frame's
    /// x0 at block time; `wait_event_current` stashes the original
    /// argument here and `wake_event_waiters` patches it back into the
    /// saved frame before the task resumes, so the re-executed copy_out
    /// targets the app's buffer, not address 0.
    wait_event_buf: u64 = 0,
    /// Card 3c (claim 7786): armed-kill flag. `kill` sets it from main
    /// context; the ring converts the task's NEXT selection into the
    /// existing exit path (status 137) instead of resuming it — the OS,
    /// not the program, owns process lifetime. Reset by the slot's reap
    /// (`.{ }` clears it).
    kill_pending: bool = false,
    /// The reserved status the kill conversion exits with when
    /// `kill_pending` converts (claim 9498 follow-on: the CPU-limit
    /// arming rides 141, request_kill the 137 default). Reset to the
    /// default by the conversion and by the slot's reap (`.{ }` clears
    /// it).
    kill_pending_status: u64 = reserved_kill_status,
    /// SMP lift (claim 8477 follow-up): may this task run on a secondary
    /// core? Only console-free kernel tasks (the worker) and explicitly
    /// pinned user tasks today — ordinary user tasks print through the
    /// polled virtio TX and must stay on core 0 (their other syscalls
    /// touch unlocked core-0 state).
    secondary_ok: bool = false,
    /// SMP user tasks (claim 2369): the ONLY core this task may run on
    /// (0 = any core). Core 0's pick skips a pinned candidate outright;
    /// a secondary core's pick requires pin_core == its own id (plus
    /// `secondary_ok`). `exec -c<core>` sets this via `pin_task`.
    pin_core: usize = 0,
};
var tasks: [max_tasks]Task = [_]Task{.{}} ** max_tasks;

// ---------------------------------------------------------------------------
// Per-core ready rings (claim 881 / issue #856)
// ---------------------------------------------------------------------------
//
// The ready ring of core `c` is the set of tasks core `c` will run next:
// a task with state `.ready` sits on EXACTLY ONE core's ring (its "home").
// Selection pops the ring head, so two cores can never both select the
// same ready task — single-owner by construction, not by lock. This slice
// (claim 881 slice 1) introduces the structure, its ops, and the seeding
// seams (init/spawn/pin/reap) with an invariant checker; the rotation
// paths (tick/switch/yield/sleep/wait/exit) convert to ring pop/push in
// slice 2, at which point the ring becomes the scheduler's ONLY notion of
// "ready" and the shared scan disappears.
//
// Ring-home rules (frozen in the claim): spawns join ring 0 unless
// `pin_core` is set (then that ring — a pinned task never leaves it); a
// preempted/self-yielded task joins the ring of the core it ran on; a
// blocked task leaves its ring and wakes onto ring 0 (or its pin ring);
// an idle secondary core steals from ring 0 only at the WFE->run seam
// (the exact place the old shared scan let it grab work). Capacity is the
// whole pool: every task could be ready at once.
const ReadyRing = struct {
    /// Fixed-order membership array, walked FIFO: `head` is the next pop,
    /// `(head + count) % max_tasks` the next push slot. Indexing by
    /// `(head + i) % max_tasks` keeps `get(i)` the i-th in run order.
    members: [max_tasks]usize = undefined,
    head: usize = 0,
    count: usize = 0,

    fn len(self: *const ReadyRing) usize {
        return self.count;
    }

    fn empty(self: *const ReadyRing) bool {
        return self.count == 0;
    }

    /// The i-th member in run order (head first).
    fn get(self: *const ReadyRing, i: usize) usize {
        std.debug.assert(i < self.count);
        return self.members[(self.head + i) % max_tasks];
    }

    fn contains(self: *const ReadyRing, id: usize) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.get(i) == id) return true;
        }
        return false;
    }

    /// Append at the tail. Single-home invariant: a task already on this
    /// (or any) ring must not be pushed again — the assert is the
    /// double-pick guard.
    fn push(self: *ReadyRing, id: usize) void {
        std.debug.assert(self.count < max_tasks);
        std.debug.assert(!self.contains(id));
        self.members[(self.head + self.count) % max_tasks] = id;
        self.count += 1;
    }

    /// Pop the head (FIFO run order).
    fn pop(self: *ReadyRing) ?usize {
        if (self.count == 0) return null;
        const id = self.members[self.head];
        self.head = (self.head + 1) % max_tasks;
        self.count -= 1;
        return id;
    }

    /// Remove `id` wherever it sits, compacting the tail down one slot so
    /// run order is preserved. Returns false when it is not a member.
    fn remove(self: *ReadyRing, id: usize) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.get(i) != id) continue;
            var j = i;
            while (j + 1 < self.count) : (j += 1) {
                self.members[(self.head + j) % max_tasks] = self.members[(self.head + j + 1) % max_tasks];
            }
            self.count -= 1;
            return true;
        }
        return false;
    }
};

var ready_rings: [smp.max_cores]ReadyRing = [_]ReadyRing{.{}} ** smp.max_cores;

/// The ring a task's `ready` membership lives on: its pin core when
/// pinned, else ring 0 (the any-core default home).
fn home_ring_of(id: usize) usize {
    return if (tasks[id].pin_core != 0) tasks[id].pin_core else 0;
}

/// Drop `id` from whichever ring holds it (cross-ring remove — the
/// exit/reap and pin re-home seams). Returns true when it was a member.
fn ring_remove_anywhere(id: usize) bool {
    var c: usize = 0;
    while (c < smp.max_cores) : (c += 1) {
        if (ready_rings[c].remove(id)) return true;
    }
    return false;
}

/// The ready-membership invariant, asserted at the slice-1 seeding seams
/// (init/spawn/pin/reap) — and by the host tests after every seam. In
/// slice 1 the rotation paths are not yet ring-wired, so a task whose
/// state the ROTATION paths changed (.ready after a preempt, .zombie
/// after an exit) may sit in a stale ring position until slice 2; call
/// the checker only where no rotation has happened since the last seeded
/// seam. Rules (all hold by construction once slice 2 lands everywhere):
///   1. every member of every ring is a `.ready` task, on no other ring,
///      and not any core's `current` (executing tasks are off-ring);
///   2. every `.ready` task is on exactly one ring, unless it is a core's
///      `current` (executing off-ring — the boot shell / a
///      rollback-resumed task);
///   3. the idle reaper sits on ring 0 exactly (core-0-owned);
///   4. no non-`.ready` task is on any ring.
fn check_ready_membership() void {
    var c: usize = 0;
    while (c < smp.max_cores) : (c += 1) {
        const ring = &ready_rings[c];
        var i: usize = 0;
        while (i < ring.len()) : (i += 1) {
            const m = ring.get(i);
            std.debug.assert(m < max_tasks);
            std.debug.assert(tasks[m].state == .ready);
            var other: usize = 0;
            while (other < smp.max_cores) : (other += 1) {
                if (other == c) continue;
                std.debug.assert(!ready_rings[other].contains(m));
            }
            // A core never executes a task that sits on ITS OWN ring (the
            // double-run guard). Cross-core equality is legal: parked
            // secondary cores hold `current = idle_id` while the idle
            // reaper is ring 0's member.
            std.debug.assert(current[c] != m);
        }
    }
    var id: usize = 0;
    while (id < max_tasks) : (id += 1) {
        if (tasks[id].state == .ready) {
            var on: usize = 0;
            var ring_c: usize = 0;
            while (ring_c < smp.max_cores) : (ring_c += 1) {
                if (ready_rings[ring_c].contains(id)) on += 1;
            }
            std.debug.assert(on <= 1);
            if (on == 1) continue;
            var is_current: bool = false;
            var cur_c: usize = 0;
            while (cur_c < smp.max_cores) : (cur_c += 1) {
                if (current[cur_c] == id) is_current = true;
            }
            std.debug.assert(is_current); // .ready, off-ring => executing
        } else {
            var ring_c: usize = 0;
            while (ring_c < smp.max_cores) : (ring_c += 1) {
                std.debug.assert(!ready_rings[ring_c].contains(id));
            }
        }
    }
    std.debug.assert(tasks[idle_id].state == .ready);
    std.debug.assert(ready_rings[0].contains(idle_id));
    var ring_c: usize = 1;
    while (ring_c < smp.max_cores) : (ring_c += 1) {
        std.debug.assert(!ready_rings[ring_c].contains(idle_id));
    }
}

var task_count: usize = 0;
/// The running task per core. Core 0 owns the task ring today
/// (irq_dispatch gates tick to PE 0 — claim 7339); cores 1-3 sit in
/// `idle_id` until the tick gate, ring locking, and task migration land.
/// The old `current_by_core` vestige folded into this array.
pub var current: [smp.max_cores]usize = [_]usize{ 0, idle_id, idle_id, idle_id };
pub var sched_lock = spinlock.Spinlock.init();
/// The core that currently holds `sched_lock` (smp.max_cores = nobody).
/// Lets ring callbacks (the events.push hook) detect same-core reentry —
/// `exit_current`/`tick` hold the lock when they push window-close events,
/// and the hook wakes waiters by mutating the same ring.
var sched_lock_holder: usize = smp.max_cores;

fn sched_lock_acquire() void {
    sched_lock.lock();
    sched_lock_holder = smp.core_id();
}

fn sched_lock_release() void {
    sched_lock_holder = smp.max_cores;
    sched_lock.unlock();
}
var enabled_flag: bool = false;
var switches: u64 = 0;
var cooperative_yields: u64 = 0;
var exits: u64 = 0;
/// SMP lift (claim 8477 follow-up) evidence: how many times a secondary
/// core staged a real task (WFE->task jump or secondary preemption).
/// Printed once per change from the shell idle loop (main context).
var secondary_runs: u64 = 0;
var secondary_runs_printed: u64 = 0;
/// The names of the most recent tasks a secondary core staged (the
/// evidence line's `task=`; a process name when one exists), one ring
/// slot per run so the drain can print EVERY run — a worker run between
/// two user runs would otherwise mask the user name (the drain only sees
/// the latest value).
var secondary_last_task: []const u8 = "";
const secondary_run_name_cap = 16;
var secondary_run_names: [secondary_run_name_cap][]const u8 = undefined;
var secondary_run_names_count: usize = 0;
/// Secondary-core WFE-park capture (claim 2369): the location of the WFE
/// loop's saved frame on the secondary stack + its ELR/SPSR, captured by
/// `tick` the moment it starts a task from the parked state. A running
/// task uses its OWN kstack (the eret into it moved SP_EL1 there), so
/// the WFE frame bytes stay pristine on the secondary stack; a core-1
/// task that exits with no eligible successor erets back to them instead
/// of rolling the exit back (the old core-0-only orelse).
var park_sp: [smp.max_cores]u64 = [_]u64{ 0, 0, 0, 0 };
var park_elr: [smp.max_cores]u64 = [_]u64{ 0, 0, 0, 0 };
var park_spsr: [smp.max_cores]u64 = [_]u64{ 0, 0, 0, 0 };
/// Claim 0635: scheduler tick counter — advanced once per timer tick by
/// `tick`/`on_tick`; the clock `sys_sleep` deadlines are measured against.
/// Distinct from `timer.ticks` (timer deliveries, including polls) because
/// the scheduler may be inactive or the timer path may change; the sleep
/// contract is in SCHEDULER ticks.
var tick_count: u64 = 0;

/// Restored-context staging, PER-CORE: written by `switch_context`/
/// `stage_current` (SVC context) and applied by `tick`/`apply_pending`
/// (IRQ context) on the SAME core — staging and apply never cross cores,
/// so indexing both by the running core keeps a switch atomic against that
/// core's own ticks. Cores 1-3 hold idle staging until they run tasks.
var pending_sp: [smp.max_cores]u64 = [_]u64{0} ** smp.max_cores;
var pending_elr: [smp.max_cores]u64 = [_]u64{0} ** smp.max_cores;
var pending_spsr: [smp.max_cores]u64 = [_]u64{0} ** smp.max_cores;
var pending_sp_el0: [smp.max_cores]u64 = [_]u64{0} ** smp.max_cores;
var pending_ttbr0: [smp.max_cores]u64 = [_]u64{0} ** smp.max_cores;

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
/// Milestone sixteen C2 (claim 8403): the EL0 fault reports are a bounded
/// FIFO like the exit reports — a faulting process's name + FAR_EL1 +
/// ESR_EL1 EC are snapshotted in exception context, then the shell idle
/// loop prints `fault: <name> far=0x... ec=0x...` IN ORDER. The name
/// pointer is a safe snapshot (task names are static string literals).
pub const fault_report_max: usize = 4;
const FaultEntry = struct { name: []const u8, far: u64, ec: u64, pc: u64 = 0 };
var fault_reports: [fault_report_max]FaultEntry = [_]FaultEntry{.{ .name = "", .far = 0, .ec = 0 }} ** fault_report_max;
var fault_report_head: usize = 0;
var fault_report_count: usize = 0;
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
    current[0] = 0; // the shell boots on core 0
    switches = 0;
    cooperative_yields = 0;
    exits = 0;
    enabled_flag = false;
    @memset(&report_pending, false);
    exit_report_head = 0;
    exit_report_count = 0;
    reap_report_head = 0;
    reap_report_count = 0;
    fault_report_head = 0;
    fault_report_count = 0;
    sleep_report_pending = false;
    spawn_demo_armed = false;
    user_timer_preemptions = 0;
    tick_count = 0;
    for (&tasks) |*task| task.* = .{};
    // Claim 3848: every pool reset also clears the process layer (the
    // boot path initializes both here; host tests get isolation). Card 3f
    // (claim 5965): the IPC mailbox rings reset with it. Card E1 (claim 7670):
    // event queues reset with it.
    process.init();
    mailbox.init();
    events.init();
    events.on_event_pushed = wake_event_waiters;
    app_timers.init();
    wm_server.init();
    tasks[0] = .{ .name = "shell", .state = .ready, .ttbr0 = mmu.kernel_root_phys() };
    tasks[idle_id] = .{
        .name = "idle",
        .state = .ready,
        .sp = build_initial_frame(&idle_stack, @intFromPtr(&idle_entry)),
        .elr = @intFromPtr(&idle_entry),
        .spsr = spsr_el1h_irqs,
        .ttbr0 = mmu.kernel_root_phys(),
    };
    // Claim 881 slice 1: every test reset also clears the per-core ready
    // rings, then the always-ready idle reaper takes its ring-0 seat (the
    // shell is `current[0]` and executing — off-ring until its first real
    // preemption joins it to ring 0 in the slice-2 rotation wiring).
    for (&ready_rings) |*r| r.* = .{};
    ready_rings[0].push(idle_id);
    task_count = 2;
    return 0;
}

/// Claim 6729: allocate the first free pool slot for a new task and build
/// its synthetic initial frame on `stack`. Explicit, bounded allocation:
/// returns null when the fixed pool is full (every slot registered). The
/// caller supplies the name, runtime entry address, SPSR mode, TTBR0 root,
/// and SP_EL0 (0 for EL1h tasks). The new task starts `ready`.
pub fn spawn(name: []const u8, entry: u64, spsr: u64, stack: []u8, ttbr0: u64, sp_el0: u64) ?usize {
    sched_lock_acquire();
    defer sched_lock_release();
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
    // Claim 881 slice 1: the new task joins its home ring (ring 0 for the
    // any-core default; `pin_task` re-homes it when `exec -c<core>` pins).
    ready_rings[home_ring_of(id)].push(id);
    task_count += 1;
    return id;
}

/// Register the claim-5275 demo worker (an EL1h task that bumps its advance
/// counter each quantum). `entry` is a runtime-computed function address
/// (the caller takes `@intFromPtr(&task_fn)`).
pub fn register_worker(entry: u64) ?usize {
    const id = spawn("worker", entry, spsr_el1h_irqs, &worker_stack, mmu.kernel_root_phys(), 0) orelse return null;
    // The worker is console-free (note_advance + request_report + spin),
    // so it is the one task safe on a secondary core (the polled virtio
    // TX has no lock — anything that prints must stay on core 0).
    tasks[id].secondary_ok = true;
    return id;
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
    return register_exec_user_auxv(entry_va, root_phys, text_len, stack_va, stack_len, kstack, argc, argv_va, 0);
}

pub fn register_exec_user_auxv(
    entry_va: u64,
    root_phys: u64,
    text_len: u64,
    stack_va: u64,
    stack_len: u64,
    kstack: []u8,
    argc: u64,
    argv_va: u64,
    auxv_va: u64,
) ?usize {
    const sp_el0 = stack_va + stack_len;
    const id = spawn("user-exec", entry_va, spsr_el0t_irqs, kstack, root_phys, sp_el0) orelse return null;
    // Claim 9498: unpinned user tasks may run on ANY core (the console TX
    // is locked — claim 2369 — and the userspace-service gate serializes
    // their syscalls). `exec -c<core>` / the WM registration pin after
    // this via `pin_task`.
    tasks[id].secondary_ok = true;
    tasks[id].regions = .{
        .text = .{ .base = userspace.text_va, .len = text_len },
        .stack = .{ .base = stack_va, .len = stack_len },
    };
    // Card 3e (claim 4636): the entry-contract extension — the exec'd
    // program's `_start` receives argc in x0 and the argv block VA in x1.
    // Dynamic linking (claim 7921): interpreter receives auxv_va in x2.
    const frame: *exceptions.VectorFrame = @ptrFromInt(tasks[id].sp);
    _ = exceptions.frame_write(frame, 0, argc);
    _ = exceptions.frame_write(frame, 1, argv_va);
    _ = exceptions.frame_write(frame, 2, auxv_va);
    return id;
}

/// Restrict task `id` to a single core (claim 9498: a RESTRICTION over
/// the any-core default every user task now spawns with). `core > 0`
/// pins to that secondary core (secondary_ok on, so that core's pick can
/// take it); `core = 0` pins to CORE 0 only (secondary_ok off) — used by
/// the registered WM, whose COMPOSITE_TICK pacing is core-0-tick-driven.
/// Used by `exec -c<core>` and the WM registration; must be called right
/// after the task is spawned (before it can be picked).
pub fn pin_task(id: usize, core: usize) bool {
    if (id >= max_tasks or tasks[id].state == .free) return false;
    tasks[id].pin_core = core;
    tasks[id].secondary_ok = (core != 0);
    // Claim 881 slice 1: a still-`ready` task re-homes to its pin ring so
    // the membership invariant holds (a task pinned after spawn must leave
    // ring 0; a task pinned back to 0 returns home). A task that is
    // already running/blocked/zombie is off-ring by construction — its
    // fields are set and the next preemption/wake places it per the pin.
    if (tasks[id].state == .ready) {
        _ = ring_remove_anywhere(id);
        ready_rings[home_ring_of(id)].push(id);
    }
    return true;
}

pub fn add_task_read_region(id: usize, reg: userspace.Region) void {
    if (id < max_tasks and tasks[id].regions.extra_read_count < tasks[id].regions.extra_reads.len) {
        tasks[id].regions.extra_reads[tasks[id].regions.extra_read_count] = reg;
        tasks[id].regions.extra_read_count += 1;
    }
}

pub fn add_task_write_region(id: usize, reg: userspace.Region) void {
    if (id < max_tasks and tasks[id].regions.extra_write_count < tasks[id].regions.extra_writes.len) {
        tasks[id].regions.extra_writes[tasks[id].regions.extra_write_count] = reg;
        tasks[id].regions.extra_write_count += 1;
    }
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
    sched_lock_acquire();
    defer sched_lock_release();
    if (id >= max_tasks or tasks[id].state == .free) return .not_found;
    if (tasks[id].state == .zombie) return .already_exited;
    // The shell (id 0) owns the console and the idle task is
    // scheduler-owned (never exits — exit_current refuses it anyway);
    // neither may be force-terminated.
    if (id == idle_id or id == 0) return .refused;
    tasks[id].kill_pending = true;
    return .ok;
}

/// Milestone sixteen C2 (claim 8403): an EL0 synchronous fault reached the
/// exception dispatcher (registered as `exceptions.set_fault_dispatcher`).
/// Snapshot the faulting task's name + FAR_EL1 + ESR_EL1 EC into the bounded
/// fault FIFO, then terminate the process through the existing exit path
/// with `reserved_fault_status` — the full exit → zombie → idle-reap →
/// page-return lifecycle runs, the ring stages the next task, and the shell
/// survives. Pure BSS writes, safe in the exception context the dispatcher
/// runs in (no console, no allocation).
pub fn fault_current(esr: u64, far: u64, pc: u64) void {
    if (task_count == 0) return;
    const c = smp.core_id(); // per-core current
    // Prefer the PROCESS name (e.g. "GUARD.BIN") over the generic task name
    // ("user-exec") — the process name is a stable name_buf slice, so the
    // pointer is a safe FIFO snapshot (same rule as the exit reports).
    const name: []const u8 = if (process.find_by_task(current[c])) |pid|
        process.info(pid).?.name
    else
        tasks[current[c]].name;
    const ec = (esr >> 26) & 0x3f;
    if (fault_report_count == fault_report_max) {
        fault_report_head = (fault_report_head + 1) % fault_report_max;
        fault_report_count -= 1;
    }
    const idx = (fault_report_head + fault_report_count) % fault_report_max;
    fault_reports[idx] = .{ .name = name, .far = far, .ec = ec, .pc = pc };
    fault_report_count += 1;
    // Arc5 issue #246: if the process has a memory limit and it's exceeded,
    // use status 140 (mem_limit) instead of 139 (guard page).
    const fault_status = if (process.find_by_task(current[c])) |pid|
        if (process.check_mem_limit(pid)) reserved_mem_limit_status else reserved_fault_status
    else
        reserved_fault_status;
    _ = exit_current(fault_status);
}

/// The user apertures of the CURRENT task (the EL0t task about to SVC —
/// zero for EL1h tasks). The syscall layer arms these into uaccess at SVC
/// entry so `sys_write` bounds always follow the task that issued the call.
pub fn current_user_regions() UserRegions {
    return tasks[current[smp.core_id()]].regions;
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
    tasks[id].secondary_ok = true; // claim 9498: user tasks may run on any core
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
        events.reset(proc_id);
        file_table.reset_process(proc_id);
        app_timers.reset(proc_id);
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
/// x16/x17 ... x0/x1 at the bottom; every slot zeroed except x30. The
/// FP/SIMD block (q0..q31, `exceptions.fp_save_bytes`) that the shared
/// `exc_fp_common` pushes below the GPR frame at every exception is
/// reserved and zeroed beneath it, so the restore macro's `sub sp, x0,
/// #fp_save_bytes` + FP pops land in valid zeros when a fresh task is
/// first scheduled.
fn build_initial_frame(stack: []u8, entry: u64) u64 {
    _ = entry; // ELR carries the entry; the frame only needs x30 = park
    const frame = stack[stack.len - frame_bytes ..];
    @memset(frame, 0);
    const park_addr = @intFromPtr(&park);
    std.mem.writeInt(u64, frame[0..8], park_addr, .little);
    const fp_block = stack[stack.len - frame_bytes - @as(usize, exceptions.fp_save_bytes) .. stack.len - frame_bytes];
    @memset(fp_block, 0);
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
/// Pick the next runnable task after `after` on behalf of core `cid`
/// (the shared ring; callers hold `sched_lock`). Core 0 may pick any
/// ready task; secondary cores may pick only `secondary_ok` tasks — never
/// the shell (console owner) and never the shared idle slot (core 0's
/// reaper — one frame, one owner).
fn next_runnable_for(after: usize, cid: usize) ?usize {
    if (task_count == 0) return null;
    var offset: usize = 1;
    while (offset <= max_tasks) : (offset += 1) {
        const candidate = (after + offset) % max_tasks;
        if (tasks[candidate].state != .ready) continue;
        // A pinned task is visible only to its own core.
        if (tasks[candidate].pin_core != 0 and tasks[candidate].pin_core != cid) continue;
        if (cid != 0 and (candidate == 0 or candidate == idle_id or !tasks[candidate].secondary_ok)) continue;
        return candidate;
    }
    return null;
}

fn next_runnable(after: usize) ?usize {
    return next_runnable_for(after, smp.core_id());
}

fn stage_selected(c: usize, next: usize) void {
    // Card 3c (claim 7786): a selected task with a pending kill is NOT
    // resumed — the ring converts its selection into the existing exit
    // path with the reserved status (the OS owns process lifetime). The
    // task's saved frame is abandoned; `exit_current` stages the next
    // task, so the killed task never executes again. `next` is the
    // selected task and its state is `ready` (exactly what exit_current
    // accepts), so this is the real exit/reap/pages-return lifecycle, not
    // a special teardown. No switching-core change: the same frame/ELR/
    // SPSR/TTBR0 machinery that follows any exit is used.
    // Claim 9094 (#810): validate `current` before the kill_pending read
    // (Task+0x178 — the exact byte read that faulted in run-11 boot 2).
    audit.slot(next, .tick);
    if (tasks[next].kill_pending) {
        // Kill conversion runs the full exit teardown (window close,
        // shared-surface revoke, file/event/timer reset) — userspace-gate
        // state. SVC/exit callers already hold the gate (reentrant); the
        // IRQ tick's ungated rotation (claim 9498: rotation runs on
        // sched_lock alone so gate contention never stalls the ring)
        // try-acquires it here — never spins, since we hold sched_lock.
        // When a syscall on another core is mid-flight, stage the task
        // one more quantum instead: kill_pending stays set, so the next
        // selection converts it.
        const taken = svclock.try_take(svclock.all_bits);
        if (taken != null) {
            defer svclock.release_set(taken.?);
            tasks[next].kill_pending = false;
            const status = tasks[next].kill_pending_status;
            tasks[next].kill_pending_status = reserved_kill_status; // back to the request_kill default
            _ = exit_current_locked(status);
            return;
        }
    }
    pending_sp[c] = tasks[next].sp;
    pending_elr[c] = tasks[next].elr;
    pending_spsr[c] = tasks[next].spsr;
    pending_sp_el0[c] = tasks[next].sp_el0;
    pending_ttbr0[c] = tasks[next].ttbr0;
    // Claim 6729: the selected task is now the one that will execute.
    tasks[next].state = .running;
    tasks[next].resumes += 1;
    switches += 1;
    if (c != 0) {
        secondary_runs +%= 1; // SMP lift evidence: a secondary core took a task
        // Remember WHICH task for the evidence line (the process name when
        // there is one — the exec'd file name — else the task name). A
        // bounded ring keeps the name for every unprinted run (the drain
        // prints each one; a full ring drops the oldest — runs are per
        // tick, so 16 covers any real drain gap).
        if (process.find_by_task(next)) |pid|
            secondary_last_task = process.info(pid).?.name
        else
            secondary_last_task = tasks[next].name;
        if (secondary_run_names_count < secondary_run_names.len) {
            secondary_run_names[secondary_run_names_count] = secondary_last_task;
            secondary_run_names_count += 1;
        } else {
            std.mem.copyForwards([]const u8, secondary_run_names[0 .. secondary_run_names.len - 1], secondary_run_names[1..]);
            secondary_run_names[secondary_run_names.len - 1] = secondary_last_task;
        }
    }
}

fn stage_current() void {
    const c = smp.core_id(); // per-core staging
    stage_selected(c, current[c]);
}

pub fn switch_context(frame_sp: u64, elr: u64, spsr: u64, sp_el0: u64) void {
    if (task_count == 0) return;
    const c = smp.core_id(); // per-core current
    tasks[current[c]].sp = frame_sp;
    tasks[current[c]].elr = elr;
    tasks[current[c]].spsr = spsr;
    tasks[current[c]].sp_el0 = sp_el0;
    tasks[current[c]].saves += 1;
    // The preempted task is runnable again; only a zombie is removed from
    // the ring (claim 6729).
    if (tasks[current[c]].state == .running) tasks[current[c]].state = .ready;
    current[c] = next_runnable(current[c]) orelse return;
    stage_current();
}

fn apply_pending() void {
    const c = smp.core_id(); // per-core staging: the core that staged it
    exceptions.resume_frame[c] = pending_sp[c];
    exceptions.resume_sp_el0[c] = pending_sp_el0[c];
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    // Claim 5804: install the selected task's TTBR0 (with a full TLB
    // invalidation) before restoring its ELR/SPSR, so the eret to EL0 (or
    // the resumed EL1h instruction stream) sees the task's own user space.
    mmu.set_ttbr0(pending_ttbr0[c]);
    asm volatile ("msr elr_el1, %[v]"
        :
        : [v] "r" (pending_elr[c]),
    );
    asm volatile ("msr spsr_el1, %[v]"
        :
        : [v] "r" (pending_spsr[c]),
    );
    asm volatile ("isb");
}

fn current_exception_pc() struct { elr: u64, spsr: u64 } {
    const c = smp.core_id(); // per-core current
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) {
        return .{ .elr = tasks[current[c]].elr, .spsr = tasks[current[c]].spsr };
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
    sched_lock_acquire();
    defer sched_lock_release();
    const c = smp.core_id(); // per-core current
    const pc = current_exception_pc();
    switch_context(exceptions.resume_frame[c], pc.elr, pc.spsr, exceptions.resume_sp_el0[c]);
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
    sched_lock_acquire();
    defer sched_lock_release();
    const c = smp.core_id(); // per-core current
    if (!scheduling_active() or task_count == 0 or current[c] == idle_id) return false;
    if (tasks[current[c]].state != .ready and tasks[current[c]].state != .running) return false;
    const duration = if (ticks == 0) 1 else ticks;
    const deadline = std.math.add(u64, tick_count, duration) catch return false;
    const sleeping = current[c];
    const name = tasks[sleeping].name;
    // Save the calling task's context (frame SP + ELR/SPSR + SP_EL0), the
    // same seam yield_current uses — the task MUST find its saved SVC frame
    // intact when wake_expired flips it back to ready and the ring resumes
    // it. Unlike exit_current, which never resumes the saved context.
    const pc = current_exception_pc();
    tasks[sleeping].sp = exceptions.resume_frame[c];
    tasks[sleeping].elr = pc.elr;
    tasks[sleeping].spsr = pc.spsr;
    tasks[sleeping].sp_el0 = exceptions.resume_sp_el0[c];
    tasks[sleeping].saves += 1;
    tasks[sleeping].state = .blocked;
    tasks[sleeping].wakeup_tick = deadline;
    const next = next_runnable(sleeping) orelse {
        // A secondary core with no eligible successor parks on its WFE
        // loop; the sleeping task stays blocked for core 0's tick to wake.
        if (stage_secondary_park(c)) return true;
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
    current[c] = next;
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
    sched_lock_acquire();
    defer sched_lock_release();
    const c = smp.core_id(); // per-core current
    if (!scheduling_active() or task_count == 0 or current[c] == idle_id) return false;
    if (tasks[current[c]].state != .ready and tasks[current[c]].state != .running) return false;
    const waiting = current[c];
    const pc = current_exception_pc();
    // Save the calling task's context (frame SP + ELR/SPSR + SP_EL0), the
    // same seam yield_current/sleep_current use — the task MUST find its
    // saved SVC frame intact when the target exits and the ring resumes it.
    tasks[waiting].sp = exceptions.resume_frame[c];
    tasks[waiting].elr = pc.elr;
    tasks[waiting].spsr = pc.spsr;
    tasks[waiting].sp_el0 = exceptions.resume_sp_el0[c];
    tasks[waiting].saves += 1;
    tasks[waiting].state = .blocked;
    tasks[waiting].wait_pid = target_pid;
    const next = next_runnable(waiting) orelse {
        // A secondary core with no eligible successor parks on its WFE
        // loop; the waiting task stays blocked until the target exits.
        if (stage_secondary_park(c)) return true;
        // No successor: roll back (the always-ready idle task makes this
        // unreachable in a normal boot; kept as a defensive bound).
        tasks[waiting].state = .ready;
        tasks[waiting].wait_pid = null;
        tasks[waiting].saves -%= 1;
        return false;
    };
    current[c] = next;
    stage_current();
    apply_pending();
    return true;
}

/// Milestone 9 (claim 1016): block the calling task until an application event
/// arrives for process `pid`, then stage its successor. Rewinds ELR by 4
/// so when the task wakes up, it re-executes `svc #0` under its own context.
pub fn wait_event_current(pid: usize) bool {
    sched_lock_acquire();
    defer sched_lock_release();
    const c = smp.core_id(); // per-core current
    if (!scheduling_active() or task_count == 0 or current[c] == idle_id) return false;
    if (tasks[current[c]].state != .ready and tasks[current[c]].state != .running) return false;
    const waiting = current[c];
    const pc = current_exception_pc();
    tasks[waiting].sp = exceptions.resume_frame[c];
    tasks[waiting].elr = if (pc.elr >= 4) pc.elr - 4 else pc.elr;
    tasks[waiting].spsr = pc.spsr;
    tasks[waiting].sp_el0 = exceptions.resume_sp_el0[c];
    tasks[waiting].saves += 1;
    tasks[waiting].state = .blocked;
    tasks[waiting].wait_event_pid = pid;
    // Claim 6359 (wait_event fix): stash the re-executed svc's first
    // argument (the event-buffer address) BEFORE the syscall layer writes
    // the blocking result (0) into the saved frame's x0 — the elr-4
    // re-execution must see the original x0, or the wake's copy_out
    // targets address 0 (EFAULT) and every blocking GUI event loop dies.
    const saved_frame: *const exceptions.VectorFrame = @ptrFromInt(exceptions.resume_frame[c]);
    tasks[waiting].wait_event_buf = exceptions.frame_read(saved_frame, 0);
    const next = next_runnable(waiting) orelse {
        // A secondary core with no eligible successor parks on its WFE
        // loop; the waiting task stays blocked until the event arrives.
        if (stage_secondary_park(c)) return true;
        tasks[waiting].state = .ready;
        tasks[waiting].wait_event_pid = null;
        tasks[waiting].wait_event_buf = 0;
        tasks[waiting].saves -%= 1;
        return false;
    };
    current[c] = next;
    stage_current();
    apply_pending();
    return true;
}

/// Milestone 9 (claim 1016): wake any task blocked in `sys_wait_event` for `pid`.
pub fn wake_event_waiters(pid: usize) void {
    // The events.push hook fires from SVC contexts AND from inside
    // sched_lock-held teardown (exit_current's close_owner pushes
    // WIN_CLOSE events) — same-core reentry must not re-lock.
    const already_held = sched_lock_holder == smp.core_id();
    if (!already_held) sched_lock_acquire();
    defer if (!already_held) sched_lock_release();
    var i: usize = 0;
    while (i < max_tasks) : (i += 1) {
        if (tasks[i].state != .blocked) continue;
        if (tasks[i].wait_event_pid != pid) continue;
        // Claim 6359 (wait_event fix): restore the re-executed svc's x0
        // (the event-buffer address) into the saved frame — the blocking
        // result write clobbered it with 0 at block time.
        const frame: *exceptions.VectorFrame = @ptrFromInt(tasks[i].sp);
        _ = exceptions.frame_write(frame, 0, tasks[i].wait_event_buf);
        tasks[i].wait_event_buf = 0;
        tasks[i].state = .ready;
        tasks[i].wait_event_pid = null;
    }
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
        // Card 4c / Card E5: event-blocked tasks (`sys_wait` / `sys_wait_event` —
        // no deadline) are woken by their event hooks, never by the tick clock.
        if (tasks[i].wait_pid != null or tasks[i].wait_event_pid != null) continue;
        if (tick_count < tasks[i].wakeup_tick) continue;
        tasks[i].state = .ready;
        tasks[i].wakeup_tick = 0;
    }
}

/// Host-testable tick seam (mirrors `timer.on_tick`): advance the tick
/// counter and run the timer-driven wakeups. Called by the real `tick`
/// before preemption; host tests call it directly to drive sleepers.
pub fn on_tick() void {
    const c = smp.core_id(); // per-core current
    tick_count +%= 1;
    wake_expired();
    // Milestone 14 (claim 7323): count every armed app timer down and fire
    // the due ones (one TIMER event per process into its ADR 0009 queue,
    // which wakes a blocked sys_wait_event caller via on_event_pushed).
    app_timers.on_tick();
    // M32 WMS2 (issue #622): while a WM is registered, deliver one
    // COMPOSITE_TICK (kind 18) to the registrant's process queue — the
    // composite pacing moves OFF the shell idle to this tick path. A no-op
    // when no WM is registered (zero-regression: shim mode unchanged).
    wm_server.on_tick();
    // Arc5 issue #246: per-process CPU limit enforcement. Increment the
    // current process's tick counter; if the limit is exceeded, arm the
    // ring's kill conversion with status 141 (distinct from guard-page
    // 139). Claim 9498 follow-on: on_tick holds only the EV + kernel
    // subset, while the exit teardown needs the FULL domain set — exiting
    // synchronously here would require acquiring file/net/win out of
    // canonical order (a deadlock risk against a teardown holding them),
    // so the task converts at its next ring selection instead, one
    // quantum later.
    if (current[c] != idle_id and tasks[current[c]].state == .running) {
        if (process.find_by_task(current[c])) |pid| {
            if (process.inc_cpu_ticks(pid)) {
                tasks[current[c]].kill_pending = true;
                tasks[current[c]].kill_pending_status = reserved_cpu_limit_status;
            }
        }
    }
}

/// Remove the calling task from the runnable ring and stage its successor.
/// The SVC exception return consumes the staged frame, so the terminated task
/// never resumes after `sys_exit`. Claim 6729: the exiting task becomes a
/// ZOMBIE (its status is preserved for `terminated_status`); the idle task
/// reaps it later. The idle task itself can never be exited.
/// Ring-exit entry (sys_exit / fault / kill): lock, then exit the calling
/// task. Exception context is IRQ-masked, so spinning on `sched_lock` is
/// safe — a main-context holder (the idle reaper) is never starved because
/// its own preempting ticks `try_lock` and skip.
pub fn exit_current(status: u64) bool {
    // Service-domain locks (claim 9498 follow-on): the teardown below
    // (window close, shared-surface revoke, file/event/timer reset)
    // touches EVERY service domain — take the full set in canonical
    // order, FIRST, before sched_lock, everywhere. The sys_exit dispatch
    // already holds the full set (acquire_missing returns nothing); the
    // fault path does not.
    const taken = svclock.acquire_missing(svclock.all_bits);
    defer svclock.release_set(taken);
    sched_lock_acquire();
    defer sched_lock_release();
    return exit_current_locked(status);
}

/// Ring-exit core: mark the calling task zombie and stage its successor.
/// Callers hold `sched_lock` (exit_current, stage_selected's kill path,
/// on_tick's CPU-limit enforcement).
fn exit_current_locked(status: u64) bool {
    const c = smp.core_id(); // per-core current
    if (task_count == 0 or current[c] == idle_id) return false;
    if (tasks[current[c]].state != .ready and tasks[current[c]].state != .running) return false;
    const exiting = current[c];
    const name = tasks[exiting].name;
    tasks[exiting].state = .zombie;
    tasks[exiting].exit_status = status;
    // Arc5 issue #243: record a tombstone for fault exits (status 139)
    // or any non-zero unexpected exit. The tombstone is written to /data/crash/
    // on the DATA partition. Pure BSS writes, safe in this exception context.
    if (status == reserved_fault_status or (status != 0 and status != reserved_kill_status)) {
        // Get fault address + PC from the most recent fault report if
        // status is 139. M22 D3 (issue #326): the PC rides along so the
        // tombstone can resolve CODE symbols for BRK-style faults whose
        // FAR is meaningless.
        var fault_addr: u64 = 0;
        var fault_pc: u64 = 0;
        if (status == reserved_fault_status and fault_report_count > 0) {
            const last_fault_idx = (fault_report_head + fault_report_count - 1) % fault_report_max;
            fault_addr = fault_reports[last_fault_idx].far;
            fault_pc = fault_reports[last_fault_idx].pc;
        }
        // Use the process name if available, otherwise the task name
        const proc_name = if (process.find_by_task(exiting)) |pid|
            process.info(pid).?.name
        else
            name;
        const pid_val = if (process.find_by_task(exiting)) |pid| @as(u64, pid) else @as(u64, 0);
        // Capture the last 512 bytes of serial output for the tombstone.
        var serial_buf: [512]u8 = undefined;
        const serial_n = serial_ring.snapshot(&serial_buf);
        tombstone.record(proc_name, pid_val, status, fault_addr, fault_pc, serial_buf[0..serial_n], serial_n);
        // Arc5 issue #243: persist the tombstone to crash/ on the host
        // share. The write is a polled exchange on the file channel (no
        // allocation, no interrupt, no global-state conflict with the
        // exception context). M34 HF6 (issue #740): the DATA partition /
        // virtio-blk path is gone.
        if (virtio_file.available()) {
            _ = tombstone.write_to_disk(tombstone.get(tombstone.count() - 1).?);
        }
    }
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
        // M33 SB2 (claim 8878): the exiting process's shared surfaces die
        // with it. Regions it OWNED are revoked NOW — every peer RO leaf
        // unmapped and the descriptors dropped BEFORE the reap unrefs the
        // owner's pages, so a peer can never retain access into freed
        // physical memory (ADR 0016 D2 revocation-on-teardown). Regions it
        // PEER-mapped (the WM role) are detached — unmap + unref 2->1 — and
        // the owner's surface survives. Pure BSS + leaf writes, safe in this
        // exception context.
        _ = shared_mmap.revoke_owner(pid);
        _ = shared_mmap.revoke_peer_role(pid);
        file_table.reset_process(pid);
        tcp.close_owner(pid);
        // Milestone 14 (claim 7323): a dead process's app timer is disarmed
        // now — no stale fire can ever reach a recycled pid.
        app_timers.reset(pid);
        // M32 WMS2 (issue #622): if the exited process was the registered
        // WM, unregister it NOW — pacing falls back to the shell idle shim
        // (the desktop survives a crashed WM, mirroring the close_owner
        // window-teardown semantic right above). Pure BSS write; the shell
        // idle loop drains the `wm: unregistered, shim resumed` report.
        _ = wm_server.unregister(pid);
    }
    const next = next_runnable(exiting) orelse {
        // No successor. Core 0 is unreachable here (the always-ready idle
        // task); a SECONDARY core parks back on its WFE loop instead of
        // rolling the exit back — the exiting task stays a zombie for core
        // 0's reaper (claim 2369).
        if (stage_secondary_park(c)) {
            queue_exit_report(name, status);
            exits +%= 1;
            return true;
        }
        // No successor (defensive rollback — the always-ready idle task
        // makes this unreachable in a normal boot; kept as a bound).
        tasks[exiting].state = .ready;
        tasks[exiting].exit_status = 0;
        return false;
    };
    queue_exit_report(name, status);
    exits +%= 1;
    current[c] = next;
    stage_current();
    apply_pending();
    return true;
}

/// Card 3d (claim 1014): EVERY exit is queued (a full ring drops the
/// oldest) — N exits in one window print N lines in order. Callers hold
/// `sched_lock`.
/// Secondary-core park (claim 2369): stage the WFE frame captured when
/// this core started its task, so an SVC that must give up the CPU
/// (sleep/wait/wait_event/exit) with no eligible successor returns the
/// core to its WFE loop instead of rolling back. The parked task stays in
/// its new state (blocked/zombie) for core 0's tick/reaper to service;
/// a later tick picks it up again when it is ready (pin_core routes it
/// back to this core). Callers hold `sched_lock` and run on core `c`.
fn stage_secondary_park(c: usize) bool {
    if (c == 0 or park_sp[c] == 0) return false;
    current[c] = idle_id;
    pending_sp[c] = park_sp[c];
    pending_elr[c] = park_elr[c];
    pending_spsr[c] = park_spsr[c];
    pending_sp_el0[c] = 0;
    pending_ttbr0[c] = mmu.kernel_root_phys();
    apply_pending();
    return true;
}

fn queue_exit_report(name: []const u8, status: u64) void {
    if (exit_report_count == exit_report_max) {
        exit_report_head = (exit_report_head + 1) % exit_report_max;
        exit_report_count -= 1;
    }
    const report_index = (exit_report_head + exit_report_count) % exit_report_max;
    exit_reports[report_index] = .{ .name = name, .status = status };
    exit_report_count += 1;
}

/// Claim 6729: reap a zombie — free its pool slot. Only a zombie may be
/// reaped, and the reaped slot becomes spawnable again. Returns false for a
/// non-zombie slot. Claim 4613: the exited process that last ran on this
/// slot has its allocator-backed pages (text/user-stack/EL1-exception-
/// stack) returned to the physical allocator at the same reap — the
/// exited descriptor (name, status, stack VA) stays in the `procs` table
/// for the claim-3848 exit record, but the memory is recycled immediately.
pub fn reap(id: usize) bool {
    // Kernel lock first (claim 9498 follow-on): release_pages_on_reap
    // zeroes the exited process's registry rows, which sys_procs and the
    // registry syscalls read under the kernel lock.
    const gated = !svclock.kernel.held();
    if (gated) svclock.kernel.acquire();
    defer if (gated) svclock.kernel.release();
    sched_lock_acquire();
    defer sched_lock_release();
    if (id >= max_tasks or tasks[id].state != .zombie) return false;
    _ = process.release_pages_on_reap(id);
    // Claim 881 slice 1: the freed slot leaves its ring BEFORE the reset
    // (the exit path's ring removal lands with the slice-2 rotation
    // wiring, so a zombie can still hold its spawn seat until the reap).
    _ = ring_remove_anywhere(id);
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
        // Claim 9094 (#810): validate the slot BEFORE reading its state —
        // the idle reaper is where run-11 boots 2/3 faulted on wildly
        // corrupted fields; the audit records the evidence first.
        audit.slot(i, .reap);
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
/// stack (`exceptions.resume_frame[c]`); ELR_EL1/SPSR_EL1 still hold the
/// interrupted PC/PSTATE. The switch itself only programs ELR/SPSR and the
/// stub's restore frame — the stub does the register pop and eret.
pub fn tick() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (!scheduling_active()) return;
    // Ring lock FIRST (held briefly): the preemption rotation (save,
    // pick, stage) touches only per-core staging and ready<->running
    // flips, which need no userspace gate. It must NOT be held hostage
    // to the gate — a syscall on another core holds it for its WHOLE
    // duration, and a tick that skipped on that would stall the ring
    // (the idle reaper never runs, zombies pile up — the claim-9498
    // live flake). Gate-protected work below (timekeeping + kill
    // conversions) try-acquires it and defers only THAT work.
    if (!sched_lock.try_lock()) return; // ring busy (idle reaping etc.) — skip this beat
    sched_lock_holder = smp.core_id();
    defer sched_lock_release();
    const c = smp.core_id(); // per-core staging
    smp.core_ticks[c] +%= 1;
    // Userspace-service gate: on_tick's registries (app timers, WM
    // pacing, CPU-limit exits) mutate the same state user syscalls hold
    // the gate over. Every gate hold masks IRQs, so a same-core holder
    // can never be paused under a tick — contention here is always a
    // syscall mid-flight on ANOTHER core, and the rotation below is safe
    // without the gate (only on_tick's registry work + the exit
    // teardowns need it). The held() check is a defensive bound: if a
    // same-core holder ever IS paused under us, do not rotate (any task
    // we switched to would spin on a gate only this core can release).
    // Service-domain locks (claim 9498 follow-on): on_tick's registry
    // work (app timers, WM pacing, CPU-limit arming) mutates EV + kernel
    // state — its canonical subset. try_take NEVER spins (we hold
    // sched_lock): a same-domain syscall elsewhere defers only this work
    // while the rotation below proceeds (the claim-9498 ring-progress
    // fix). try_take also skips bits this core already holds — but svclock
    // holders mask IRQs, so no tick can ever preempt a same-core hold.
    const evk = svclock.dom_bit(.ev) | svclock.dom_bit(.kernel);
    const evk_taken = svclock.try_take(evk);
    defer if (evk_taken) |t| svclock.release_set(t);
    // Global timekeeping + registries (tick_count, wake_expired, app
    // timers, WM pacing, CPU limits) stay on the core-0 authority; a
    // secondary core runs ONLY the switch machinery on its own per-core
    // staging (claim 8477 follow-up lift). Skipped when a same-domain
    // syscall is mid-flight (one 1 s cadence loss — the pre-existing
    // skip semantic).
    if (c == 0 and evk_taken != null) on_tick();
    var elr: u64 = 0;
    var spsr: u64 = 0;
    asm volatile ("mrs %[v], elr_el1"
        : [v] "=r" (elr),
    );
    asm volatile ("mrs %[v], spsr_el1"
        : [v] "=r" (spsr),
    );
    if (c != 0 and current[c] == idle_id) {
        // The secondary core's WFE loop owns no ring slot — jump straight
        // to an eligible task (nothing to save). If none is runnable, the
        // stub restores the WFE frame and the core keeps spinning.
        // Capture the WFE frame FIRST (claim 2369): `resume_frame[c]` is
        // the tick IRQ frame on the secondary stack, and `elr`/`spsr` the
        // interrupted loop's — a task staged from here runs on its own
        // kstack, so these bytes survive intact until the task exits, when
        // exit_current erets back to them (park) if no successor exists.
        park_sp[c] = exceptions.resume_frame[c];
        park_elr[c] = elr;
        park_spsr[c] = spsr;
        const next = next_runnable_for(idle_id, c) orelse return;
        current[c] = next;
        stage_selected(c, next);
        apply_pending();
        return;
    }
    // A lone secondary-eligible task keeps running (the shared idle
    // fallback is core 0's, so there is no always-ready successor here).
    // A kill_pending must still convert even without a successor to
    // switch to — request_kill on a lone core-1 task would otherwise
    // stall until it blocks (claim 9498). The conversion runs the exit
    // teardown — EVERY service domain — so it try-takes the missing
    // file/net/win bits now (ev+kernel already held above). When any is
    // contended the task runs one more quantum and the next beat
    // converts it (the outer defer releases ev+kernel).
    if (c != 0 and current[c] != idle_id and tasks[current[c]].kill_pending and evk_taken != null) {
        if (svclock.try_take(svclock.all_bits)) |more| {
            defer svclock.release_set(more);
            tasks[current[c]].kill_pending = false;
            const status = tasks[current[c]].kill_pending_status;
            tasks[current[c]].kill_pending_status = reserved_kill_status; // back to the request_kill default
            _ = exit_current_locked(status); // tick holds all five + sched_lock
            return;
        }
    }
    if (c != 0 and next_runnable_for(current[c], c) == null) return;
    timer_switch_context(exceptions.resume_frame[c], elr, spsr, exceptions.resume_sp_el0[c]);
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
// Claim 9094 (#810 writer hunt): task-ring + process-registry audit
// ---------------------------------------------------------------------------

/// Instrumentation ONLY — no behavior change. The #810 corruption family
/// (wild Task/Process field values in the vf-output era: 0xfcab6000, −1,
/// 0x80000000-based pointers) always violates a field invariant BEFORE the
/// faulting read, so the audit prints the slot/field/value that binds the
/// corruption to its window. Windows: (a) EVERY virtio_file queue-5
/// exchange arms at entry / checks at exit (`.vf`); (b) `reap_one_zombie`
/// validates the slot it is about to read (`.reap`); (c) the tick's ring
/// select validates `current` before the `kill_pending` read — the +0x178
/// byte read that faulted in run-11 boots — (`.tick`, record-only: no
/// console in IRQ context, claim 9187); (d) the shell idle loop drains
/// recorded violations via `drain` (main context, inside `maybe_report`).
///
/// Bounds are strict supersets of observed LEGAL values: kernel pointers
/// (image, BSS stacks, allocator frames) sit in [0x1000, 0x80000000) — the
/// top of the guest's 2 GiB RAM @ 0 (the same ceiling as
/// exceptions.deep_dump; the SEA at 0x80000178 proves nothing maps at or
/// above it in this class). User-space VAs (sp_el0, the randomized user
/// stack) are LEGAL as task fields and deliberately not validated. Task
/// names are kernel string literals ("worker", "user-exec", …); process
/// names are copied into BSS name buffers — all kernel memory.
pub const audit = struct {
    pub const ram_ceiling: u64 = 0x8000_0000;
    pub const Tag = enum { vf, reap, tick, drain };
    pub const Field = enum(u8) { state, name_ptr, name_len, sp, elr, ttbr0, p_state, p_name_len, p_task_id, p_kstack, p_text, p_stack };
    const max_violations: usize = 8;
    const Violation = struct {
        tag: Tag = .drain,
        field: Field = .state,
        slot: usize = 0,
        value: u64 = 0,
        tick: u64 = 0,
    };

    /// Nested-arm depth (an exchange nested inside an exchange keeps ONE
    /// armed window).
    pub var depth: u32 = 0;
    pub var arms: u64 = 0;
    pub var checks: u64 = 0;
    /// Scheduler tick at which the current window was armed.
    pub var armed_tick: u64 = 0;
    /// One "audit armed" evidence line per boot (proves the seam runs;
    /// nothing else prints on healthy boots).
    var boot_line: bool = false;
    /// The last (slot, field) pair DRAINED this boot — repeating
    /// violations (the reap pass re-validates the same corrupted slot
    /// every idle iteration) print once, so one corruption = one line.
    var last_slot: usize = 0;
    var last_field: Field = .state;
    var have_last: bool = false;

    var viol: [max_violations]Violation = [_]Violation{.{}} ** max_violations;
    var viol_head: usize = 0;
    var viol_count: usize = 0;

    /// Legal kernel pointer: 0 or a RAM-class address.
    fn valid_ptr(v: u64) bool {
        return v == 0 or (v >= 0x1000 and v < ram_ceiling);
    }

    /// Legal physical root/table pointer: page-aligned RAM-class or 0.
    fn valid_aligned(v: u64) bool {
        return v == 0 or ((v & 0xfff) == 0 and v >= 0x1000 and v < ram_ceiling);
    }

    /// NOTE: saved PSTATE is deliberately NOT validated — observed legal
    /// spsr values span PAN/UAO/condition bits up to 0x60000000 and even
    /// 0x80000005 (the #810 frames), so no shape check separates corrupt
    /// from legit. Run-12 boot 1 proved it: a too-tight spsr rule fired
    /// on every reap pass and flooded the serial with 38 false-positive
    /// lines. Excluded; the remaining fields still catch every observed
    /// corruption value (−1, 0xfcab6000, string bytes, dead-space VAs).
    /// Raw storage read of the state enum — the TYPED load of a rogue
    /// byte as an enum is UB in safe builds; the audit must not fault
    /// itself.
    fn enum_raw(ptr: *const anyopaque) u64 {
        var raw: u64 = 0;
        const bytes: [*]const u8 = @ptrCast(ptr);
        var i: usize = 0;
        while (i < @sizeOf(State)) : (i += 1) raw |= @as(u64, bytes[i]) << @intCast(i * 8);
        return raw;
    }

    /// Arm a window (nested arms keep one open window).
    pub fn arm(tag: Tag) void {
        _ = tag;
        if (depth == 0) armed_tick = tick_count;
        depth +%= 1;
        arms +%= 1;
    }

    /// Close the window and validate the whole ring + registry.
    pub fn check(tag: Tag) void {
        checks +%= 1;
        if (depth > 0) depth -%= 1;
        sweep(tag);
    }

    /// Validate ONE task slot (the reap/tick read seams).
    pub fn slot(id: usize, tag: Tag) void {
        if (id < max_tasks) check_task(id, tag);
    }

    fn sweep(tag: Tag) void {
        if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
        var i: usize = 0;
        while (i < max_tasks) : (i += 1) check_task(i, tag);
        var p: usize = 0;
        while (p < process.max_processes) : (p += 1) check_proc(p, tag);
    }

    fn check_task(id: usize, tag: Tag) void {
        const t = &tasks[id];
        const st = enum_raw(&t.state);
        if (st > @intFromEnum(State.zombie)) record(tag, .state, id, st);
        const nptr = @intFromPtr(t.name.ptr);
        if (!valid_ptr(nptr)) record(tag, .name_ptr, id, nptr);
        if (t.name.len > 64) record(tag, .name_len, id, t.name.len);
        if (!valid_ptr(t.sp)) record(tag, .sp, id, t.sp);
        if (!valid_ptr(t.elr)) record(tag, .elr, id, t.elr);
        if (!valid_aligned(t.ttbr0)) record(tag, .ttbr0, id, t.ttbr0);
    }

    fn check_proc(id: usize, tag: Tag) void {
        const c = process.audit_proc(id);
        if (c.state > @intFromEnum(process.State.exited)) record(tag, .p_state, id, c.state);
        if (c.name_len > process.name_max) record(tag, .p_name_len, id, c.name_len);
        if (c.task_id) |tid| {
            if (tid >= max_tasks) record(tag, .p_task_id, id, tid);
        }
        if (!valid_aligned(c.kstack_phys)) record(tag, .p_kstack, id, c.kstack_phys);
        if (!valid_aligned(c.text_phys)) record(tag, .p_text, id, c.text_phys);
        if (!valid_aligned(c.stack_phys)) record(tag, .p_stack, id, c.stack_phys);
    }

    fn record(tag: Tag, field: Field, row: usize, value: u64) void {
        const idx = (viol_head + viol_count) % max_violations;
        if (viol_count == max_violations) {
            viol_head = (viol_head + 1) % max_violations;
        } else {
            viol_count += 1;
        }
        viol[idx] = .{ .tag = tag, .field = field, .slot = row, .value = value, .tick = tick_count };
    }

    fn field_name(f: Field) []const u8 {
        return switch (f) {
            .state => "state",
            .name_ptr => "name_ptr",
            .name_len => "name_len",
            .sp => "sp",
            .elr => "elr",
            .ttbr0 => "ttbr0",
            .p_state => "procs.state",
            .p_name_len => "procs.name_len",
            .p_task_id => "procs.task_id",
            .p_kstack => "procs.kstack",
            .p_text => "procs.text",
            .p_stack => "procs.stack",
        };
    }

    fn tag_name(t: Tag) []const u8 {
        return switch (t) {
            .vf => "vf",
            .reap => "reap",
            .tick => "tick",
            .drain => "drain",
        };
    }

    /// Print the one-per-boot armed line and drain any recorded
    /// violations (main context only — called from `maybe_report`).
    pub fn drain(con: *console.Console) void {
        if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
        if (!boot_line) {
            boot_line = true;
            con.puts("[AUDIT] task-ring+procs audit armed slots=");
            con.print_u64(max_tasks);
            con.puts(" procs=");
            con.print_u64(process.max_processes);
            con.puts("\n");
        }
        while (viol_count > 0) {
            const v = viol[viol_head];
            viol_head = (viol_head + 1) % max_violations;
            viol_count -= 1;
            // Repeat-suppression: the same (slot, field) re-recorded by a
            // later window (e.g. the next reap pass) is a repeat of the
            // SAME corruption — one line per boot per corruption.
            if (have_last and v.slot == last_slot and v.field == last_field) continue;
            have_last = true;
            last_slot = v.slot;
            last_field = v.field;
            const is_task = @intFromEnum(v.field) < @intFromEnum(Field.p_state);
            con.puts("[AUDIT] ");
            con.puts(if (is_task) "tasks slot=" else "procs id=");
            con.print_u64(v.slot);
            con.puts(" field=");
            con.puts(field_name(v.field));
            con.puts(" value=");
            con.print_hex(v.value);
            con.puts(" tag=");
            con.puts(tag_name(v.tag));
            con.puts(" tick=");
            con.print_u64(v.tick);
            con.puts("\n");
        }
    }
};

// ---------------------------------------------------------------------------
// Worker progress (main context only — never from the IRQ tick)
// ---------------------------------------------------------------------------

/// Task-side: bump the current task's advance counter (the worker calls
/// this in its main-context loop).
pub fn note_advance() void {
    if (task_count == 0) return;
    const c = smp.core_id(); // per-core current
    tasks[current[c]].advances += 1;
}

/// Task-side: ask the shell idle loop to print the current task's advance
/// counter. Keeps the FIRST snapshot per task while that task's slot is
/// pending (no backlog). Console output stays in main context (claim 9187
/// — never print from IRQ). Claim 6729: per-task slots, so one task's
/// reports cannot starve another's (the worker requests every 64
/// iterations; the spawn-demo task every 16).
pub fn request_report() void {
    const c = smp.core_id(); // per-core current
    if (task_count == 0 or report_pending[current[c]]) return;
    report_pending[current[c]] = true;
    report_advances[current[c]] = tasks[current[c]].advances;
}

/// Shell-side (main context, next to timer.maybe_heartbeat): print every
/// pending report line, then the exit/reap reports.
pub fn maybe_report(con: *console.Console) void {
    // Claim 9094 (#810): the idle-loop drain point for the task-ring/
    // process audit — main context, console-safe (claim 9187). Nothing
    // prints on healthy boots beyond the one-per-boot armed line.
    audit.drain(con);
    // SMP lift evidence (claim 8477 follow-up): one line per secondary
    // RUN (not per drain check), printed from the shell idle loop (main
    // context). The ring preserves the per-run name, so a user run
    // sandwiched between worker runs still gets its own line.
    while (secondary_runs_printed < secondary_runs) {
        secondary_runs_printed += 1;
        const index = secondary_runs_printed - 1;
        const name = if (index < secondary_run_names_count) secondary_run_names[index] else secondary_last_task;
        con.puts("smp: secondary runs=");
        con.print_u64(secondary_runs_printed);
        con.puts(" task=");
        con.puts(name);
        con.puts("\n");
    }
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
    // Milestone sixteen C2 (claim 8403): drain the EL0 fault FIFO IN ORDER
    // before the exit reports, so a `fault:` line precedes its
    // `exited status=139` consequence in the serial log.
    while (fault_report_count > 0) {
        const entry = fault_reports[fault_report_head];
        fault_report_head = (fault_report_head + 1) % fault_report_max;
        fault_report_count -= 1;
        con.puts("fault: ");
        con.puts(entry.name);
        con.puts(" far=");
        con.print_hex(entry.far);
        con.puts(" ec=");
        con.print_hex_min(entry.ec);
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
    /// SMP user tasks (claim 2369): the only core this task may run on
    /// (0 = any core). Set by `pin_task` via `exec -c<core>`.
    pin_core: usize,
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
        .current = current[smp.core_id()],
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
        .pin_core = tasks[id].pin_core,
    };
}

pub fn current_id() usize {
    return current[smp.core_id()];
}

pub fn current_task_for_core(cid: usize) usize {
    if (cid < smp.max_cores) return current[cid];
    return 0;
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
    // Milestone sixteen C3 (claim 0339): the pool is shell + idle +
    // worker + EIGHT user slots (eight live programs at the 11/11 budget);
    // a registration beyond the 11-slot budget fails (bounded).
    try std.testing.expectEqual(@as(usize, 2), register_user(0x3333, 0).?);
    try std.testing.expectEqual(@as(usize, 3), register_worker(0).?);
    try std.testing.expectEqual(@as(usize, 4), register_worker(0).?);
    try std.testing.expectEqual(@as(usize, 5), register_worker(0).?);
    try std.testing.expectEqual(@as(usize, 6), register_worker(0).?);
    try std.testing.expectEqual(@as(usize, 7), register_worker(0).?);
    try std.testing.expectEqual(@as(usize, 8), register_worker(0).?);
    try std.testing.expectEqual(@as(usize, 9), register_worker(0).?);
    try std.testing.expectEqual(@as(usize, 11), task_count);
    try std.testing.expect(register_worker(0) == null);
    // Claim 0826: capacity is observable — the full pool has no free slot.
    try std.testing.expect(!has_free_slot());
}

test "scheduler: user tasks are any-core and the shell/idle stay on core 0" {
    // Claim 9498: the console TX is locked (2369) and the userspace gate
    // serializes syscalls, so USER tasks default to ANY core. The shell
    // (console owner / command runner) and the shared idle slot (core 0's
    // reaper — one frame, one owner) stay core-0.
    _ = init();
    const worker = register_worker(0x1111).?; // secondary_ok = true
    try std.testing.expectEqual(@as(usize, 1), worker);
    try std.testing.expect(tasks[worker].secondary_ok);
    try std.testing.expect(!tasks[0].secondary_ok); // shell stays on core 0
    try std.testing.expect(!tasks[idle_id].secondary_ok); // idle is core-0's reaper
    const user = register_user(0x2222, 0).?;
    try std.testing.expectEqual(@as(usize, 2), user);
    try std.testing.expect(tasks[user].secondary_ok); // any-core default
    try std.testing.expectEqual(@as(usize, 0), tasks[user].pin_core);
    // Core 1 walking from the shell finds the worker first (slot order).
    try std.testing.expectEqual(@as(?usize, worker), next_runnable_for(0, 1));
    // Core 1 from the worker finds the user task (now eligible) ahead of
    // the wrap.
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(worker, 1));
    // Core 0 picks the user task normally too.
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(worker, 0));
}

test "scheduler: pin_task restricts a user task to exactly one core" {
    // SMP user tasks (claim 2369 + 9498): `exec -c<core>` pins a spawned
    // task; `pin_task(.., 0)` pins back to CORE 0 only (the any-core
    // default is a RESTRICTION removed by pinning, never re-added).
    _ = init();
    const worker = register_worker(0x1111).?;
    const user = register_user(0x2222, 0).?;
    try std.testing.expect(tasks[user].secondary_ok); // any-core default
    try std.testing.expect(pin_task(user, 1));
    try std.testing.expectEqual(@as(usize, 1), tasks[user].pin_core);
    try std.testing.expect(tasks[user].secondary_ok); // pinned off core 0
    // Core 1 from the worker finds the pinned user task (it is eligible
    // AND ahead of the worker in the wrap order).
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(worker, 1));
    // Core 0 skips the pinned task entirely — from the worker it wraps
    // straight to the idle fallback, never to the user task.
    try std.testing.expectEqual(@as(?usize, idle_id), next_runnable_for(worker, 0));
    // Core 1 may also still pick the worker (any-core, secondary_ok).
    try std.testing.expectEqual(@as(?usize, worker), next_runnable_for(user, 1));
    // Pinning to core 0 (the WM registration) makes the task core-0-ONLY:
    // core 1 skips it again and core 0 picks it again.
    try std.testing.expect(pin_task(user, 0));
    try std.testing.expectEqual(@as(usize, 0), tasks[user].pin_core);
    try std.testing.expect(!tasks[user].secondary_ok);
    try std.testing.expectEqual(@as(?usize, worker), next_runnable_for(worker, 1));
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(worker, 0));
    // Unknown ids are refused.
    try std.testing.expect(!pin_task(max_tasks + 4, 1));
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
    try std.testing.expectEqual(@as(usize, 1), current[0]);
    try std.testing.expectEqual(@as(u64, 1), switches);
    try std.testing.expectEqual(@as(u64, 1), tasks[0].saves);
    try std.testing.expectEqual(@as(u64, 0), tasks[0].resumes);
    try std.testing.expectEqual(@as(u64, 1), tasks[1].resumes);
    try std.testing.expectEqual(@as(u64, 0), tasks[1].saves);
    try std.testing.expectEqual(tasks[1].sp, pending_sp[0]);
    try std.testing.expectEqual(worker_entry, pending_elr[0]);
    try std.testing.expectEqual(spsr_el1h_irqs, pending_spsr[0]);
    // Second switch: the worker is preempted; the user task is restored to
    // its synthetic EL0t frame.
    switch_context(0x2000, 0x2000, 0x5, 0xbbbb);
    try std.testing.expectEqual(@as(usize, 2), current[0]);
    try std.testing.expectEqual(@as(u64, 2), switches);
    try std.testing.expectEqual(@as(u64, 1), tasks[1].saves);
    try std.testing.expectEqual(@as(u64, 1), tasks[1].resumes);
    try std.testing.expectEqual(tasks[2].sp, pending_sp[0]);
    try std.testing.expectEqual(@as(u64, 0x3000), pending_elr[0]);
    try std.testing.expectEqual(spsr_el0t_irqs, pending_spsr[0]);
    // Third switch: the user is preempted; the idle task is restored.
    switch_context(0x3000, 0x3000, 0x0, 0xcccc);
    try std.testing.expectEqual(@as(usize, idle_id), current[0]);
    try std.testing.expectEqual(@as(u64, 3), switches);
    try std.testing.expectEqual(@as(u64, 1), tasks[2].saves);
    try std.testing.expectEqual(@as(u64, 1), tasks[idle_id].resumes);
    try std.testing.expectEqual(tasks[idle_id].sp, pending_sp[0]);
    // Fourth switch: the idle task is preempted; the shell is restored to
    // its exact saved context (the round-trip).
    switch_context(0x4000, 0x4000, 0x5, 0xdddd);
    try std.testing.expectEqual(@as(usize, 0), current[0]);
    try std.testing.expectEqual(@as(u64, 4), switches);
    try std.testing.expectEqual(@as(u64, 1), tasks[idle_id].saves);
    try std.testing.expectEqual(@as(u64, 1), tasks[0].resumes);
    try std.testing.expectEqual(@as(u64, 0x1000), pending_sp[0]);
    try std.testing.expectEqual(@as(u64, 0x1000), pending_elr[0]);
    try std.testing.expectEqual(@as(u64, 0x5), pending_spsr[0]);
    try std.testing.expectEqual(@as(u64, 0xaaaa), pending_sp_el0[0]);
    // Fifth switch returns to the worker's saved context (the round-trip).
    switch_context(0x1000, 0x1001, 0x5, 0xaaaa);
    try std.testing.expectEqual(@as(usize, 1), current[0]);
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
    try std.testing.expectEqual(@as(usize, 1), current[0]);
    switch_context(0x2000, 0x2000, spsr_el1h_irqs, 0xbbbb); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), current[0]);
    try std.testing.expectEqual(spsr_el0t_irqs, pending_spsr[0]);
    try std.testing.expectEqual(initial_user_sp, pending_sp_el0[0]);

    const preempted_user_sp: u64 = initial_user_sp - 16;
    // Claim 6729: the preempted EL0 task's successor is the idle task
    // (sp_el0 = 0 for an EL1h task), then the shell on the next switch.
    switch_context(0x3000, 0x3004, spsr_el0t_irqs, preempted_user_sp); // user -> idle
    try std.testing.expectEqual(@as(usize, idle_id), current[0]);
    try std.testing.expectEqual(@as(u64, 0), pending_sp_el0[0]);
    try std.testing.expectEqual(preempted_user_sp, tasks[2].sp_el0);
    switch_context(0x4000, 0x4000, spsr_el1h_irqs, 0xcccc); // idle -> shell
    try std.testing.expectEqual(@as(usize, 0), current[0]);
    try std.testing.expectEqual(@as(u64, 0xaaaa), pending_sp_el0[0]);

    switch_context(0x1000, 0x1004, spsr_el1h_irqs, 0xaaaa);
    switch_context(0x2000, 0x2004, spsr_el1h_irqs, 0xbbbb);
    try std.testing.expectEqual(@as(usize, 2), current[0]);
    try std.testing.expectEqual(preempted_user_sp, pending_sp_el0[0]);
    try std.testing.expectEqual(@as(u64, 0x3004), pending_elr[0]);
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
    current[0] = 1; // pretend the worker is running
    note_advance();
    note_advance();
    note_advance();
    try std.testing.expectEqual(@as(u64, 3), tasks[1].advances);
    try std.testing.expectEqual(@as(u64, 0), tasks[0].advances);
}

test "scheduler: worker report snapshots once and prints from the shell side" {
    _ = init();
    _ = register_worker(0x2000).?;
    current[0] = 1; // pretend the worker is running
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
    try std.testing.expectEqual(@as(usize, 1), current[0]);
    // The blocked task drops out of the ring: worker -> user -> idle -> worker.
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 2), current[0]);
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, idle_id), current[0]);
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 1), current[0]);
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
    try std.testing.expectEqual(@as(usize, 2), current[0]);
    try std.testing.expect(yield_current()); // user -> idle
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expectEqual(@as(usize, 0), current[0]);
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
    current[0] = idle_id;
    try std.testing.expect(!sleep_current(1));
    try std.testing.expect(!is_blocked(idle_id));
    // A zombie cannot sleep either.
    tasks[1].state = .zombie;
    current[0] = 1;
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
    // Milestone sixteen C3 (claim 0339): the 11-slot pool holds EIGHT user
    // tasks. Fill the remaining four slots so the capacity gate is
    // observable at the new budget.
    var kstack_e_bytes: [task_stack_size]u8 align(16) = undefined;
    const kstack_e = kstack_e_bytes[0..];
    _ = register_exec_user(0x7000, root_b, 64, 0x1d400000, 8192, kstack_e, 0, 0).?;
    var kstack_f_bytes: [task_stack_size]u8 align(16) = undefined;
    const kstack_f = kstack_f_bytes[0..];
    _ = register_exec_user(0x8000, root_b, 64, 0x1e400000, 8192, kstack_f, 0, 0).?;
    var kstack_g_bytes: [task_stack_size]u8 align(16) = undefined;
    const kstack_g = kstack_g_bytes[0..];
    _ = register_exec_user(0x9000, root_b, 64, 0x1f400000, 8192, kstack_g, 0, 0).?;
    var kstack_h_bytes: [task_stack_size]u8 align(16) = undefined;
    const kstack_h = kstack_h_bytes[0..];
    _ = register_exec_user(0xa000, root_b, 64, 0x20400000, 8192, kstack_h, 0, 0).?;
    try std.testing.expectEqual(@as(usize, 11), task_count); // shell + worker + A..H + idle
    try std.testing.expect(!has_free_slot());
    // Each task carries ITS OWN root and apertures.
    try std.testing.expect(task_ttbr0(user_a) != task_ttbr0(user_b));
    try std.testing.expectEqual(root_a, task_ttbr0(user_a));
    try std.testing.expectEqual(root_b, task_ttbr0(user_b));
    // The current-task regions follow the ring: put A current and read its
    // regions, then B.
    current[0] = user_a;
    const ra = current_user_regions();
    try std.testing.expectEqual(userspace.text_va, ra.text.base);
    try std.testing.expectEqual(userspace.stack_va, ra.stack.base);
    current[0] = user_b;
    const rb = current_user_regions();
    try std.testing.expectEqual(userspace.text_va, rb.text.base);
    try std.testing.expectEqual(@as(u64, 0x1a400000), rb.stack.base);
    try std.testing.expectEqual(@as(u64, 8192), rb.stack.len);
    // Restore the ring position before the round-robin exercise (the region
    // checks above moved `current` for readability).
    current[0] = 0;
    // Both run in the ring (round-robin reaches each).
    start();
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(yield_current()); // worker -> user A
    try std.testing.expectEqual(@as(usize, user_a), current_id());
    try std.testing.expect(yield_current()); // A -> B
    try std.testing.expectEqual(@as(usize, user_b), current_id());
    // A ninth user program cannot load: the pool is the capacity gate.
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

test "scheduler: an EL0 fault reaps the task with status 139 and reports it" {
    // Milestone sixteen C2 (claim 8403): a synchronous EL0 fault (here an
    // EC-0x24 data abort at a guard-page FAR) reaches fault_current, which
    // snapshots the fault report AND reaps the task through the existing
    // exit path with reserved_fault_status. The shell drains `fault:` before
    // the exit report.
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), current_id());
    fault_current(0x24 << 26, 0x7fff_f000, 0x4000); // user -> idle
    try std.testing.expectEqual(@as(usize, idle_id), current_id());
    try std.testing.expect(is_terminated(2));
    try std.testing.expectEqual(@as(?u64, reserved_fault_status), terminated_status(2));
    var mock = console.MockConsole(128){};
    var con = mock.console();
    maybe_report(&con);
    try std.testing.expectEqualStrings(
        "fault: user-el0 far=0x000000007ffff000 ec=0x24\n" ++
            "tasks user-el0 exited status=139\n" ++
            "procs user-el0 exited status=139\n",
        mock.contents(),
    );
    try std.testing.expect(reap(2));
    try std.testing.expect(task_info(2) == null);
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

// ---------------------------------------------------------------------------
// Claim 881 slice 1 — per-core ready rings
// ---------------------------------------------------------------------------

test "scheduler: ready rings — FIFO push/pop order, contains, remove, wrap" {
    var r: ReadyRing = .{};
    try std.testing.expect(r.empty());
    try std.testing.expectEqual(@as(usize, 0), r.len());
    try std.testing.expectEqual(@as(?usize, null), r.pop());

    r.push(3);
    r.push(1);
    r.push(2);
    try std.testing.expectEqual(@as(usize, 3), r.len());
    try std.testing.expect(r.contains(1));
    try std.testing.expect(!r.contains(9));
    try std.testing.expectEqual(@as(usize, 3), r.get(0));
    try std.testing.expectEqual(@as(usize, 1), r.get(1));
    try std.testing.expectEqual(@as(usize, 2), r.get(2));

    // FIFO: pop order = push order.
    try std.testing.expectEqual(@as(?usize, 3), r.pop());
    try std.testing.expectEqual(@as(?usize, 1), r.pop());
    try std.testing.expectEqual(@as(?usize, 2), r.pop());
    try std.testing.expect(r.empty());

    // remove compacts while keeping order (middle, head, tail).
    r.push(5);
    r.push(6);
    r.push(7);
    try std.testing.expect(r.remove(6));
    try std.testing.expect(!r.remove(99));
    try std.testing.expectEqual(@as(?usize, 5), r.pop());
    try std.testing.expectEqual(@as(?usize, 7), r.pop());
    r.push(8);
    r.push(9);
    r.push(10);
    try std.testing.expect(r.remove(8));
    try std.testing.expect(r.remove(10));
    try std.testing.expectEqual(@as(?usize, 9), r.pop());

    // Wrap-around: the head advances past the array end and push/pop
    // still behave FIFO (head = (head + 1) % max_tasks).
    r.push(1);
    r.push(2);
    r.push(3);
    _ = r.pop();
    _ = r.pop();
    r.push(4);
    r.push(5);
    try std.testing.expectEqual(@as(?usize, 3), r.pop());
    try std.testing.expectEqual(@as(?usize, 4), r.pop());
    try std.testing.expectEqual(@as(?usize, 5), r.pop());
    try std.testing.expect(r.empty());
}

test "scheduler: ready rings — seeded membership at init/spawn/pin with the invariant" {
    // Slice-1 seeding seams (no rotation yet — the checker's call
    // precondition; rotation paths wire into the rings in slice 2).
    _ = init();
    // init: the idle reaper is ring 0's only member; the shell is
    // current[0] and executing (off-ring).
    try std.testing.expectEqual(@as(usize, 1), ready_rings[0].len());
    try std.testing.expect(ready_rings[0].contains(idle_id));
    check_ready_membership();

    // spawn: new ready tasks join ring 0 in spawn order.
    const worker = register_worker(0x1111).?;
    try std.testing.expectEqual(@as(usize, 2), ready_rings[0].len());
    try std.testing.expect(ready_rings[0].contains(worker));
    const user = register_user(0x2222, 0).?;
    try std.testing.expect(ready_rings[0].contains(user));
    try std.testing.expectEqual(@as(usize, 1), ready_rings[0].get(1)); // spawn order = run order
    try std.testing.expectEqual(@as(usize, 2), ready_rings[0].get(2));
    check_ready_membership();

    // pin re-homes a still-ready task: ring 0 -> ring 1, and back.
    try std.testing.expect(pin_task(user, 1));
    try std.testing.expect(!ready_rings[0].contains(user));
    try std.testing.expect(ready_rings[1].contains(user));
    check_ready_membership();
    try std.testing.expect(pin_task(user, 0));
    try std.testing.expect(ready_rings[0].contains(user));
    try std.testing.expect(!ready_rings[1].contains(user));
    check_ready_membership();
}

test "scheduler: ready rings — reap drops the slot's ring membership" {
    _ = init();
    const t = spawn("ring-test", 0x6000, spsr_el1h_irqs, &worker_stack, 0, 0).?;
    try std.testing.expect(ready_rings[0].contains(t));
    // Exit it (state -> zombie) and reap. The exit path does NOT touch the
    // rings until the slice-2 rotation wiring — the zombie keeps its spawn
    // seat — so the checker is deliberately not called between exit and
    // reap; the reap itself drops the membership.
    current[0] = t;
    try std.testing.expect(exit_current(7));
    try std.testing.expect(ready_rings[0].contains(t));
    try std.testing.expect(reap(t));
    try std.testing.expect(!ready_rings[0].contains(t));
    // The freed slot is spawnable again and re-joins ring 0 exactly once.
    const again = spawn("ring-test-2", 0x6001, spsr_el1h_irqs, &worker_stack, 0, 0).?;
    try std.testing.expectEqual(@as(usize, t), again);
    var on: usize = 0;
    for (&ready_rings) |*r| {
        if (r.contains(again)) on += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), on);
}
