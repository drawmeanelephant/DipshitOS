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
