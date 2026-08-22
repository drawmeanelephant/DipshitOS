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
| K1 | **Programmer mode.** Ctrl+P toggles between standard and programmer view. Programmer shows: hex/octal/decimal display (all three simultaneously), AND/OR/XOR/NOT/shift operators (<<, >>), register display (R0–R7 as scratch). Base selector buttons: HEX/DEC/OCT. | ⬜ | — | `calc.zig` mode state + operator dispatch. New BSS: `prog_mode` flag, `base` (HEX/DEC/OCT), `registers[8]` (64 bytes). New buttons: AND, OR, XOR, NOT, SHL, SHR, base selectors. The display area splits into three rows (hex/dec/oct) in programmer mode. |
| K2 | **Memory store.** MS (memory store) / MR (memory recall) / M+ (memory add) / M- (memory subtract) with 4 memory slots (M0–M3). Memory indicator in the display showing which slots are non-zero. Ctrl+1/2/3/4 selects the active memory slot. | ⬜ | — | `calc.zig` BSS memory slots (4 × 8 bytes = 32 bytes). Memory buttons in the button grid. Display shows "M0: 42" when a slot has content. |
| K3 | **Unit conversion.** Ctrl+U opens a conversion bar at the top. Categories: `temp` (C/F/K), `length` (m/ft/in/cm/mm), `weight` (kg/lb/g/oz). Type a value, select units, result appears instantly. Conversion factors are comptime constants. | ⬜ | — | `calc.zig` conversion table (comptime). New BSS: `convert_mode` flag, `convert_value` (f64), `convert_from`/`convert_to` (unit enum). The conversion bar is a `ui.zig` TextInput + two DropDown widgets (C1's DropDown reused). |
| K4 | **Constant calculator.** Mathematical constants available as dedicated buttons: π (3.14159…), e (2.71828…), √2 (1.41421…), φ (1.61803…), ∞, and 1/3 (0.333…). Press the constant button and the value appears in the display, ready to be used in the next operation. | ⬜ | — | `calc.zig` comptime constant table. New buttons in the grid. Each button inserts the constant's value into the display accumulator. |
| K5 | **History persistence.** Last 20 calculations survive reboot (FAT write). `calc history` command from the shell shows them. History ring is saved on each Enter (new result). History is restored on CALC.BIN startup from FAT. | ⬜ | — | `calc.zig` + FAT write. History ring extended from 10 to 20 entries (M17 C9 was 10). BSS: 20 × 32 bytes = 640 bytes. FAT write uses existing file syscalls. |

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
