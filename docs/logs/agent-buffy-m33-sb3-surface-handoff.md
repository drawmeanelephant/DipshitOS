# Log - agent/buffy/m33-sb3-surface-handoff

## 2026-08-31 - claim 9361 opened (SB3: window surface handoff)

Phase-2 card on `agent/buffy/m33-sb3-surface-handoff` off `main` (PR #688 merged -
SB2 landed). Elevates the SB2 shared-anon capability to WINDOWS: a user window's
back-buffer content moves from the kernel `user_bufs[id]` copy into a shared
surface the app renders into with plain stores and the registered WM mirrors
read-only. Frozen `sys_win_fill`/`sys_win_present`/`sys_win_open` slots stay
byte-identical for unmigrated apps. Gate: migrated app draws -> WM reads the
bytes RO (parity vs the old fill path), host proof + headless VZ live gate.
