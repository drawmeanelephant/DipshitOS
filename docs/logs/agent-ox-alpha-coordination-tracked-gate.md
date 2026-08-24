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
