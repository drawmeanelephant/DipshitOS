# Log — `DESKTOP.BIN` (Desktop Launcher & Environment) & Capstone Gate

## Context

- **Goal:** Implement `user/src/desktop.zig`, package `DESKTOP.BIN`, author `tools/verify-live-desktop.sh`, and verify Milestone 11 on live VZ hardware.
- **Claim:** [`docs/claims/2427-a5-desktop-launcher.md`](../claims/2427-a5-desktop-launcher.md)

## Entries

### 2026-08-15: Initialized Card A5 implementation (claim 2427)

- Created `user/src/desktop.zig` desktop launcher and diagnostics panel.
- Integrated `DESKTOP.BIN` into `build.zig` and `image/make-image.sh`.
- Authored live capstone verification gate `tools/verify-live-desktop.sh`.

### 2026-08-15: Milestone 11 capstone gate PASS (claim 2427 closed)

- Fixed EL0 binary VMA: set `user/linker.ld` `. = 0x00400000` so `.rodata`
  tables (`font8x8.glyphs`, string literals) resolve to the actual
  `userspace.text_va` (was `0x0`, caused data-abort at `far=0x000012f3`).
- Scaled `driving_award.user_windows_max` from 2 → 4 so all four GUI apps
  (CALC, NOTEPAD, TOP, DESKTOP) can open concurrent windows simultaneously.
- Fixed FAT32 image sector overwrite in `image/mkfat32.py` (spurious
  `wsec(geo.cluster_sector(dir_start + i), …)` line silently corrupted data).
- Scaled `exec_program_max` in `kernel/src/exec.zig` to 16 KiB (4 pages)
  for larger compiled GUI binaries.
- Refactored all EL0 GUI apps to pure stack-local `AppState` (W^X compliance).
- `tools/verify-live-desktop.sh` — **PASS** on live VZ hardware:
  CALC.BIN OK, NOTEPAD.BIN OK, TOP.BIN OK, DESKTOP.BIN OK.
- Milestone 11 complete. All A0–A5 cards ✅ done.
