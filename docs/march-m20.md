# Milestone twenty march — text rendering & Unicode (living tracker)

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts. This file holds M20's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

M18–M19 gave us a powerful terminal and shell. But the text rendering is
still stuck at 8×8 ASCII — one font size, one character set. The compose
sequences from ADR 0014 produce Unicode codepoints that can't be *displayed*
because `text.zig` only knows about glyphs 0x00–0x7F. Window chrome is
functional but inconsistent. M20 fixes all of this.

**One new syscall slot** for font size (58). The rest is pure userland.

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| U1 | **Multiple font sizes.** Three bitmap font sizes: 8×8 (current default), 16×16 (2×), and 24×24 (3×). `font small/medium/large` command switches. Per-window font size via slot 58 `sys_font_size(id, size)`. All three sizes are comptime-generated from the existing 8×8 glyphs (nearest-neighbor scaling). | ⬜ | — | Kernel: slot 58 `sys_font_size(id, size)`. `text.zig` gains three font tables (comptime generated). The `font` shell command and the syscall both call the same setter. Font size affects line spacing and character width for that window. |
| U2 | **Unicode glyph table.** Extend `text.zig` to render Latin-1 Supplement (U+0080–U+00FF) and Latin Extended-A (U+0100–U+017F). Compose sequences (ADR 0014) now display their output. Glyphs are comptime-generated bitmap tables at 8×8, 16×16, and 24×24. | ⬜ | — | `text.zig` comptime Unicode lookup. ~190 new glyphs × 3 sizes. The existing ASCII range (U+0000–U+007F) is unchanged. The glyph table is a `comptime` array keyed by codepoint. |
| U3 | **Text search in apps.** Ctrl+F in NOTEPAD opens the find bar (extend M17 C6). Ctrl+G goes to a specific line. FILE.BIN preview highlights the searched filename. The find bar works on the visible buffer and the scrollback. | ⬜ | — | Pure `notepad.zig` and `file_browser.zig` changes. Extends the existing find-bar widget from C6. |
| U4 | **Improved window chrome.** 2-pixel border (up from 1px), 16px title bar (up from 8px), 8×8 close button glyph in the title bar, drag-from-title-bar to move (extend current pointer grab). Consistent look across all windows. | ⬜ | — | `driving_award.zig` paint changes only. No ABI. The title bar and close button are drawn during the composite pass. |
| U5 | **Monospace rendering.** Proper tab-stop alignment (8-char tabs) in the terminal and text apps. Fix the current proportional-width artifacts where some characters take different widths. All characters are guaranteed 8px wide at 8×8. | ⬜ | — | `text.zig` tab-stop logic. `shell.zig` tab rendering. Ensures the monospace invariant: every codepoint renders at exactly the font's cell width. |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Font & Unicode** | `kernel/src/text.zig` for U1 (font sizes) + U2 (Unicode glyphs) + U5 (monospace). These are deeply intertwined in the same rendering path. | M18 done. |
| **B — App improvements** | `user/src/notepad.zig` + `user/src/file_browser.zig` for U3 (text search). `kernel/src/driving_award.zig` for U4 (window chrome). | U1 (font sizes affect chrome dimensions). |

## Notes

1. **ABI budget:** 1 new syscall slot (58) for `sys_font_size`.
   Cumulative: 59/64 after M20.
2. **BSS budget:** Three font tables at 3 sizes. 8×8 = existing. 16×16:
   256 bytes × 190 glyphs = ~48.6 KiB. 24×24: 72 bytes × 190 glyphs =
   ~13.7 KiB. Unicode lookup: ~380 bytes (190 × 2 bytes codepoint mapping).
   Total M20 BSS delta: ~62.7 KiB. This is the largest single-milestone
   BSS add — review against the 11 MiB budget.
3. **Gate shape:** U1: `verify-live-font-sizes.sh` — font switch observed in
   terminal output. U2: `verify-live-unicode.sh` — compose character rendered.
   U3: `verify-live-text-search.sh` — NOTEPAD find highlights match. U4:
   `verify-live-chrome.sh` — title bar dimensions verified. U5:
   `verify-live-tabs.sh` — tab alignment verified.
4. **Glyph generation:** The 8×8 base glyphs exist in `text.zig`. The 16×16
   and 24×24 versions are generated at comptime by 2× and 3× nearest-neighbor
   scaling of the 8×8 source. This keeps the font data in a single source
   of truth.
5. **Scope exclusions:** No anti-aliasing (bitmap fonts stay crisp). No
   variable-width fonts (monospace only). No CJK, Cyrillic, or Arabic —
   Latin only for now. No font file loading (all comptime).
