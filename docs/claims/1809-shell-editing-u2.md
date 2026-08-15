# Claim: milestone eight, card U2 — shell editing & history (ADR 0008 D2)

- **Owner:** buffy (`freebuff/can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc`)
- **Prompt / plan:** `docs/march-m8.md` U2 row — the line editor + input keymap
  card, implementing ADR 0008 D2 on top of U0/U1 and the I3 input path.
- **Scope:** `kernel/src/lineedit.zig` (bounded history ring, cursor movement,
  Ctrl-A/E/K/U/L, Delete, tab completion via a completer callback),
  `kernel/src/input.zig` (arrow/Home/End/Delete usages + Ctrl-chord modifier
  decoding), `kernel/src/text.zig` (honor `\b`/`\r` so erase + redraw render on
  the framebuffer), `kernel/src/shell.zig` (wire the completer to the registry
  + a bounded sub-verb table), and the runner's new `--input-chords` seam. No
  syscalls, no ADR 0007 change.
- **Depends on:** U0 (ADR 0008, claim 8938), I3 (input path, claim 6050).
- **Status:** ✅ done 2026-08-14

## Notes

The byte seam is preserved exactly for the unchanged paths: typing at end of
line still echoes one byte per char; backspace still emits `\b \b`; submit
`\r\n`; cancel `^C\r\n` — the transcript fixture stays byte-identical. Editing
operations are deterministic byte sequences (`\x08` = left, `\x1b[C` = right,
full-line redraw for mid-line insert/delete + history recall), so the live gate
asserts them exactly.

## Verified

- **Class A** — `zig fmt --check` clean; `verify-unit-tests.sh` green (input
  391→392: `hid_to_bytes` nav-cluster + ctrl-chord tests; lineedit gains the
  full D2 surface — history recall/draft, cursor left/right/Home/End, Ctrl-
  A/E/K/U/L/C, Delete, tab completion); `zig build test-console` byte-
  identical transcript; `zig build`/`image`/`inspect`/`context` + `swift
  build` + `verify-coordination` + `test-coordination` + `verify-mmu-debt` +
  `decode-screen-glyphs.py --self-test` all green.
- **Class B** — `tools/verify-live-editing.sh` **PASS 1/1 on VZ**: a scripted
  `--input-chords` sequence (`echo ab` + Left + `c` + Enter, Up + Enter,
  `echo u2done` + Enter) typed by a real VZ keyboard drove mid-line insert
  (`echo acb` → `acb`) and history recall (Up re-ran it → `acb` a second
  time) over the XHCI transport, asserted by the guest's own output
  (`acb` x2, `u2done` x1, `input: armed`, the serial marker, and the
  runner's `input-chords: ENABLED` flag line). The default VM stays
  byte-identical (no `--input` → `config.keyboards/pointingDevices` stay
  `[]`).
- **Root-caused + fixed en route** a latent I3 bug this card's longer
  sequence exposed: `xhci_arm_intr` computed the report-buffer slot from the
  PRE-wrap interrupt-ring enqueue pointer, so the re-arm after the ring's
  Link-TRB boundary read `intr_slots[slot][tr_usable]` (one past the array)
  and pointed the TRB at garbage — VZ then wrote the next report to the wrong
  address and the guest re-read the stale slot-0 buffer (the first `e`
  report), producing the phantom `e` that corrupted both edited lines. Fix:
  a pure `intr_slot_index` wrap helper (unit-tested) used by
  `xhci_arm_intr`. After the fix the gate is clean (`acb` x2, `done=1`).
