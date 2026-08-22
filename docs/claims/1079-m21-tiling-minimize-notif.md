# Claim: M21 compositor — tiling, minimize, notification center (W1–W5)

- **Owner:** Buffy (`agent/buffy/m21-compositor`)
- **Prompt / plan:** `docs/agent-concurrency-plan.md` (Lane E), `docs/march-m21.md`
- **Scope:** M21 W1–W5: tiling mode, master-detail, minimize, workspace-aware alt-tab, notification center
- **Depends on:** M18 done ✅ (M20 font sizes are a soft dependency — chrome uses existing 8×8 font)
- **Status:** 🔄 agent/buffy/m21-compositor

## Notes

Lane E owns `kernel/src/driving_award.zig` and `kernel/src/input.zig`.

**W1 — Tiling mode (Ctrl+T):** Toggle focused window between floating and tiled. Master-stack model (left/right). Max 2 tiled windows per workspace. New BSS: `tile_mode`, `tile_master_id`, `tile_stack_id`.

**W2 — Master-detail (Ctrl+M):** 2/3 : 1/3 split. Ctrl+M swaps master. Drag detaches tiled window. New BSS: `tile_master_side`.

**W3 — Minimize (Ctrl+N):** Minimize to dock, restore on dock click. `minimized` flag per window. Alt+Tab skips minimized. No paint/events while minimized.

**W4 — Workspace-aware alt-tab:** Filter overlay by current workspace. Alt+` cycles workspaces. Show WS name in overlay.

**W5 — Notification center:** Pull-out panel (10 notifications), click dismiss, clear all. Opens on tray clock click. BSS ring: 10 × 128 bytes.

All zero new syscall slots. Pure compositor geometry + paint. Verification via host tests (unit) and live gate scripts (later).
