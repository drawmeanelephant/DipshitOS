# Claim: Horizontal ScrollBar widget for ui.zig (GH #222)

- **Owner:** Muse Spark (`agent/buffy/arc1-progressbar`)
- **Prompt / plan:** `docs/m17-desktop-completeness.md` Arc1 + GH #222
- **Scope:** Arc1 pure `user/src/lib/ui.zig` HScrollBar — offset/content_width/viewport_width, 8px track at bottom, thumb proportional viewport/content (min 16), drag-to-scroll, track click page left/right by viewport, optional Shift+MOUSE_SCROLL (kind 13) horizontal, no new ABI/event, host tests + BSS budget, combine with ScrollView in FILE.BIN 2D nice-to-have
- **Depends on:** M17 done, #218 ScrollView + #219 Checkbox/Toggle done, #220 ProgressBar done (same branch)
- **Status:** ✅ done 2026-08-21 — `user/src/lib/ui.zig` HScrollBar + 4 host tests, `zig test` 29/29, `verify-bss-budget` 9788088/11534336, `verify-coordination` PASS

## Notes

Implements HScrollBar per GH #222 grooming: horizontal analog of ScrollView, rect is track (8px high per spec), `content_w/viewport_w/offset`, `max_offset=content-viewport` (0 if fits), `thumb_w=max(16, rect.w*viewport/content)`, `thumb_x=rect.x + offset*(rect.w-thumb_w)/max`, `thumb_rect`, `track_contains`, `scroll_by` clamp, `handle_event` MOUSE_DOWN thumb drag (drag_start_x/offset) or track page left/right by viewport, MOUSE_MOVE scales `delta*max/track_w`, MOUSE_UP end drag, KEY_DOWN Left0x50/Right0x4f ±16, Home0x4a/End0x4d, optional MOUSE_SCROLL kind13 Shift+horizontal (MOD_SHIFT flag or packed 0x4000) with simple bitcast delta fallback (mirrors ScrollView). Host tests: proportional thumb (60/30 + fits/clamp/min16), track page + drag scaling (40px drag →100 offset), Shift+scroll (+16) + without Shift ignored + left/right/home/end + clamp when fits, 2D demo with ScrollView (vertical+horizontal offset + drag to max + draw no panic). Zero heap, pure BSS, FILE.BIN 2D nice-to-have deferred. Verified: `zig test` 29/29, `zig fmt` PASS, `zig build` PASS, `verify-bss-budget` 9788088/11534336.
