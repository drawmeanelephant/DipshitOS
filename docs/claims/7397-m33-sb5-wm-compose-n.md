# Claim: SB5 — WM compose-N + one final present (M33 seam B, phase 3)

- **Owner:** buffy (`agent/buffy/m33-sb5-wm-compose-n`)
- **Prompt / plan:** `docs/march-m33-seam-b-pixel-ownership.md` (SB5 card, issue #692), `docs/decisions/0016-shared-anonymous-mmap.md` (accepted), `docs/decisions/0007-syscall-abi.md`
- **Scope:** M33 SB5 (phase 3 - compose). The registered WM composites the N migrated shared RO surfaces into the scanout itself and issues the FINAL present (REQUEST_PRESENT = flush only); per-rect `sys_win_fill` SVCs are gone for migrated apps.
- **Gate:** a registered-WM desktop composites entirely from shared surfaces; the kernel reports ZERO fill SVCs for migrated apps (host proof + a headless VZ live gate where migrated apps never issue `sys_win_fill`).
- **Depends on:** SB4 landed (claim 2382, PR #713) - rect damage + the COMPOSITE_TICK arg1 mask; SB3 (claim 3633, PR #690) - surface-bound windows + WM auto-mirror.
- **Touches:** kernel/src/syscall.zig kernel/src/wm_server.zig kernel/src/driving_award.zig docs/claims/7397-m33-sb5-wm-compose-n.md docs/logs/agent-buffy-m33-sb5-wm-compose-n.md tools/verify-live-sb5-wm-compose-n.sh docs/archive/gate-inventory-detail.md build.zig image/make-image.sh user/src/sb5_own.zig user/src/sb5_wm.zig docs/march-m33-seam-b-pixel-ownership.md docs/decisions/0007-syscall-abi.md docs/decisions/0016-shared-anonymous-mmap.md
- **Heartbeat:** 2026-08-31
- **Status:** ✅

## Plan

1. **Scanout grant (the compose-N target).** A new `sys_mmap` addr-tag
   (`M33_SURF_SCAN_TAG`, bit 62) lets the REGISTERED WM map the virtio-gpu
   framebuffer (`gpu_fb`, kernel-owned pages) WRITABLE into its own root -
   full-frame only, WM seat only, idempotent. Teardown on WM unregister/exit
   and on a full-frame munmap: unmap leaves WITHOUT unref (the GPU fb pages
   are never ref-counted to the WM).
2. **Chrome paints at the tick; the present is the final present.** Split
   `driving_award.composite()` into `paint_scene()` (chrome + unmigrated
   windows into gpu_fb, BSS-only, host-test safe) + the flush tail.
   `wm_server.on_tick` calls `paint_scene()` BEFORE pushing COMPOSITE_TICK,
   so the kernel's layer is under the WM's compose-N stores (correct z-order
   at flush time). `REQUEST_PRESENT` becomes flush-only (`request_present`'s
   G1 transfer+flush) - no composite, so the kernel can never overdraw the
   WM's stores. Migrated (surface-backed) user windows are SKIPPED by
   `paint_scene` when the WM owns the user layer (set when the scanout is
   bound).
3. **Zero-fill observability.** The per-slot call counter already counts
   `sys_win_fill` (slot 13); the gate reads `syscalls` via the monitor and
   asserts `sys_win_fill calls=0` after the migrated app ran.
4. **Host proof.** Scanout bind contract (WM-only / full-frame / writable /
   idempotent / teardown); paint-skip (migrated window untouched by
   paint_scene when the WM owns the user layer); zero-fill (a migrated
   window's lifecycle dispatches no slot-13 call).
5. **Live gate + docs.** SB5OWN.BIN (plain-store render, no fill) +
   SB5WM.BIN (bind scanout, peer the surface, compose-N into the scanout,
   readback the magic byte, REQUEST_PRESENT). `verify-live-sb5-wm-compose-n.sh`
   registered in the class-B inventory.

## Result

DONE (2026-08-31). The registered WM now composites the migrated surfaces into
the scanout and issues the FINAL present. New `sys_mmap` addr-tag
`M33_SURF_SCAN_TAG` (bit 62): the registered WM maps `gpu_fb` writable into its
own root (full-frame only, kernel-owned pages never ref'd/unref'd; torn down on
WM exit and on a full-frame munmap). Chrome paints at the TICK
(`wm_server.on_tick` -> `driving_award.paint_scene()` before the COMPOSITE_TICK
event); REQUEST_PRESENT (cmd 3) is flush-only; paint_scene SKIPS migrated
(surface-backed) windows while the WM owns the user layer — the scanout
z-order is kernel-under-WM at flush time (the old composite-at-present could
overdraw the WM's stores).

Host tests: scanout bind contract (WM-only EACCES / full-frame EINVAL /
writable-required EINVAL / idempotent / teardown-without-unref), paint-skip
(migrated window's damage consumed with NO kernel blit), WM-seat refusal.

Live gate PASS (headless VZ, `verify-live-sb5-wm-compose-n.sh`): SB5WM binds
the scanout, SB5OWN renders with plain stores ONLY (never `sys_win_fill`), the
WM composes the surface into the scanout, reads the byte back
(`sb5: wm readback=0x5B`), presents, and the `syscalls` monitor reports
`13 sys_win_fill calls=0` — zero fill SVCs for the migrated app. Build clean,
full host suite green, fmt/coordination ok, BSS PASS (685128 B headroom).

Note: `docs/status.md` update deferred — claim 2852 on the `docs-pass` branch
is ACTIVE and declares it (coordination gate); the M33 status line lands via a
later docs pass.
