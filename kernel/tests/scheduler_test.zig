//! VirelaiOS scheduler decoupled unit tests (M41 TS3, #954).
//!
//! Host unit test suite extracted from kernel/src/scheduler.zig.
//! Tests thread registration, priority/ready rings, context switching,
//! EL0 preemption, SMP work-stealing, sleeping deadlines, and lifecycle reaping.

const std = @import("std");
const scheduler = @import("scheduler");
const helpers = @import("helpers");
const task_mock = helpers.task;

// Re-export scheduler types, functions, and state
const KillResult = scheduler.KillResult;
const ReadyRing = scheduler.ReadyRing;
const State = scheduler.State;
const build_initial_frame = scheduler.build_initial_frame;
const check_ready_membership = scheduler.check_ready_membership;
const console = scheduler.console;
const current_id = scheduler.current_id;
const current_user_regions = scheduler.current_user_regions;
const enabled = scheduler.enabled;
const exceptions = scheduler.exceptions;
const exit_count = scheduler.exit_count;
const exit_current = scheduler.exit_current;
const fault_current = scheduler.fault_current;
const frame_bytes = scheduler.frame_bytes;
const has_free_slot = scheduler.has_free_slot;
const idle_entry = scheduler.idle_entry;
const idle_id = scheduler.idle_id;
const init = scheduler.init;
const is_blocked = scheduler.is_blocked;
const is_terminated = scheduler.is_terminated;
const max_tasks = scheduler.max_tasks;
const maybe_report = scheduler.maybe_report;
const mmu = scheduler.mmu;
const next_runnable_for = scheduler.next_runnable_for;
const note_advance = scheduler.note_advance;
const on_tick = scheduler.on_tick;
const park = scheduler.park;
const pin_task = scheduler.pin_task;
const process = scheduler.process;
const reap = scheduler.reap;
const reap_one_zombie = scheduler.reap_one_zombie;
const register_exec_user = scheduler.register_exec_user;
const register_user = scheduler.register_user;
const register_worker = scheduler.register_worker;
const request_kill = scheduler.request_kill;
const request_report = scheduler.request_report;
const reserved_fault_status = scheduler.reserved_fault_status;
const reserved_kill_status = scheduler.reserved_kill_status;
const ring_claim = scheduler.ring_claim;
const rotation_lock = scheduler.rotation_lock;
const rotation_unlock = scheduler.rotation_unlock;
const scheduling_active = scheduler.scheduling_active;
const sleep_current = scheduler.sleep_current;
const spawn = scheduler.spawn;
const spawn_demo = scheduler.spawn_demo;
const spsr_el0t_irqs = scheduler.spsr_el0t_irqs;
const spsr_el1h_irqs = scheduler.spsr_el1h_irqs;
const start = scheduler.start;
const stats = scheduler.stats;
const switch_context = scheduler.switch_context;
const task_info = scheduler.task_info;
const task_stack_size = scheduler.task_stack_size;
const task_ttbr0 = scheduler.task_ttbr0;
const terminated_status = scheduler.terminated_status;
const tick = scheduler.tick;
const timer_switch_context = scheduler.timer_switch_context;
const user_timer_preemption_count = scheduler.user_timer_preemption_count;
const userspace = scheduler.userspace;
const yield_current = scheduler.yield_current;

// ---------------------------------------------------------------------------
// Tests (host-side; the asm tick is proven on real VZ hardware by the
// class B gate tools/verify-live-scheduler.tasks.sh)
// ---------------------------------------------------------------------------

test "scheduler: init registers the shell and idle scheduler.tasks; start flips enabled" {
    try std.testing.expectEqual(@as(usize, 0), init());
    // Claim 6729: the pool starts as shell + the scheduler-owned idle task
    // (the idle task's synthetic frame targets `idle_entry`).
    try std.testing.expectEqual(@as(usize, 2), scheduler.task_count);
    try std.testing.expectEqualStrings("shell", scheduler.tasks[0].name);
    try std.testing.expectEqualStrings("idle", scheduler.tasks[idle_id].name);
    try std.testing.expectEqual(State.ready, scheduler.tasks[idle_id].state);
    try std.testing.expectEqual(@intFromPtr(&idle_entry), scheduler.tasks[idle_id].elr);
    try std.testing.expect(!enabled());
    try std.testing.expect(!scheduling_active());
    start();
    try std.testing.expect(enabled());
    // Two runnable scheduler.tasks (shell + idle) are enough for the tick to switch.
    try std.testing.expect(scheduling_active());
    // Claim 0826: shell + idle leave three free slots (the capacity gate).
    try std.testing.expect(has_free_slot());
}

test "scheduler: register_worker builds a valid synthetic frame" {
    _ = init();
    const entry: u64 = 0x1234_5678_9abc_def0;
    try std.testing.expectEqual(@as(usize, 1), register_worker(entry).?);
    try std.testing.expectEqual(@as(usize, 3), scheduler.task_count); // shell + idle + worker
    const t = &scheduler.tasks[1];
    try std.testing.expectEqual(entry, t.elr);
    try std.testing.expectEqual(spsr_el1h_irqs, t.spsr);
    try std.testing.expectEqual(State.ready, t.state);
    // Frame: 160 bytes below the stack top; the x30 slot holds the park
    // address; every other slot is zeroed (the stub pops them as x0..x17).
    const stack_top = @intFromPtr(&scheduler.worker_stack) + scheduler.worker_stack.len;
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
    try std.testing.expectEqual(@as(usize, 11), scheduler.task_count);
    try std.testing.expect(register_worker(0) == null);
    // Claim 0826: capacity is observable — the full pool has no free slot.
    try std.testing.expect(!has_free_slot());
}

test "scheduler: user scheduler.tasks are any-core and the shell/idle stay on core 0" {
    // Claim 9498: the console TX is locked (2369) and the userspace gate
    // serializes syscalls, so USER scheduler.tasks default to ANY core. The shell
    // (console owner / command runner) and the shared idle slot (core 0's
    // reaper — one frame, one owner) stay core-0.
    _ = init();
    const worker = register_worker(0x1111).?; // secondary_ok = true
    try std.testing.expectEqual(@as(usize, 1), worker);
    try std.testing.expect(scheduler.tasks[worker].secondary_ok);
    try std.testing.expect(!scheduler.tasks[0].secondary_ok); // shell stays on core 0
    try std.testing.expect(!scheduler.tasks[idle_id].secondary_ok); // idle is core-0's reaper
    const user = register_user(0x2222, 0).?;
    try std.testing.expectEqual(@as(usize, 2), user);
    try std.testing.expect(scheduler.tasks[user].secondary_ok); // any-core default
    try std.testing.expectEqual(@as(usize, 0), scheduler.tasks[user].pin_core);
    // Core 1 walking from the shell finds the worker first (slot order).
    try std.testing.expectEqual(@as(?usize, worker), next_runnable_for(0, 1));
    // Core 1 from the worker finds the user task (now eligible) ahead of
    // the wrap.
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(worker, 1));
    // Core 0 picks the user task normally too.
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(worker, 0));
}

test "scheduler: pin_task restricts a user task to exactly one core" {
    // SMP user scheduler.tasks (claim 2369 + 9498): `exec -c<core>` pins a spawned
    // task; `pin_task(.., 0)` pins back to CORE 0 only (the any-core
    // default is a RESTRICTION removed by pinning, never re-added).
    _ = init();
    const worker = register_worker(0x1111).?;
    const user = register_user(0x2222, 0).?;
    try std.testing.expect(scheduler.tasks[user].secondary_ok); // any-core default
    try std.testing.expect(pin_task(user, 1));
    try std.testing.expectEqual(@as(usize, 1), scheduler.tasks[user].pin_core);
    try std.testing.expect(scheduler.tasks[user].secondary_ok); // pinned off core 0
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
    try std.testing.expectEqual(@as(usize, 0), scheduler.tasks[user].pin_core);
    try std.testing.expect(!scheduler.tasks[user].secondary_ok);
    try std.testing.expectEqual(@as(?usize, worker), next_runnable_for(worker, 1));
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(worker, 0));
    // Unknown ids are refused.
    try std.testing.expect(!pin_task(max_tasks + 4, 1));
}

test "scheduler: core 0 steals an unpinned ready task parked on ring 1 (#857)" {
    // The issue-857 gap: a task preempted on core 1 sits on ring 1 while
    // core 0 needs work. Core 0's rotation must pull it in slot order,
    // and the claim must drop it off ring 1 (single owner — no other
    // core can select it afterwards).
    _ = init();
    const worker = register_worker(0x1111).?; // slot 1
    const user = register_user(0x2222, 0).?; // slot 2, any-core
    // Simulate a preemption on core 1: the user parks on ring 1.
    try std.testing.expect(scheduler.ready_rings[0].remove(user));
    scheduler.ready_rings[1].push(user);
    check_ready_membership();
    // Core 0 walking from the worker steals the ring-1 user (slot 2)
    // ahead of the idle fallback (slot 10).
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(worker, 0));
    // The claim removes it from ring 1.
    try std.testing.expectEqual(@as(?usize, user), ring_claim(0, worker));
    try std.testing.expect(!scheduler.ready_rings[1].contains(user));
    try std.testing.expect(!scheduler.ready_rings[0].contains(user));
}

test "scheduler: core-0 yield steals ring-1 work synchronously (#857)" {
    // End to end through the real rotation: the steal happens AT the
    // block/yield point — no tick, no park — which is the issue-857
    // success criterion on two cores.
    _ = init();
    _ = register_worker(0x2000).?; // slot 1
    _ = register_user(0x3000, 0).?; // slot 2
    start();
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expectEqual(@as(usize, 1), scheduler.current[0]);
    // The user is preempted on core 1: parked on ring 1 while core 1 is
    // busy elsewhere.
    try std.testing.expect(scheduler.ready_rings[0].remove(2));
    scheduler.ready_rings[1].push(2);
    // Core 0 yields: the worker rejoins ring 0 and the rotation steals
    // the ring-1 user immediately.
    try std.testing.expect(yield_current()); // worker -> user (stolen)
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    try std.testing.expect(!scheduler.ready_rings[1].contains(2));
    check_ready_membership();
}

test "scheduler: secondaries steal from each other's rings; pins stay home (#857)" {
    // The four-core shape (max_cores = 4): a secondary's rotation sees
    // every ring, not just ring 0 + its own. Pinned scheduler.tasks are still
    // never stolen — the pin ring keeps them.
    _ = init();
    const worker = register_worker(0x1111).?; // slot 1, any-core
    const user = register_user(0x2222, 0).?; // slot 2, any-core
    const pinned = register_user(0x3333, 0).?; // slot 3, pinned to core 2
    try std.testing.expect(pin_task(pinned, 2));
    // Park the any-core scheduler.tasks on ring 2 (as if preempted there).
    try std.testing.expect(scheduler.ready_rings[0].remove(worker));
    try std.testing.expect(scheduler.ready_rings[0].remove(user));
    scheduler.ready_rings[2].push(worker);
    scheduler.ready_rings[2].push(user);
    check_ready_membership();
    // Core 1 steals across in slot order: worker, then user. The
    // core-2-pinned task is skipped, and with everything eligible gone
    // the scan finds nothing (idle is never stealable).
    try std.testing.expectEqual(@as(?usize, worker), next_runnable_for(0, 1));
    try std.testing.expectEqual(@as(?usize, worker), ring_claim(1, 0));
    try std.testing.expectEqual(@as(?usize, user), next_runnable_for(worker, 1));
    try std.testing.expectEqual(@as(?usize, user), ring_claim(1, worker));
    try std.testing.expect(next_runnable_for(user, 1) == null);
    // Core 0 steals from ring 2 the same way, then falls back to idle.
    _ = init();
    const w2 = register_worker(0x1111).?;
    const u_two = register_user(0x2222, 0).?;
    try std.testing.expect(scheduler.ready_rings[0].remove(u_two));
    scheduler.ready_rings[2].push(u_two);
    try std.testing.expectEqual(@as(?usize, w2), next_runnable_for(0, 0));
    try std.testing.expectEqual(@as(?usize, u_two), next_runnable_for(w2, 0));
}

test "scheduler: register_user separates EL1 exception and EL0 stacks" {
    _ = init();
    _ = register_worker(0x2000).?;
    const entry: u64 = 0x3000;
    try std.testing.expectEqual(@as(usize, 2), register_user(entry, 0).?);
    const task = &scheduler.tasks[2];
    try std.testing.expectEqualStrings("user-el0", task.name);
    try std.testing.expectEqual(entry, task.elr);
    try std.testing.expectEqual(spsr_el0t_irqs, task.spsr);
    try std.testing.expectEqual(@intFromPtr(&scheduler.user_kernel_stack) + scheduler.user_kernel_stack.len - frame_bytes, task.sp);
    try std.testing.expectEqual(@intFromPtr(&scheduler.user_stack) + scheduler.user_stack.len, task.sp_el0);
    try std.testing.expect(task.sp + frame_bytes != task.sp_el0);
    const frame: *exceptions.VectorFrame = @ptrFromInt(task.sp);
    try std.testing.expectEqual(@intFromPtr(&scheduler.user_timer_preemptions), exceptions.frame_read(frame, 9));
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
    const frame: *exceptions.VectorFrame = @ptrFromInt(scheduler.tasks[id].sp);
    try std.testing.expectEqual(@as(u64, 2), exceptions.frame_read(frame, 0));
    try std.testing.expectEqual(@as(u64, 0x4000_0064), exceptions.frame_read(frame, 1));
    const id2 = register_exec_user(userspace.text_va, 0x4000_0000, 100, 0x8000_0000, 8192, &kstack, 0, 0).?;
    const frame2: *exceptions.VectorFrame = @ptrFromInt(scheduler.tasks[id2].sp);
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
    try std.testing.expectEqual(@as(usize, 1), scheduler.current[0]);
    try std.testing.expectEqual(@as(u64, 1), scheduler.switches);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[0].saves);
    try std.testing.expectEqual(@as(u64, 0), scheduler.tasks[0].resumes);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[1].resumes);
    try std.testing.expectEqual(@as(u64, 0), scheduler.tasks[1].saves);
    try std.testing.expectEqual(scheduler.tasks[1].sp, scheduler.pending_sp[0]);
    try std.testing.expectEqual(worker_entry, scheduler.pending_elr[0]);
    try std.testing.expectEqual(spsr_el1h_irqs, scheduler.pending_spsr[0]);
    // Second switch: the worker is preempted; the user task is restored to
    // its synthetic EL0t frame.
    switch_context(0x2000, 0x2000, 0x5, 0xbbbb);
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    try std.testing.expectEqual(@as(u64, 2), scheduler.switches);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[1].saves);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[1].resumes);
    try std.testing.expectEqual(scheduler.tasks[2].sp, scheduler.pending_sp[0]);
    try std.testing.expectEqual(@as(u64, 0x3000), scheduler.pending_elr[0]);
    try std.testing.expectEqual(spsr_el0t_irqs, scheduler.pending_spsr[0]);
    // Third switch: the user is preempted; the idle task is restored.
    switch_context(0x3000, 0x3000, 0x0, 0xcccc);
    try std.testing.expectEqual(@as(usize, idle_id), scheduler.current[0]);
    try std.testing.expectEqual(@as(u64, 3), scheduler.switches);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[2].saves);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[idle_id].resumes);
    try std.testing.expectEqual(scheduler.tasks[idle_id].sp, scheduler.pending_sp[0]);
    // Fourth switch: the idle task is preempted; the shell is restored to
    // its exact saved context (the round-trip).
    switch_context(0x4000, 0x4000, 0x5, 0xdddd);
    try std.testing.expectEqual(@as(usize, 0), scheduler.current[0]);
    try std.testing.expectEqual(@as(u64, 4), scheduler.switches);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[idle_id].saves);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[0].resumes);
    try std.testing.expectEqual(@as(u64, 0x1000), scheduler.pending_sp[0]);
    try std.testing.expectEqual(@as(u64, 0x1000), scheduler.pending_elr[0]);
    try std.testing.expectEqual(@as(u64, 0x5), scheduler.pending_spsr[0]);
    try std.testing.expectEqual(@as(u64, 0xaaaa), scheduler.pending_sp_el0[0]);
    // Fifth switch returns to the worker's saved context (the round-trip).
    switch_context(0x1000, 0x1001, 0x5, 0xaaaa);
    try std.testing.expectEqual(@as(usize, 1), scheduler.current[0]);
    try std.testing.expectEqual(@as(u64, 5), scheduler.switches);
    try std.testing.expectEqual(@as(u64, 2), scheduler.tasks[0].saves);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[0].resumes);
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[1].saves);
    try std.testing.expectEqual(@as(u64, 2), scheduler.tasks[1].resumes);
}

test "scheduler: mixed EL1h and EL0t round-robin restores SP_EL0" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    const initial_user_sp = scheduler.tasks[2].sp_el0;

    switch_context(0x1000, 0x1000, spsr_el1h_irqs, 0xaaaa); // shell -> worker
    try std.testing.expectEqual(@as(usize, 1), scheduler.current[0]);
    switch_context(0x2000, 0x2000, spsr_el1h_irqs, 0xbbbb); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    try std.testing.expectEqual(spsr_el0t_irqs, scheduler.pending_spsr[0]);
    try std.testing.expectEqual(initial_user_sp, scheduler.pending_sp_el0[0]);

    const preempted_user_sp: u64 = initial_user_sp - 16;
    // Claim 6729: the preempted EL0 task's successor is the idle task
    // (sp_el0 = 0 for an EL1h task), then the shell on the next switch.
    switch_context(0x3000, 0x3004, spsr_el0t_irqs, preempted_user_sp); // user -> idle
    try std.testing.expectEqual(@as(usize, idle_id), scheduler.current[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler.pending_sp_el0[0]);
    try std.testing.expectEqual(preempted_user_sp, scheduler.tasks[2].sp_el0);
    switch_context(0x4000, 0x4000, spsr_el1h_irqs, 0xcccc); // idle -> shell
    try std.testing.expectEqual(@as(usize, 0), scheduler.current[0]);
    try std.testing.expectEqual(@as(u64, 0xaaaa), scheduler.pending_sp_el0[0]);

    switch_context(0x1000, 0x1004, spsr_el1h_irqs, 0xaaaa);
    switch_context(0x2000, 0x2004, spsr_el1h_irqs, 0xbbbb);
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    try std.testing.expectEqual(preempted_user_sp, scheduler.pending_sp_el0[0]);
    try std.testing.expectEqual(@as(u64, 0x3004), scheduler.pending_elr[0]);
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
    timer_switch_context(0x3000, 0x3004, spsr_el0t_irqs, scheduler.tasks[2].sp_el0);
    try std.testing.expectEqual(@as(u64, 1), user_timer_preemption_count());
}

test "scheduler: the worker's advance counter belongs to its own task" {
    _ = init();
    _ = register_worker(0x2000).?;
    scheduler.current[0] = 1; // pretend the worker is running
    note_advance();
    note_advance();
    note_advance();
    try std.testing.expectEqual(@as(u64, 3), scheduler.tasks[1].advances);
    try std.testing.expectEqual(@as(u64, 0), scheduler.tasks[0].advances);
}

test "scheduler: worker report snapshots once and prints from the shell side" {
    _ = init();
    _ = register_worker(0x2000).?;
    scheduler.current[0] = 1; // pretend the worker is running
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
    // The next scheduler.switches skip the zombie user: idle -> shell -> worker -> idle.
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
    // scheduler.current is shell (0). Sleep 2 ticks: shell -> blocked, worker next.
    try std.testing.expect(sleep_current(2));
    try std.testing.expect(is_blocked(0));
    try std.testing.expectEqual(@as(u64, 2), scheduler.tasks[0].wakeup_tick);
    try std.testing.expectEqual(@as(usize, 1), scheduler.current[0]);
    // The blocked task drops out of the ring: worker -> user -> idle -> worker.
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, idle_id), scheduler.current[0]);
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 1), scheduler.current[0]);
    // Tick 1: deadline (scheduler.tick_count 0 + 2) not reached yet.
    on_tick();
    try std.testing.expect(is_blocked(0));
    try std.testing.expectEqual(@as(u64, 1), scheduler.tick_count);
    // Tick 2: the timer-driven wakeup flips the sleeper back to ready.
    on_tick();
    try std.testing.expect(!is_blocked(0));
    try std.testing.expectEqual(State.ready, scheduler.tasks[0].state);
    try std.testing.expectEqual(@as(u64, 0), scheduler.tasks[0].wakeup_tick);
    // The ring reaches the woken shell again.
    try std.testing.expect(yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    try std.testing.expect(yield_current()); // user -> idle
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expectEqual(@as(usize, 0), scheduler.current[0]);
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
    try std.testing.expectEqual(@as(u64, 1), scheduler.tasks[0].wakeup_tick);
    // The idle task cannot sleep (it is the ring's fallback).
    scheduler.current[0] = idle_id;
    try std.testing.expect(!sleep_current(1));
    try std.testing.expect(!is_blocked(idle_id));
    // A zombie cannot sleep either.
    scheduler.tasks[1].state = .zombie;
    scheduler.current[0] = 1;
    try std.testing.expect(!sleep_current(1));
}

test "scheduler: two live user scheduler.tasks coexist with their own roots and regions" {
    // Claim 0826: the exec gate is gone — a second user program loads and
    // runs while the first is alive. Give each a DISTINCT user root and
    // user stack (per-process address spaces), and pin the per-task
    // syscall regions that follow the TCB at SVC entry.
    _ = init();
    _ = register_worker(0x2000).?;
    // Build A's root FIRST (the boot payload registers against the scheduler.current
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
    // Card 3g (claim 5795): the 7-slot pool holds FOUR user scheduler.tasks. Fill
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
    // scheduler.tasks. Fill the remaining four slots so the capacity gate is
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
    try std.testing.expectEqual(@as(usize, 11), scheduler.task_count); // shell + worker + A..H + idle
    try std.testing.expect(!has_free_slot());
    // Each task carries ITS OWN root and apertures.
    try std.testing.expect(task_ttbr0(user_a) != task_ttbr0(user_b));
    try std.testing.expectEqual(root_a, task_ttbr0(user_a));
    try std.testing.expectEqual(root_b, task_ttbr0(user_b));
    // The scheduler.current-task regions follow the ring: put A scheduler.current and read its
    // regions, then B.
    scheduler.current[0] = user_a;
    const ra = current_user_regions();
    try std.testing.expectEqual(userspace.text_va, ra.text.base);
    try std.testing.expectEqual(userspace.stack_va, ra.stack.base);
    scheduler.current[0] = user_b;
    const rb = current_user_regions();
    try std.testing.expectEqual(userspace.text_va, rb.text.base);
    try std.testing.expectEqual(@as(u64, 0x1a400000), rb.stack.base);
    try std.testing.expectEqual(@as(u64, 8192), rb.stack.len);
    // Restore the ring position before the round-robin exercise (the region
    // checks above moved `scheduler.current` for readability).
    scheduler.current[0] = 0;
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
    // user scheduler.exits -> zombie at slot 2; the ring's next ready task is the
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
    try std.testing.expectEqual(@as(usize, 2), spawn("revived", 0x5000, spsr_el1h_irqs, &scheduler.worker_stack, 0, 0).?);
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
    // first-wins flags — two scheduler.exits in one idle-loop window print two
    // `scheduler.tasks <name> exited status=` lines (and two process reports) in
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
    // One drain prints BOTH scheduler.exits in order, then nothing more.
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
    // the shell drains print two `scheduler.tasks <name> reaped` lines.
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
    // The next scheduler.switches walk the ring; when the ring SELECTS the user, the
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
    // The worker sleeps 4 ticks (scheduler.current = worker, slot 1).
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

test "scheduler: ready rings — sorted membership, contains, remove, remove_at" {
    var r: ReadyRing = .{};
    try std.testing.expect(r.empty());
    try std.testing.expectEqual(@as(usize, 0), r.len());

    // push keeps ascending-slot order (the pre-ring round-robin scanned
    // slot order from `after + 1`, and the 508 tests pin that order).
    r.push(3);
    r.push(1);
    r.push(2);
    try std.testing.expectEqual(@as(usize, 3), r.len());
    try std.testing.expect(r.contains(1));
    try std.testing.expect(!r.contains(9));
    try std.testing.expectEqual(@as(usize, 1), r.get(0));
    try std.testing.expectEqual(@as(usize, 2), r.get(1));
    try std.testing.expectEqual(@as(usize, 3), r.get(2));

    // remove compacts while keeping order (middle, head, tail).
    try std.testing.expect(r.remove(2));
    try std.testing.expect(!r.remove(99));
    try std.testing.expectEqual(@as(usize, 1), r.get(0));
    try std.testing.expectEqual(@as(usize, 3), r.get(1));
    r.push(4);
    try std.testing.expect(r.remove(1));
    try std.testing.expect(r.remove(4));
    try std.testing.expectEqual(@as(usize, 1), r.len());

    // remove_at returns the removed member and compacts (the claim).
    try std.testing.expectEqual(@as(usize, 3), r.remove_at(0));
    try std.testing.expect(r.empty());
    r.push(7);
    r.push(5);
    r.push(6);
    try std.testing.expectEqual(@as(usize, 5), r.remove_at(0));
    try std.testing.expectEqual(@as(usize, 7), r.remove_at(1));
    try std.testing.expectEqual(@as(usize, 6), r.remove_at(0));
    try std.testing.expect(r.empty());
}

test "scheduler: ready rings — seeded membership at init/spawn/pin with the invariant" {
    // Slice-1 seeding seams (no rotation yet — the checker's call
    // precondition; rotation paths wire into the rings in slice 2).
    _ = init();
    // init: the idle reaper is ring 0's only member; the shell is
    // scheduler.current[0] and executing (off-ring).
    try std.testing.expectEqual(@as(usize, 1), scheduler.ready_rings[0].len());
    try std.testing.expect(scheduler.ready_rings[0].contains(idle_id));
    check_ready_membership();

    // spawn: new ready scheduler.tasks join ring 0 in spawn order.
    const worker = register_worker(0x1111).?;
    try std.testing.expectEqual(@as(usize, 2), scheduler.ready_rings[0].len());
    try std.testing.expect(scheduler.ready_rings[0].contains(worker));
    const user = register_user(0x2222, 0).?;
    try std.testing.expect(scheduler.ready_rings[0].contains(user));
    // Slot-sorted run order: worker, user, idle (the old scan's order).
    try std.testing.expectEqual(@as(usize, 1), scheduler.ready_rings[0].get(0));
    try std.testing.expectEqual(@as(usize, 2), scheduler.ready_rings[0].get(1));
    try std.testing.expectEqual(@as(usize, idle_id), scheduler.ready_rings[0].get(2));
    check_ready_membership();

    // pin re-homes a still-ready task: ring 0 -> ring 1, and back.
    try std.testing.expect(pin_task(user, 1));
    try std.testing.expect(!scheduler.ready_rings[0].contains(user));
    try std.testing.expect(scheduler.ready_rings[1].contains(user));
    check_ready_membership();
    try std.testing.expect(pin_task(user, 0));
    try std.testing.expect(scheduler.ready_rings[0].contains(user));
    try std.testing.expect(!scheduler.ready_rings[1].contains(user));
    check_ready_membership();
}

test "scheduler: ready rings — reap drops the slot's ring membership" {
    _ = init();
    const t = spawn("ring-test", 0x6000, spsr_el1h_irqs, &scheduler.worker_stack, 0, 0).?;
    try std.testing.expect(scheduler.ready_rings[0].contains(t));
    // Exit it (state -> zombie) and reap. Slice 2: the exit path itself
    // drops the membership (the task was scheduler.current/off-ring — the remove is
    // defensive), so the checker is valid again right after the exit.
    scheduler.current[0] = t;
    try std.testing.expect(exit_current(7));
    try std.testing.expect(!scheduler.ready_rings[0].contains(t));
    check_ready_membership();
    try std.testing.expect(reap(t));
    try std.testing.expect(!scheduler.ready_rings[0].contains(t));
    // The freed slot is spawnable again and re-joins ring 0 exactly once.
    const again = spawn("ring-test-2", 0x6001, spsr_el1h_irqs, &scheduler.worker_stack, 0, 0).?;
    try std.testing.expectEqual(@as(usize, t), again);
    var on: usize = 0;
    for (&scheduler.ready_rings) |*r| {
        if (r.contains(again)) on += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), on);
}

test "scheduler: ready rings — rotation, block, wake, exit keep the invariant" {
    // Claim 881 slice 2: every rotation path claims from / pushes onto the
    // per-core rings, so the ready-membership invariant holds after every
    // transition — asserted with the checker at each phase.
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    check_ready_membership();

    // shell -> worker: the shell joins ring 0 on its first real
    // preemption; the worker is claimed off it.
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 1), scheduler.current[0]);
    try std.testing.expect(scheduler.ready_rings[0].contains(0));
    try std.testing.expect(!scheduler.ready_rings[0].contains(1));
    check_ready_membership();

    // worker -> user.
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    check_ready_membership();

    // The user sleeps: blocked, off-ring; the successor is the idle
    // reaper (ring 0's always-ready seat).
    try std.testing.expect(sleep_current(1));
    try std.testing.expectEqual(@as(usize, idle_id), scheduler.current[0]);
    try std.testing.expect(!scheduler.ready_rings[0].contains(2));
    check_ready_membership();

    // Deadline passes: the user wakes onto its home ring (ring 0).
    on_tick();
    try std.testing.expect(!is_blocked(2));
    try std.testing.expect(scheduler.ready_rings[0].contains(2));
    check_ready_membership();

    // idle -> shell -> worker -> user: the woken user runs again.
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 0), scheduler.current[0]);
    try std.testing.expect(yield_current());
    try std.testing.expect(yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current[0]);
    check_ready_membership();

    // The user scheduler.exits: zombie off-ring (the exit path drops membership), a
    // successor claimed from the ring.
    try std.testing.expect(exit_current(43));
    try std.testing.expectEqual(@as(usize, idle_id), scheduler.current[0]);
    try std.testing.expect(!scheduler.ready_rings[0].contains(2));
    check_ready_membership();

    // The idle reaper reaps; the slot stays off every ring.
    reap_one_zombie();
    try std.testing.expect(!scheduler.ready_rings[0].contains(2));
    check_ready_membership();
}

// ---------------------------------------------------------------------------
// Claim 881 slice 3 — per-ring locks; exit teardown out of scheduler.sched_lock
// ---------------------------------------------------------------------------

test "scheduler: rotation paths release every ring lock" {
    // Claim 881 slice 3: the rotation (yield/switch, block, exit) holds
    // the per-ring locks only for the claim/push/flip critical section —
    // an accidentally-held ring lock would stall every other core's
    // rotation forever (and a held-then-released pair is the easiest way
    // for this single-threaded suite to catch the choreography).
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000, 0).?;
    start();
    const rings_clear = struct {
        fn all_clear() bool {
            for (&scheduler.ring_locks) |*l| {
                if (l.lock_impl.is_locked()) return false;
            }
            return true;
        }
    }.all_clear;
    try std.testing.expect(rings_clear());
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(rings_clear());
    try std.testing.expect(yield_current()); // worker -> user
    try std.testing.expect(rings_clear());
    try std.testing.expect(sleep_current(3)); // user -> idle (its successor)
    try std.testing.expect(rings_clear());
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expect(rings_clear());
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(rings_clear());
    try std.testing.expect(exit_current(43)); // worker -> idle (zombie)
    try std.testing.expect(rings_clear());
    // The kill conversion path releases the ring locks BEFORE the exit
    // teardown (the frozen lock-order rule) — drive it via a killed
    // selection and re-check.
    const worker2 = register_worker(0x2000).?; // a fresh worker (slot 3)
    try std.testing.expectEqual(KillResult.ok, request_kill(worker2));
    try std.testing.expect(yield_current()); // idle -> shell
    try std.testing.expect(yield_current()); // shell -> worker2 -> killed -> idle
    try std.testing.expect(rings_clear());
    check_ready_membership();
}

test "scheduler: rotation_lock holds every ring ascending; unlock releases all" {
    // Issue #857: the generalized steal scans every ring, so the
    // rotation's set is ALL rings acquired in ascending index order (the
    // frozen no-cycle rule). Verify the helper's lock/unlock
    // choreography directly.
    _ = init();
    const lk0 = rotation_lock(0);
    for (&scheduler.ring_locks) |*l| try std.testing.expect(l.lock_impl.is_locked());
    rotation_unlock(lk0);
    for (&scheduler.ring_locks) |*l| try std.testing.expect(!l.lock_impl.is_locked());
    const lk1 = rotation_lock(1);
    for (&scheduler.ring_locks) |*l| try std.testing.expect(l.lock_impl.is_locked());
    rotation_unlock(lk1);
    for (&scheduler.ring_locks) |*l| try std.testing.expect(!l.lock_impl.is_locked());
}

test "scheduler: teardown_pending gates the reaper off a mid-teardown zombie" {
    // Claim 881 slice 3: the exit teardown runs OUTSIDE scheduler.sched_lock; the
    // zombie mark + teardown_pending flag (under scheduler.sched_lock) keep the
    // idle reaper off the slot until the teardown completes. Simulate
    // the mid-teardown window and verify reap refuses, then clears.
    _ = init();
    _ = register_worker(0x2000).?; // slot 1 — the user then lands at slot 2
    _ = register_user(0x3000, 0).?;
    start();
    try std.testing.expect(yield_current()); // shell -> worker
    try std.testing.expect(yield_current()); // worker -> user
    try std.testing.expect(exit_current(43)); // user -> shell (zombie)
    try std.testing.expect(is_terminated(2));
    // Mid-teardown: the slot is a zombie but the reaper must not touch it.
    scheduler.tasks[2].teardown_pending = true;
    try std.testing.expect(!reap(2));
    try std.testing.expect(!reap(2)); // still gated
    try std.testing.expect(task_info(2) != null);
    // Teardown completes: the reaper may free the slot.
    scheduler.tasks[2].teardown_pending = false;
    try std.testing.expect(reap(2));
    try std.testing.expect(task_info(2) == null);
    // A reaped slot's flag is cleared by the reset; a fresh exit -> reap
    // cycle never sees a stale gate.
    try std.testing.expectEqual(@as(usize, 2), register_user(0x3000, 0).?);
    try std.testing.expect(!scheduler.tasks[2].teardown_pending);
}
