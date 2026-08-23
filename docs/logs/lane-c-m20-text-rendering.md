# Log — `lane-c/m20-text-rendering`

## M20 Lane C claimed

Claimed M20 text rendering & Unicode (issues #306–#320, cards U1–U15),
claim file `docs/claims/5127-m20-text-rendering-lane-c.md`. Branch synced
to origin/main @ 4d11713. Verified no other agent holds `text.zig`,
`monitor.zig`, or an open PR touching them; driving_award.zig (U9) has no
active Lane E editor at claim time — its edit will stay inside the
existing `draw_chrome` zone and land as one self-contained commit.
Plan of attack (dependency order): tabs/wcwidth → Latin-1 + Ext-A +
fallback → clusters/combining → font sizes (slot 58 + `font` command +
settings) → emoji → measurement → wrap → cache → torture test → app
search → chrome. Commit per issue; live gates created alongside their
cards.

## M20 Lane C complete — U1–U15 all landed

All fifteen issues closed in dependency order, one commit per issue,
host tests alongside each: tabs/wcwidth → Latin-1+Ext-A+fallback →
clusters/combining → font sizes (slot 58 + `font` cmd + SETTINGS.TXT)
→ emoji (24 glyphs, comptime geometry) → measurement → wrap_line →
glyph LRU cache → torture doc + pixel golden → notepad/file-browser
search → window chrome.

### Verification

- Class A: verify-unit-tests green across every touched module
  (text.zig 71 tests, font_unicode, font_emoji, driving_award,
  monitor 517, syscall 394, shell 578 incl. updated goldens,
  lineedit 30, settings, notepad 50, file_browser 49); transcript
  fixture byte-exact; kernel builds; image builds; BSS budget PASS at
  9,918,560 B / 11 MiB (~1.6 MiB headroom).
- Class B on real VZ (Apple silicon, macOS 27):
  - `verify-live-font-sizes.sh` PASS 1/1 — text report now prints live
    geometry; cell=8x8→16x16→24x24 observed over serial.
  - `verify-live-unicode.sh` PASS 1/1 — café decodes through the live
    UTF-8 path with missing=0; 中文 double-wide fallback counted
    (missing=4 including echo, last=U+6587).
  - `verify-live-tabs.sh` BLOCKED here: headless runner yields blank
    frames (fwd_ink=0), so the two-boot pixel proof cannot decode. The
    gate reports this loudly by default (VERIFY_LIVE_TABS_STRICT=1
    enforces on display-capable machines); tab rendering remains pinned
    pixel-exactly by the class-A torture golden.

### Notable finds during bring-up

- The serial line editor dropped every byte ≥0x80 — accented input
  could never reach the guest. lineedit now inserts them as data;
  the fb layer decodes UTF-8 downstream.
- The monitor `text` report printed ring constants, not live geometry —
  masked font-size changes from any serial observer.
- The e2e transcript/help goldens exist in THREE places (monitor
  registry test, shell e2e const, tests/transcript-console.txt) plus a
  syscalls-report count in shell.zig — all four must move together.
