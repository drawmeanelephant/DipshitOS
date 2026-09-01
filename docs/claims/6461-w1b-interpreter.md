# Claim: M35 W1b — wasm binary parse + validate + integer-subset exec (#762)

- **Owner:** buffy (`freebuff/okay-shower-thoughts-here-we-re-using-fat32-for-so-b0ce3067-2b04-4b81-984d-9fd76bfcf123`)
- **Prompt / plan:** Build the wasm interpreter core in Zig: parse +
  validate + execute the integer subset (i32/i64, block/loop/if/br/br_if/
  br_table/return/call/call_indirect) with one bounded linear memory and
  one function table, dispatching imports to the frozen contract
  (`docs/wasm-import-contract.md` — W1a #778 landed via PR #786, on main).
  Path frozen: `user/src/wasm.zig` → `WASM.BIN` (the zc/ZC.BIN pattern).
- **Scope:** wasm-core module parse (magic/version, type/func/table/
  memory/global/export/import/start/element/data sections), validation,
  integer-subset exec, traps (bounds, call_indirect type, div-by-zero,
  unreachable, grow_limit, stack_overflow — each named with module +
  offset), one linear memory bounded at **2 MiB / 32 pages max — trap on
  `memory.grow` beyond, no unbounded mmap**, one function table, host
  unit tests on BOTH parse and exec, `user/src/wasm-corpus/` started with
  hand-built modules. Out: floats (W4), threads/atomics/SIMD (never),
  `wasm run` command (W2), import breadth beyond the contract's first
  set (W3).
- **Touches:** user/src/wasm.zig (new), build.zig (WASM.BIN target),
  user/src/wasm-corpus/fib-loop.wasm (new fixture),
  docs/claims/6461-w1b-interpreter.md, docs/logs/freebuff-20260901-006.md
- **Depends on:** W1a #778 contract on main (merged PR #786); W2+ wait on
  this card
- **Heartbeat:** 2026-09-01
- **Status:** ✅ done (PR #794)

## Notes

Gate (all verified at HEAD): `zig test user/src/wasm.zig` — **11/11 pass**
(parse rejects bad magic/version + truncated/unknown sections; validate
rejects f64; add3 deterministic double-run; loop+br_if factorial 5!==120
and 0!==1; unreachable traps with module "boom" + offset; div-by-zero on
i32.div_s and clean pass on 7/2; memory store/load round-trip + bounds
trap at 65530 (65528 would be exactly in-bounds — corrected test);
memory.grow returns 1, grow past cap traps grow_limit (no unbounded mmap);
call_indirect type-mismatch + OOB traps; embedded corpus fixture executes
byte-identically, 7!==5040). `zig build wasm install` produces
`zig-out/bin/WASM.BIN` (106 bytes, entry 0x18); guest entry follows the
house `pub export fn _start(argc, argv) callconv(.c) noreturn` convention
(plain `pub fn main` links entry 0 with this toolchain — fixed). Default
boots byte-identical: no kernel change, WASM.BIN not added to the ESP
image (W2 does delivery + `exec WASM.BIN`).

### BSS budget (artifacts/bss-w1b-before.txt / bss-w1b-after.txt)
Planned from the fixed-array constants: ~110 KiB interpreter state
(fixed operand stack 8 KiB, ctl/call stacks, module tables). Measured:
`@sizeOf(Module)` = 79,288 B and `@sizeOf(Machine)` = 30,576 B (109,864 B
total — within the plan; Element.funcs [max_table]u32 per segment is the
largest block, ~64 KiB, flagged for W2's flat-pool revisit). Guest marker
binary: .text 36 B / .rodata 34 B / WASM.BIN 106 B — the interpreter body
is dead-stripped until W2 wires `wasm run`; the 2 MiB linear-memory cap
is caller-backed, never BSS.

### Implementation notes worth keeping
- Fixture home is `user/src/wasm-corpus/`, not `tests/`: Zig 0.16
  `@embedFile` cannot reach outside the module root (the file's dir), so
  `../../tests/...` fails; W4's corpus work should add fixtures here.
- Three spec gotchas caught while encoding fixtures byte-exactly (via a
  python assembler, not by hand): elem segments with flags 0 have NO
  table-index byte (my first parse read one); section order is
  type<import<func<table<memory<global<export<start<elem<code<data
  (elem after export); 8-byte `i64.load` at 65528 is exactly in-bounds
  (±8 == 65536) — a real trap needs 65530+.
- Zig 0.16 dialect: `.unreachable` is a parse error (keyword) — the
  TrapKind variant is `@"unreachable"`; switch prongs with side effects
  use `{ }` bodies; `@truncate` requires matching signedness.
- Host-side unit-test CI wiring stays out of this card:
  `tools/verify-unit-tests.sh` gates kernel monitor modules only; the
  wasm suite runs via `zig test user/src/wasm.zig` (verified here) and
  W2 brings the live gate (`verify-live-wasm.sh`).

Claim id: 6461 (owner branch hash, per coordination gate).