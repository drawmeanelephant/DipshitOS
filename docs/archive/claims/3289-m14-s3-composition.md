# Claim: Milestone 14 Card S3 — the composition capstone: NOTEPAD copy/paste with a timer-driven cursor

- **Owner:** buffy (`freebuff/m14-s3-composition`)
- **Prompt / plan:** `docs/march-m14.md`
- **Scope:** Milestone 14, Card S3 (Issue #177: composition capstone — S1+S2
  proven together in a real app; NOTEPAD copy/paste rides the shared kernel
  clipboard while its cursor blinks on the per-process application timer)
- **Depends on:** S1 (claim 0169, slots 38/39) + S2 (claim 7323, slots
  40/41) — both merged in PR #182
- **Status:** ✅ done 2026-08-18 — NOTEPAD paste + copy (S1) and the timer-driven cursor blink (S2) proven together in ONE EL0 session on VZ: `tools/verify-live-m14-composition.sh` PASS 1/1 — `selfdemo pasted` → `selfdemo copied` → 6 `cursor blink` TIMER events (arm + re-arm, `sys_timer_set calls=7`) → `selfdemo done` → exit 43, and the syscalls report shows `implemented=42` with `sys_clipboard_set calls=1` / `sys_clipboard_get calls=1` / `sys_timer_set calls=7`

## Notes

S1 and S2 each proved their seam with a dedicated proof program. S3 is the
composition card: the SAME app, NOTEPAD, uses both facilities at once, so a
live gate can show copy/paste (clipboard) and a blinking cursor (app timer)
working together in one EL0 program — the "apps stop spinning" promise of
the M14 arc, realized in the flagship text app.

- NOTEPAD arms its per-process timer once at startup and, on every `TIMER`
  event (kind 9 on the ADR 0009 queue), toggles the cursor's visibility and
  re-arms for the next tick — the cursor blinks on the kernel's scheduler
  tick, not a `sys_sleep` spin loop. The blink state machine is host-tested
  at class A (blink on/off transitions, re-arm on fire, timer failure → the
  cursor stays visible, never a hard hang).
- Copy/paste is the S1 half: NOTEPAD's Ctrl+C/Ctrl+X/Ctrl+V chords
  (whole-buffer, claim 0169's honest bound) ride the shared kernel
  clipboard, proven live in a real editing session.
- Live gate `tools/verify-live-m14-composition.sh`: exec NOTEPAD on VZ, arm
  the clipboard via the terminal (`clip ...`), drive the copy/paste chords
  into the focused window, and observe BOTH facilities in one session — the
  blink markers (timer-driven) + the paste markers (clipboard-driven) — then
  the `syscalls` report shows `implemented=42` with slots 38–41 all counted
  in the same boot.

## Result

- Class A green (fmt; notepad module 21/21 incl. the blink state-machine
  tests; unit suite; byte-identical transcript; build + image;
  coordination).
- Class B `tools/verify-live-m14-composition.sh` **PASS 1/1 on VZ**: the
  gate pre-loaded the clipboard with the terminal's `clip` command, exec'd
  `NOTEPAD.BIN selfdemo`, and observed the SAME app paste (S1 read),
  copy (S1 write), and blink (S2) — 6 TIMER events with the cursor
  toggling on each, the demo completing, and NOTEPAD exiting status 43
  through the real lifecycle. The syscalls report in the same boot shows
  `implemented=42` with slots 38/39/40 all counted (`sys_clipboard_set
  calls=1`, `sys_clipboard_get calls=1`, `sys_timer_set calls=7`).
- Input-seam note (issue #179): the synthesized keyboard route reports
  `events=0` on this machine (reproduced on a fresh boot 2026-08-18 — the
  runner's KEY-SEQ claims ok=true, the guest ring stays empty), so the gate
  drives the composition through NOTEPAD's argv `selfdemo` mode (claim
  4636's entry contract) rather than scripted Ctrl+C/V chords, and records
  the seam state in the report. The chord path is unchanged and host-tested
  (claim 0169's keyboard tests); it regains live coverage when the seam
  recovers.
