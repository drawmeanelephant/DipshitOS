# Claim: z1e-control-flow

- **Owner:** antigravity (`agent/antigravity/z1e-control-flow`)
- **Prompt / plan:** `docs/line-of-sight.md` (issue #754)
- **Scope:** Milestone 20 Lane 2 (Self-hosting Z1e: Control-flow depth: for + switch)
- **Touches:** user/src/zc.zig, tools/verify-live-zc.sh, tests/zc-corpus/z1e-control.z, docs/claims/6823-z1e-control-flow.md, docs/logs/agent-antigravity-z1e-control-flow.md
- **Depends on:** 5725
- **Heartbeat:** 2026-09-02
- **Status:** ✅ done

## Notes

Implement Z1e control-flow depth: `for` and `switch`.

- `for` loops:
  - Range iteration: `for (0..n) |i| { ... }` or `for (0..n) { ... }` (lowered to counter variable, condition, increment, body).
  - Array/slice iteration: `for (arr) |item| { ... }` (lowered to index 0..len, load item, body).
  - Also support optional index capture `for (arr, 0..) |item, i| { ... }`.
- `switch` expressions/statements:
  - `switch (val) { prong => stmt/block, else => stmt/block }`
  - Prong conditions: single integers, multiple comma-separated integers (`1, 2 => ...`), ranges (`1...5 => ...`), or expressions.
  - Lowered as a condition chain (`cmp` + `b.eq` / `b.ne`) with jump to exit.
- New test fixture `tests/zc-corpus/z1e-control.z`.
- Integration into `tools/verify-live-zc.sh`.
- Host unit tests in `user/src/zc.zig`.
