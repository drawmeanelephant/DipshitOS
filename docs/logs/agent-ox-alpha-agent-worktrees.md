# Log — per-agent worktrees

- **2026-08-23** — *ox-alpha*: Opened. Shared-checkout fallout keeps
  recurring (PR #524's false coordination failure via foreign untracked
  staging files; claim 2564 made the gate immune, but builds and live VM
  gates still share one tree). Adding `just new-agent` / `resume-agent` /
  `drop-agent` / `list-agents` helpers with canonical naming
  (`../dipshitos-<name>`, branch `agent/<name>/<slug>`) and mandating the
  workflow in AGENTS.md. Implements issue #523 item 1. Claim 4928.
