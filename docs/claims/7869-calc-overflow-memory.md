# Claim: `CALC.BIN` polish — checked arithmetic, repeat-last-op, memory keys

- **Owner:** buffy (`agent/buffy/m11-calc-polish`)
- **Prompt / plan:** post-M11 CALC.BIN polish (Phase A, first card — per the M11-apps review)
- **Scope:** `user/src/calc.zig`, `docs/claims/7869-calc-overflow-memory.md`, `docs/logs/agent-buffy-m11-calc-polish.md`
- **Depends on:** `docs/claims/8401-a2-calc-calculator.md`
- **Status:** ✅ done

## Notes

Polish pass on `CALC.BIN`'s `CalcEngine` (pure 64-bit integer engine, class A
tested), closing three gaps found in the post-M11 app review:

1. **Checked arithmetic instead of silent wrap.** `+`/`-`/`*` used wrapping
   `+%`/`-%`/`*%`, so `9223372036854775807 + 1` rendered garbage instead of
   ERROR. Now every binary op runs through checked i64 math (`std.math`
   `add`/`sub`/`mul`) plus the two division edge cases the safe checks do not
   cover: `/` and `%` by zero (already guarded) and `INT64_MIN / -1`
   (two's-complement overflow that would trap). Any overflow sets `has_error`
   (display shows ERROR) and clears the pending/repeat chain, matching the
   existing divide-by-zero contract. `toggle_sign` and `format_display` are
   hardened against `INT64_MIN` negation without relying on wrapping
   arithmetic.

2. **Repeat-last-op on `=`.** `5 + 3 = =` now yields 8, then 11, then 14 —
   a `last_op`/`last_operand` chain kept by `evaluate()` when a binary op
   completes. A new operand after `=` starts a fresh chain (constant-mode:
   `5 + 3 =` then `2 =` gives 5). `C` clears the chain.

3. **Memory keys `M+` / `M-` / `MR` / `MC`.** A fourth row of buttons in the
   grid (the layout is re-pitched to fit six rows: memory row + the existing
   five, 20 px buttons on a 26 px pitch) wired to a checked `mem` register
   with an `M` indicator in the display; `MC` clears it. Keyboard `m`/`M`
   recalls. `C` does not touch memory (that is `MC`'s job).

Also fixes the `window_h: u192` type typo (a 192-bit integer type; now `u32`).

Class A: `zig test user/src/calc.zig` (new tests: add/sub/mul overflow,
`INT64_MIN / -1` and `% -1`, repeat-op chain, digit-after-`=` constant mode,
M+/M-/MR/MC semantics incl. memory persisting across `C`, `format_display`
edge cases) — all green; `zig fmt` clean; `zig build calc` green.
