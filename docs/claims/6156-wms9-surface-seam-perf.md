# Claim 6156: WMS9 — Surface-seam perf: batched spans / raw-region push for text

- **Owner:** buffy (`agent/buffy/wms9-surface-seam-perf`)
- **Prompt / plan:** issue #629 (WMS9 of 10, phase 4 payoff)
- **Scope:** Replace per-pixel `sys_win_fill` (slot 13) in `draw_char`/`draw_char_16`/`draw_rect` with batched spans via slot 46 `sys_win_fill_batch` (payload extended, no new slot). Pixel-identical output; LIBFONT.SO metrics unchanged; M20 text gates stay green.
- **Touches:** `user/src/lib/ui.zig`, `user/src/libui_so.zig`, `kernel/src/syscall.zig`, `kernel/src/driving_award.zig` (batch handler only), measurement artifact, claim + log
- **Depends on:** WMS7 (toolkit re-pointed), WMS8 Gate 6 (claim 3687)
- **Heartbeat:** 2026-08-30
- **Status:** 🔄 `agent/buffy/wms9-surface-seam-perf`

[Result to be filled on completion.]
