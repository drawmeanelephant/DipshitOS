# Claim: VM-teardown tail window (script-expect cuts the kernel reap line)

- **Owner:** buffy (`agent/buffy/vm-teardown-tail`)
- **Prompt / plan:** Freebuff session — root-cause and fix the VM-teardown
  tail race that occasionally drops the kernel reap line in live gates.
- **Scope:** host `vm-runner` only. After `--script-expect` first matches,
  hold the VM through a short tail window (default 1.5 s, flag
  `--script-expect-tail`) so serial output the guest prints AFTER the
  marker — the exec reap/report lines, drained from the shell idle loop on
  the kernel's 1 Hz timer tick — reaches the serial log before `finish()`
  stops the VM. No kernel or gate changes.
- **Touches:** host/vm-runner/Sources/VMRunner/main.swift
- **Depends on:** —
- **Heartbeat:** 2026-09-03 — update while Status is 🔄 so staleness checks see life
- **Status:** 🔄 agent/buffy/vm-teardown-tail

## Notes

### Root cause (observed)

1. **Guest side.** A scripted app prints its final marker and exits. The
   kernel queues the exec exit/reap reports (`tasks <name> exited status=N`
   / `procs <name> exited status=N`), but they are printed from the shell
   idle loop (`scheduler.maybe_report`, next to `timer.maybe_heartbeat`),
   which only runs when the shell is idle and a tick fires. The EL1
   physical timer period is **1 s** (`kernel/src/timer.zig` `period_ns =
   1_000_000_000`), so the reap line can land anywhere from ~0 to ~1 s
   AFTER the app's own last marker has reached the host serial log.
2. **Host side.** `scriptPoll()` polls the serial log every 0.5 s and calls
   `finish(success: true)` → `runner.vm.stop` → `exit(0)` on the FIRST read
   that contains the `--script-expect` text. A poll that lands inside that
   up-to-1 s window stops the VM before the kernel ever prints the reap
   line. Gates that expect an app marker and then grep the serial log for
   the kernel reap after it (e.g. `verify-live-crash-viewer.sh`: expect
   `rx-crashview-ok`, then grep `exited status=139`) flake "occasionally" —
   the exact observed tail race.

### Fix

In `scriptPoll()`, when the expected transcript is first observed, do not
tear down: remember the match time and keep polling (VM running, log still
being teed) until a configurable tail window (default 1.5 s — one 1 Hz
guest tick plus delivery/tee margin) has elapsed, THEN print SUCCESS and
`finish(true)`. The window is fixed-time (not quiescence-based) so gates
whose guest keeps printing after the marker are not held past it; the run
deadline still bounds everything, and a match observed before the deadline
still passes if the deadline arrives mid-window. `--script-expect-tail 0`
restores the legacy stop-on-first-match behavior for any caller that needs
it.

### Verification

- Class A: `swift build` the runner; argument/default plumbing is host
  Swift only.
- Class B: re-run the exposed live gates on VZ — `verify-live-crash-viewer`
  (expect marker precedes the reaped `status=139` line) and
  `verify-live-image-viewer` (regression; expect IS the reap line) — and
  confirm the serial tail (reap lines after the expect marker) is present
  in the copied serial logs.
