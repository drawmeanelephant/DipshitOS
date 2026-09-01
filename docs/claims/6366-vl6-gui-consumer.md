# Claim: vl6-gui-consumer

- **Owner:** antigravity (`agent/antigravity/vl6-gui-consumer`)
- **Prompt / plan:** `docs/roadmap-post-arc5.md` (issue #708)
- **Scope:** Milestone 20 Lane 2 (Self-hosting VL6: GUI consumer)
- **Touches:** user/src/zc.zig, user/src/lib/zc.zig, tools/verify-live-zc.sh, tests/zc-corpus/vl6-gui.z, docs/claims/6366-vl6-gui-consumer.md, docs/logs/agent-antigravity-vl6-gui-consumer.md
- **Depends on:** 8956
- **Heartbeat:** 2026-09-01
- **Status:** 🔄 agent/antigravity/vl6-gui-consumer

## Notes

Implement VL6 GUI consumer for in-guest compiler `zc`:
- Add window syscall wrappers in `user/src/lib/zc.zig` (`win_open`, `win_fill`, `win_present`, `win_close`).
- Add `zc.win_*` builtin dispatch in `user/src/zc.zig`.
- Add test fixture `tests/zc-corpus/vl6-gui.z`.
- Extend live verification gate in `tools/verify-live-zc.sh` to compile and execute a GUI window application in-guest.
