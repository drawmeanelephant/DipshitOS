# Milestone thirty-seven march — desktop quality pass (living tracker)

> [`docs/status.md`](status.md) is the canonical milestone-level source. This
> file holds M37's per-card detail, order, and gate notes. A card's row flips
> to ✅ only with real observed evidence.
> Binding: **[desktop-quality scoping](desktop-quality-scoping.md)** (DRAFT,
> claim 8459) — split of umbrella issue **#821** (Phase 1: claim 7154).
> Proposed GitHub milestone: **24 — M37 Desktop quality pass**
> (created 2026-09-03: DQ1 #836, DQ2 #840, DQ3 #839, DQ4 #838, DQ5 #837).

## Where we are

M19 landed the Sexiburger mechanics + tab model; M32 moved WM policy to
`WND.BIN`; M34 gave us `/host/APPS.TXT`; M36 gave us the raster engine +
wallpaper. Phase 1 of #821 (claim 7154, `1d80f50`) put the `SexiburgerMenu`
overlay into `WND.BIN` with hardcoded sections. Four completions remain, and
the tab/visual/snap halves have pure-rule foundations in
`kernel/src/wnd_core.zig` with no WND.BIN callers yet.

## The cards, in order

> **DQ1 close-out → DQ2 render → DQ3 interact → DQ4 tokens → DQ5 preview.**

| DQ# | Card | Phase | Depends on | Status | Touches | Notes |
|----:|------|:------|------------|--------|---------|-------|
| DQ1 | **God Menu completion** (#836) — dynamic APPS.TXT, live active-app actions, real theme/exec, full win/tab entries | close-out | — | ⬜ unclaimed | `user/src/wnd.zig` god-menu fns, `user/src/lib/sexiburger.zig` | **Gate: unit + Class-B Ctrl+Space → filter → Enter executes.** Umbrella #821 §1. |
| DQ2 | **Tab-bar chrome render** (#840) — WM strip, truncation, active/hover/× | render | DQ1-stable | ⬜ unclaimed | `kernel/src/wnd_core.zig`, WND blit half | **Gate: unit (layout/hit-test) + Class-B strip visible.** Umbrella #821 §2 (render half). |
| DQ3 | **Tab mouse interaction** (#839) — click switch, × close, drag-detach | interact | DQ2 | ⬜ unclaimed | WND input half `user/src/wnd.zig` | **Gate: unit + Class-B pointer injection.** Umbrella #821 §2 (input half). Strictly after DQ2. |
| DQ4 | **Design tokens & cohesion** (#838) — ui.zig metrics, borders/shadows, cursors, 6-app rollout | polish | DQ2 | ⬜ unclaimed | `user/src/lib/ui.zig` + per-app sites | **Gate: unit + Class-B light/dark.** Umbrella #821 §3. One app per commit. |
| DQ5 | **Snap guides** (#837) — drag preview outline, release commits | preview | DQ2 | ⬜ unclaimed | WND drag path | **Gate: unit + Class-B drag.** Umbrella #821 §4. |

### Dependency phases (why this order)

```text
DQ1 close-out ──────────────────────────────┐ free wnd.zig god-menu fns
DQ2 render ─────────────────────────────────┼─ strip + hit-test first
DQ3 interact (after DQ2) ───────────────────┘  click what is drawn
DQ4 tokens (after DQ2) ─────────────────────── look settled, then unify
DQ5 preview (after DQ2) ────────────────────── rect math settled, then outline
```

## Notes

1. **Out of scope:** new syscall slots by default (DQ2 chrome bits only if
   justified); kernel policy growth; full theme engine; touch/multi-mon.
2. **Zero-regression contract:** hardcoded Phase-1 menu keeps working until
   DQ1 replaces each section; unmigrated apps keep frozen slots; every card
   re-runs `verify-live-sexiburger-actions.sh` green.
3. **BSS watch:** god-menu registry + mascot pixels + per-app token growth —
   every card re-runs `verify-bss-budget.sh`.

_Created by claim 8459 (2026-09-03), splitting issue #821's umbrella into
gated cards. Per-card GitHub issues to be filed under milestone 24; bodies
in the scoping doc's card table + the five drafts below._
