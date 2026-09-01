# Claim: z1a-data-segment

- **Owner:** antigravity (`agent/antigravity/z1a-data-segment`)
- **Prompt / plan:** `docs/roadmap-post-arc5.md` (issue #750)
- **Scope:** Milestone 20 Lane 2 (Self-hosting Z1a: Data segment + string literals)
- **Touches:** user/src/zc.zig, user/src/lib/zc.zig, user/src/lib/asmenc.zig, tools/verify-live-zc.sh, tests/zc-corpus/z1a-strings.z, docs/claims/8708-z1a-data-segment.md, docs/logs/agent-antigravity-z1a-data-segment.md
- **Depends on:** 6366
- **Heartbeat:** 2026-09-01
- **Status:** 🔄 agent/antigravity/z1a-data-segment

## Notes

Implement Z1a Data segment + string literals:
- Add data segment support to `build_elf32` in `user/src/lib/asmenc.zig`.
- Add `zc.print` wrapper in `user/src/lib/zc.zig`.
- Add string literal tokenizer, data segment emission, ADR patching, and `zc.print` / `zc.write` codegen in `user/src/zc.zig`.
- Grow `image_buf` in `user/src/zc.zig` to 32 KiB.
- Add test corpus `tests/zc-corpus/z1a-strings.z`.
- Assert byte-exact string printing in `tools/verify-live-zc.sh`.
