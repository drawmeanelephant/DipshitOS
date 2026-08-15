# Log — `CALC.BIN` polish: checked arithmetic, repeat-op, memory keys

## Context

- **Goal:** Post-M11 polish of `CALC.BIN`'s `CalcEngine` — checked i64
  arithmetic (ERROR instead of silent wrap), repeat-last-op on `=`, and
  memory keys `M+` / `M-` / `MR` / `MC` — with class A tests.
- **Claim:** [`docs/claims/7869-calc-overflow-memory.md`](../claims/7869-calc-overflow-memory.md)

## Entries

### 2026-08-15: Claimed and implemented (claim 7869)

- Claimed under `agent/buffy/m11-calc-polish` (deterministic ID 7869).
- `CalcEngine.evaluate()` rewritten around checked i64 math:
  - `+`/`-`/`*` via `std.math` `add`/`sub`/`mul` (overflow → `has_error`).
  - `/` and `%` guard both `b == 0` and `a == INT64_MIN and b == -1`
    (the two's-complement overflow the safe intrinsics do not cover);
    `INT64_MIN % -1` returns 0 mathematically without trapping.
  - Any overflow clears accum/current/pending/repeat (the divide-by-zero
    contract extended to all overflow).
- Repeat-last-op: `evaluate()` records `last_op`/`last_operand` when a
  binary op completes; a bare `=` with no pending op repeats it
  (`5 + 3 = =` → 8, 11, 14). New operand after `=` → constant mode.
- Memory: `mem` register + `mem_flag`; `M+`/`M-` checked add/sub,
  `MR` recalls (entering-mode), `MC` clears. `C` leaves memory intact.
- GUI: memory button row (M+, M-, MR, MC) at the top of the grid; rows
  re-pitched to 20 px buttons on 26 px (six rows fit the 192 px window);
  `M` indicator drawn in the display when `mem_flag`; keyboard `m`/`M` → MR.
- Fixed the `window_h: u192` type typo (was a 192-bit integer type) → `u32`.
- Class A: `zig test user/src/calc.zig` green (existing 3 tests + new
  overflow/repeat/memory/format tests); `zig fmt --check` clean;
  `zig build calc` green.
- Coordination: indexes refreshed, `verify-coordination.sh` ok.
