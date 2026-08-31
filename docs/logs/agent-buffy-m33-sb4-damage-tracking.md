# Log — agent/buffy/m33-sb4-damage-tracking

## 2026-08-31 - claim 2382 opened (SB4: damage tracking)

Phase-3 compose card on `agent/buffy/m33-sb4-damage-tracking` off `origin/main`
(SB3 merged, PR #690). Makes the kernel's damage model rect-granular and
delivers it to the WM via an extended kind-18 COMPOSITE_TICK.

Design (user-confirmed): transport = extend COMPOSITE_TICK to carry damage
(kernel-notify; the arg1 field), source this card = kernel-infers per-fill
(rect known to `sys_win_fill` / the surface-bound fill route); migrated
plain-store apps stay whole-window dirty, rect-wired in SB5.
Gate: one rect writes -> that rect repaints (rect-granular damage).

## 2026-08-31 - claim 2382 done (SB4: damage tracking)

Implemented and verified. Kernel `Window` now carries a per-surface damage rect
(`dx/dy/dw/dh` + `damaged`), union-clamped via `mark_damage`; `user_fill` records
the exact written rect (fill-first source this card); `composite()`'s user-window
blit repaints only the damaged region and records the consumed rect in
`last_dx..`. `wm_server.on_tick` (kind 18 COMPOSITE_TICK) now packs a per-surface
dirty bitmask into the reserved arg1 (`.user`-only spill guard so fixed high-id
layers don't overflow the shift). `dui` gained `damage=` (pending) + `last=`
(consumed) columns; `monitor.zig` exposes the rects.

Host tests: exact-rect, union-of-two-rects, bitmask, consume-and-clear, spill
guard — all pass. Full host suite green, fmt/coordination ok, BSS PASS.

Live gate PASS (headless VZ): `verify-live-sb4-damage-tracking.sh` —
SB4DAM.BIN opens a window and fills two rects (8,8,48,48)+(100,60,16,16) with no
yield so they union; `dui[4]: ... last=8,8,108,68` proves the compositor
repainted exactly the union rect, not the whole window. Zero faults.
