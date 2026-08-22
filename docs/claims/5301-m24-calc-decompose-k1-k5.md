# Claim: M24 CALC decomposition + K1–K5 implementation

- **Owner:** buffy (`agent/buffy/m24-calc-features`)
- **Prompt / plan:** `docs/march-m24.md`
- **Scope:** M24 cards K1–K5 — decompose `calc.zig` into focused submodules, implement programmer mode (K1), 4-slot memory (K2), unit conversion (K3), mathematical constants (K4), history FAT persistence (K5). Class-B live gate script for K1.
- **Depends on:** M17 (DropDown widget), M18 (FAT write), M11 (CALC.BIN base)
- **Status:** ✅ done 2026-08-22 — PR #482

## Notes

The monolithic `calc.zig` (1,147 lines) was decomposed into 5 focused modules before adding M24 features:

- `calc/engine.zig` — pure arithmetic engine (checked overflow, bitwise ops)
- `calc/history.zig` — ring buffer + FAT persistence
- `calc/programmer.zig` — base conversion, registers, format helpers
- `calc/constants.zig` — comptime constant table
- `calc.zig` — slim entry point, GUI orchestration

All K1–K5 code is complete. 61/61 host tests pass. `zig build calc` 14,137 B.
Serial markers added: `calc: prog-on`/`calc: prog-off`, `calc: conv-on`/`calc: conv-off`, `calc: mem-slot`.
Gate script written: `tools/verify-live-calc-prog.sh`.

### Files changed

- **New:** `user/src/calc/engine.zig` — CalcEngine with bitwise ops (AND/OR/XOR/NOT/SHL/SHR), format_i64 standalone
- **New:** `user/src/calc/history.zig` — HistoryRing with FAT save_to_fat/load_from_fat
- **New:** `user/src/calc/programmer.zig` — ProgrammerState, format_hex/format_oct/format_dec
- **New:** `user/src/calc/constants.zig` — comptime constant table (π, e, √2, φ)
- **Modified:** `user/src/calc.zig` — rewritten as slim entry point importing submodules, K2 4-slot memory, K3 unit conversion UI, K4 constant buttons, serial markers
- **Modified:** `docs/march-m24.md` — K1–K5 marked ✅ code, file decomposition section added
- **New:** `tools/verify-live-calc-prog.sh` — class-B VZ gate for K1 programmer mode

### Verification

- `zig test user/src/calc.zig` — 61/61 tests pass
- `zig build calc` — CALC.BIN 14,137 B
- `zig build` — full build passes
- `zig build image` — disk image builds
- `bash tools/verify-unit-tests.sh` — all modules pass
- `bash tools/verify-coordination.sh` — indexes in sync
