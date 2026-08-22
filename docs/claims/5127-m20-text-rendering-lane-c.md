# Claim: M20 text rendering & Unicode (Lane C — U1–U15)

- **Owner:** ox-alpha (`lane-c/m20-text-rendering`)
- **Prompt / plan:** `docs/agent-concurrency-plan.md` Lane C (Phase 2);
  GitHub issues #306–#320; card detail in `docs/march-m20.md`
- **Scope:** milestone twenty — multiple font sizes (U1), Latin-1
  Supplement + Latin Extended-A glyph tables (U2/U3), wcwidth (U4),
  grapheme clusters (U5), zero-width/combining handling (U6), basic emoji
  (U7), app text search (U8), window chrome (U9), monospace/tab stops
  (U10), missing-glyph fallback (U11), text measurement API (U12), glyph
  cache (U13), Unicode torture test (U14), line breaking (U15). One new
  ABI slot: 58 `sys_font_size`. Primary file: `kernel/src/text.zig`;
  new files `font_unicode.zig` / `font_emoji.zig`; small self-contained
  additions to `monitor.zig` (`font` command), `syscall.zig` (slot 58,
  append-only), `settings.zig` (persistence), `notepad.zig`/
  `file_browser.zig` (U8), `driving_award.zig` (U9 chrome — coordinated:
  no Lane E agent active at claim time, changes kept to the existing
  `draw_chrome` zone).
- **Depends on:** M18 done ✅ (per plan Lane C is Phase 2 after M19, but
  the lane owns disjoint files from shell.zig; no Lane A agent is
  editing shared files at claim time — verified via open PR/branch list)
- **Status:** 🔄 in progress

## Notes

Why: every visual milestone downstream (M21 tiling, M27 previews) needs
font sizes and Unicode working; this is the fast lane to unblock the
compositor. The compose sequences from ADR 0014 produce codepoints that
cannot display today because the render path drops everything >0x7e.

Verification per card: host unit tests under `just test` /
`tools/verify-unit-tests.sh` (text.zig is a listed module); class-A
portable gates (`just verify-portable`); BSS budget gate (headroom at
claim time: 1,688,992 B of 11 MiB); new live gates
`verify-live-font-sizes.sh`, `verify-live-unicode.sh`,
`verify-live-tabs.sh` on real VZ where the harness allows.

Honest bounds recorded up front: comptime font tables are ROM, not BSS;
the ring widening for codepoint storage (~80 KiB) and the glyph cache
(~18 KiB) are the real BSS movers. No anti-aliasing, no proportional
fonts, Latin script only, emoji subset bounded by hand-authored art.
