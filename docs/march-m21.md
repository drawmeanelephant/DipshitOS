# Milestone twenty-one march — window management depth (living tracker)

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts. This file holds M21's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

M17–Arc5 built a full floating window manager with drag, resize, snap zones,
context menus, alt-tab, workspaces, a system tray, and a dock. But every
window floats — there's no tiling, no master-detail layout, no minimize-to-
dock, and the notification toasts disappear forever. M21 makes the window
manager feel *intentional*.

**Zero new syscall slots.** Every card is pure compositor geometry or paint.

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| W1 | **Tiling mode.** Ctrl+T toggles the focused window between floating and tiled. Tiled windows split the screen: master-stack model (left half / right half). Max 2 tiled windows per workspace. Third window reverts to floating. | ✅ **live 2026-08-25 (claim 8777)** | `bash tools/verify-live-m21-tile-master.sh` run A — PASS | Geometry math + layout in `driving_award.zig` (`toggle_tiling`, `apply_tile_layout`, tile state BSS). The gate drives it through the EL1h `dui tile <n>` half (the chord seam — Ctrl+T cannot be typed through the serial script path; the real wiring is host-tested in input.zig/shell.zig, synthesized-keyboard limitation #179 deferred). Registry-asserted AND pixel-asserted: master-left rect=24,0,837,700 / detail-right rect=861,0,419,700 (667:333 per mille of the 1256 px usable width), with each window's own colors decoded at its tiled origin. Claim-time fix: the tiled blit source clamp — `apply_tile_layout` rects (up to 837×700) exceed the fixed 512×384 back-buffer and `paint(.user)` → `blit_rect` did not clamp the source (latent OOB, never live-observed before this gate). |
| W2 | **Master-detail layout.** When two windows are tiled, the left is master (2/3 width) and the right is detail (1/3 width). Ctrl+M cycles which window is master. Dragging a tiled window detaches it (back to floating). | ✅ **live 2026-08-25 (claim 8777)** | `bash tools/verify-live-m21-tile-master.sh` run B — PASS | `swap_master` + `tile_master_side`. Gate run B: after `dui master`, side=right and BOTH rects move (A → detail-left 24,0,419,700; B → master-right 443,0,837,700), with B's cyan block observed at the NEW origin and gone from the old spot. Drag-detach lives in the pointer path (out of this gate's serial-script reach); toggle-detach via a second `dui tile <n>` on a tiled window is the same code path (host-tested). |
| W3 | **Window minimize.** Ctrl+N minimizes the focused window to the dock (shows as icon). Click the dock icon to restore to previous position and size. Minimized windows don't paint and don't receive events. Alt+Tab skips minimized windows. | ⬜ | — | `driving_award.zig` + `desktop.zig` dock integration. New BSS: `minimized` flag per window in the `Kind.window` state. The dock's click handler checks minimized flag and restores. |
| W4 | **Workspace-aware alt-tab.** Alt+Tab only shows windows on the current workspace (extend Arc2 C2's overlay). Alt+` (backtick) cycles workspaces directly without the overlay. The overlay shows workspace name ("WS 0", "WS 1", "WS 2"). | ⬜ | — | `driving_award.zig` overlay filter + `input.zig` Alt+` binding. Extends the existing alt-tab overlay from C2. |
| W5 | **Notification center.** Right edge pull-out panel showing the last 10 notifications. Click to dismiss one. "Clear all" button. Opens on the system tray clock click (extend W3 tray). Notification text stored in a BSS ring. | ⬜ | — | `driving_award.zig` notification history BSS ring (10 × 128 bytes = 1,280 bytes). The tray clock click opens the panel. The panel is a special `Kind` window that sits above the taskbar. |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Tiling** | `kernel/src/driving_award.zig` tiling geometry for W1 + W2. | M20 done (font sizes affect tile dimensions). |
| **B — Window lifecycle** | `kernel/src/driving_award.zig` minimize + `user/src/desktop.zig` dock restore for W3. `kernel/src/driving_award.zig` alt-tab filter + `kernel/src/input.zig` Alt+` for W4. | W1 (tiling affects alt-tab filtering). |
| **C — Notification center** | `kernel/src/driving_award.zig` notification history + tray integration for W5. | M18 done (clipboard for notification content), M20 done (font for panel text). |

## Notes

1. **ABI budget:** Zero new syscall slots. All compositor geometry and paint.
2. **BSS budget:** W1/W2 add ~12 bytes (tile state). W3 adds 1 byte per
   window (minimized flag). W5 adds ~1.3 KiB (notification ring). Total
   M21 BSS delta: ~1.4 KiB.
3. **Gate shape:** the W1+W2 gate is `tools/verify-live-m21-tile-master.sh`
   (one gate, two live runs: run A = tiled split, run B = master swap —
   claim 8777). Remaining planned gates: W3: `verify-live-m21-minimize.sh`
   — minimize + dock restore. W4: `verify-live-m21-ws-alttab.sh` —
   workspace-only alt-tab. W5: `verify-live-m21-notif-center.sh` —
   notification panel opens and shows entries.
4. **Tile limit:** Two tiled windows per workspace is a deliberate constraint.
   More windows stay floating. This avoids the complexity of arbitrary tiling
   layouts (binary split, fibonacci, etc.) while covering the most common
   use case (editor + terminal side by side).
5. **Scope exclusions:** No multi-monitor. No arbitrary tiling layouts. No
   window groups/containers. No keyboard-driven window placement (only
   Ctrl+T toggle and Ctrl+M swap).
