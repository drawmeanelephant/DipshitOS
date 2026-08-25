# Claim: M20 closure — U1–U5 live gates + U3 goto-line completion

- **Owner:** ox-alpha (`agent/oxalpha/m20-text-unicode`)
- **Prompt / plan:** `docs/march-m20.md` (the five cards U1–U5)
- **Scope:** milestone twenty end-to-end close-out. The Lane C pass
  (claim 5127, PR #500) landed the code for all five cards but the march
  tracker still reads ⬜ across the board and two cards lack a PASSing
  class-B gate. This claim closes each card the only way the rules
  accept: a live VZ run on real Apple silicon, guest-observed evidence
  under `artifacts/`.
  - U1 font sizes: re-run `tools/verify-live-font-sizes.sh` at HEAD,
    fresh artifacts, flip the row.
  - U2 Unicode glyphs: re-run `tools/verify-live-unicode.sh` at HEAD,
    fresh artifacts, flip the row.
  - U3 text search: complete the card's missing scope — Ctrl+G
    goto-line in NOTEPAD (no implementation exists; Ctrl+F find bar and
    the FILE.BIN filter landed with Lane C) — plus bounded serial
    marker seams on notepad find/goto and file-browser filter so a
    class-B gate can assert guest-observed behavior over serial.
    New gate `tools/verify-live-text-search.sh` driving REAL ctrl-chords
    through the custom-virtio INPUT queue (`--via-virtio --input-chords`,
    claim 9588's transport carries the HID mods byte, so Ctrl+F/Ctrl+G
    are deliverable headlessly — no activation wall).
  - U4 chrome: the 2px border / 16px title bar / centered label /
    close-glyph paint landed (driving_award `draw_chrome` zone). New
    gate `tools/verify-live-chrome.sh` measuring chrome geometry from
    byte-exact guest scanouts (`--cvc-snap` raw frames, claim 0680 —
    no ScreenCaptureKit, no TCC, no activation wall) plus a behavioral
    click-close differential inside vs below the title strip.
  - U5 monospace/tabs: `tools/verify-live-tabs.sh` is red-on-main
    (fleet log 2026-08-24: pixel decode never sees the probe row;
    every decoded line loses leading glyphs — decoder grid-search vs
    the M20 fixed 8px-cell geometry). Fix: deterministic decode of the
    RAW scanout at the known origin (0,0) pitch 8 instead of the lossy
    ScreenCaptureKit phase search; `decode-screen-glyphs.py` grows a
    `--raw W H` mode (PNG path untouched for verify-live-glyphs.sh).
- **Touches:** user/src/notepad.zig, user/src/file_browser.zig, tools/verify-live-text-search.sh, tools/verify-live-chrome.sh, tools/verify-live-tabs.sh, tools/decode-screen-glyphs.py, docs/march-m20.md, docs/logs/agent-oxalpha-m20-text-unicode.md
- **Depends on:** claim 5127 ✅ (all five cards' code merged via #500); claim 0680 ✅ (snapshot channel); claim 9367 ✅ (virtio input transport)
- **Heartbeat:** 2026-08-25
- **Status:** ✅ done 2026-08-25 — all five march-m20 cards live-gated on
  real Apple silicon VZ at HEAD: U1 font-sizes PASS 1/1, U2 unicode PASS
  1/1, U3 text-search PASS 2/2 (Ctrl+G goto-line landed; find/filter
  serial markers), U4 chrome PASS 3/3 (raw-scanout metrics + close
  click), U5 tabs PASS 2/2 (was red-on-main; rewritten onto claim-0680
  raw scanouts). Two cross-milestone findings recorded in the log and
  gate docstrings: dock occlusion of terminal columns 0–2 (the real
  "leading glyph loss"), and the putraw `\t` seam dead since the M19 P5
  tokenizer unescape.

## Notes

Why now: march-m20.md is the last experience-layer tracker whose rows
were never reconciled with merged reality, and its U5 gate is the one
red-on-main class-B gate (handed to the text-layer owners by the fleet-
remainder log). Every visual milestone downstream (M21 tiling sweeps)
consumes these surfaces.

Coordination bounds: kernel/src/monitor.zig, driving_award.zig,
shell.zig, input.zig and build.zig are deliberately NOT touched — they
are declared ACTIVE by claim 8777 (t3code window-gate sweep). All five
cards close without editing them: U1/U2/U4/U5 code already landed; U3
is pure userland (notepad/file_browser) + tools.

Verification per card: class-B live gate run on this Apple silicon
macOS 27 host, artifacts under `artifacts/live-*`; host unit tests for
the new notepad/goto logic; portable set green before push.

Gate naming follows the tracker's own Note 3 shapes
(`verify-live-font-sizes/unicode/text-search/chrome/tabs.sh`) — the
existing descriptive convention, not literal u<N> filenames.
