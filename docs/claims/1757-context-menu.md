# Claim: Right-click context menus

- **Owner:** Muse Spark (`agent/buffy/arc2-context-menu`)
- **Prompt / plan:** `docs/m17-desktop-completeness.md` + GH #228 — Arc2 Window Management deferred past M17 (needs ABI)
- **Scope:** Arc2 — `user/src/lib/ui.zig` ContextMenu widget (items[]{label,callback}, show(x,y), dismiss on outside click, z-order above windows like #223 dropdown) + `kernel/src/events.zig` kinds 11 `MOUSE_RIGHT_DOWN` + 13 `MOUSE_RIGHT_UP` (ADR 0013 D2 — kind 12 is MOUSE_SCROLL) + compositor right-button delivery + NOTEPAD/FILE.BIN/TOP.BIN integration. No dependency on #224/#226.
- **Depends on:** M17 done, ADR 0013 proposed (kinds 11/13). Verify events.zig next free=10 at claim time; BTN_RIGHT already in hid report (events.zig:47). Syscall not needed (events only).
- **Status:** 🔄 `agent/buffy/arc2-context-menu`

## Notes

Implements #228 per groomed issue: kernel posts MOUSE_RIGHT_DOWN/UP to focused window (right button already in HID report), ui.zig ContextMenu renders at click position with outside-click dismiss, app integration copy/cut/paste etc. Owns ui.zig ContextMenu + events kinds 11/13. Zero heap, fixed BSS, host tests for menu show/dismiss + hit-test.
