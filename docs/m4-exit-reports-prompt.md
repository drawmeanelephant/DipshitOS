# Milestone-four follow-on 3, card 3d — per-process exit reports (kill the first-wins collapse)

Planning-first prompt doc for DipshitOS, the second card of the follow-on
3 set (after claim 4613 / PR #75).

- **Branch:** `agent/buffy/m4-exit-report-fifo` (claim 1014, deterministic
  ID from branch + slug via `bash tools/status/claim-id.sh`)
- **Date:** 2026-08-10
- **Depends on:** claim 4613 (the documented single-slot collapse), claim
  3848 (the process exit report), claim 0826 (two concurrent exits in one
  window). Independent of card 3c (kill). The syscall ABI (ADR 0007) is
  frozen and untouched; the scheduler switching core and the process
  lifecycle states are untouched.

## The card

The exit/reap report is a single first-wins-while-undrained flag, so N
exits in one idle-loop window collapse to ONE report line and the
concurrent/long-lived gates must assert ≥1 instead of exact counts. The
report is evidence — when two programs exit in the same idle-loop window,
the log should show BOTH exits, in order:

1. **Replace the single pending flags with small bounded FIFOs.** Three
   flags collapse today: `scheduler.exit_report_pending` (the `tasks
   <name> exited status=N` line), `process.exit_report_pending` (the
   `procs <name> exited status=N` line), and
   `scheduler.reap_report_pending` (the `tasks <name> reaped` line). Each
   becomes a 4-slot FIFO of name+status drained IN ORDER by the shell
   idle loop (`scheduler.maybe_report`) without double-printing.
2. **Overflow behavior documented + host-tested.** A full 4-slot FIFO
   drops the OLDEST entry to admit the newest (honestly reported).
3. **Host tests.** 2–3 exits in one window → exactly N report lines, in
   order; no double-print; overflow drops the oldest.
4. **Tighten the existing gates from ≥1 to EXACT counts:**
   `verify-live-concurrent` (both USER.BIN exits → exactly 2 report lines
   each) and `verify-live-long-lived` (the phase-1 USER exit + the
   phase-2 re-exec exit stay distinct; the boot payload exit stays its
   own distinct line).
5. **Docs + claim + PR** (march-m4 row 3d, roadmap, status,
   gate-inventory, README, log, claim flip).

Do not touch ADR 0007, the scheduler switching core, or the process
lifecycle states — this card is the REPORTING machinery only. No
libc/POSIX/heap; host tests first; class B on VZ.

## Survey (what the code actually looks like today)

- **The three collapsing flags.** `kernel/src/scheduler.zig` has
  `exit_report_pending` + `exit_report_name` + `exit_report_status`
  (set by `exit_current`, printed by `maybe_report` as `tasks <name>
  exited status=N`) and `reap_report_pending` + `reap_report_name` (set
  by `reap_one_zombie`, printed as `tasks <name> reaped`).
  `kernel/src/process.zig` has `exit_report_pending` + an owned name
  buffer + `exit_report_status` (set by `on_task_exit` under
  `if (!exit_report_pending)`, drained by `take_exit_report`, printed by
  `maybe_report` as `procs <name> exited status=N`).
- **The consumer is the shell idle loop.** `boot_and_park` calls
  `scheduler.maybe_report` on every idle poll; it drains the task exit
  report, the process exit report (`process.take_exit_report`), the reap
  report, and the sleep report. The pushes happen in exception/idle
  context — pure BSS writes only.
- **Task names are static string literals.** "user-exec", "user-el0",
  "spawn-demo", "shell", "worker", "idle" — so the scheduler FIFO can
  snapshot name POINTERS (they never dangle). The process names are owned
  copies in per-descriptor buffers, so the process FIFO needs per-slot
  name storage (4 × `name_max`).
- **The reap is one-per-idle-iteration.** `reap_one_zombie` reaps one
  zombie per idle task iteration; the report is set only if not already
  pending, so two reaps in one idle-loop window collapse. With a FIFO,
  both print in order.
- **The tightened gates capture the full window.** Both run without
  `--script-expect` (the runner exits 0 on timeout when no expect is
  configured; the assertions are the gate), so every exit's report lines
  land in the log and exact counts are observable.

## Design

### `kernel/src/scheduler.zig` — the task exit + reap report FIFOs

- `pub const exit_report_max: usize = 4`.
- Task exit reports: `exit_reports: [exit_report_max]ExitEntry` (name
  slice + status), `exit_report_head`, `exit_report_count`. `exit_current`
  PUSHES (never overwrites); when full, the head advances (drop-oldest)
  and the count stays at max.
- Reap reports: `reap_reports: [exit_report_max]ReapEntry` (name slice
  only), same ring discipline. `reap_one_zombie` pushes every reap.
- `maybe_report` drains each FIFO in order (`while count > 0 { pop;
  print }`) — the `tasks <name> exited status=N` lines and the `tasks
  <name> reaped` lines both become exact.
- `init()` resets the rings.

### `kernel/src/process.zig` — the process exit report FIFO

- `pub const exit_report_max: usize = 4`; per-slot name buffers
  (`[exit_report_max][name_max]u8`) + lens + statuses + head + count.
- `on_task_exit` PUSHES every exit (the `if (!exit_report_pending)`
  first-wins guard is gone); drop-oldest on overflow.
- `take_exit_report` pops in FIFO order. `init()` resets the ring.

### Host tests

- Scheduler: two exits in one window → `maybe_report` prints exactly 2
  `tasks ... exited` lines in exit order; three exits → 3; a second
  `maybe_report` prints nothing more (no double-print); a fifth exit with
  a full FIFO drops the OLDEST (the four newest print); two reaps in one
  window → 2 `tasks ... reaped` lines.
- Process: two `on_task_exit` calls → `take_exit_report` returns both in
  order; overflow drops the oldest.
- Existing exit-report tests updated to the FIFO drain (they drain with
  `take_exit_report` / `maybe_report` as before — the API shape is
  unchanged, only the collapse is gone).

### The tightened live gates

- `tools/verify-live-concurrent.sh`: `exited`/`procs_exited`/`reaped`
  become EXACTLY 2 (both USER.BIN runs exit status 43; the boot payload
  exits BEFORE the script is forwarded, so its lines cannot land in the
  window). The gate comment updates: the report flags are no longer
  single-slot.
- `tools/verify-live-long-lived.sh`: `tasks user-exec exited status=43`
  / `procs USER.BIN exited status=43` / `tasks user-exec reaped` become
  EXACTLY 2 (the phase-1 USER.BIN + the phase-2 re-exec both exit); the
  boot payload's `tasks user-el0 exited status=7` stays its own distinct
  line (asserted exactly 1 — it is the `--script-after` trigger, drained
  before the script is forwarded).

## Definition of done

Stage A: the three FIFOs + overflow policy + host tests; class A green
(fmt, unit tests, transcript byte-identical, build/image/inspect, swift
build, context, coordination ×2, mmu-debt).

Stage B: the two tightened live gates PASS on VZ with the saved serial
evidence; shared-seam regressions green (exec/procs/concurrent/tasks/
lifecycle/addrspaces/sleep/svc/uaccess/userspace/entropy/long-lived).

Stage C: docs reconciliation (march-m4 row 3d, roadmap, status, README,
gate-inventory), log append, claim flip, PR (template filled in, real
observed evidence only).

## Do not

- Touch ADR 0007, the scheduler switching core (frame/ELR/SPSR/TTBR0), or
  the process lifecycle states — the REPORTING machinery only.
- Grow anything unbounded (the FIFOs are fixed at 4 slots).
- Add libc/POSIX/heap allocation anywhere.
- Hand-edit generated indexes (`refresh-indexes.sh` only).
- Claim hardware behavior without a saved VZ log (`artifacts/`).

## Process

1. Claim first (done): claim 1014 in `docs/claims/1014-exact-exit-reports.md`,
   log in `docs/logs/agent-buffy-m4-exit-report-fifo.md`,
   `refresh-indexes.sh`.
2. Write this plan (done), then implement: Stage A — the FIFOs + host
   tests (class A green); Stage B — the tightened gates (class B on VZ);
   Stage C — docs reconciliation, claim flip, PR.
3. Class A: `zig fmt --check`, unit tests, transcript, build/image/inspect,
   swift build, context, coordination ×2, mmu-debt.
4. Class B: `verify-live-concurrent.sh` + `verify-live-long-lived.sh`
   with exact assertions + shared-seam regressions. Evidence under
   `artifacts/`.
5. Reconcile docs, append the log, flip the claim to ✅, refresh indexes,
   open the PR.
