# Log — milestone-four follow-on 3, card 3c: kill (the kernel owns process lifetime)

- **Branch:** `agent/buffy/m4-kill`
- **Claim:** [`docs/claims/7786-kill-command.md`](../claims/7786-kill-command.md)
- **Prompt / plan:** [`docs/m4-kill-prompt.md`](../m4-kill-prompt.md)
- **Started:** 2026-08-10

## Progress

- **Claimed** (2026-08-10): claimed the milestone-four follow-on 3 card 3c
  (kill — the kernel owns process lifetime) on `agent/buffy/m4-kill` with
  claim 7786 (deterministic ID from branch+slug), branched off
  `origin/main` (PR #75 merged, `c984398`). Written plan first
  (`docs/m4-kill-prompt.md`).

- **Implemented — Stage A (the kill seam + command)** (2026-08-10):
  `scheduler.zig` gains `request_kill(id)` (`KillResult` — ok/not_found/
  already_exited/refused; the shell + scheduler-owned idle task are
  refused) which sets a `kill_pending` flag on the TCB, and
  `stage_current` — the selection point every switch goes through (tick,
  yield, sleep wake, exit) — converts an armed selection into the
  EXISTING `exit_current(reserved_kill_status=137)` instead of resuming
  it: the killed task never executes again, the process exit report
  carries 137, and the idle-task reap returns its pages. The switching
  core (frame/ELR/SPSR/TTBR0) is untouched; ADR 0007 frozen (no
  syscall). `monitor.zig` gains `kill <pid|name>` (registry 30→31,
  alphabetical between hex/ls) — resolve by `procs` id or name, exact
  refusal strings (`no such process` / `already exited` / `not running`),
  reply `kill: <name> armed`; host tests cover by-id/by-name arming, all
  refusals, the 137 flow, and the re-exec-after-kill + exact +5 page
  recovery in exec.zig. The runner gains `--script3`/`--script3-after`
  (the same forwardScriptOnce machinery as `--script2`).

- **Verification — Stage A** (2026-08-10): class A all green — fmt;
  `verify-unit-tests.sh` (every module; scheduler 85/85, monitor 188/188,
  exec 128/128, shell 212/212); `zig build test-console` (transcript
  byte-identical — the help listing gained the kill line, the CRLF-mixed
  fixture updated byte-exactly); `zig build`/`image`/`inspect`;
  `swift build`; `zig build context`; `verify-coordination.sh`;
  `test-coordination.sh` (15/15); `verify-mmu-debt.sh` PASS.

- **Implemented — Stage B (the live kill gate)** (2026-08-10): new class-B
  gate `tools/verify-live-kill.sh` — THREE scripted phases: phase 1 (after
  the boot payload exits) `ls | exec COUNTER.BIN | procs | pages | echo
  rx-kill-phase1`; phase 2 (after the first `counter: alive` marker)
  `kill COUNTER.BIN | echo rx-kill-killed`; phase 3 (after the counter's
  reap `tasks user-exec reaped`) `procs | pages | exec USER.BIN | procs |
  echo rx-kill-ok`. Registered in `docs/gate-inventory.md` (`live-kill`,
  B/gate, + the verify-vz aggregate row + machine record), `justfile
  verify-vz`, README.

- **Verification — Stage B** (2026-08-10): `bash tools/verify-live-kill.sh`
  **PASS 1/1 on VZ** — evidence `artifacts/live-kill-serial-01.log`:
  `exec: loaded COUNTER.BIN size=0x3b … stack=0x6ac40000`; the phase-1
  procs row `id=1 name=COUNTER.BIN state=running task=2` (the counter's
  task id); EXACTLY ONE `counter: alive` marker (line 74) before
  `kill: COUNTER.BIN armed` (line 76) and NO marker after the kill line
  (the deterministic anchor — the killed task never executes again);
  `tasks user-exec exited status=137` + `procs COUNTER.BIN exited
  status=137` + `tasks user-exec reaped`; the phase-3 procs row
  `name=COUNTER.BIN state=exited task=reaped stack=0x000000006ac40000
  exit=137`; `pages` free 0xfd59 → 0xfd5e (EXACT +5 recovery at the
  reap); `exec USER.BIN` re-exec landing on the SAME task id (2) the
  counter had (`procs: id=2 name=USER.BIN state=running task=2`); shell
  responsive (all three echoes); no exception park. Full 12-gate
  shared-seam sweep all PASS 1/1: exec, procs, concurrent, tasks,
  lifecycle, addrspaces, sleep, svc, uaccess, userspace, entropy,
  long-lived (`artifacts/live-kill-sweep.txt`).

- **Implemented — Stage C (docs reconciliation + claim flip)** (2026-08-10):
  `docs/march-m4.md` gains row 3c (kill — kernel-owned lifetime, ✅ done,
  claim 7786 + prompt link) and the best-agent split row covers card 3c;
  `docs/roadmap.md` gains a "Kill — the kernel owns process lifetime is
  DONE" bullet; `docs/status.md` milestone-four row + command-count bullet
  updated (registry 30→31); README + `docs/gate-inventory.md` (`live-kill`
  gate) updated during Stage B. Claim 7786 flipped ✅ done. Indexes
  refreshed; coordination + test-coordination checks green.

- **PR** (2026-08-10): branch pushed, PR opened — body per the repo
  template (summary + AGENTS compliance checklist + observed class A/B
  evidence + commands).
