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

### Live-gate evidence (2026-08-22; updated by the arrow-chord follow-up)

`bash tools/verify-live-history.sh` — **class-B PASS 1/1** (two VZ boots)
on real hardware: boot 1 types distinctive commands (persisted to
HISTORY.TXT), boot 2 recalls via Up arrow and re-executes T4-third-marker.
Evidence: `artifacts/live-history-gate.txt`, `live-history-report.txt`,
`live-history-serial-01-boot1.log` / `-boot2.log` (banner=1 marker=1
report=1 ok=1 runner-flag=1).

Boot 2's Up arrow is now a single SYNTHESIZED-KEYBOARD chord
(`--input-chords "up"`, claim 5093); the Enter that submits stays serial
(original walk's `\r`), and the shell's own `input` report proves the
chord decoded exactly once (`events=1 kb-usage=0x52 kb-byte=A`). The
recall output only appears if the chord really landed (history is not
printed at load). Bring-up lesson: an initial two-chord walk
(`up,return`) passed ONLY because a lost Return chord was masked by the
serial burst appending to the still-open recalled line — the gate now
fails honestly (events=1 assertion) instead of passing on that accident.

Bring-up findings fixed along the way:
- **`load_history()` ordering bug:** it restored HISTORY.TXT **oldest-first**
  (the backward iteration left the file's FIRST line at history[0]),
  contradicting the newest-first intent — so the first Up arrow after
  reboot recalled the oldest command. Fixed to insert in file order
  (newest at index 0, matching the session ring); a host test
  (`load_history restores newest-first`) now guards it.
- **Gate mechanics:** the runner only honors `--script2`/`--script-expect`
  in script mode (a `--script` must be present; boot 2 uses an empty
  script file), the runner exits as soon as `--script-expect` matches (so
  boot 1's expected line must be the LAST line), and the Up-arrow bytes
  are fed over serial (`--script2`) since VZ's synthesized keyboard
  cannot deliver ESC bytes.

### Files changed

- **Modified:** `kernel/src/shell.zig` — `save_to_history()`, `load_history()`, constants, call in submit handler, call in `boot_and_park()`; `load_history` newest-first fix + host test (2026-08-22)
- **Modified:** `kernel/src/esp.zig` — `set_disk_ready_for_test` hook for the load_history host test
- **Modified:** `tools/verify-live-history.sh` — gate walk fixed per the bring-up findings above

### Verification

- `zig test kernel/src/shell.zig` — 525/525 tests pass (+1 history test in claim-0469 session: 545/545)
- `bash tools/verify-unit-tests.sh` — all modules pass
- `zig build test-console` — transcript byte-identical
- `zig build kernel` — builds
- Class-B gate at `tools/verify-live-history.sh` (boot → save commands → reboot → recall) — **PASS 1/1** on VZ 2026-08-22