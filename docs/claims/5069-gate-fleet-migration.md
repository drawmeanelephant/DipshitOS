# Claim: migrate every class-B live gate to run isolation + repair stale expectations (#528)

- **Owner:** ox-alpha (`agent/ox-alpha/gate-fleet-migration`)
- **Prompt / plan:** issue #528 (gate-rot audit) + issue #523 item 2 template landed on main (claim 6637 / PR #529, tools/lib/gate-run.sh + tools/verify-live-net-tcp.sh)
- **Scope:** fleet migration of the remaining unmigrated `tools/verify-live-*.sh` class-B gates: (1) per-run isolation via gate_begin/gate_end ($RUN_DIR, GATE_RUNNER_ARGS overlays or private writable copies, per-run --vars/--serial); (2) rot-class-1 expects — replace `<marker>\ndipshit> ` prompt-suffix expects with OUTPUT-ONLY substrings (prompt ANSI-colored since M18 T5, claim 0163); (3) rot-class-2 stale counter-line asserts aligned to observed bytes with citation comments; (4) rot-class-3 host-dependent observation runs made env-selectable defaulting to today's behavior.
- **Touches:** tools/verify-live-* docs/gate-inventory.md
- **Depends on:** PR #529 (tools/lib/gate-run.sh) — already on origin/main
- **Heartbeat:** 2026-08-24 (batch 6 done: 31 gates migrated; win-family pixel red confirmed pre-existing on main)
- **Status:** 🔄 in progress

## Notes

Method: small batches of related gates; after each batch every migrated gate
runs end-to-end on this host with rc=0 required before moving on. Any gate
that fails is first reproduced on unmodified origin/main (detached baseline
worktree) to separate pre-existing rot from migration damage. Expectation
changes quote observed serial bytes; semantics changed by later milestones
cite the claiming march doc. Pre-existing reds (e.g. live-pointer-cg's
Accessibility-trust self-gate, issue #151) are cited, not rewritten.

Verification bar: every migrated gate rc=0 individually; ≥2 different gates
demonstrated running CONCURRENTLY (distinct DIPSHIT_GATE_SUFFIXes, both
rc=0); verify-coordination.sh + test-coordination.sh green; final commit
re-verified inside a detached worktree before pushing (staging trap, see
docs/logs/agent-ox-alpha-coordination-tracked-gate.md).

Evidence under artifacts/: per-gate gate logs + reports, concurrency proof,
baseline-comparison notes.
