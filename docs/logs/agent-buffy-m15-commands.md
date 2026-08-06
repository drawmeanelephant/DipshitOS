# Log — `agent/buffy/m15-commands` (PR #12)

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-06** — **Claim (buffy, `agent/buffy/m15-commands`):** claimed
  the M1.5 commands & personality row (steps 12–18). Per the C-prompt
  process gate: design written first (`docs/m15-commands-design.md`), all
  code in new `kernel/src/*.zig` modules (`console.zig`, `monitor.zig`,
  `handoff.zig`, `memmap.zig`) with host-side `zig test` coverage against a
  mock console; `kernel/src/main.zig` untouched. 🔄 in progress — no code
  written yet.
- **2026-08-06** — **M1.5 commands & personality slice done (buffy,
  `agent/buffy/m15-commands`):** implemented and host-tested the monitor
  command layer in four new kernel modules: `console.zig` (transport-agnostic
  `Console` interface + bounded `MockConsole`), `handoff.zig` (handoff-v2
  struct + validation, ADR 0004 D5), `memmap.zig` (captured-map view +
  saturating summary), `monitor.zig` (comptime registry, `lookup`/`exec`,
  `MachineControl` interface + honest `disabled()` default, all 14 commands:
  help/about/version/uname/handoff/mem/echo/clear/hex/repeat/reboot/shutdown/
  elephant/beans, boot-message pool + banner). Design in
  `docs/m15-commands-design.md`. **Observed:** `zig fmt --check` pass,
  `zig build`/`zig build image`/`zig build inspect` pass (no regression),
  `zig test` 53/53 pass on the host (console 7, handoff 3, memmap 5, monitor
  38) — no VZ, no serial device; evidence `artifacts/m15-commands-{fmt,build,
  image,inspect,tests}.txt`. Step-15 fs decision recorded (defer to storage
  milestone; hard gates 5/6 stay open). `kernel/src/main.zig` has zero diff
  (gate 3). ✅ — on branch awaiting merge through the
  `m1.5-interactive-monitor` integration branch.
- **2026-08-06** — **Correction (buffy, `agent/buffy/m15-commands`):**
  the `m1.5-interactive-monitor` integration branch was **never created**;
  streams A and C targeted `main` directly per ADR 0003 / branch
  protection (PRs #12/#13 — see march step 3 in `docs/status.md`). This
  entry supersedes the "awaiting merge through the integration branch"
  wording in the slice-done entry above. ✅
- **2026-08-06** — **Claim — status-system merge hardening (buffy,
  `agent/buffy/m15-commands`):** claimed
  `docs/claims/0007-status-sharding-hardening.md` before writing code.
  Plan: generate the claim/log index tables from the files (no more
  hand-editing shared tables), add a coordination verify gate, and shrink
  `docs/status.md`'s remaining shared edit surface (claims table →
  pointer; last changelog stragglers → per-branch logs). 🔄 in progress.
- **2026-08-06** — **Migration note:** the two entries below were moved
  verbatim out of `docs/status.md`'s changelog section (reduced to a
  pointer 2026-08-06); they were originally logged against this branch.
- **2026-08-06** — **Status system sharded for multiagent safety (buffy,
  `agent/buffy/m15-commands`):** the append-only changelog moved out of
  this file into per-branch logs under `docs/logs/` (historical entries
  migrated verbatim), and claims moved into per-claim files under
  `docs/claims/` (TEMPLATE + index). `docs/status.md` now holds only
  milestone-level facts (position, gates, march) plus pointers to the
  shards. Rationale: PR #12 and PR #13 both appended to this file's
  changelog and collided; sharding makes parallel appends conflict-free.
  ✅ — see `docs/logs/README.md` and `docs/claims/README.md`.
- **2026-08-06** — **PR #12 merged onto current `main` (buffy,
  `agent/buffy/m15-commands`):** merged `origin/main` (PR #13 host
  plumbing + CI unit-test gate) into this branch and resolved the
  `docs/status.md` changelog collision by preserving both sides' entries
  (append-only). The commands & personality slice is now mergeable against
  `main`. ✅ — on branch awaiting merge.
- **2026-08-06** — **Status-system merge hardening done (buffy,
  `agent/buffy/m15-commands`):** implemented `docs/claims/0007-status-sharding-hardening.md`.
  The claim/log index tables are now **generated** from the files
  (`tools/status/refresh-indexes.sh`), so claiming/logging is create-file
  + run-script — no more hand-editing shared tables (the #12/#13
  collision class). `docs/status.md` shrank to pointers: its claims table
  is gone and its last two changelog entries were migrated verbatim to
  this log (migration note above). New gate
  `tools/verify-coordination.sh` (`just verify-coordination`, added to
  `just verify` and CI) validates claim/log files and fails on index
  drift. **Observed:** `bash tools/status/refresh-indexes.sh` + `bash
  tools/verify-coordination.sh` exit 0; `--check` is idempotent; a
  deliberately hand-edited index fails the gate (exit 1) with a
  "run refresh-indexes.sh" message, then passes again after restore. ✅
- **2026-08-06** — **Supplement — march moved out of status.md (buffy,
  `agent/buffy/m15-commands`):** review feedback flagged `docs/status.md`'s
  twenty-step march + agent-split tables as the remaining shared edit
  surface (agents marking steps collided with gate/status edits). Moved
  verbatim to the per-milestone `docs/march-m15.md`; `docs/status.md`
  holds pointers only. `tools/verify-coordination.sh` now enforces the
  invariants (no changelog entries / claims rows / march / agent-split in
  `docs/status.md`), `refresh-indexes.sh` is self-verifying after splice,
  and log-header parsing tolerates `—`/`-`. Prompts/roadmap/logs-README
  pointers updated. **Observed:** `verify-coordination.sh` exits 0.
  Supersedes the "status.md shrank to pointers" claim in the entry above
  for the march portion (the earlier entry covered claims + changelog
  only). ✅
- **2026-08-06** — **Supplement 2 — gate-work statuses out of status.md
  (buffy, `agent/buffy/m15-commands`):** second review pass flagged the
  "Immediate gate work" section as the last inline status surface (gate
  pass results were edited into status.md). Its statuses are now pointers
  to the claim files (0001 ✅ / 0002 ⬜ / marker fallback unclaimed); the
  verify gate gained content-based tripwires for the march/agent-split
  tables (catches re-added tables under any heading), an existence check
  for `docs/march-m15.md`, and a comment on the strict em-dash log header.
  **Observed:** `verify-coordination.sh` exits 0; negative test (march
  table re-added to status.md) exits 1, passes again after restore. ✅
