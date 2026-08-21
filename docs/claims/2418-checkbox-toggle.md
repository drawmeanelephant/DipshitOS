# Claim: Checkbox and Toggle widgets for ui.zig

- **Owner:** Muse Spark (`agent/buffy/arc1-checkbox-toggle`)
- **Prompt / plan:** `docs/m17-desktop-completeness.md` + GH #219
- **Scope:** Arc1 Widget Toolkit Depth — pure `user/src/lib/ui.zig` Checkbox (12×12) + Toggle (48×20 pill) per #219, no ABI, post-#218
- **Depends on:** M17 done (3046bc8) + Arc1 #218 ScrollView done (3046bc8), no dep on #234/#236
- **Status:** 🔄 `agent/buffy/arc1-checkbox-toggle`

## Notes

Implements Checkbox and Toggle per GH #219: Checkbox 12×12 box with filled square when checked, Toggle 48×20 pill accent/muted + 2-frame slide, both take *bool + rect, draw + click hit-test, zero heap. Host tests for toggle + visual state, no app integration required (SETTINGS.BIN toggle deferred to #234/C10 per grooming). Isolated demo via host test, keeps SETTINGS.BIN unchanged.
