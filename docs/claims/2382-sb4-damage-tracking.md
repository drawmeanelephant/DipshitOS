# Claim: SB4 — damage tracking (M33 seam B, phase 3)

- **Owner:** buffy (`agent/buffy/m33-sb4-damage-tracking`)
- **Prompt / plan:** `docs/march-m33-seam-b-pixel-ownership.md` (SB4 card), `docs/decisions/0016-shared-anonymous-mmap.md` (accepted), `docs/decisions/0007-syscall-abi.md`, ADR 0009 (event kinds)
- **Scope:** M33 SB4 (phase 3 - compose). Make damage **rect-granular**: the kernel tracks a per-surface (per-user-window) **dirty rect** for every kernel-visible write and delivers a damage summary to the registered WM on each `COMPOSITE_TICK` (kind 18), instead of a whole-window present. Migrated (plain-store) apps stay whole-window dirty this card — rect damage for them is SB5; this card wires the transport + the kernel-visible (fill) path.
- **Gate:** damage is repaint-granular — one rect writes → the damage rect is exactly that rect (not the whole window), observable to the registered WM via the extended COMPOSITE_TICK.
- **Depends on:** SB3 landed (claim 3633, PR #690) - surface-bound windows + `sys_win_fill` routing + the window-tag binding.
- **Touches:** kernel/src/driving_award.zig kernel/src/wm_server.zig kernel/src/syscall.zig docs/march-m33-seam-b-pixel-ownership.md docs/claims/2382-sb4-damage-tracking.md docs/logs/agent-buffy-m33-sb4-damage-tracking.md tools/verify-live-sb4-damage-tracking.sh docs/archive/gate-inventory-detail.md build.zig image/make-image.sh
- **Heartbeat:** 2026-08-31
- **Status:** ✅

## Plan

1. **Rect-granular damage in `driving_award`.** Extend each user `Window` with a
   damage rect (`dx/dy/dw/dh` + a damaged flag). A `mark_damage(id,x,y,w,h)`
   helper unions the rect. `user_fill` (and the SB3 surface-bound fill route)
   call it with the exact written rect; whole-window operations (move, hide,
   workspace switch, focus fade) call it with the full window rect.
2. **Extend COMPOSITE_TICK (kind 18) to carry damage.** `wm_server.on_tick`
   packs a damage summary into the now-reserved arg1 (a per-surface dirty
   bitmask) so the registered WM sees which surfaces have pending damage. The
   per-surface rects are observable via the existing monitor (`dui`) for the
   gate, and are the payload SB5's compose-N consumes.
3. **Host proof.** Fill one rect in a surface/window → assert the damage rect
   IS that rect (not the whole window) and the tick carries its mask bit.
4. **Live gate + docs.**

## Result

DONE (2026-08-31). Rect-granular damage delivered to the WM. `Window` now tracks a
damage rect (dx/dy/dw/dh + damaged), union-clamped by `mark_damage`; `user_fill`
records the exact written rect; `composite()`'s user-window blit repaints only the
damaged region and records the consumed rect in `last_dx..`. KIND 18 COMPOSITE_TICK
extended: `wm_server.on_tick` packs a per-surface dirty bitmask into arg1
(`.user`-only spill guard). `dui` shows `damage=` (pending) + `last=` (consumed).

Host tests pin exact-rect / two-rect union / bitmask / consume-clear / spill guard.
Live gate PASS (headless VZ): SB4DAM fills two rects, compositor repaints exactly
their union (`last=8,8,108,68`, not whole-window). Build clean, host suite green,
fmt/coordination ok, BSS PASS.
