# Log — `agent/buffy/m2-kernel-proper` (PR #10)

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-06** — **PR #10** (buffy, `agent/buffy/m2-kernel-proper): added
  the gate-status evidence table (build gates green; VZ serial gate unpassed;
  bad-handoff gate re-verified failing with no `RC.TXT`), the two
  planning-first prompt docs for the immediate gate work
  (`docs/m2-bad-handoff-fix-prompt.md`, `docs/m2-vz-serial-gate-prompt.md`),
  housekeeping (`just verify*` aliases, context-snapshot coverage,
  `.DS_Store` cleanup), and this changelog machinery. ✅ written — on the PR
  branch awaiting review; reconciled with `main`'s M1.5 tracker in the
  conflict-resolution entry below.
- **2026-08-06** — **Conflict resolution:** PR #8's M1.5 tracker and PR
  #10's gate evidence collided on `docs/status.md` + `README.md`. Unified
  this file (M1.5 plan + gate evidence + coordination rules), resolved
  `README.md`, and preserved both sides' roadmap/testing/architecture edits
  via a clean merge of `origin/main` into the PR branch. ✅ done — awaits
  merge review.
- **2026-08-06** — **Reconciliation detail:** M1.5 march steps 1 and 2 are
  marked ✅ — this file *is* the frozen scope document, and the finish line
  / hard gates are defined above — and the active-claims "how to claim"
  convention was added so the claim-before-you-start rule is expressible. ✅
