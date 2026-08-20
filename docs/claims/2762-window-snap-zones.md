# Claim: Window snap zones — halves and quadrants (M15 C3)

- **Owner:** buffy (`agent/buffy/m15-c3-snap-zones`)
- **Prompt / plan:** `docs/m17-desktop-completeness.md` C3 (issue #227)
- **Scope:** Arc 2 Window Management — pure compositor geometry in `driving_award.zig`. Drag a user window within 20 px of screen edges snaps to halves/quadrants on release, translucent preview while dragging, restore original size on drag-out. No new syscall, no new event kind, no heap, BSS `last_user_rect[8]` + `last_drag_zone` + `is_snapped` bitmap. Respects `dock=true` future and `D7` layering (snap preview below notification, above windows). Stacks on C2's `driving_award` changes.
- **Depends on:** C2 Alt+Tab overlay (✅ PR #251) — same file `driving_award.zig`, sequential; drag-to-move ✅ (pointer_tick).
- **Status:** 🔄 agent/buffy/m15-c3-snap-zones

## Notes

C3 is the second compositor-depth card. The window manager already supports drag-to-move (`pointer_tick` stores `drag_id`/`drag_offset`, `user_move` clamps). C3 adds snap:

- **State:** per-window `last_rect[8]` (x,y,w,h,valid) + `is_snapped[8]` + `current_snap_zone` enum (none/left/right/top/bottom/tl/tr/bl/br) + `snapped_from[8]` for restore. All BSS, no allocation.
- **Detection:** `snap_zone_for_point(x,y)` — corners first (20 px from both edges → quadrant), then edges (20 px from one edge → half). Precedence `last_drag_zone` avoids flicker when corner zones overlap edges.
- **Preview:** while `drag_id != null` and zone != none, `draw_chrome` paints a translucent accent overlay (30% alpha via checker, honest opaque preview for host test) showing target zone rect. Highlight is D7-correct (below notification, above windows).
- **Snap on release:** `pointer_tick` on `btn_released` with zone != none → `snap_window(did, zone)` — saves current rect to `last_rect[did]` if not already snapped, sets window x/y/w/h to zone bounds clamped to `user_buf_w`/`h` and `taskbar` exclusion, marks dirty, sets `is_snapped=true`.
- **Restore:** dragging a snapped window out (move beyond 20 px from snapped zone's edge) → restores `last_rect` before continuing drag, clears `is_snapped`. Host-tested pure `snap_zone_for_point` + `zone_bounds`.
- **Verification:** host tests for zone detection, bounds, snap/restore, BSS budget, and a class-B `verify-live-snap.sh` that drags via `--pointer` / `--input` chords and decodes the highlighted preview (like `verify-live-win-hig`). `just verify-bss-budget` headroom checked.

