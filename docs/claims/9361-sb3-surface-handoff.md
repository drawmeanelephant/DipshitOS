# Claim: SB3 — window surface handoff (M33 seam B, phase 2)

- **Owner:** buffy (`agent/buffy/m33-sb3-surface-handoff`)
- **Prompt / plan:** `docs/march-m33-seam-b-pixel-ownership.md` (SB3 card), `docs/decisions/0016-shared-anonymous-mmap.md` (accepted), `docs/decisions/0007-syscall-abi.md` (M33_MAP_SHARED, claim 7418)
- **Scope:** M33 SB3 (phase 2 - surface). Let an app hand its user window's rendering over to a **shared-anonymous surface** it renders into with plain stores, which the registered WM mirrors read-only - parity with the old `sys_win_fill` path. Unmigrated apps keep the frozen `sys_win_fill`/`sys_win_present`/`sys_win_open` slots (12-14) byte-identically; migrated apps draw into a shared region and the WM reads the bytes RO through the SB2 mirror. `uaccess` registration stays owner-side only (the WM never writes the surface).
- **Gate:** a migrated app draws to its shared buffer and the registered WM sees the bytes (parity vs. the old fill path) - host proof (two roots, WM RO mirror reads what the app stored through its writable leaf) + a headless VZ live gate.
- **Depends on:** SB2 landed (claim 8878, PR #688) - `sys_mmap` owner create/WM peer-attach + `shared_mmap.map_peer_leaves` + the ESP window fix.
- **Touches:** kernel/src/syscall.zig kernel/src/driving_award.zig kernel/src/shared_region.zig kernel/src/shared_mmap.zig kernel/src/wm_server.zig docs/march-m33-seam-b-pixel-ownership.md docs/claims/9361-sb3-surface-handoff.md docs/logs/agent-buffy-m33-sb3-surface-handoff.md tools/verify-live-sb3-surface-handoff.sh
- **Heartbeat:** 2026-08-31
- **Status:** in-progress

## Plan

1. **Window->surface binding seam.** A user window can be opened/declared as
   surface-backed: it holds the shared region's handle/pa_base/page_count
   instead of the kernel `user_bufs[id]` copy. Frozen slots stay unchanged for
   unmigrated apps.
2. **`sys_win_fill`/`sys_win_present` handoff.** A migrated (surface-backed)
   window routes `sys_win_fill` into its shared surface (the kernel writes the
   region's pages) - or, per the card, plain stores become the render path and
   present just marks dirty. Unmigrated windows stay on `user_bufs` unchanged.
3. **WM mirror.** The registered WM peers the surface RO (SB2 peer-attach) and
   reads the app's bytes; parity: the surface bytes equal what the old
   `user_fill` would have produced for the same rects.
4. **Composite parity.** `composite()` draws a migrated window from its shared
   surface pages (same blit) so the on-scanout result equals the old fill path.
5. **Host proof + live gate + docs/commit.**
