# Claim: M18 T4 — persistent command history (HISTORY.TXT)

- **Owner:** buffy (`agent/buffy/m18-t4-history`)
- **Prompt / plan:** `docs/march-m18.md`
- **Scope:** M18 card T4 — persistent command history saved to HISTORY.TXT on every submit, loaded into editor ring on boot
- **Depends on:** M18 T1 (scrollback), T2 (selection), T3 (search)
- **Status:** ✅ done 2026-08-22

## Notes

Implements issue #407 T4: persistent shell command history.

### Features

- **Save on submit:** every non-empty submitted line calls `save_to_history(line)` which appends to HISTORY.TXT on the FAT volume. Keeps at most 50 lines (oldest truncated).
- **Load on boot:** `boot_and_park()` calls `load_history()` which reads HISTORY.TXT and populates the editor's history ring (newest-first).
- **Safe no-ops:** both functions return immediately when no FAT volume is mounted (`esp.disk_ready()` checks).

### No tab-completion changes

The existing tab completion via ADR 0008 D2 (monitor.complete) already works for built-in commands. No changes to completion logic in this card.

### Files changed

- **Modified:** `kernel/src/shell.zig` — `save_to_history()`, `load_history()`, constants, call in submit handler, call in `boot_and_park()`

### Verification

- `zig test kernel/src/shell.zig` — 525/525 tests pass
- `bash tools/verify-unit-tests.sh` — all modules pass
- `zig build test-console` — transcript byte-identical
- `zig build kernel` — builds
- Class-B gate at `tools/verify-live-history.sh` (boot → save commands → reboot → recall)