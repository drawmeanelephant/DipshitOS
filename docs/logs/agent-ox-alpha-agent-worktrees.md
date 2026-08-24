# Log — per-agent worktrees

- **2026-08-23** — *ox-alpha*: Opened. Shared-checkout fallout keeps
  recurring (PR #524's false coordination failure via foreign untracked
  staging files; claim 2564 made the gate immune, but builds and live VM
  gates still share one tree). Adding `just new-agent` / `resume-agent` /
  `drop-agent` / `list-agents` helpers with canonical naming
  (`../dipshitos-<name>`, branch `agent/<name>/<slug>`) and mandating the
  workflow in AGENTS.md. Implements issue #523 item 1. Claim 4928.

- **2026-08-24** — *ox-alpha*: DONE. PR #526 merged. `just` was not installed
  on the dev host until now (`brew install just`, v1.58.0). Round-trip
  selftest proved the recipes; `list-agents` surfaced four pre-existing
  ad-hoc worktrees under `../dipshitos-wt/` with non-canonical naming —
  agents were already escaping the shared checkout unsystematically. Merge
  conflict in the generated index regions was resolved by the user via
  "accept both", which happened to be safe (disjoint sorted positions);
  verified the committed tree in a detached worktree before merge.
