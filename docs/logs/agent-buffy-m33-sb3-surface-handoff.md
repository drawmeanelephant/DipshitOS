# Log — agent/buffy/m33-sb3-surface-handoff

## 2026-08-31 - claim 9361 opened (SB3: window surface handoff)

Phase-2 card on `agent/buffy/m33-sb3-surface-handoff` off `main` (PR #688 merged -
SB2 landed). Elevates the SB2 shared-anon capability to WINDOWS: a user window's
back-buffer content moves from the kernel `user_bufs[id]` copy into a shared
surface the app renders into with plain stores and the registered WM mirrors
read-only. Frozen `sys_win_fill`/`sys_win_present`/`sys_win_open` slots stay
byte-identical for unmigrated apps. Gate: migrated app draws -> WM reads the
bytes RO (parity vs the old fill path), host proof + headless VZ live gate.

## 2026-08-31 - claim 3633 COMPLETE (SB3: window surface handoff)

**SB3 done, live gate PASS.** A user window gets a shared-anonymous surface
back-buffer. Implementation:
- `sys_mmap(addr = M33_SURF_WIN_TAG | window_id, MAP_ANON|M33_MAP_SHARED)`
  (slot 63) binds the window to a shared surface: the addr-tag runs through the
  SB2 owner-create, whose tail the plain and window paths now share; the frozen
  `sys_win_open`/`fill`/`present` slots (12-14) stay byte-identical for
  unmigrated apps.
- `driving_award`: `Window.surface_*` fields + `bind_window_surface` (close/exit
  teardown), `sys_win_fill` routes into the surface when bound, and a registered
  WM auto-mirrors RO at bind time (SB2 peer attach in the WM's own root).
- Host test pins the structures (bind recorded; owner leaf writable aliasing the
  surface pa; WM mirror leaf RO+`sw_cow` aliasing the SAME pa; unmigrated
  windows untouched).
- New EL0 apps SB3OWN.BIN/SB3WM.BIN wired into build.zig, make-image.sh, and the
  class-B GATE_INVENTORY. Input fix during bring-up: `sys_win_open` args are
  (x,y,w,h) — the first draft passed (w,h) as (x,y).

**Live gate `tools/verify-live-sb3-surface-handoff.sh` PASS (headless VZ).**
`sb3: wm registered -> own opened -> own bound -> own stored -> wm-read=0xAB ->
owner done -> wm done`, zero fatal: the app stored 0xAB via a plain write and
the registered WM read it RO through the mirror — the surface-handoff parity
proof (a migrated app's stores, not a kernel fill, produce what the WM sees).
Build clean, full host suite green, fmt/coordination ok. Tracker row flipped
to ✅ claim 3633.
