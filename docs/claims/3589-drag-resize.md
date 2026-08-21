# Claim: Drag-to-resize window (bottom-right corner)

- **Owner:** Muse Spark (`agent/buffy/arc2-resize`)
- **Prompt / plan:** `docs/m17-desktop-completeness.md` + GH #224 — Arc2 Window Management deferred past M17
- **Scope:** Arc2 — `kernel/src/driving_award.zig` resize hit-test (6×6 at x+w-6,y+h-6) + resize_id/origin + clamp 128×64..512×384 + chrome repaint + `kernel/src/syscall.zig` slot 47 `sys_win_resize` + `kernel/src/events.zig` kind 10 `WIN_RESIZE` (ADR 0013 D1/D2). No dependency on #228/#236.
- **Depends on:** M17 done (main ff19197), ADR 0013 proposed (slot 47, kind 10). Verify `syscall.zig:78 implemented_count=47` and `events.zig:33 next free=10` at claim time.
- **Status:** ✅ done 2026-08-21 — drag-to-resize live on host (merge 44ca7d2): `driving_award` 6×6 hit + clamped resize + WIN_RESIZE kind 10 + `sys_win_resize` slot 47 (implemented_count 47→48), 4 host tests, `verify-bss-budget` PASS 9788088/11534336, `verify-coordination` PASS — branch `agent/buffy/arc2-resize` merged to `main` (commit 17e7951)

## Notes

Implements #224 per groomed issue: MOUSE_DOWN in 6×6 resize region → resize_id/origin like drag_id, MOUSE_MOVE computes clamped new_w/h, MOUSE_UP finalizes via sys_win_resize, apps receive WIN_RESIZE w/h. Owns driving_award resize geometry + syscall slot 47 + event kind 10. Zero heap, fixed BSS, host tests for clamp + hit-test, verify-bss-budget PASS.
