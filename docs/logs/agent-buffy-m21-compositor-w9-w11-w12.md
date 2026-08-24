# Log — agent/buffy/m21-compositor-w9-w11-w12

## 2026-08-24 — Buffy (claim 2621)

**M21 W9/W11/W12 compositor polish.** Working through GitHub milestone 9
(#425/#427/#428) to close the remaining window-management cards. Code written
and verified on `agent/buffy/m21-compositor-w9-w11-w12` (fresh branch off
`origin/main`).

- W9: `user_border_unfocused()` + per-theme accent `focus_ring()`; focused vs
  unfocused border branch in `draw_chrome()`.
- W11: `serialize_state()`/`restore_state()` (32-byte records) + shell
  `WINDOWS.SAV` save/restore (every ~300 idle cycles + boot).
- W12: `title_buf`/`title_len`, `set_window_title()`, `sys_win_set_title`
  (slot 61) with ownership + uaccess checks.

Verification: `zig build` clean; `zig test` driving_award 189/189, syscall
427/427, shell 729/729, monitor 526/526; `zig fmt --check` clean.

Note: slot 60 was already taken by M26 `sys_ping_poll`, so
`sys_win_set_title` uses slot 61; `implemented_count` bumped 61 → 62.
