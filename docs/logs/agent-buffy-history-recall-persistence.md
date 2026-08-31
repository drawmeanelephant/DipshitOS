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
  virtio-blk completion; `esp.disk_ready()` is true pre-shell. ~~The loss is
  at the VM boundary~~ **(SUPERSEDED by the checkpoint finding below — not a
  VM-boundary flush problem).**

## 2026-08-31 (later) — checkpoint instrumentation flipped the diagnosis

Added temporary python checkpoints to `tools/verify-live-history.sh` dumping
`artifacts/disk.img` after boot 1 and after boot 2:

- After boot 1 the disk DOES contain `echo T4-third` (but not T4-first/
  T4-second) — the write physically lands.
- After boot 2 the disk contains only boot-2's own lines — boot-2 read
  HISTORY.TXT as empty and clobbered boot-1's bytes.
- Boot-1's file ended up as only the LAST line → the read-modify-write chain
  broke WITHIN boot-1: every save read back empty.

Root cause found by simulating `kernel/src/esp.zig`'s window accounting over
the real disk (`image/mkfat32.py --list`): 40 files are eligible for
content-loading (≤ `esp_content_max` 2048 B) totaling **26,564 B**, but
`content_pool_max = 8192` — the pool exhausted at root slot 23 (FSTEST.BIN),
so `HISTORY.TXT` (slot 78) and every other late small file was listed but
never content-loaded (`len=0`). `load_history`/`save_to_history` read via
`esp.content_of` → silent empty → recall no-op + clobbering saves.

Fix (this branch, `kernel/src/esp.zig`):
1. `content_pool_max` 8192 → 32768 (fits 26.5 KB eligible content +
   headroom; bss-budget gate still PASS).
2. `content_of` load-on-demand: entries listed-but-not-loaded (len==0,
   size>0 ≤ cap, disk mounted) are read from the FAT volume on first access
   and cached in the pool — a small file can never silently read as empty.

Validated live: `verify-live-history` **PASS 1/1** — checkpoints show boot-1
persisted all T4 lines AND boot-2 recalled `echo T4-third-marker` on the
synthesized Up chord.
- No code landed blind. The durable fix — verify boot-1→boot-2 persistence
  survives (e.g. a settled/graceful teardown or an explicit durable-history
  surface), gated on a live checkpoint that HISTORY.TXT is present before
  boot-2 mounts — remains as the next step.