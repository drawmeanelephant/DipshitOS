# Log — `agent/buffy/history-recall-persistence`

Claim: [6344](../claims/6344-history-recall-persistence.md)

## 2026-08-31 — root-caused; fix deferred pending a durable-persistence check

Investigated `verify-live-history` being red on main
(`rc1=0 rc2=0 banner=1 marker=0 report=1 ok=1`).

- Reproduced deterministically on a clean un-renamed `origin/main` checkout —
  **pre-existing, not the rename**. (The rename updated the gate's serial
  triggers to `virelai> `; this run used the `dipshit>` prompt and failed
  identically.)
- **Signature:** the Up-arrow keyboard chord decodes once
  (`events=1 kb-usage=0x52`, runs-through the tee read path, FIFO drained to
  0), but the recalled `echo T4-third-marker` never echoes and `recall_older`
  never beeps (only the timer-heartbeat BEL is present) → boot-2 history ring
  is empty.
- **Direct disk evidence:** `HISTORY.TXT` on the shared `artifacts/disk.img`
  after the gate run contains ONLY boot-2's own typed lines (`input`,
  `echo history-live-ok`) — none of boot-1's `echo T4-*` commands. So
  boot-1's per-submit `save_to_history` writes did not persist across the
  reboot for boot-2's `load_history`.
- `esp.write_file` → `fat.write_file` runs synchronously and awaits the
  virtio-blk completion; `esp.disk_ready()` is true pre-shell. The loss is at
  the VM boundary: the runner kills boot-1 ≤0.5 s after the `T4-third-marker`
  script-expect, intersecting the macOS-27 canonical-disk FAT-write/fresh-copy
  fragility the gate's own comments document. Boot-2's writes survive the
  same teardown, so it is a timing/flush-specific durability gap for
  boot-1's shortest-lived writes, not a wholesale write failure.
- No code landed blind. The durable fix — verify boot-1→boot-2 persistence
  survives (e.g. a settled/graceful teardown or an explicit durable-history
  surface), gated on a live checkpoint that HISTORY.TXT is present before
  boot-2 mounts — remains as the next step.