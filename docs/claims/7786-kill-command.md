# Claim: kill — the kernel owns process lifetime

- **Owner:** Buffy (`agent/buffy/m4-kill`)
- **Prompt / plan:** milestone-four follow-on 3 card 3c (after claim 4613 /
  PR #75). Written plan first:
  [`docs/m4-kill-prompt.md`](../m4-kill-prompt.md).
- **Scope:** (1) a monitor command `kill <pid|name>` (registry 30→31) that
  looks up a process and refuses cleanly on unknown/already-exited
  (host-tested exact errors); (2) an armed-kill path in the scheduler that
  marks the target's TCB so its NEXT scheduled quantum (or yield/sleep
  wake) calls the existing `exit_current` with the reserved status 137 —
  WITHOUT touching the scheduler switching core; (3) the killed process
  flows through the real lifecycle — `procs` shows
  `state=exited task=reaped exit=137`, `release_pages_on_reap` returns its
  5 allocator pages (host test pins the exact +5 recovery), the slot
  frees, and a subsequent exec lands in it; (4) host tests for kill-by-name
  and by-id, unknown/already-exited refusals, the killed-status report,
  page recovery, and re-exec after kill; (5) a live gate
  `tools/verify-live-kill.sh` on VZ; (6) docs/march-m4 reconciliation
  (row 3c) + claim + PR. Syscall ABI (ADR 0007) frozen; no libc/POSIX/heap;
  host tests first; class B on VZ.
- **Depends on:** claim 4613 (never-exiting COUNTER.BIN + reap page-return
  + the runner's `--script2` second phase — PR #75, the branch this card
  branches off), claim 0826 (per-process roots/pages), claim 3848
  (`procs`).
- **Status:** 🔄 agent/buffy/m4-kill

## Notes

**Why it matters:** card 3b proved a process can REFUSE to exit
(COUNTER.BIN loops forever) — but nothing can END it: today no command can
terminate a running process, so a permanent occupant is permanent even if
the operator changes their mind. This card proves the OS, not the program,
owns process lifetime: the never-exiting program is force-terminated,
reaped through the EXISTING exit→zombie→idle-reap path, its allocator
pages return (free-count recovery), and its slot is re-exec'd.

**Key design facts (from the survey):**

- **Kill is a monitor command, not a syscall.** The `kill <pid|name>`
  command (registry 30→31) looks up a process — by its `procs` id or its
  name (the FAT file name) — and arms the target's TCB through a new
  `scheduler.request_kill(task_id)` seam. No new syscall, ADR 0007 frozen.
- **The kill takes effect at the target's next selection, not inline.**
  `request_kill` sets a `kill_pending` flag on the TCB. When the
  round-robin ring next selects that task, `stage_current` checks the
  flag and converts the selection into the existing `exit_current(137)`
  instead of resuming it — the task becomes a zombie, the process exit
  report (`tasks user-exec exited status=137` / `procs <name> exited
  status=137`) fires, the idle task reaps it, and
  `release_pages_on_reap` returns its pages. The scheduler switching core
  (frame save/restore, ELR/SPSR/TTBR0 programming) is untouched — the
  kill reuses the exact exit path a `sys_exit` uses. Because only one
  task runs at a time, the killed task never executes again after the arm:
  NO `counter: alive` marker can land after the `kill:` reply line — the
  deterministic anchor the live gate asserts.
- **The reserved status is 137** (128 + 9, a plain number — no POSIX
  semantics), documented in the claim + the `kill` command reply.
- **Refusals are clean and exact.** Unknown pid/name →
  `kill: no such process: <arg>`; an already-exited process →
  `kill: <name> already exited`; the shell and scheduler-owned idle task
  are refused (killing the console is never useful). Host tests pin the
  exact strings.
- **Page recovery is the claim-4613 path, now exercised by a kill.**
  Exec allocates 5 pages per program (1 text + 2 user stack + 2 EL1
  exception stack); the kill → exit → reap returns all 5 at the reap. The
  host test pins the exact +5 free-count recovery; the live gate prints
  `pages` in two phases and asserts the late count is the early count + 5.
- **The live gate uses the claim-4613 second phase.** The primary script
  is one burst (claim 6684), so the kill that must land AFTER the
  counter's markers appear cannot be in it: phase 1 execs the counter and
  phase 2 (`kill COUNTER.BIN | echo`) is forwarded after the FIRST
  `counter: alive` marker. The kill's exit + reap lines land in the log
  naturally (the shell idle loop prints them), and a NEW third scripted
  phase (`--script3`/`--script3-after`, same machinery as `--script2`)
  forwards the post-reap snapshot — `procs | pages | exec USER.BIN |
  procs | echo` — after `tasks user-exec reaped` (the counter's reap), so
  the gate can assert the exited/reaped row, the exact page recovery, and
  the re-exec into the freed slot.

## Verification

- **Class A:** fmt, unit tests (scheduler kill-arming + exact exit-status
  flow, monitor kill command replies incl. refusals, process exit status
  137, exec re-exec-after-kill + exact page recovery), transcript
  byte-identical, build/image/inspect, swift build, context, coordination
  ×2, mmu-debt — all green.
- **Class B — the live gate:** `tools/verify-live-kill.sh` on VZ — phase 1
  `ls | exec COUNTER.BIN | echo rx-kill-phase1` (after the boot payload
  exits); phase 2 (`kill COUNTER.BIN | echo rx-kill-killed`, forwarded
  after the first `counter: alive` marker); phase 3 (`procs | pages |
  exec USER.BIN | procs | echo rx-kill-ok`, forwarded after the counter's
  `tasks user-exec reaped`). Asserted in `vm-serial.log`: the counter
  loaded + markers landing before the kill; NO `counter: alive` marker
  after the `kill:` line; `tasks user-exec exited status=137` +
  `procs COUNTER.BIN exited status=137` + `tasks user-exec reaped`;
  `procs: … name=COUNTER.BIN state=exited task=reaped exit=137`; the
  phase-3 `pages` free is phase-1 free + 5 (the counter's pages
  returned); the re-exec'd USER.BIN lands in the freed slot (its procs
  row shows the SAME task id the counter had); shell responsive; no
  `[EXC] parking:`.
- **Class B — shared-seam regressions:** the full live sweep
  (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/uaccess/
  userspace/entropy/long-lived) all PASS 1/1 against the kill change.
