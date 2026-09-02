# Log — M35 W4 core completeness: f32/f64, sign-extension proof, bulk-memory gated (issue #765)

Branch: `agent/buffy2/m35-w4-core-completeness` · Worktree: `../virelaios-buffy2`

## 2026-09-02 — claim 7395 filed; W4 scoped against the merged W3 interpreter

- **Survey done (read of the W3 tree at 7e8a087):** `user/src/wasm.zig`
  (3,085 lines) already parses `f32`/`f64` value types and rejects them at
  five `FloatOutOfSubset` sites: type-section params/results + globals in
  `validate()`, float memory ops 0x2A/0x2B/0x38/0x39, `f32/f64.const`
  0x43/0x44, and the float opcode ranges 0x5B–0x66 / 0x8B–0xA6 /
  0xAA–0xBF in `validateOp`. Sign-extension (0xC0–0xC4) is ALREADY
  implemented in validation + execBody (W1b's full integer set) but no
  fixture exercises it — the card's sign-ext work is proof, not
  re-implementation.
- **Bulk-memory parser gaps pinned:** the DataCount section (id 12) is
  rejected as `UnknownSection` (`parseInto`'s `seen[12]` guard) and passive
  data segments (flag 0x01) as `BadElementKind` — both must land before any
  0xFC exec. Decision gate: probe the wc-style `zig cc` build for
  `memory.copy/fill/init` emission; implement only if justified.
- **Float trap discipline recorded for implementation:** wasm div-by-zero →
  ±inf (never a trap); only plain trunc* conversions trap (NaN /
  out-of-range); min/max/nearest/copysign carry IEEE-754 minNum/maxNum
  semantics — the byte-exact-fixture failure surface.
- Plan doc `docs/march-m35-w4-core-completeness.md` written; claim 7395
  filed (`claim-id.sh "agent/buffy2/m35-w4-core-completeness"
  m35-w4-core-completeness` → 7395); coordination gate clean (no other
  ACTIVE claim touches `user/src/wasm.zig`).

## 2026-09-02 — float core slice implemented; unit + build green

- **W4 float core landed in `user/src/wasm.zig`:** `Value` union gains
  f32/f64 lanes; the five W1b `FloatOutOfSubset` reject sites lifted
  (types, globals, consts 0x43/0x44, memory 0x2A/0x2B/0x38/0x39, opcode
  ranges); `parseConstExpr` accepts f32/f64.const (float globals);
  validation + exec cover the full current-encoding float surface —
  f32 cmp 0x5B–0x60 / f64 cmp 0x61–0x66, f32 unary+arith 0x8B–0x98,
  f64 0x99–0xA6, conversions/reinterpret 0xB2–0xBF, trunc = 0xFC 0..7.
  Opcode map confirmed against zig-cc emission (probes: f32.div=0x95,
  f64.neg=0x9A, f64.add=0xA0, f64.mul=0xA2, f64.convert_i64_s=0xB9,
  trunc fc 00/fc 02) + the current spec page — NOT memory.
- **Trap discipline:** float div-by-zero yields ±inf (never traps — new
  host test pins rec(0)=+inf); the only new trap is `invalid_conv`
  (0xFC trunc on NaN/out-of-range, named module+offset). min/max are
  IEEE-754 minNum/maxNum (numeric-over-NaN, ±0 sign rules), `nearest` is
  round-half-to-even (own `roundEven` — no @round).
- **Sign-extension proof:** new hand-built fixture runs all five
  0xC0–0xC4 ops end-to-end (W3 left them implemented but fixture-less).
- **Tests: 30/30** (`zig test user/src/wasm.zig`) — W1b/W2/W3 all stay
  green; the W1b "rejects f64 type" test flipped to an acceptance test;
  8 new w4 tests (f64 scale mul/add byte-exact, f32 div ±inf, trunc +
  NaN/overflow traps, f64.convert_i64_s rounding, NaN cmp semantics,
  f64.store/load round-trip with clang memarg shape, sign-ext).
- **Build + gates:** `zig build wasm` green — WASM.BIN 59,296 B
  (text 28,672 / data 30,576 / bss 152,728 ≈ 207 KiB staged, inside the
  256 KiB loader budget; W3 before was text 24,576 / bss 145,528 —
  +4,096 text, +7,200 bss for the float surface).
  `verify-coordination` PASS; `verify-bss-budget` PASS (11.0 MiB/11.0 MiB
  kernel .bss, 542 KiB headroom).
- **Still open on W4 (next commits):** bulk-memory 0xFC 8+ parser+exec is
  gated on the wc `zig cc` probe (per plan); the named C float utility +
  corpus fixture + `verify-live-wasm.sh` W4 phase; docs flips (scoping
  card, contract §6, status).
## 2026-09-02 — bulk-memory probe + 0xFC 8–11 landed (W4, issue #765)

- **Decision probe (run first, as the plan gated):** compiled a wc-shaped
  program against the real `tests/virelai.h` shim under the plain W3
  recipe (`zig cc -target wasm32-freestanding`, no bulk-memory flag) and
  a `-mbulk-memory` variant. Constant-size memcpy/memset lower to
  inlined i32 ops under both — but a **runtime-size** memcpy/memset
  (the honest wc shape) emits `0xFC 0A` memory.copy and `0xFC 0B`
  memory.fill under the plain recipe (clang enables bulk-memory by
  default for wasm32). The W3 interpreter rejected those modules at
  validate (`BulkMemoryOutOfSubset`). **Verdict: bulk-memory is
  justified** — any real wc tool hits it.
- **Parser:** DataCount section (id 12) accepted between element and code
  with ordering enforced; `Module.has_datacount`/`data_count_decl`
  added; count-vs-data-section mismatch → `DataCountMismatch`; passive
  data flag 0x01 accepted; active segments stay flag 0/2 with the same
  instantiate semantics. Passive data never lands at instantiate (poison
  test pins store[0..8] = 0xEE after instantiate).
- **Machine:** `Machine.data_dropped[max_datas]` per-instance state, reset
  in `resetMachine`.
- **Validation:** 0xFC 8 = memory.init (dataidx+memidx, `[dst src n]`),
  9 = data.drop, 10 = memory.copy, 11 = memory.fill; 8/9 require the
  DataCount section (`DataCountMissing`) and index < data_count_decl;
  all four require a memory; 0xFC ≥ 12 (table.init/copy/grow etc.)
  stays out of subset. skipInstr/scanner taught the 0xFC immediate
  shapes so validateOp and exec agree.
- **Exec:** memory.init/copy/fill/data.drop with the W1 bounds discipline
  (module + offset named traps). copy is a true memmove (`@memmove`:
  backward for dst > src) — the overlap test would smear under a plain
  forward copy; init is `@memcpy` from the (possibly dropped) segment.
- **Tests: 35/35** (`zig test user/src/wasm.zig`). New: init/copy/fill
  byte-exact (right-shift 1,1,2,3,4,5,6,7,9 — index 8 keeps init's 9th
  byte, proving copy never wrote past its window), data.drop makes a
  later init trap bounds, memory.init without DataCount →
  DataCountMissing, DataCount count mismatch → parse error, table ops
  (0xFC 16) still BulkMemoryOutOfSubset. (Debugging note: three new
  tests had off-by-one section/body size bytes and one had a wrong
  expectation — exec was correct all along; fixed in-test.)
- **End-to-end proof:** a self-contained clang module (runtime-size
  memmove, exported `shift`, `--initial-memory`, no imports) parses →
  validates → instantiates → executes through the interpreter:
  `shift(4)=4` then `shift(3)=3` on the same instance — clang-emitted
  memory.copy confirmed working, not just validated.
- **Build + gates:** `zig build wasm` green — WASM.BIN image 63,456 B
  (≈ 248 KiB staged incl. bss tail, inside the 256 KiB loader budget).
  `verify-coordination` PASS; `verify-bss-budget` PASS (542 KiB
  headroom). Probe scratch cleaned (nothing unreferenced left in tree).
- **Still open on W4 (next commits):** the named C float utility +
  pinned corpus fixture + `verify-live-wasm.sh` W4 live-gate phase;
  docs flips (scoping card, contract §6, status).

## 2026-09-02 — W4 READY: float utility fixture + trunc-family correction + live-gate phase (claim done)

- **The name:** the fixture is **floatapp** — a no-libc C temp-unit converter
  (`tests/floatapp.c`, compiled against `tests/virelai.h` alone with the W3
  determinism recipe — `zig cc -target wasm32-freestanding -nostdlib
  -fno-sanitize=undefined -g0`, 3,441 B). Volatile input tables defeat
  constant-folding so the float ops run at runtime; every emitted value was
  cross-validated against independent IEEE arithmetic (Python `struct`
  doubles) before pinning. Committed as `user/src/wasm-corpus/floatapp.wasm`
  (sha256 **c963d5aa…48b42**); the W3 fixture-rebuild recipe reproduces the
  existing pins byte-identically, so the pin is a true rebuild sentinel.
- **The fixture flushed out a real opcode-map error (W4 fix):** floatapp's
  `(long)d` lowering tripped the interpreter on 0xAC — which is
  `i64.extend_i32_s`, NOT a trunc; my earlier float slice (and the W1b-era
  wiring both) had misread the 0xA8–0xB1 region. Ground truth now matches
  the spec/v8 opcode tables: plain trapping trunc lives at 0xA8/0xA9/0xAA/0xAB
  (→i32) and 0xAE–0xB1 (→i64); 0xAC/0xAD are the i64 extends; the 0xFC 0–7
  forms are the SATURATING (never-trap) trunc_sat family — which is what
  clang actually emits for C casts. Rewired validate+exec: 0xFC 0–7 → the
  new `truncSat` (NaN→0, clamp to min/max), 0xA8–0xB1 → trapping
  `execTrunc` (NaN/out-of-range → `invalid_conv`). floatapp exercises both
  families live. New host tests: trunc_sat saturates (no trap), plain trunc
  traps, 0xAC/0xAD extend with correct sign.
- **The .bss lesson (host-test contract, no interpreter change):** fresh
  wasm memory is zero-initialized per spec; instantiate copies active data
  segments on top and relies on the caller for zero pages (the guest runner
  mmaps). floatapp is the first fixture that READS .bss (the env.write
  cursor) before writing it — the host test's `undefined` stack store
  poisoned that read (0xaa…) → false bounds trap. Fixed the test's store to
  `@splat(0)`. Worth a note in the contract doc (§3 reads stay zero-copy).
- **Live gate W4 phase (tools/verify-live-wasm.sh):** FLOATAPP.WASM is
  sha-pinned (c963d5aa), exec'd FIRST in script1 (FLOATAPP, FILEAPP,
  HELLO, then WINAPP — all short non-display apps stay in proven-safe
  overlap classes; the winapp's overlap set stays ≤1 app). Per run the gate
  asserts five distinctive byte-exact output needles, one per float opcode
  family — `mC 100000 = 212.00` (f64 arith/mC loop), `bits64 c2f 21.50 =
  4051accccccccccd` (f64 bit-pattern hex), `f2c 98.60 = 37.00` (saturating
  trunc rounding), `f32 f2c -4.00 = -20.00` (f32 path), `sext chk = -66`
  (i64.extend_i32_s) — plus `tasks user-exec exited status=590` (the total
  output byte count: fileapp's length proof) and the `rx-w4-float` shell
  response.
- **Evidence (this boot, artifacts/):** `zig test user/src/wasm.zig`
  **38/38**; `zig build wasm` green — WASM.BIN 63,456 B (bss tail 152,728,
  inside the 256 KiB loader budget); `verify-coordination` + 
  `verify-bss-budget` PASS (542 KiB headroom); **live class-B gate PASS
  boot1** — float590=1 float1..5=1 floatresp=1, red fill 10,436 px,
  fileapp 512, hello 55 all intact (artifacts/m35-wasm-live.txt,
  live-wasm-report.txt, live-wasm-serial-boot1.log).
- **Docs flipped:** wasm.zig header (0xFC 12+ out of subset, not 8+);
  docs/wasm-core-scoping.md (W4 row ✅ 2026-09-02 + what-landed note, value
  types/bulk-memory table rows, traps row); docs/wasm-import-contract.md
  §6 (bulk-memory removed from the trap list — normative fix — and the
  floating-point line says landed); docs/status.md (M35 table row: 5/6
  closed, W5 open; open-workstreams pointer).
- **W4 is done.** Remaining on the milestone: W5 #766 (the `wc` capstone).
