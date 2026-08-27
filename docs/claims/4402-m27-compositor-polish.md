# Claim: M27 compositor polish — G1-G7 (about, previews, tooltips, sound)

- **Owner:** Buffy (`agent/buffy/m21-compositor`)
- **Prompt / plan:** `docs/march-m27.md`, `docs/agent-concurrency-plan.md` (Lane E)
- **Scope:** M27 G1-G7: boot splash, about dialog, window previews, sound design, sysmon, tooltips
- **Depends on:** M21 done ✅ (W1-W16 landed)
- **Heartbeat:** 2026-08-26
- **Status:** ✅ done 2026-08-26 — completed and merged under full M27 sweep (claim 8041, PR #591)

## Notes

Lane E owns `driving_award.zig` and `input.zig`.

**G1 — Boot splash:** Already exists (`render_splash`). First-boot wizard is in `settings_panel.zig` (not Lane E).

**G2 — About dialog:** Ctrl+Shift+A opens centered dialog. "DipshitOS", version, build date, credits, close button.

**G3 — Window previews in alt-tab:** 64×48 nearest-neighbor scaled thumbnails of each window's framebuffer. Overlay shows 4 across with preview + name.

**G4 — Sound design:** Compositor calls audio syscalls on window open/close, notification, error. Needs chime.zig integration.

**G5 — System monitor:** New userland app `sysmon.zig`. Not pure compositor.

**G6 — Tooltip system:** Hover 1s → tooltip appears. 32-char text, 4px below cursor. Disappear on mouse move.

All zero new syscall slots. Pure compositor paint.
