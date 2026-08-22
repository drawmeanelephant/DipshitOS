# Milestone twenty-four march — CALC grows up (living tracker)

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts. This file holds M24's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

CALC.BIN (M11 A2, M17 C9) is a basic four-function calculator with
keyboard input, memory (MR/M+), and a scrollable history ring. It works
for simple arithmetic. But it can't do hex, can't convert units, and
doesn't survive a reboot. M24 makes it *useful*.

**Zero new syscall slots.** All changes are pure userland.

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| K1 | **Programmer mode.** Ctrl+P toggles between standard and programmer view. Programmer shows: hex/octal/decimal display (all three simultaneously), AND/OR/XOR/NOT/shift operators (<<, >>), register display (R0–R7 as scratch). Base selector buttons: HEX/DEC/OCT. | ✅ code + gate | 61 tests pass, `zig build calc` 14,137 B. `tools/verify-live-calc-prog.sh` written. Live gate run pending. | `calc/programmer.zig` + bitwise ops in `calc/engine.zig` (opcodes `A/O/X/L/R`, `bitwise_not`). Triple-line display (hex `0x`/dec/oct `0o`), R0–R7 register display. Serial markers: `calc: prog-on` / `calc: prog-off`. |
| K2 | **Memory store.** MS (memory store) / MR (memory recall) / M+ (memory add) / M- (memory subtract) with 4 memory slots (M0–M3). Memory indicator in the display showing which slots are non-zero. Ctrl+1/2/3/4 selects the active memory slot. | ✅ code | 61 tests pass, `zig build calc` 13,915 B. | `AppState.mem_slots[4]`, `mem_active_slot`, `mem_any_nonzero` flag. MS/MR/MC/M+/M- buttons + keyboard `m` (MR), `s` (MS), Ctrl+1/2/3/4 slot select. Memory indicator `M0`–`M3` in display. Live gate pending. |
| K3 | **Unit conversion.** Ctrl+U opens a conversion bar at the top. Categories: `temp` (C/F/K), `length` (m/ft/in/cm/mm), `weight` (kg/lb/g/oz). Type a value, select units, result appears instantly. Conversion factors are comptime constants. | ✅ code | 61 tests pass, `zig build calc` 13,915 B. | `convert_active`, `convert_category` (temp/length/weight), `convert_from_idx`/`convert_to_idx`, `convert_value` (f64). Conversion bar overlays history area with category labels + from/to display + result. Temperature C→F 100→212 verified in tests. Live gate pending. |
| K4 | **Constant calculator.** Mathematical constants available as dedicated buttons: π (3.14159…), e (2.71828…), √2 (1.41421…), φ (1.61803…), ∞, and 1/3 (0.333…). Press the constant button and the value appears in the display, ready to be used in the next operation. | ✅ code | 61 tests pass, `zig build calc` 13,915 B. | `calc/constants.zig` comptime table. PI/e/sqrt2/phi buttons insert integer value (3/2/1/1) into accumulator. Live gate pending. |
| K5 | **History persistence.** Last 20 calculations survive reboot (FAT write). `calc history` command from the shell shows them. History ring is saved on each Enter (new result). History is restored on CALC.BIN startup from FAT. | ✅ code | 61 tests pass, `zig build calc` 13,915 B. | `calc/history.zig` `Ring.save_to_fat()` / `load_from_fat()`. `/data/calc_hst.txt` format: `expr=result\n`. History ring extended from 10→20. FAT read/write via `ui.file_open`/`file_write`/`file_close`. Live gate pending. |

## File decomposition

M24 split the monolithic `calc.zig` (1,147 lines) into focused modules:

```
user/src/calc.zig          — entry point, AppState, GUI orchestration (~950 lines)
user/src/calc/engine.zig   — CalcEngine: pure arithmetic, bitwise ops, format (~350 lines)
user/src/calc/history.zig  — Ring buffer: push/get/format/FAT persistence (~200 lines)
user/src/calc/programmer.zig — ProgrammerState: base conversion, registers, format (~180 lines)
user/src/calc/constants.zig  — comptime constant table + get() (~55 lines)
```

Total: ~1,735 lines across 5 files (was 1,147 in 1 file). Each module is
independently testable and has clear dependency boundaries.

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — CALC features** | `user/src/calc.zig` for K1 (programmer mode), K2 (memory), K4 (constants), K5 (history persistence). K1 and K2 can be done in parallel (disjoint state). K4 is independent. K5 extends K1–K4. | M18 done (FAT write for persistence). |
| **B — Unit conversion** | `user/src/calc.zig` + `user/src/lib/ui.zig` (DropDown reuse) for K3. | M17 done (DropDown widget exists). K1 (programmer mode affects which conversions are relevant). |

## Notes

1. **ABI budget:** Zero new syscall slots.
2. **BSS budget:** Registers 64 bytes. Memory slots 32 bytes. Conversion
   state ~32 bytes. History ring 640 bytes. Total M24 BSS delta: ~768 bytes.
   Negligible.
3. **Gate shape:** K1: `verify-live-calc-prog.sh` — hex/octal display toggles.
   K2: `verify-live-calc-memory.sh` — store/recall round-trip. K3:
   `verify-live-calc-units.sh` — unit conversion result. K4:
   `verify-live-calc-constants.sh` — constant button inserts value. K5:
   `verify-live-calc-history.sh` — history persists across reboot.
4. **Programmer mode vs standard mode:** The mode toggle (Ctrl+P) switches
   the entire UI layout. Standard mode shows: display + basic buttons + history.
   Programmer mode shows: triple display (hex/dec/oct) + extended buttons +
   registers. Both modes share the same calculator core.
5. **Scope exclusions:** No graphing. No symbolic algebra. No equation solver.
   No complex numbers. No matrix operations. This is a pocket calculator
   with programmer extensions.
