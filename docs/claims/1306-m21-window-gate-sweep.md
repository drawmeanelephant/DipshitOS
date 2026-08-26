# Claim: M21 window-management gate sweep (W1–W16)

- **Owner:** Buffy (`agent/buffy/m21-window-depth`)
- **Prompt / plan:** `docs/march-m21.md` (W1–W5 card detail; W6–W16 specs live in issues #321–#432)
- **Scope:** Milestone twenty-one (GitHub milestone 9) — comprehensive verification sweep of all 16 cards (W1–W16): per-card class-B gates on VZ, monitor inspection halves, march/status doc updates, issue close-outs with observed evidence.
- **Touches:** docs/march-m21.md docs/status.md kernel/src/monitor.zig kernel/src/driving_award.zig kernel/src/input.zig kernel/src/shell.zig user/src/m21demo.zig tools/verify-live-m21* tools/verify-live-m21-tile-master.sh tools/verify-live-m21-minimize-ws.sh tools/verify-live-m21-max-fullscreen-aot.sh tools/verify-live-m21-notif-dialog-transient.sh tools/verify-live-m21-persist-title-orphan.sh build.zig
- **Depends on:** #488 (W1–W5 implementation) + 1a8dedf (W9/W11/W12 polish) — both already on main
- **Status:** ✅ done 2026-08-26 (`agent/buffy/m21-window-depth`)

## Notes

State survey at sweep start (HEAD `933ece7`): every W-card's core logic is
merged, but cards need complete observed evidence and live class-B gates:
- W1: Tiling mode (Ctrl+T) (#321)
- W2: Master-detail layout (Ctrl+M) (#322)
- W3: Window minimize (Ctrl+N) (#323)
- W4: Workspace-aware alt-tab (#420)
- W5: Notification center (#421)
- W6: Maximize / restore (#422)
- W7: Fullscreen mode (F11) (#423)
- W8: Always-on-top (Ctrl+Shift+T) (#424)
- W9: Focus rings & visual focus indicator (#425)
- W10: Keyboard window movement (Alt+arrows) (#426)
- W11: Window persistence across sessions (#427)
- W12: Window title updates (#428)
- W13: Close confirmation dialog (#429)
- W14: Orphan window cleanup (#430)
- W15: Modal windows (#431)
- W16: Transient window behavior (#432)

5 class-B live gates cover the full matrix on real VZ VMs with serial
marker assertions and pixel proofs.
