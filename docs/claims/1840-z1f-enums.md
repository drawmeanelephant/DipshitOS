# Claim: z1f-enums

- **Owner:** buffy (`agent/buffy/z1f-enums`)
- **Prompt / plan:** `docs/line-of-sight.md` (issue #755)
- **Scope:** Milestone 20 Lane 2 (Self-hosting Z1f: Enums)
- **Touches:** user/src/zc.zig, tools/verify-live-zc.sh, tests/zc-corpus/z1f-enums.z, docs/claims/1840-z1f-enums.md, docs/logs/agent-buffy-z1f-enums.md
- **Depends on:** 6823
- **Heartbeat:** 2026-09-02
- **Status:** ✅ done

## Notes

Implement Z1f tagged constants — `enum` declarations, int↔enum casts, and
enum prongs in the Z1e `switch` — so state machines and tags become typed.

- `enum` keyword + tokenizer support; top-level `const Name = enum(u8) { a, b = 5, c };`
  declarations are registered in pass 1 (optional explicit tag type parsed and
  ignored for codegen; implicit members count up from 0, explicit `= N` values
  set the running counter).
- Enum types resolve through `typeSize` (word storage), so typed locals and
  function parameters of enum type work unchanged.
- `Color.member` expression lowering emits the member's tag as an immediate;
  unknown members are a compile error.
- `@intFromEnum(x)` / `@enumFromInt(x)` lower as identity casts (tags are their
  integer values in zc); unknown `@`-builtins are rejected.
- Enum constants flow through the existing Z1e `switch` lowering unchanged —
  prong values, multi-value and `else` prongs, statement and expression form.
- New corpus fixture `tests/zc-corpus/z1f-enums.z` (implicit + explicit tags,
  both casts, exhaustive switch expression and statement switch); the
  `verify-live-zc.sh` live SRC is now an enum-valued switch that prints its tag
  string and exits 72 (kept ≤256 bytes — the shell `write` command refuses
  longer input lines). Five new host unit tests (29/29 passing).

Verified: host `zig 0.16` `build-obj` parses SRC + fixture; `verify-live-zc.sh`
PASS 1/1 (compiled=1 loaded=1 printed=1 exit72=1 fatal=0); full monitor unit
suite and `verify-bss-budget.sh` green.
