# Claim: per-agent worktrees

- **Owner:** ox-alpha (`agent/ox-alpha/agent-worktrees`)
- **Status:** 🔄 `agent/ox-alpha/agent-worktrees`
- **Depends on:** 2564 (tracked-only coordination gate — complementary; that fix made the gate immune to shared-checkout leaks, this removes the shared checkout)

## Problem

Concurrent agents have been working in one checkout. Consequences observed
2026-08-23: foreign untracked staging files failed an unrelated branch's
coordination gate (PR #524, fixed by claim 2564), builds contend for the
same `.build` caches, and live VM gates share `artifacts/disk.img` +
`artifacts/vm-serial.log`. Issue #523 item 1 ("one checkout per agent via
git worktree") is the structural fix.

## Fix

`just` helpers making per-agent worktrees the default workflow, with a
standard naming scheme so agents stop inventing different layouts:

- `just new-agent <name> <slug>` → worktree at `../dipshitos-<name>`, new
  branch `agent/<name>/<slug>` off `origin/main`
- `just resume-agent <name> <branch>` → reattach an existing branch into a
  fresh worktree
- `just drop-agent <name>` → remove the worktree
- `just list-agents` → show all worktrees

Each worktree gets its own `.build/` and `artifacts/`, so class-B VM gates
and builds of concurrent agents cannot collide. AGENTS.md coordination
rules updated to mandate this.

## Verification

- Round-trip selftest executed on this machine: `new-agent zz-selftest …`
  creates the worktree + branch, gate suite passes inside it,
  `drop-agent zz-selftest` removes both cleanly.
- `verify-coordination.sh` + `test-coordination.sh` pass on this branch.
