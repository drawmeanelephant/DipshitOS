# Log — `CALC.BIN` (Interactive Graphical Calculator)

## Context

- **Goal:** Implement the standalone EL0 calculator program `user/src/calc.zig`, package it into `CALC.BIN`, and verify its calculation engine and GUI interactions.
- **Claim:** [`docs/claims/8401-a2-calc-calculator.md`](../claims/8401-a2-calc-calculator.md)

## Entries

### 2026-08-15: Initialized and completed Card A2 implementation (claim 8401)

- Implemented `user/src/calc.zig` (`CALC.BIN`):
  - 64-bit integer calculation engine (`+`, `-`, `*`, `/`, `%`, `+/-`) with division-by-zero protection.
  - Interactive clickable button grid in $256 \times 192$ user window.
  - Keyboard numeric entry and operator handling.
  - Right-aligned LCD-style display formatting.
- Integrated `CALC.BIN` into `build.zig`, `image/make-image.sh`, and `image/mkfat32.py`.
- Made root directory cluster allocation in `image/mkfat32.py` dynamic.
- Verified with unit tests (`zig test user/src/calc.zig`), disk image inspection (`zig build inspect`), and FAT32 file embedding.
- Flipped claim 8401 to ✅ done and updated `docs/march-m11.md`.
