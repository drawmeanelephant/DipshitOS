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
