# Claim 6156: WMS9 — Surface-seam perf: batched spans / raw-region push for text

- **Owner:** buffy (`agent/buffy/wms9-surface-seam-perf`)
- **Prompt / plan:** issue #629 (WMS9 of 10, phase 4 payoff) —
  `docs/march-m32-wm-migration.md` WMS9 row
- **Scope:** Kill the standing text-perf debt: the toolkit stops issuing one
  1×1 `sys_win_fill` per glyph pixel (64+ fills per 8×8 character in
  `user/src/lib/ui.zig draw_char` and `libui_so.zig`) and switches to batched
  spans / raw-region push on the surface seam. First measure slot 46
  `sys_win_fill_batch` (issue #205) as-is, extend its payload shape rather
  than adding a slot (ABI budget stays at 66). Pixel-identical output is the
  bar: LIBFONT.SO glyph metrics unchanged, all M20 text gates stay green.
  Host tests: span batcher correctness (clipping, wrap, color runs) against
  the mock canvas pattern.
- **Touches:** `user/src/lib/ui.zig`, `user/src/libui_so.zig`,
  `kernel/src/syscall.zig` (slot-46 payload growth if needed),
  `kernel/src/driving_award.zig` (batch handler only), measurement artifact,
  claim + log
- **Depends on:** WMS7 (toolkit re-pointed; seam shape final), WMS8 Gate 6
  (claim 3687)
- **Heartbeat:** 2026-08-30
- **Status:** 🔄 `agent/buffy/wms9-surface-seam-perf`

[Result to be filled on completion.]
