# Claim: verify-live-history — boot-2 Up-chord recall no-ops because boot-1's HISTORY.TXT never persists

- **Owner:** buffy (`agent/buffy/history-recall-persistence`)
- **Prompt / plan:** root-cause why verify-live-history's Up-arrow/chord recall
  marker never echoes and fix the shell history keybinding path so it passes on main.
- **Scope:** M18 T4 persistent-history gate. Investigation of the boot-2 recall
  no-op; no kernel milestone creep.
- **Touches:** kernel/src/esp.zig (fix), tools/verify-live-history.sh (temporary checkpoint diagnostics)
- **Depends on:** —
- **Heartbeat:** 2026-08-31
- **Status:** 🔄 agent/buffy/history-recall-persistence

## Notes

`verify-live-history` fails red on main with the exact signature
`rc1=0 rc2=0 banner=1 marker=0 report=1 ok=1 runner-flag=1` — the Up-arrow
keyboard chord decodes cleanly once (`input: ... events=1 kb-usage=0x52`
= HID Up), but the recalled `echo T4-third-marker` never appears, and the
only subsequent serial `\r` submits an empty line (`error: no command given`).

Reproduced deterministically on a clean, un-renamed `origin/main` checkout
(as well as the rename branch) — pre-existing, rename-exonerated. The rename
sweep even updated the gate's serial triggers to the new `virelai> ` prompt,
so this is not a prompt-name mismatch.

Mechanism: `esc_state` at the line editor maps `ESC [ A` to `recall_older`,
which no-ops (empty line, nothing echoed) when `hist_count == 0`. No recall
echo AND no `recall_older` beep (only the timer-heartbeat BEL exists in the
boot-2 serial) means the boot-2 history ring is empty. Direct evidence from the
shared `artifacts/disk.img` after the run: `HISTORY.TXT` on the ESP contains
only boot-2's own typed lines (`input`, `echo history-live-ok`) — none of
boot-1's `echo T4-*` commands, so boot-1's per-submit `save_to_history`
writes did not survive for boot-2's `load_history` to reload.

`esp.write_file` → `fat.write_file` runs synchronously and awaits the
virtio-blk completion (guest-side durable), and `esp.disk_ready()` is true
from `set_disk` before the shell — so boot-1's writes are lost at the VM
boundary (host-side: the runner kills boot-1 ≤0.5 s after the `T4-third-marker`
script-expect; the macOS-27 canonical-disk FAT-write/fresh-copy fragility the
gate's own comments document). Boot-2's writes survive the SAME teardown, so
the loss is timing/flush-specific to the shortest-lived writes at boot-1's
exit, not a wholesale write failure.

## Resolution (2026-08-31) — ROOT CAUSE: ESP window content-pool exhaustion

The live boot-1→boot-2 checkpoint instrumentation (temporary additions to
`tools/verify-live-history.sh`) changed the picture: boot-1's writes DO land
on `artifacts/disk.img` (the disk contains `echo T4-third` after boot 1), but
boot-2 reads HISTORY.TXT as empty and its saves clobber boot-1's bytes. The
read-modify-write chain also broke *within* boot-1 (each save read back empty,
so the file ended up as only the last line).

Root cause confirmed against the real disk with `image/mkfat32.py --list`:
the ESP window (`kernel/src/esp.zig`) content-loads only files ≤
`esp_content_max` (2048 B) while the shared pool fits, and the M33 SB2 proof
binaries pushed eligible root content to **26,564 bytes across 40 files** —
far beyond `content_pool_max = 8192`. The pool exhausted at root slot 23
(FSTEST.BIN), so every later small file — including `HISTORY.TXT` (slot 78,
27 B), plus BOOTED.TXT, MEMMAP.TXT, APPS.TXT — was listed but never
content-loaded (`len=0`). `load_history` and `save_to_history` both read
through `esp.content_of`, which silently returned empty → recall no-op +
clobbering writes. Not a VM-boundary flush problem at all.

Fix landed in `kernel/src/esp.zig`:
1. `content_pool_max` raised 8192 → 32768 (fits all 26.5 KB of eligible
   content with headroom; .bss budget gate still passes with 660 KB spare).
2. `content_of` now does load-on-demand: an entry with `len==0`, `size>0 ≤
   cap`, disk mounted → read from the FAT volume and cache in the pool, so a
   listed-but-not-loaded file can never silently read as empty again.

Unit tests: esp.zig 26/26, fat.zig 21/21, shell.zig 792/792 pass;
`verify-bss-budget.sh` PASS. Live validation with the checkpoint gate is the
remaining step.