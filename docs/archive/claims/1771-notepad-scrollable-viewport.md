# Claim: NOTEPAD.BIN — scrollable text viewport, visible cursor, and line wrapping

- **Owner:** buffy (`agent/buffy/m11-notepad-scroll`)
- **Prompt / plan:** Phase A card from the post-M11 apps review: NOTEPAD gets a scrollable text viewport with a visible cursor and line wrapping, with class-A tests.
- **Scope:** `user/src/notepad.zig` (TextLayout model + draw + input routing + tests), `docs/logs/agent-buffy-m11-notepad-scroll.md`
- **Depends on:** milestone eleven (NOTEPAD.BIN, claim 3234) — pure userland, no kernel change
- **Status:** ✅ done

## Notes

The M11 NOTEPAD clips text past the bottom of the editor box with no way to
reach it, and cursor navigation is left/right only. This card adds a
wrap-aware text layout model:

- **Line wrapping:** a display row holds `cols` glyphs (29 at 8px in the
  232px text box); the model and the renderer share the same wrap rule, so
  what you navigate is what you see.
- **Scrollable viewport:** `TextLayout.scroll` is the first visible display
  row; `visible_rows` (11) rows render, with a scrollbar thumb when content
  overflows. Cursor movement auto-scrolls (`ensure_visible`) so the cursor
  is never clipped off-screen.
- **Visible cursor + navigation:** Up/Down/Home/End/PageUp/PageDown move
  across *display* rows preserving column (clamped to each row's length);
  Ctrl+A/Ctrl+E jump to buffer start/end; forward-Delete added; clicking in
  the editor places the cursor via `offset_at`.
- **PageUp/PageDown keys** (HID usages 0x4b/0x4e) already flow through the
  kernel event path as KEY_DOWN (arg0 = usage), so no kernel change is
  needed — they scroll by a viewport.

Class-A host tests cover the layout mapping (wrap/newline/empty/edge rows),
row bounds, column-preserving navigation, ensure_visible auto-scroll,
offset_at click mapping, forward-delete, and keyboard routing.

Live behavior is unchanged for the M11 desktop gate (the `notepad: ready`
marker still prints); this is a pure userland enhancement.
