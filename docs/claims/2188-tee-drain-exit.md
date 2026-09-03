# Claim: Tee drain-before-exit (finish + console exits race the tee thread)

- **Owner:** buffy (`agent/buffy/tee-drain-exit`)
- **Prompt / plan:** Freebuff session — harden the remaining VM-teardown
  race: `finish()` (script/evidence polls) and the console-mode exit paths
  exit the process while the guest-output tee thread may still hold the
  LAST pipe bytes, so the serial log tail can be cut mid-write.
- **Scope:** host `vm-runner` only. Track the tee thread's completion with a
  `DispatchGroup` and wait on it (bounded) after the VM stops, at every
  exit path — instead of the fixed 0.4–0.5 s sleeps that only "hoped" the
  tee finished. Console timeout/signal exits now stop the VM first (which
  closes the serial pipe and makes the tee hit EOF). No kernel or gate
  changes.
- **Touches:** host/vm-runner/Sources/VMRunner/main.swift
- **Depends on:** claim 4912 (the script-expect tail window) — this branch
  is off origin/main, which includes it.
- **Heartbeat:** 2026-09-03 — update while Status is 🔄 so staleness checks see life
- **Status:** ✅

## Notes

### Why the tail can still be cut after claim 4912

The claim-4912 tail window guarantees the GATE's evidence is in the serial
log before teardown, but the process exit itself still races the tee:

- `finish()` (script-poll success/failure, evidence poll) calls
  `runner.vm.stop` and `exit()` from the completion handler with no wait
  for the tee thread — `exit()` does not join other threads, so a chunk
  the tee had read but not yet written (or VZ had delivered to the pipe)
  could be lost.
- Console mode already slept 0.4–0.5 s before exiting, but that is a fixed
  guess: the signal and timeout paths exit WITHOUT stopping the VM, so the
  pipe write end never closes and the tee never sees EOF — the sleep is
  the only thing between the tee and `exit()`.

### Fix (final design)

**Observed during verification:** pipe EOF never arrives at stop time — VZ
keeps its copy of the pipe's write end open until the process exits, so a
wait-for-EOF drain can only time out (every first-draft run warned). The
tee therefore stops on a REQUEST, not on EOF:

- `startGuestOutputTee()` runs a `poll()` loop (200 ms cadence) with
  `O_NONBLOCK` reads; entering the tee `enter()`s a `DispatchGroup`.
- `drainTeeBeforeExit(_:timeout:)` — called only AFTER `vm.stop` has
  completed (so every guest byte VZ will deliver is already in the pipe):
  it sets the stop-request flag (NSLock-guarded), then waits on the group
  (3 s bound). The tee notices the flag within one poll cycle, drains the
  pipe to empty, `synchronize()`s the log, and leaves the group.
- `finish()` drains inside the `vm.stop` completion, before the NVRAM reads
  and `exit()`.
- Console exits are unified behind `beginConsoleExit` / `stopAndDrainForExit`
  (single-teardown flag so a second signal or a signal-vs-timeout race
  cannot double-stop or double-exit): every path stops the VM if needed,
  then drains the tee, then restores the terminal and exits. The fixed
  0.4/0.5 s sleeps are gone. The signal branch is explicit (`restore:`
  parameter — a `hasPrefix("signal")` check never matched
  "caught signal N" and was caught in verification).

Evidence mode (no duplex pipe — VZ writes the serial log directly) has no
tee, so the drain is a structural no-op there; `finish()` still calls it
uniformly.

### Verification

- Class A: `swift build --package-path host/vm-runner --configuration
  release -Xswiftc -DSPIKE` clean.
- Class B (real VZ, 2026-09-03):
  - Console timeout path (`--console --timeout 45`, stdin `/dev/null`):
    RC=0, exit message + device-stop, **zero** drain warnings.
  - Console SIGTERM path (group-delivered like the CI teardown):
    `console: caught signal 15 — terminal restored, draining guest
    output, exiting` → device stop → drain clean (zero warnings) → exit.
    (SIGINT to a bash-backgrounded child is born-ignored — a harness
    artifact of Dispatch signal sources, unchanged from the pre-existing
    handler.)
  - `verify-live-crash-viewer` PASS rc=0 and `verify-live-image-viewer`
    PASS 2/2 — and the claim-2188 drain warnings that every run printed
    with the first-draft EOF design are gone (0 in all gate run logs;
    the tee now drains on request instead of waiting for an EOF that
    never comes).
