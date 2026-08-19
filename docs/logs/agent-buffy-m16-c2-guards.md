# Log — `agent/buffy/m16-c2-guards`

## 2026-08-19 — claim 8403 opened

Claimed M16 card C2 (guard pages + per-segment permissions, issue #191) on
branch `agent/buffy/m16-c2-guards` (stacked on C1). Surveyed the EL0 fault
path: `exc_dispatch` reports-and-parks on any sync fault outside the uaccess
window, so a guard-page step hangs the machine; `scheduler.exit_current`
already reaps the current task and stages its successor, and `request_kill` /
`stage_current` show the exit-with-status pattern. Plan: a registered fault
dispatcher that turns an EL0 sync fault into `exit_current(139)`, explicit
guard documentation, a hostile `GUARD.BIN` + a benign neighbor, and
`verify-live-m16-guards.sh`.

## 2026-08-19 — claim 8403 done

Implemented and verified live. An EL0 synchronous fault is now process
termination, not a machine hang:

- `exceptions.zig`: a `FaultDispatcher` seam (`set_fault_dispatcher`) +
  `is_from_el0(spsr)`; `exc_dispatch` routes a sync fault from EL0 (not an
  SVC, not a recoverable uaccess fault) to the dispatcher and returns the
  staged next-task frame. EL1h faults still report-and-park.
- `scheduler.zig`: `reserved_fault_status = 139`, `fault_current(esr, far)`
  (snapshots the PROCESS name + FAR + EC into a bounded FIFO, then
  `exit_current(139)`), and the `fault: <name> far=0x… ec=0x…` drain in
  `maybe_report` (before the exit report). The fault name prefers the process
  name (`process.find_by_task` → `info().name`) over the generic task name.
- `main.zig`: registers `exceptions.set_fault_dispatcher(scheduler.fault_current)`.
- `mmu.zig`: documents the implicit guard pages (the user root maps ONLY
  text/data/stack, so the page below the stack and above the data region are
  unmapped).
- `GUARD.BIN` (29th ESP program): prints `guard: stepping off`, steps 20 KiB
  below its 16 KiB stack top (4 KiB below the bottom — the guard page), and
  faults. Wired through build.zig + make-image.sh + mkfat32.py.

Verification (all green): fmt clean, 477 transcript tests byte-identical, 22
unit + exceptions(36)/scheduler(220)/exec suites, build/image/inspect, swift
build, coordination ok, and `tools/verify-live-m16-guards.sh` PASS 1/1 on VZ —
`guard: stepping off` → `fault: GUARD.BIN far=0x… ec=0x24` → `tasks user-exec
exited status=139` / `procs GUARD.BIN exited status=139`, with COUNTER.BIN
still `state=running` beside it (never corrupted).

One real catch from the first live run: the exec'd stack is 16 KiB
(`scheduler.task_stack_size`), not the 8 KiB the first draft assumed, so the
initial `sub sp, sp, #0x3000` step landed INSIDE the stack and the store
succeeded (exit 1). The step is now `#0x5000` (20 KiB) — exactly 4 KiB below
the stack bottom.
