# Claim: Archive ragshit test artifacts

- **Owner:** oxalpha (`t3code/handle-issue-268-git-current`)
- **Prompt / plan:** https://github.com/drawmeanelephant/DipshitOS/issues/268
- **Scope:** Repo hygiene — move the ~500K of ragshit context-engine test
  evidence under `artifacts/ragshit-0176/` (claim 0176 / verification 4922:
  `before-40000.{md,json}`, `after-40000.{md,json}`,
  `dogfood-{20000,30000,40000,60000}.md`, `verification-summary.txt`) to
  `docs/archive/ragshit-0176/`, and move the 122K m3 context bundle
  `artifacts/m3-ragshit-bundle.md` (the issue's "ragshit-bundle.md") to
  `docs/archive/`. Bodies untouched — these are point-in-time evidence,
  so no frozen-record banner is added (a banner would taint raw evidence;
  JSON cannot carry one). Assess `.ragshitignore` for needed updates.
  References: every mention of the old paths lives in append-only
  `docs/claims/` + `docs/logs/` entries or the one-shot archived prompt
  `docs/archive/m3-ragshit-dogfood-prompt.md` — all left untouched per
  the append-only / historical-record rules.
- **Depends on:** —
- **Status:** ✅ done

## Notes

Why: 610K+ of test/audit data sits at the top of `artifacts/`, where any
agent listing the directory sees it as live work product.
`docs/archive/README.md` already establishes that completed-work material
belongs in the archive. `.ragshitignore` needs no change: it only excludes
untracked build/meta paths plus one host-side binary, and the prior
archive moves (claims 2860, 4429, 5512) deliberately kept `docs/archive/`
indexed.

Verification plan: `git mv` shows clean renames into `docs/archive/`;
repo-wide grep confirms zero remaining live references outside
append-only claims/logs and the archived prompt; `artifacts/` root holds
no ragshit files afterwards; class A gates re-run green (fmt, build,
coordination ×2).

## Verification

- `git mv artifacts/ragshit-0176 docs/archive/ragshit-0176` and
  `git mv artifacts/m3-ragshit-bundle.md docs/archive/m3-ragshit-bundle.md`
  → `git status` shows 10 clean renames (R), bodies byte-identical, no
  banners added (raw evidence; JSON cannot carry one).
- `artifacts/` root afterwards holds only the other live evidence dirs
  (`docs-reconciliation-20260808/`, `syscall-abi-3594/`) and the four
  m3-ragshit side files (doctor/index/review/verification) that issue #268
  does not list — left in place, flagged in the branch log as possible
  follow-up.
- `.ragshitignore`: no change needed — it excludes untracked build/meta
  paths plus one host-side binary; tracked-file eligibility is unaffected
  by the move, and prior archive moves (2860/4429/5512) kept
  `docs/archive/` indexed deliberately.
- Repo-wide grep for `ragshit-0176|m3-ragshit-bundle|ragshit-bundle`:
  remaining hits are append-only `docs/claims/` + `docs/logs/` entries
  (historical record of where evidence lived) and the one-shot archived
  prompt `docs/archive/m3-ragshit-dogfood-prompt.md` (a recorded command,
  not a doc link) — all untouched per coordination rules. No references
  exist in `docs/status.md`, `docs/roadmap.md`, or any live doc.
- `docs/archive/README.md` updated with one sentence covering the new
  evidence-archive contents (byte-identical, banner-free).
- `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig` → pass
- `zig build` → exit 0
- `bash tools/status/refresh-indexes.sh` → indexes in sync
- `bash tools/verify-coordination.sh` → ok
