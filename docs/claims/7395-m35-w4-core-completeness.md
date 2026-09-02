# Claim: M35 W4 — core completeness — f32/f64, sign-extension, bulk-memory (issue #765)

- **Owner:** buffy2 (`agent/buffy2/m35-w4-core-completeness`)
- **Prompt / plan:** `docs/march-m35-w4-core-completeness.md` (this card's prompt/plan doc); tracker `docs/wasm-core-scoping.md` (card table); issue #765 (Milestone #22)
- **Scope:** grow the wasm interpreter honestly past the W1b/W3 integer subset: f32/f64 value types + the full f32/f64 numeric opcode surface with W1-discipline trap semantics (conversion traps named with module+offset; IEEE semantics for div/NaN so no bogus traps), sign-extension ops exercised by a named program + fixtures (the five 0xC0–0xC4 ops are already implemented — W1b's integer set — but untested by any fixture), and bulk-memory (memory.copy/fill/init/data.drop) only if the W5-capstone host build justifies it (probe `zig cc` lowering of the wc-style C first). Floats are justified by a named C float utility (unit-converter shape, `zig cc -target wasm32-freestanding`, fixed-point-in / two-decimal-out, pinned byte-exact output in the live gate). Determinism fixtures extend the corpus; interpreter BSS budget before/after recorded in the claim.
- **Touches:** user/src/wasm.zig (float value lanes, validation flips, f32/f64 const/load/store/arith/cmp/convert exec, trap naming, tests; 0xFC bulk-memory + DataCount/passive-data parse only if the W5 probe justifies), tests/wasm-corpus/*.wasm (new pinned float fixture(s)), tools/verify-live-wasm.sh (W4 phase), docs/march-m35-w4-core-completeness.md (prompt/plan), docs/wasm-core-scoping.md (card row when landed), claim + branch log; claim id via `bash tools/status/claim-id.sh`
- **Depends on:** W3 #764 merged (PR #807); W1a #778 contract (PR #786); W2 #763 (PR #796)
- **Heartbeat:** 2026-09-02
- **Status:** 🔄 agent/buffy2/m35-w4-core-completeness

## Notes

Scope discipline: sign-extension is NOT re-implemented (it is in the tree,
`validateOp` 0xC0–0xC4 + execBody) — the card's real sign-ext work is proof
(exercise the ops in the named program where they naturally appear + a
hand-built fixture). Bulk-memory is gated: the parser must first accept the
DataCount section (id 12 — currently `UnknownSection`) and passive data
segments (flag 0x01 — currently `BadElementKind`) before 0xFC exec can exist;
that parser work happens only if the wc-style `zig cc` probe emits
`memory.copy`/`memory.fill`/`memory.init`. The float trap discipline: wasm
div-by-zero yields ±inf (NOT a trap); only the non-saturating trunc*
conversions trap (NaN / out-of-range); min/max/nearest/copysign follow the
spec's IEEE-754 minNum/maxNum semantics — these are where byte-exact
fixtures catch drift.

Gate: `zig test user/src/wasm.zig` green (W1b–W3 tests stay green, float
acceptance tests added, the W1b "validate: rejects f64 type" test flips to an
acceptance test); host-built float utility runs in `tools/verify-live-wasm.sh`
W4 phase on VZ with pinned byte-exact output; BSS before/after in
`artifacts/`; `tools/verify-coordination.sh` PASS.

Claim id derivation: `bash tools/status/claim-id.sh "agent/buffy2/m35-w4-core-completeness" m35-w4-core-completeness` → **7395** (the backticked owner branch, not the display name).
