# Log — `agent/buffy/m14-s3-composition`: the composition capstone (claim 0120)

## 2026-08-19 — branch opened

- Claimed (claim 0120): Milestone 14 card S3 — the composition capstone
  (issue #177). Prove NOTEPAD's clipboard copy/paste (S1) + timer-driven
  cursor blink (S2) together live on VZ. No ABI change: a `clipboard`
  monitor command, NOTEPAD serial markers + Ctrl+Q quit, and the gate
  `tools/verify-live-m14-composition.sh`.
- Branch based on `agent/buffy/m14-s2-timers` (PR #196 — M14 S2 — carries
  the timer + clipboard work; S3 layers the capstone on top, so S3's PR
  depends on S1 and S2 merging first).

## 2026-08-19 — the keyboard chord wall, then the `dui key` seam

- First cut drove NOTEPAD via `--input-chords "h,e,l,l,o,ctrl-c,ctrl-v,ctrl-q"`.
  The live run hit the claim-0935 modifier wall: the synthesized Ctrl chords
  arrive as PLAIN letters (VZ drops the modifier flags on a synthesized
  keyDown), so NOTEPAD typed "c", "v", "q" instead of copying/pasting/quitting.
  The `--input-string` path (plain letters) works — only modifiers are dropped.
- Tried an argv `demo` mode in NOTEPAD instead. It was refused at exec time:
  `error: image leaves no room for the argv block (256 bytes)` — NOTEPAD.BIN's
  content (8175 bytes) overflows the 2-page text leaf once a 256-byte argv
  block is packed after it (claim-4636's `no_args_room` bound). Reverted.
- Landed on the honest, precedent-consistent seam: a `dui key
  <char|copy|cut|paste|quit>` subcommand that pushes a synthetic `KEY_DOWN`
  into the focused window's event queue — the U5 `dui cycle` precedent
  (synthesizing the Alt+Tab focus signal the keyboard cannot deliver)
  generalized to key chords. It exercises NOTEPAD's real `handle_keyboard_event`
  (the interactive path), one layer above the HID→modifier translation VZ
  drops. The interactive Ctrl-C/Ctrl-V/Ctrl-Q decode is host-tested in
  notepad.zig.
- The gate now: `exec NOTEPAD.BIN` → `dui key h/e/l/l/o` (type) → `dui key
  copy` (Ctrl+C) → `dui key paste` (Ctrl+V) → `dui close 2` (WIN_CLOSE →
  exit 43) → `clipboard` + `syscalls` (byte-exact + counts).
- A cosmetic `0x` double-prefix in the `dui key` report (`flags=0x0x0`) was
  fixed (print_hex_min already emits the prefix).

## 2026-08-19 — live PASS

- Class A green: fmt, 463 console tests + 22 unit tests (incl. the monitor
  `clipboard`/`dui key` commands), byte-identical transcript,
  build/image/inspect, swift build, coordination.
- `bash tools/verify-live-m14-composition.sh` PASS 1/1 on VZ:
  `notepad: copy ok` → `notepad: paste ok` → `notepad: blink` (timer) →
  `clipboard: len=5 'hello'` byte-exact → `sys_clipboard_set calls=1`,
  `sys_clipboard_get calls=1`, `sys_timer_set calls=1` →
  `tasks user-exec exited status=43`. Screenshot evidence captured
  (`artifacts/gpu-screen-after`).
