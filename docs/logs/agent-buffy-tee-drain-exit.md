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

- **2026-09-03** — *buffy*: Implemented + verified. First-draft EOF-wait
  drain was WRONG in practice: VZ keeps its copy of the pipe's write end
  open until process exit, so the tee never sees EOF — every drain timed
  out with a warning (observed in the console smoke test AND in all three
  gate run logs). Redesigned: the tee now runs a 200 ms `poll()` loop with
  `O_NONBLOCK` reads and stops on a REQUEST set only after `vm.stop`
  completes (when every guest byte is already in the pipe), draining to
  empty and leaving a `DispatchGroup`; `drainTeeBeforeExit` waits on the
  group (3 s bound). Also fixed a verification-caught bug: the signal
  branch test `hasPrefix("signal")` never matched `"caught signal N"`,
  so the signal path skipped `restoreTerminal()` — now an explicit
  `restore:` parameter. Class-B: console timeout path RC=0 no warning;
  console SIGTERM path handler→stop→clean drain→exit; crash-viewer PASS
  rc=0 and image-viewer PASS 2/2 with the drain warnings GONE from all
  gate run logs.
