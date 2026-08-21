# Log — `t3code/handle-issue-268-git-current`

Append-only per-branch changelog (AGENTS.md). One entry per change.

- **2026-08-21** — *ox-alpha (t3code/handle-issue-268-git-current)*: claim
  4516 — repo hygiene issue #268 → **done**: moved the ~500K ragshit
  context-engine test evidence `artifacts/ragshit-0176/` (claims 0176 /
  4922: before/after 40000 packets, four dogfood bundles,
  verification-summary) to `docs/archive/ragshit-0176/` and the 122K
  bundle `artifacts/m3-ragshit-bundle.md` to `docs/archive/m3-ragshit-bundle.md`
  via `git mv` — 10 clean renames, bodies byte-identical, no banners (raw
  evidence). The issue's "artifacts/ragshit-bundle.md" is this file under
  its current tracked name. `.ragshitignore` unchanged (tracked-file
  eligibility unaffected; archive stays indexed by design). Remaining old-path
  mentions live only in append-only claims/logs and the archived one-shot
  prompt `m3-ragshit-dogfood-prompt.md` (recorded command, not a link) —
  untouched per coordination rules. Observed out of scope:
  `artifacts/m3-ragshit-{doctor.txt,index.txt,review.md,verification.txt}`
  are also completed-milestone ragshit output but are not listed in #268;
  left in place as possible follow-up. `docs/archive/README.md` gains one
  sentence covering the evidence archives. Gates: fmt ✅, build ✅,
  refresh-indexes ✅, verify-coordination ✅. ✅
