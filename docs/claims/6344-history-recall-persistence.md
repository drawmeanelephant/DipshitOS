## Claim 6344 — `verify-live-history`: boot-2 history recall no-op (ESP window content-pool exhaustion)

- **Owner:** buffy (`agent/buffy/history-recall-persistence`)
- **Prompt / plan:** make boot-1's HISTORY.TXT durable across the VM boundary, validated by a live boot-1→boot-2 persistence checkpoint, so `verify-live-history` passes on main.
- **Scope:** M18 T4 persistent-history gate. Root-cause the recall no-op and fix the data layer that silently returned empty content.
- **Touches:** kernel/src/esp.zig (fix), tools/verify-live-history.sh (boot-1/boot-2 disk checkpoints as permanent diagnostics)
- **Depends on:** —
- **Heartbeat:** 2026-08-31
- **Status:** ✅ done — landed via PR #724 (2026-08-31).

## Notes

Initial hypothesis (VM-boundary flush) was **disproven** by live checkpoints.

### Live checkpoint findings (temporary gate instrumentation)

- After boot 1, `artifacts/disk.img` DOES contain `echo T4-third` — the write physically lands.
- After boot 2, the disk contains only boot-2's own lines — boot-2 read HISTORY.TXT as empty and clobbered boot-1's bytes.
- Boot-1's file ended up as only the LAST line → the read-modify-write chain broke WITHIN boot-1 (each save read back empty).

### Root cause (confirmed against the real disk with `image/mkfat32.py --list`)

The ESP window (`kernel/src/esp.zig`) content-loads only files ≤ `esp_content_max` (2048 B) while the shared pool fits. The M33 SB2 proof binaries pushed eligible root content to **26,564 bytes across 40 files** — far beyond `content_pool_max = 8192`. Pool exhausted at root slot 23 (FSTEST.BIN), so every later small file — `HISTORY.TXT` (slot 78, 27 B), plus BOOTED.TXT, MEMMAP.TXT, APPS.TXT — was listed but never content-loaded (`len=0`). `load_history` and `save_to_history` both read through `esp.content_of`, which silently returned empty → recall no-op + clobbering writes.

### Fix (kernel/src/esp.zig)

1. `content_pool_max` raised 8192 → 32768 (fits all eligible content with headroom; bss-budget gate still passes).
2. `content_of` now does load-on-demand: an entry with `len==0`, `size>0 ≤ cap`, disk mounted → read from the FAT volume on first access and cache in the pool. A listed-but-not-loaded small file can never silently read as empty again.

### Validation

- Live: `verify-live-history` **PASS 1/1** — checkpoints show boot-1 persisted all T4 lines AND boot-2 recalled `echo T4-third-marker` on the synthesized Up chord.
- Host: build, fmt, unit suite (esp 26/26, fat 21/21, shell 792/792), bss-budget PASS, coordination gate ok.
