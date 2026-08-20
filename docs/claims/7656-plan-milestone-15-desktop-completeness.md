# Claim: milestone fifteen — desktop completeness & UX depth (10-card scope)

- **Owner:** buffy (`freebuff/can-you-review-issues-223-247-and-try-to-provide-h-f6c8d8a0-9349-4ada-9bca-1705150f0bde`)
- **Prompt / plan:** user request 2026-08-20 — "review issues 223–247 and try to provide help in fleshing out their scope" — followed by "we can maybe group the stuff that's attainable into a milestone" — yielding this milestone proposal.
- **Scope:** docs only — `docs/m17-desktop-completeness.md` (the M15 per-card tracker, agent split, and dependency-ordered scope). No code, no syscall ABI amendment, no event-kind addition. M15 is a **scope-shaping proposal**, not an implementation claim; each M15 card lands under its own per-card claim when claimed.
- **Depends on:** M14 S1–S4 (clipboard, app timers, composition capstone, hardening) closing first. Per `docs/m17-desktop-completeness.md`, M15 assumes M14 closed (`implemented_count = 42`); M15 itself does not advance `implemented_count` further.
- **Status:** ✅ done 2026-08-20 — `docs/m17-desktop-completeness.md` exists, 127 lines, 10 cards (C1–C10) with status legend, evidence column, dependency notes, best-agent split, notes section, and three open questions for the user.

## Notes

Milestones 0–13 shipped a real graphical desktop (Road Pops + Driving Award + 4
GUI apps + file browser + manifest). Issues #223–#247 (filed 2026-08-20)
represent the natural next step: **depth into the existing static window
model** before adding any new kernel ABI. This claim picks the attainable
subset and groups it into one milestone.

**What M15 is and is not (per `docs/m17-desktop-completeness.md`):**

- **M15 = depth into the static window model.** Every card is pure
  `user/src/lib/ui.zig`, a `driving_award.zig` compositor addition, or an
  app upgrade in `user/src/<app>.zig`.
- **No new kernel syscalls**, no new event kinds, no new uaccess paths.
  Where the issue text proposes new ABI slots (e.g. `#224 sys_win_resize`,
  slot 47), M15 defers them to a follow-on milestone — they belong to a
  post-M14 arc that benefits from the BSS-budget gate (claim 6560) being
  in place first.
- **Zero new event kinds.** M9 (`kernel/src/events.zig`) shipped kinds
  0–9. M15 reuses MOUSE_DOWN/UP (kinds 4/5) for the Alt+Tab overlay (no
  new kinds).

**The 10 cards, in dependency order:**

| # | Card | Arc | Issue |
|---|------|-----|-------|
| C1 | DropDown widget | 1 | #223 |
| C2 | Alt+Tab cycling overlay | 2 | #225 |
| C3 | Window snap zones | 2 | #227 |
| C4 | Desktop quick-launch dock | 2 | #229 |
| C5 | NOTEPAD multi-line + word wrap | 3 | #230 |
| C6 | NOTEPAD find/replace | 3 | #231 |
| C7 | FILE preview + breadcrumbs | 3 | #232 |
| C8 | TOP sortable + filter | 3 | #233 |
| C9 | CALC keyboard + history | 3 | #235 |
| C10 | SETTINGS live preview | 3 | #234 |

**What was deliberately excluded (deferred to a follow-on arc):**

- `#224 drag-to-resize` — proposes slot 47 → post-M14 ADR 0007 amendment.
- `#236 mouse wheel` — proposes event kind 12 → collides with #228; needs
  the kind-12 resolution in `docs/decisions/0013-post-m14-abi-amendment.md`
  D2 first.
- `#237 drag-and-drop` — proposes slots 48 + kinds 14/15/16 → ADR 0013 D1/D2.
- `#238 z-order front/back` — proposes slots 49/50 → ADR 0013 D1.
- `#239 animations` — proposes using M14 S2 app timer slot 40 (planned,
  not landed) → ADR 0013 D1.
- `#240 notifications` — proposes slot 51 → ADR 0013 D1.
- `#241 workspaces` — proposes slot 52 → ADR 0013 D1 (architectural
  capstone of the post-M14 arc).
- `#242 unsaved-state` — depends on sibling issue #221 (Dialog widget,
  not in #223–#247) → ADR 0013 D1.
- `#243 tombstones` — depends on M14 S4 hardening harness → M16+.
- `#244 graceful shutdown` — collides with M1.5's existing `shutdown`
  semantics (claim 0527) and depends on M14 S1 clipboard → M16+.
- `#245 compose` — needs the 8×8 font extended to Latin-1 supplement (the
  font ships Latin-1 only per M11 D4) → M16.
- `#246 resource limits` — collides with claim 4636's argv-block
  contract + needs a per-task CPU-tick counter added to the scheduler →
  M16+.
- `#247 settings migration` — depends on ADR-0011-v2 schema design →
  M15b / M16.

**Best-agent split (one editor per file, per AGENTS.md):**

- **Agent A — Widget depth:** `user/src/lib/ui.zig` for C1 DropDown, plus
  the toolkit seams C3/C7/C9 consume. C1 first; C5/C6 are app-specific.
- **Agent B — Window-managed depth:** `kernel/src/driving_award.zig` +
  `user/src/desktop.zig` for C2 Alt+Tab overlay, C4 dock, and the C10 EL1
  `theme_set` monitor command (single 3-line zig change to the existing
  registry).
- **Agent C — App-upgrade depth:** `user/src/notepad.zig`,
  `file_browser.zig`, `top.zig`, `calc.zig` for C5–C9. C5/C6 in lockstep
  (wrap + find highlight contract).

**Open questions for the user (left in `docs/m17-desktop-completeness.md` for ack):**

1. Split M15 into M15a (C1–C9, all userland) + a tiny M15b (C10, with the
   EL1 monitor-command touch)? Or 10 cards in one milestone?
2. C5/C6 in lockstep to keep the wrap/find highlight contract honest —
   OK?
3. C4 dock manifest amendment: `dock=true` flag on existing `APPS.TXT`
   rows, or a separate `DOCK.TXT`?

**Relationship to other planning artifacts (this branch):**

- `docs/decisions/0013-post-m14-abi-amendment.md` (claim 6215) — the
  post-M14 ABI reservation that unblocks the deferred M16+ arc.
- `tools/verify-bss-budget.sh` (claim 6560) — the class-A BSS-budget
  gate that protects the design space M15 builds in.
- 25 per-issue comments on GitHub issues #223–#247 — each comment
  captured the discipline questions for the corresponding card, recorded
  observed facts (the kind-12 collision, the workspace cascade, the
  argv/rlimit collision, the font coverage gap, etc.) that this scope
  document resolves into a sequenced milestone.

**Predicate:** every M15 card assumes M14 S1 (clipboard) and M14 S2
(app timers) are landed. C9 / C10 specifically do not use them; M15
only assumes M14 closed.

## Verified

- ✅ `docs/m17-desktop-completeness.md` exists (127 lines, 11 KiB), with the U0–U8-
  style table (10 rows: C1–C10), the best-agent split, and the notes
  section.
- ✅ docs only — no kernel, no `user/`, no ADR 0007 amendment, no
  event-kind addition. M15 stays "depth into existing systems" — the
  M16+ arc inherits the new ABI work via ADR 0013 (claim 6215).
- ✅ Per-issue scope drift is captured in the 25 GitHub comments on
  #223–#247 (already posted 2026-08-20); this milestone doc folds them
  into a sequenced milestone plan rather than re-litigating them.
