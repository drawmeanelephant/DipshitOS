# Claim: Milestone 14 Card S3 — composition capstone (NOTEPAD copy/paste + timer cursor)

- **Owner:** buffy (`agent/buffy/m14-s3-composition`)
- **Prompt / plan:** `docs/march-m14.md`
- **Scope:** Milestone 14, Card S3 (Issue #177): S1+S2 proven together in NOTEPAD
- **Depends on:** M14 S1 clipboard (claim 2611, PR #195); M14 S2 timers (claim 5390, PR #196)
- **Status:** ✅ done

## Notes

The milestone-fourteen capstone: prove NOTEPAD.BIN's clipboard copy/paste (S1)
and timer-driven cursor blink (S2) working TOGETHER in the real app, live on
VZ. The composition gate `tools/verify-live-m14-composition.sh` drives NOTEPAD
end to end, then reads the shared clipboard from the shell (a new `clipboard`
monitor command) and the syscalls report.

**The live-driving seam is `dui key`** (a new `dui` subcommand), NOT the VZ
keyboard: a synthesized Ctrl-C/Ctrl-V chord cannot reach VZ's HID report
(claim 0935's modifier wall — VZ drops the modifier flags on a synthesized
keyDown, so the guest sees the plain letter). `dui key <char|copy|cut|paste|quit>`
injects the SAME `KEY_DOWN` event the keyboard path produces into the focused
window's event queue, one layer above the HID→modifier translation VZ drops —
the U5 `dui cycle` precedent (synthesizing the Alt+Tab focus signal)
generalized to key chords. The interactive Ctrl-C/Ctrl-V/Ctrl-Q decode is
host-tested in `notepad.zig`.

No ABI change: S3 adds a monitor `clipboard` command, a `dui key` subcommand,
and NOTEPAD serial markers (`copy ok` / `paste ok` / `blink`) plus a Ctrl+Q
quit chord — no new syscall slots, `implemented_count` stays 42.

**Honest bound hit and worked around:** the first attempt drove NOTEPAD through
an argv `demo` mode, but `exec NOTEPAD.BIN demo` is refused (`error: image
leaves no room for the argv block (256 bytes)` — NOTEPAD.BIN's content is 8175
bytes, over the 7936-byte budget that leaves a 256-byte argv block in its
2-page text leaf). The `dui key` seam avoids argv entirely and is the more
honest proof anyway (it exercises NOTEPAD's `handle_keyboard_event`, not a
bespoke demo path).

Verified by: class-A green (fmt, 463 console tests + 22 unit tests incl. the
monitor `clipboard`/`dui key` commands, byte-identical transcript,
build/image/inspect, swift build, coordination), and the live gate on VZ PASS
1/1 — NOTEPAD typed "hello" → copied → pasted → blinked → closed → exited 43,
`clipboard: len=5 'hello'` byte-exact from the shell,
`sys_clipboard_set`/`sys_clipboard_get`/`sys_timer_set` calls=1 each.
