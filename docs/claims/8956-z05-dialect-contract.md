# Claim: z05-dialect-contract

- **Owner:** antigravity (`agent/antigravity/z05-dialect-contract`)
- **Prompt / plan:** `docs/roadmap-post-arc5.md` (issue #749)
- **Scope:** Milestone 20 Lane 2 (Self-hosting Z0.5: Dialect contract — valid Zig 0.16)
- **Touches:** user/src/zc.zig, user/src/lib/zc.zig, tools/verify-live-zc.sh, tests/zc-corpus/z05-dialect.z, docs/claims/8956-z05-dialect-contract.md, docs/logs/agent-antigravity-z05-dialect-contract.md
- **Depends on:** —
- **Heartbeat:** 2026-09-01
- **Status:** ✅ agent/antigravity/z05-dialect-contract

## Notes

Make the in-guest compiler (zc) dialect valid Zig 0.16 syntax:
- Replace custom `svc` keyword with `@import("zc")` prelude calls.
- Create host-side `user/src/lib/zc.zig` shim using `asm volatile ("svc #0" ...)`.
- Update `tools/verify-live-zc.sh` to stage valid Zig 0.16 source and run host compile check.
- Add `tests/zc-corpus/z05-dialect.z` fixture.
- Verify in-guest live gate and unit tests.
