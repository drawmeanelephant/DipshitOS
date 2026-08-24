# Claim: claim lifecycle — declared files + staleness

- **Owner:** ox-alpha (`agent/ox-alpha/claim-lifecycle`)
- **Status:** ✅ done 2026-08-24 — PR #527 merged (8420a89): Touches overlap gate + staleness warnings live; test suite 19/19; AGENTS.md/TEMPLATE/README conventions landed
- **Depends on:** 2564 (tracked-only gate), 4928 (per-agent worktrees)
- **Touches:** tools/verify-coordination.sh, tools/status/test-coordination.sh, docs/claims/TEMPLATE.md, docs/claims/README.md, AGENTS.md, docs/claims/2564-tracked-only-coordination-gate.md, docs/claims/4928-per-agent-worktrees.md

## Problem

Issue #523 items 4 and 5:

- **(4) Lane ownership is prose-only.** Contested-file assignments live in
  docs/agent-concurrency-plan.md prose; nothing machine-checkable stops two
  active claims from declaring the same contested file
  (`kernel/src/driving_award.zig`, `shell.zig`, `text.zig`). Collisions are
  found when a PR fails CI, not at claim time.
- **(5) Claims never go stale.** An abandoned 🔄 claim blocks its gap
  forever; nothing surfaces age.

Claims also do not say which files they will touch, so there is nothing to
check conflicts against.

## Fix

- TEMPLATE.md gains two optional fields: `- **Touches:**` (comma-separated
  repo paths/prefix globs the work will edit) and `- **Heartbeat:**`
  (YYYY-MM-DD check-in date).
- verify-coordination.sh: for ACTIVE (🔄) tracked claims —
  - fail when two claims with different Owner branches declare overlapping
    Touches entries (exact match or `prefix*` glob);
  - warn (non-failing) when a 🔄 claim's last-touching commit is older than
    STALE_DAYS (default 14); docs set the convention that after ~21 days
    anyone may flip it ⛔ via their own log entry.
- Fields are optional so the 90+ grandfathered claim files stay valid;
  enforcement grows as claims adopt the fields.

Also flips claims 2564 and 4928 to ✅ (both merged: #525, #526).

## Verification

- test-coordination.sh new cases: conflicting active Touches fail the gate;
  stale 🔄 claim warns without failing; disjoint Touches pass.
- Full class-A coordination suite green on this branch.
