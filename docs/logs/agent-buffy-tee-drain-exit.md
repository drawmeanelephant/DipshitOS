# Log — `agent/buffy/tee-drain-exit`

- **2026-09-03** — *buffy (agent/buffy/tee-drain-exit)*: Claimed 2188 —
  the follow-on to claim 4912 (merged PR #851): `finish()` and the
  console-mode exits still race the guest-output tee thread at process
  exit, because `exit()` does not join other threads and the console
  signal/timeout paths never stop the VM (so the pipe never EOFs — their
  fixed 0.4–0.5 s sleeps were the only buffer). Branch off origin/main
  (includes 4912). Plan: `teeGroup` `DispatchGroup` entered by
  `startGuestOutputTee()` and left at pipe EOF; `drainTeeBeforeExit`
  bounded wait called from `finish()`'s `vm.stop` completion and from the
  console exits (which now stop the VM first via a shared
  `beginConsoleExit`/`stopAndDrainForExit` with a single-teardown guard).
  No kernel or gate changes.
