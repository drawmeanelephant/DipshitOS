# Log — `codex/el0-svc-task`

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-09** — *Codex*: claim 8215 filed at `3436676`; isolated worktree
  created so the concurrent PRs #55/#56 documentation reconciliation remains
  untouched. Scope is a minimal real EL0 task, SVC kernel boundary, focused
  host tests, and live VZ evidence; no process/address-space abstraction and no
  edits to `docs/status.md`, `docs/hardware-contract.md`, or `docs/roadmap.md`.
  · 🔄 in progress

- **2026-08-09** — *Codex*: claim 8215 completed. Added one page-isolated
  EL0t payload with dedicated EL0 text/stack permissions, per-task SP_EL0
  scheduling, a minimal x8/x0 SVC ABI, and a strict live VZ gate. Corrected
  the SPSR M=0x5 decode to EL1h and the vector-frame x0/x30 layout while
  extending exception return to carry the selected SP_EL0. Direct evidence:
  userspace gate PASS 3/3 with two sequenced SVCs; tasks, timer, and exception
  live regressions PASS 1/1 each; complete portable suite, byte-identical
  transcript, ELF section inspection, coordination, and MMU-debt gates PASS.
  The work deliberately leaves processes, loaders, separate address spaces,
  and the concurrent milestone documentation files untouched. · ✅ done
