# Log — `agent/oxalpha/m20-text-unicode`

## 2026-08-25 — M20 closure claimed (U1–U5)

Claimed milestone-twenty close-out in
`docs/claims/8961-m20-u1-u5-live-gates.md`: flip the five march-m20
cards with live VZ evidence, complete U3's missing Ctrl+G scope, and
fix the red-on-main `verify-live-tabs.sh` (decoder handed to the
text-layer owners by the fleet-remainder log). Branch off origin/main
@ b5b5a98.

Reconnaissance findings recorded up front:

- Claim 5127 / PR #500 already landed the CODE for all five cards
  (three font sizes + slot 58, Latin-1+Ext-A glyphs at three sizes,
  notepad find bar + file-browser filter, chrome paint, tab stops +
  wcwidth). march-m20.md was never flipped and two cards never got a
  PASSing class-B gate — that is this claim's work.
- `verify-live-tabs.sh` red root cause (fleet log): the ScreenCaptureKit
  phase-search decoder loses grid alignment under the M20 geometry.
  Fix direction: decode the claim-0680 RAW scanout (`--cvc-snap`) at the
  known fixed origin (cell 8x8 from (0,0)) — deterministic, headless,
  no TCC permission, no activation wall.
- The claim-9588 custom-virtio INPUT queue carries the full HID mods
  byte and the runner's `--input-chords` accepts `ctrl-f`/`ctrl-g`
  tokens on that path — so modifier chords reach GUI windows headlessly
  for U3's gate. This is new territory (prior gates typed only into the
  terminal); feasibility probed before the gate is written.
- Coordination: kernel/src/monitor.zig, driving_award.zig, shell.zig,
  input.zig, build.zig are ACTIVE-held by claim 8777 — none are touched;
  docs/status.md is also 8777-held so milestone-row flips stay in
  march-m20.md + logs this branch.

## 2026-08-25 — U3 implemented + all five cards live-gated ✅

Code (userland only — no 8777-held files touched):

- `notepad.zig`: **Ctrl+G goto-line bar** (the one piece of march-U3
  scope that had never been implemented), mutually exclusive with the
  find bar; `line_start_offset`/`count_lines` host-testable helpers;
  bounded serial markers on find Enter (`notepad: find 'wor' hit=1/1`)
  and goto (`notepad: goto line=2 offset=6` / `miss lines=N`). Printables
  in the goto bar are swallowed, never leaked into the buffer. Tests:
  53/53.
- `file_browser.zig`: `apply_filter` now reports `file: filter '<pat>'
  shown=N total=M`; list rows highlight the matched substring under an
  active filter (`find_substring_ci`). Tests: 58/58.

New/rewritten class-B gates (all run on THIS Apple silicon macOS 27
host, evidence under `artifacts/live-*`):

- `verify-live-text-search.sh` PASS 2/2 — headline mechanism: ctrl-chords
  ride the claim-9588 custom-virtio INPUT queue whose kind-1 messages
  carry the HID modifier byte, so **Ctrl+F/Ctrl+G reach the focused user
  window headlessly** — the modifier wall does not apply on this path.
  Focus returns to the terminal via serial `dui focus 0` (serial input
  reaches the monitor regardless of window focus).
- `verify-live-tabs.sh` rewritten from red to green. Two root causes
  corrected en route (honest corrections to the fleet-remainder log):
  1. The "leading glyph loss" in decodes is REAL PIXEL ABSENCE — the
     M21/M27 vertical dock paints over terminal columns 0–2 of every
     row. It was never a decoder grid bug; `decode-screen-glyphs.py`
     docstring now records this.
  2. The Lane C putraw `\t` escape is DEAD CODE since the M19 P5 word
     tokenizer landed: unquoted `\X` unescapes to `X` before cmd_text's
     own backslash conversion can fire. text.zig tab rendering itself is
     intact and now proven live by passing a REAL tab through the
     tokenizer's double-quote `"…\t…"` escape. Probe row asserts the
     exact stop-16 landing with eight materialized spaces vs adjacent
     control. Evidence: `live-tabs-screen-{A,B}.raw`.
- `verify-live-chrome.sh` new, PASS 3/3 — chrome measured from
  claim-0680 raw scanouts: focused boot (M21-W9 accent ring, label ink,
  close glyph), unfocused boot (border EXACTLY 2px incl negative probe,
  16px title band bg, client bg distinct), boot C clicks the close glyph
  → `notepad: win_close`. Engineering note recorded in-gate: kind-4
  snapshots stream the LIVE framebuffer, so interactions must not be
  scheduled alongside a stream (first attempt corrupted its own frame).

Re-runs at HEAD for fresh evidence: font-sizes PASS 1/1, unicode PASS
1/1. Environment observation (pre-existing, NOT caused by this branch):
`verify-live-glyphs.sh` fails on this session's ScreenCaptureKit captures
(stale-frame family, claim 4769/fleet item 3); its PNG decode path is
byte-identical after my edit and the forward-rendering intent is proven
by the raw-snapshot gates at `fwd_unknowns=0`. Also noted for fresh
worktrees: gate-run seeds an EMPTY efi-vars.bin when artifacts/ has none,
which VZ rejects — seeded a valid store locally to run the glyphs gate;
worth a follow-up in whoever owns gate-run.sh.

Portable set green: fmt, verify-unit-tests (all modules), test-console
transcript byte-exact, inspect, bss-budget (1.45 MiB headroom),
coordination ok, context. march-m20.md rows flipped with evidence
pointers. docs/status.md deliberately untouched (held ACTIVE by claim
8777).
