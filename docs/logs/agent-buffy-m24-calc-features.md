# Log — `agent/buffy/m24-calc-features`

## M24 CALC decomposition + K1–K5

Claimed. M24 CALC decompose + K1–K5: split calc.zig into calc/{engine,history,programmer,constants}.zig modules, implement K1 programmer mode (Ctrl+P, hex/oct/dec display, bitwise ops, registers), K2 4-slot memory (MS/MR/MC, Ctrl+1/2/3/4), K3 unit conversion (Ctrl+U, temp/length/weight), K4 constants (π, e, √2, φ), K5 history FAT persistence. Serial markers for gate scripts. Class-B gate script for K1.

Implemented. Decomposed monolithic calc.zig (1,147 lines) into 5 focused modules:
- `calc/engine.zig` (~350 lines) — CalcEngine + bitwise ops (A/O/X/L/R) + format_i64
- `calc/history.zig` (~200 lines) — HistoryRing + save_to_fat/load_from_fat
- `calc/programmer.zig` (~180 lines) — ProgrammerState + format_hex/oct/dec
- `calc/constants.zig` (~55 lines) — comptime constant table
- `calc.zig` (~950 lines) — slim entry point, GUI, K2/K3/K4 UI

All 61 host tests pass. `zig build calc` 14,137 B. Full build + image pass. Serial markers: prog-on/off, conv-on/off, mem-slot. Gate script: `tools/verify-live-calc-prog.sh` written, syntax verified.
