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
