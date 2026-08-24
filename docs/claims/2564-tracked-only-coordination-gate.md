# Claim: tracked-only coordination gate

- **Owner:** ox-alpha (`agent/ox-alpha/coordination-tracked-gate`)
- **Status:** 🔄 in progress
- **Depends on:** —

## Problem

PR #524 (`agent/ox-alpha/m19-p7-background-jobs`) fails
`verify-coordination.sh` in CI even though its own tree is consistent.
Root cause: this checkout is **shared** — parallel agents stage m25 claim/log
files here untracked (`docs/claims/0434-m25-lane-a-bulk-props.md`,
`docs/claims/2539-m25-lane-b-mkdir-du-recent.md`,
`docs/logs/agent-ox-alpha-m25-filemanager-depth.md`, observed 2026-08-23) —
and both coordination scripts glob the raw directory:

- `tools/verify-coordination.sh`: `ls docs/claims/[0-9][0-9][0-9][0-9]-*.md`
  (L38), `for f in docs/logs/*.md` (L84)
- `tools/status/refresh-indexes.sh`: same two globs (L50, L64)

Regeneration therefore includes other agents' untracked files and reports
drift against the committed tables. The gate judges the shared disk instead
of the branch being merged.

## Fix

Both scripts list files via `git ls-files -c --` (tracked/staged only), so:

- untracked staging files from concurrent agents cannot fail someone else's
  gate or leak into their regenerated index;
- a claim file must be staged before `refresh-indexes.sh` sees it — the
  index always reflects what will merge;
- deleted-but-unstaged claim files are still caught (still in the index).

Workflow docs updated: stage new claim/log files, *then* run refresh, then
commit everything together.

## Verification

- `bash tools/status/test-coordination.sh` extended: sandbox is now a git
  repo; new positive case proves an untracked claim+log pair with no index
  rows does NOT fail verify-coordination; test 5 stages the hand-sequenced
  claim so the deterministic-ID gate still sees it.
- On this branch with the three foreign untracked files present:
  `verify-coordination.sh` passes without touching them.
