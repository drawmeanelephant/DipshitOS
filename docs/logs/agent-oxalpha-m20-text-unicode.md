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
