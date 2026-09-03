# Log — `agent/buffy/vm-teardown-tail`

- **2026-09-03** — *buffy (agent/buffy/vm-teardown-tail)*: Claimed 4912
  (issue from the IMG5/IMG5-PNG live-gate flakes): `--script-expect`
  teardown races the kernel's async reap line. Root cause pinned: the
  kernel drains `tasks/procs ... exited status=N` reports from the shell
  idle loop, which only wakes on the 1 Hz EL1 timer tick (`timer.zig`
  `period_ns = 1_000_000_000`) — up to ~1 s AFTER the app's own final
  marker — while `scriptPoll()` stops the VM on the first poll that sees
  the marker (0.5 s cadence), cutting the tail. Host-only fix in
  `host/vm-runner/Sources/VMRunner/main.swift`: after the expected
  transcript first matches, hold the VM through a configurable
  `--script-expect-tail` window (default 1.5 s, 0 = legacy immediate
  stop), then finish. No kernel or gate changes.

- **2026-09-03** — *buffy*: Implemented. `scriptPoll(matchedAt:)` now keeps
  polling with the VM running after the first match until
  `--script-expect-tail` (default 1.5 s, flag parsed, `0` = legacy
  immediate stop) elapses; an early VM stop or a deadline mid-window still
  passes once the transcript was observed. Class-A: release SPIKE build
  clean. Class-B on real VZ: `verify-live-crash-viewer` PASS;
  `verify-live-image-viewer` PASS 2/2 twice (4/4 boots) — serial logs now
  end in the full post-marker tail `tasks user-exec exited status=43` /
  `procs VIEW.BIN exited status=43` / `tasks user-exec reaped` (the last
  line prints on the idle tick AFTER the expect marker and was the line
  the teardown race cut). Artifacts: `artifacts/live-{crash,image}-viewer-*`.
