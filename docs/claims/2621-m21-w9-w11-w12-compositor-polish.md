# Claim: M21 compositor polish — W9 focus rings, W11 window persistence, W12 window titles

- **Owner:** Buffy (`agent/buffy/m21-compositor-w9-w11-w12`)
- **Prompt / plan:** `docs/march-m21.md` (W9/W11/W12), GitHub milestone 9 (#425/#427/#428)
- **Scope:** M21 W9 (focus rings), W11 (window persistence across sessions), W12 (window title updates). One new syscall slot (61) for `sys_win_set_title`.
- **Touches:** kernel/src/driving_award.zig, kernel/src/syscall.zig, kernel/src/shell.zig, kernel/src/monitor.zig
- **Depends on:** M21 W1–W16 landed (tiling, minimize, fullscreen, etc.)
- **Heartbeat:** 2026-08-24 — code complete, tests green, PR opened
- **Status:** 🔄 agent/buffy/m21-compositor-w9-w11-w12

## Notes

Closes the last three milestone-9 window-management cards that were not yet
implemented (W1–W8, W10, W13–W16 were already landed; W4/W5 were verified as
complete).

**W9 — Focus rings & visual focus indicator (#425):** Added
`user_border_unfocused()` (muted per-theme border: slate/stone/blue-gray) and
made `focus_ring()` per-theme accent (dark blue / deeper blue / amber). The
focused window gets the accent focus ring + normal dark border; unfocused
windows get the muted border. `draw_chrome()` now branches on `w.id ==
focused_id`.

**W11 — Window persistence across sessions (#427):** Added
`serialize_state()` / `restore_state()` in `driving_award.zig` — fixed 32-byte
records (id, flags, workspace, x/y/w/h, 12-byte title), 16 records max (512
bytes). `shell.zig` saves to `WINDOWS.SAV` on the ESP every ~300 idle cycles
(~30s) and restores at boot before `.dipshitrc`.

**W12 — Window title updates (#428):** Added `title_buf[64]` + `title_len` to
`Window`, `set_window_title()`, and `sys_win_set_title` (slot 61) with
ownership + uaccess fault-safety checks. Titles show in taskbar and Alt+Tab.

**Verification:** `zig build` clean; `zig test` driving_award 189/189,
syscall 427/427, shell 729/729, monitor 526/526; `zig fmt --check` clean.
