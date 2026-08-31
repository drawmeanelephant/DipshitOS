# Claim: in-guest-compiler

- **Owner:** antigravity (`agent/antigravity/in-guest-compiler`)
- **Prompt / plan:** `docs/roadmap-post-arc5.md` (issue #620)
- **Scope:** Milestone 32 Lane 2 (the in-guest Zig-subset compiler)
- **Touches:** user/src/lib/asmenc.zig, user/src/asm.zig, user/src/zc.zig, build.zig, tools/verify-live-zc.sh, docs/claims/0098-in-guest-compiler.md, docs/logs/agent-antigravity-in-guest-compiler.md
- **Depends on:** —
- **Heartbeat:** 2026-08-31
- **Status:** ✅ agent/antigravity/in-guest-compiler

## Notes

Implementing the freestanding in-guest AArch64 compiler `zc.zig` compiling a subset of Zig to native ELF32 binaries, and moving existing instruction encoder logic into `user/src/lib/asmenc.zig`.
Verification: `zig test user/src/asm.zig` + `zig test user/src/zc.zig` + VZ live gate.
