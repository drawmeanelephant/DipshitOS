# Milestone fourteen march — shared user services (living tracker)

## Where we are

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds only
> milestone-fourteen's per-card detail and collision-free agent split,
> following the [`march-m13.md`](march-m13.md) pattern.
> A card's row flips to ✅ only with real observed class-B evidence, never
> code-complete alone.

Milestone thirteen gave the desktop a file story (manifest, browser,
mutating FS). With text apps and a desktop launcher in place, the wishlist's
**shared-user-services** items are the natural next arc: a clipboard (item
11 — "text apps will make the absence obvious"), application timers (item
12 — apps shouldn't spin sleep loops), and the security/isolation hardening
that grows *alongside* userland power (item 19).

Milestone fourteen is the **shared user services** milestone: S1 clipboard →
S2 app timers → S3 composition capstone → S4 hardening.

The cards, in order:

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| S1 | **Clipboard / shared text service.** `sys_clipboard_set`/`sys_clipboard_get` (ADR 0007 slots 38–39), one bounded kernel clipboard buffer (pure BSS, zero heap); NOTEPAD copy/cut/paste + terminal copy. | ⬜ | — | Issue #175; wishlist 11. |
| S2 | **Application timers.** Bounded per-process timer facility (slots 40–41) posting `TIMER` events on the ADR 0009 queue; apps stop spinning (NOTEPAD cursor blink, a live clock, TOP refresh). | ⬜ | — | Issue #176; wishlist 12. |
| S3 | **Composition capstone.** NOTEPAD copy/paste with a timer-driven cursor — S1+S2 proven together. Live gate: `verify-live-m14-composition.sh`. | ⬜ | — | Issue #177; depends on S1+S2. |
| S4 | **Security/isolation hardening.** Process-ownership audit across every EL0-named resource, uaccess validation-depth sweep, resource limits; a hostile EL0 program refused cross-process access. Live gate: `verify-live-hardening.sh`. | ⬜ | — | Issue #178; wishlist 19. |

## Notes

- The M14 plan lives in issues #175 (S1), #176 (S2), #177 (S3), #178 (S4),
  filed 2026-08-16 alongside the M13 closeout and the pointer-route
  investigation (PR #174) — the roadmap's destination sections are seeded
  ahead of the closeout, per the M12/M13 precedent.
- S1/S2 add ADR 0007 slots 38–41 (implemented_count 38 → 42), following
  slot 37 `sys_file_free`.
- Zero heap allocation stays a hard constraint for every new kernel
  resource (fixed BSS tables only).
- M8's U4 pointer live proof is a known class-C-only limitation (issue
  #151, claim 4769) — not part of M14 scope.
- Open thread from the M13/pointer work: the synthesized keyboard seam
  currently reports `events=0` (issue #179) — worth confirming no session
  dependency before relying on live input gates.
