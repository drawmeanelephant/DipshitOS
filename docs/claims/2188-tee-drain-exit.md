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
- **Status:** 🔄 agent/buffy/tee-drain-exit

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

### Fix

- `startGuestOutputTee()` enters a `DispatchGroup` (`teeGroup`) and leaves
  it when the pipe read hits EOF (after `synchronize()`), i.e. exactly
  when the tee has flushed everything it received.
- `drainTeeBeforeExit(_:timeout:)` — bounded (3 s) wait on the group; no-op
  in evidence mode (no duplex pipe: VZ writes the serial log directly).
- `finish()` drains inside the `vm.stop` completion, before the NVRAM reads
  and `exit()`.
- Console exits are unified behind `beginConsoleExit` / `stopAndDrainForExit`
  (single-teardown flag so a second signal or a signal-vs-timeout race
  cannot double-stop or double-exit): every path stops the VM if needed
  (closing the serial pipe), then drains the tee, then restores the
  terminal and exits. The fixed 0.4/0.5 s sleeps are gone.

### Verification

- Class A: `swift build --package-path host/vm-runner --configuration
  release -Xswiftc -DSPIKE` clean.
- Class B: re-run `verify-live-crash-viewer` and
  `verify-live-image-viewer` on real VZ (script-mode `finish()` path with a
  live tee) and confirm rc=0 and full serial tails.
