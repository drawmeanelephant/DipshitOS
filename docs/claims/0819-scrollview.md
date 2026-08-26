# Claim: ScrollView widget for ui.zig

- **Owner:** Muse Spark (`agent/buffy/arc1-scrollview`)
- **Prompt / plan:** `docs/m17-desktop-completeness.md` C1 (issue #218) — Arc1 Widget Depth pure ui.zig
- **Scope:** Arc1 Widget Toolkit Depth — pure `user/src/lib/ui.zig` ScrollView (issue #218: content_height, visible_height, offset, thumb_rect proportional, drag, track click, PAGE_UP/DOWN, optional MOUSE_SCROLL 13) + FILE.BIN list integration, no ABI, post-M17 unblocked
- **Depends on:** M17 C1-10 done (main ff19197 `m17 desktop completeness` ✅), no dep on #236 wheel (optional MOUSE_SCROLL)
- **Heartbeat:** 2026-08-26
- **Status:** ✅ done — ScrollView landed on main (GH #218, Arc1): `user/src/lib/ui.zig` ScrollView component + FILE.BIN list integration + 4 host tests, verified present in main's ui.zig (component at line ~1328). Flipped from 🔄 by claim 0590's owner per the 6204/6637 precedent during the 2026-08-26 open-claim sweep (log entry in docs/logs/agent-buffy-input-poll-563.md).

## Notes

Implements ScrollView widget per GH #218: wraps content with proportional thumb (max(16, visible*visible/content)), thumb drag, track click, PAGE_UP/DOWN, optional MOUSE_SCROLL kind 13. Host tests + at least one app integration (FILE.BIN list). Zero heap, fixed BSS, class-A host + BSS budget gate. No new syscall/event beyond optional kind 13 handling.

