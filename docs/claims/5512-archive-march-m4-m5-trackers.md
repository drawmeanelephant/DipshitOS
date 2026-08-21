# Claim: Archive completed M4/M5 march trackers

- **Owner:** oxalpha (`agent/oxalpha/archive-march-m4-m5`)
- **Prompt / plan:** https://github.com/drawmeanelephant/DipshitOS/issues/266
- **Scope:** Repo hygiene — move the two 47K completed-milestone march trackers (`docs/march-m4.md`, `docs/march-m5.md`) to `docs/archive/` (names unchanged), add the frozen-record banner (the `march-m15.md` precedent), and update every live reference so no link breaks: `docs/status.md` (the march-tracker pointer + related-docs list) and the pattern-reference links in `docs/march-m6.md` / `docs/march-m7.md`. Also fix the four archive navigation files whose `../march-m{4,5}.md` links the move would break: `status-m4-detail.md`, `status-m5-detail.md`, `roadmap-m4.md`, `roadmap-m5.md`. Historical `docs/archive/*-prompt.md` path mentions and append-only `docs/claims/` + `docs/logs/` entries stay untouched.
- **Depends on:** —
- **Status:** ✅ done

## Notes

Why: M4 closed 2026-08-11, M5 closed 2026-08-12; together the two
trackers are 95K of completed card-by-card detail in `docs/` root.
`docs/archive/README.md` already states the rule — completed-work docs
belong in the archive so `docs/` root holds only active documentation;
agents listing `docs/` mistake them for active work.

Verification plan: repo-wide grep for `march-m4.md` / `march-m5.md`
shows zero remaining live references outside `docs/archive/`,
historical prompts, claims, and logs; class A gates (fmt, build,
coordination ×2) re-run green.

## Verification

- `git mv` of both files → `git status` shows 2 renames into
  `docs/archive/`; names unchanged. Frozen-record banner added to each
  top (the `docs/archive/march-m15.md` precedent); bodies untouched.
- Live references updated: `docs/status.md` (march-tracker pointer now
  lists M3 + M6–M16 as live and M4/M5 as archived; related-docs entries
  point into `archive/`), `docs/march-m6.md` + `docs/march-m7.md`
  (pattern links → `archive/march-m{4,5}.md`). Archive navigation files
  the move would have broken fixed to sibling links: `status-m4-detail.md`,
  `status-m5-detail.md`, `roadmap-m4.md`, `roadmap-m5.md`.
- Repo-wide grep: zero remaining live references outside `docs/archive/`;
  historical `docs/archive/*-prompt.md` path mentions and append-only
  `docs/claims/` (3678, 3848) + `docs/logs/` old-path mentions left
  untouched per the append-only rule (the claim-4429 precedent).
- `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig` → pass
- `zig build` → exit 0 (full guest build incl. all ESP programs)
- `bash tools/status/refresh-indexes.sh` → indexes in sync
- `bash tools/verify-coordination.sh` → ok
