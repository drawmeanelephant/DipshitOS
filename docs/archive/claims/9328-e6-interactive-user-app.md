# Claim: First interactive EL0 application (KEYTEST.BIN) & Capstone Gate

- **Owner:** Buffy (`agent/buffy/m9-events`)
- **Prompt / plan:** `docs/march-m9.md`
- **Scope:** Milestone 9 card E6: standalone user program `KEYTEST.BIN` loaded from ESP that opens a Driving Award window, reads interactive keyboard and mouse events via `sys_wait_event` (slot 22), and renders real-time graphical feedback inside its window. Verified via class B live gate `tools/verify-live-events.sh`.
- **Depends on:** E0-E5 (claims 7463, 7670, 7206, 9228, 0293, 1016)
- **Status:** ✅ done (`agent/buffy/m9-events`)

## Notes

Milestone 9 Capstone Gate:
1. User application `user/src/keytest.zig` built as `KEYTEST.BIN` and packaged on ESP FAT32 volume root.
2. `KEYTEST.BIN` opens window id 2, fills background, presents window, and waits for events via `sys_wait_event`.
3. Handles `WIN_FOCUS`, `KEY_DOWN`, and `MOUSE_DOWN` / `MOUSE_MOVE` events by rendering distinct colors into the window buffer (`sys_win_fill` + `sys_win_present`) and outputting markers via `sys_write`.
4. Exits with distinct status upon completion.
5. Class B live gate `tools/verify-live-events.sh` runs on Apple Virtualization framework, executing `KEYTEST.BIN`, sending interactive keystrokes/clicks, and asserting event processing and rendered pixel output.
