# Milestone-four follow-on 3, card 3c — kill: the kernel owns process lifetime

Planning-first prompt doc for DipshitOS, the first card of the follow-on 3
set (after claim 4613 / PR #75).

- **Branch:** `agent/buffy/m4-kill` (claim 7786, deterministic ID from
  branch + slug via `bash tools/status/claim-id.sh`)
- **Date:** 2026-08-10
- **Depends on:** claim 4613 (never-exiting COUNTER.BIN, reap page-return,
  the runner's `--script2`/`--script2-after` second phase), claim 0826
  (per-process roots + allocator-backed pages), claim 3848 (process
  registry, `procs`). The syscall ABI (ADR 0007) is frozen and untouched.

## The card

Claim 4613 proved a process can REFUSE to exit (COUNTER.BIN loops forever)
— but nothing can END it: today no command can terminate a running
process, so a permanent occupant is permanent even if the operator changes
their mind. This card proves the OS, not the program, owns process
lifetime:

1. **A monitor command `kill <pid|name>`** (registry 30→31): looks up the
   process (by `procs` id or by name), refuses cleanly on
   unknown/already-exited (host-tested exact errors), and arms the target
   for termination WITHOUT touching the scheduler switching core — the
   target's next scheduled quantum (or its yield/sleep wake) calls the
   existing `exit_current` with the reserved status 137 (a plain number,
   no POSIX semantics).
2. **The killed process flows through the real lifecycle**: `procs` shows
   `state=exited task=reaped exit=137`, `release_pages_on_reap` returns
   its 5 pages (host test pins the exact +5 recovery), the slot frees,
   and a subsequent exec lands in it.
3. **Host tests**: kill-by-name and by-id, unknown/already-exited
   refusals, killed-status report, page recovery, re-exec after kill.
4. **Live gate** `tools/verify-live-kill.sh`: exec COUNTER.BIN, let it run
   (markers landing), `kill COUNTER.BIN` → assert NO `counter: alive`
   markers after the kill line, `procs` shows the exited/reaped row with
   the reserved status, `pages` free recovers, a re-exec lands in the
   freed slot, shell responsive, no `[EXC] parking:`.
5. **Docs + claim + PR** (march-m4 row 3c, roadmap, status,
   gate-inventory, README, log, claim flip).

Do not touch ADR 0007 or the switching core; do not grow the pool; kill is
a monitor command (no syscall). No libc/POSIX/heap; host tests first;
class B on VZ.

## Survey (what the code actually looks like today)

- **The lifecycle already has the full exit path.** `sys_exit` →
  `scheduler.exit_current(status)` → zombie → idle-task reap →
  `process.release_pages_on_reap` (pages return) → exited descriptor
  stays in `procs` (`task=reaped`, status kept). A kill only needs to
  *trigger* that path for an arbitrary task, with a distinct status.
- **The scheduler has no kill path today.** Tasks only exit
  cooperatively through `sys_exit`. `exit_current` operates on the
  current task from SVC context; the kill must make the ring call it for
  a DIFFERENT task at selection time. `stage_current` (the selection
  point used by every switch — tick, yield, sleep, exit) is the single
  choke point where a selected task can be converted into an exit instead
  of a resume. `exit_current` accepts `state == .ready` (what a selected
  task is at `stage_current` time), so the kill branch can literally call
  it with the reserved status.
- **The pool budget is unchanged.** `max_tasks = 5`: shell (0) + worker
  (1) + user (2) + spare (3) + idle (4). The kill gate execs ONLY the
  counter in phase 1 (the re-exec in phase 3 happens after the kill
  reaps, so the pool never exceeds 5/5). No pool growth.
- **Per-exec page count is 5** (1 text + 2 user stack + 2 EL1 exception
  stack). The kill → exit → reap returns all 5 — the exact +5 recovery
  the host test pins and the two-phase `pages` read asserts.
- **The runner forwards the primary script in ONE burst** (claim 6684),
  so the kill that must land after the counter's markers appear needs the
  claim-4613 second phase; and the post-reap snapshot (procs/pages/re-exec)
  needs a THIRD phase. `forwardScriptOnce` is generic — `--script3` +
  `--script3-after` reuse it.
- **Only one task runs at a time.** The `kill` command executes in the
  shell task; the counter is NOT running at that instant, and after its
  TCB is armed it is killed at its next selection BEFORE it executes
  again — so no `counter: alive` marker can land after the `kill:` reply
  line. This is deterministic, not probabilistic (the counter writes its
  marker at the START of each iteration; a task that never resumes cannot
  write another).

## Design

### `kernel/src/scheduler.zig` — armed-kill seam

- `Task` gains `kill_pending: bool = false` (reset by the `.{ }` reap).
- New `pub const KillResult = enum { ok, not_found, already_exited,
  refused }` and `pub fn request_kill(id: usize) KillResult`:
  - `id >= max_tasks` or slot `free` → `.not_found`;
  - slot `zombie` → `.already_exited`;
  - `id == idle_id` or the shell task (id 0) → `.refused`;
  - otherwise set `kill_pending = true` → `.ok`.
- `stage_current()` gains the kill branch BEFORE marking the task
  `running`: if `tasks[current].kill_pending` is set, clear it and call
  the existing `exit_current(reserved_kill_status)` (current == the
  selected task, state == ready, so `exit_current` accepts it; the flag
  `reserved_kill_status: u64 = 137` is a named const). `exit_current`
  already stages the next task + `apply_pending`, so the killed task
  never resumes. A task selected while sleeping is covered by the same
  check (its wake → ready → selection → kill).
- The existing scheduler test that pins the exit flow gains kill cases:
  arm → the next `switch_context` selection terminates with status 137,
  the task is a zombie, the exit report carries 137, and the ring
  continues.

### `kernel/src/monitor.zig` — the `kill` command (registry 30→31)

- `registry_count` 30 → 31; the registry gains
  `.{ .name = "kill", .help = "terminate a running process (kernel-owned lifetime)", .usage = "kill <pid|name>", .min_args = 1, .max_args = 1, .handler = cmd_kill }`
  (alphabetical, between `hex` and `ls`).
- `cmd_kill`: if `parseInt(args[0])` succeeds → look up `process.info(pid)`:
  null → `kill: no such process: <arg>`; `.exited` → `kill: <name>
  already exited`; `.running` + `task_id` → `scheduler.request_kill` →
  `.ok` → `kill: <name> armed`; `.created` → `kill: <name> not running`.
  Else match by process NAME (scan `process.info` for a name equal to the
  arg): none → `kill: no such process: <arg>`; exited → `kill: <name>
  already exited`; running → arm; created → `kill: <name> not running`.
  The scheduler's `.refused` → `kill: cannot kill the shell or
  scheduler-owned idle task`. Every string is host-tested exactly.
- The shell transcript fixture (`tests/transcript-console.txt` + the
  shell.zig e2e expected string) gains the `kill` help line.

### `tools/verify-live-kill.sh` — the live gate (new)

Phase 1 (after the boot payload exits): `ls | exec COUNTER.BIN | echo
rx-kill-phase1`
Phase 2 (after the FIRST `counter: alive` marker):
`kill COUNTER.BIN | echo rx-kill-killed`
Phase 3 (after `tasks user-exec reaped` — the counter's reap):
`procs | pages | exec USER.BIN | procs | echo rx-kill-ok`

Asserted in `vm-serial.log`:

1. The counter loaded (`exec: loaded COUNTER.BIN size=`) and its markers
   are landing before the kill (`counter: alive` count >= 1, all before
   the kill line).
2. NO `counter: alive` marker after the `kill: COUNTER.BIN armed` line.
3. The kill's exit/reap cycle: `tasks user-exec exited status=137`,
   `procs COUNTER.BIN exited status=137`, `tasks user-exec reaped`, and a
   procs row `name=COUNTER.BIN state=exited task=reaped exit=137`.
4. Page recovery: the phase-3 `pages` `free=` equals phase-1 `free=` + 5
   (the counter's 5 pages returned at the reap; nothing else allocates
   between the reads).
5. The re-exec lands in the freed slot: `exec: loaded USER.BIN size=`
   appears in phase 3 and its procs row shows the SAME task id the
   counter's row showed (slot reuse).
6. Shell responsive (`rx-kill-ok`), no `[EXC] parking:`.

The runner runs WITHOUT `--script-expect` (the full window is the gate);
evidence saved under `artifacts/live-kill-*`.

### `host/vm-runner` — third scripted phase

`--script3 <file>` + `--script3-after <text>`, forwarded once after the
marker appears, via the same `forwardScriptOnce` machinery as
`--script2` (claim 4613). Class-A-buildable; the guest kernel is
untouched.

## Definition of done

Stage A: the scheduler kill seam + `kill` command + host tests (exact
errors, 137 status flow, +5 page recovery, re-exec after kill) + the
runner `--script3`; class A green (fmt, unit tests, transcript
byte-identical, build/image/inspect, swift build, context, coordination
×2, mmu-debt).

Stage B: `tools/verify-live-kill.sh` registered in gate-inventory +
`just verify-vz`; PASS on VZ with the saved serial evidence; shared-seam
regressions green (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/
svc/uaccess/userspace/entropy/long-lived).

Stage C: docs reconciliation (march-m4 row 3c, roadmap, status, README,
gate-inventory), log append, claim flip, PR (template filled in, real
observed evidence only).

## Do not

- Touch the syscall ABI (ADR 0007) or the scheduler switching core
  (frame/ELR/SPSR/TTBR0 handling is untouched; the kill only converts a
  selection into the existing exit path).
- Grow the pool or the carve-out — document the 5/5 budget.
- Add libc/POSIX/heap allocation anywhere.
- Hand-edit generated indexes (`refresh-indexes.sh` only).
- Claim hardware behavior without a saved VZ log (`artifacts/`).

## Process

1. Claim first (done): claim 7786 in `docs/claims/7786-kill-command.md`,
   log in `docs/logs/agent-buffy-m4-kill.md`, `refresh-indexes.sh`.
2. Write this plan (done), then implement: Stage A — scheduler seam +
   command + host tests (class A green); Stage B — the live gate +
   regressions (class B on VZ); Stage C — docs reconciliation, claim
   flip, PR.
3. Class A: `zig fmt --check`, unit tests, transcript, build/image/inspect,
   swift build, context, coordination ×2, mmu-debt.
4. Class B: `tools/verify-live-kill.sh` + shared-seam regressions.
   Evidence under `artifacts/live-kill-*`.
5. Reconcile docs, append the log, flip the claim to ✅, refresh indexes,
   open the PR.
