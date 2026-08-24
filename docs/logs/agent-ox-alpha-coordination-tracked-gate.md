# Log — tracked-only coordination gate

- **2026-08-23** — *ox-alpha*: Opened. PR #524 failed `verify-coordination.sh`
  because the shared checkout holds other agents' untracked m25 staging files
  (claims 0434/2539, log agent-ox-alpha-m25-filemanager-depth) and both
  coordination scripts glob the raw docs/ directories. Commit 42d1078 on the
  PR branch already dropped those rows from the committed tables, but local
  regeneration re-picks them up — false positive against the branch. Fix:
  tracked-files-only listing in verify-coordination.sh and
  refresh-indexes.sh; sandbox in test-coordination.sh becomes a git repo;
  new regression case for untracked immunity. Claim 2564.

- **2026-08-24** — *ox-alpha*: DONE. PR #525 merged as e22b375 after two
  rounds: (1) rebase conflict in the generated logs-index region resolved by
  regenerating, not hand-merging — during which `git add -A` briefly swept
  the foreign m25 staging files into the commit (caught and removed before
  push); (2) first push failed CI because refresh-indexes.sh had fixed only
  the worktree copies while `git commit` shipped stale index tables with
  rows for files absent from the commit — fixed by staging explicitly and
  verifying the COMMIT in a detached worktree before pushing. Lesson: gate
  the tree you ship, not the one you see.

