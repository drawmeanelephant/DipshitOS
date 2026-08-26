# Claim: devcons-typed-input-proof

- **Owner:** buffy (`agent/buffy/input-poll-563`)
- **Prompt / plan:** `docs/claims/0590-devcons-typed-input-proof.md`
- **Scope:** issue #553 — extend `verify-live-devcons.sh` to type a command at the DEVCONS.BIN in-window prompt and assert the command echo + output appear in the log pane (the D14 asterisk in `docs/march-m22.md`). The blocker (#179, synthesized keyboard seam events=0) is closed; the claim 9588 custom-virtio INPUT channel productionized and proven by the #563 typing gate.
- **Touches:** tools/verify-live-devcons.sh
- **Depends on:** issue #179 (closed), claim 1382/#563 typing-gate pattern (input-string-after + heartbeat-tick screenshot/script2 phasing)
- **Heartbeat:** 2026-08-26
- **Status:** ✅ done 2026-08-26 — `verify-live-devcons.sh` PASS 2/2 with the issue #553 typed-input phase: after `devcons: ready`, `dir.bin\n` is typed at the in-window prompt over the claim 9588 custom-virtio INPUT queue; the app buffers the 7 printable chars + Enter (`input` report events=8), executes `dir.bin` via sys_exec (child prints `dir: listing /data` + `dir: success` on serial), and the `> dir.bin` + `exec: ok (output on serial)` echoes render in the log pane (screenshot pixel proof: white text rows y 54..202 in the 2x window, 493 samples).

  The typed-input phase CAUGHT A REAL PRE-EXISTING BUG (the gate's entire purpose): DEVCONS.BIN's KEY_DOWN handler compared `ev.arg0` — the raw HID usage (0x07 for 'd', 0x28 for Enter) — against ASCII ranges (`0x0a/0x0d`, `0x20..0x7f`), so every printable key was rejected and Enter never matched. The app never worked with real keyboard input (masked until now because #179 kept the keyboard seam dead). Fixed to the ADR 0009 convention EDIT.BIN uses: `arg1` carries the ASCII byte for printables, `arg0` the HID usage for Enter (0x28) / Backspace (0x2a).
