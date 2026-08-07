# Active claims (one file per claim)

**Why this exists:** claims used to live in a single table inside
`docs/status.md`. Every agent edited that table to claim work, so parallel
agents collided on the same file (PR #8/#10, then PR #12/#13). Claims are
now **one file per claim**: claiming work means creating a new file, never
editing a shared table.

**The rule is unchanged and still binding** (AGENTS.md): claim **before**
you start. Non-trivial work gets a claim file (and a log entry in
`docs/logs/<branch>.md`) *before* code is written. Unclaimed work is fair
game; claimed work is not.

## How to claim

1. Copy [`TEMPLATE.md`](TEMPLATE.md) to `docs/claims/<NNNN>-<slug>.md`
   (next number, kebab-case slug).
2. Fill in Owner (agent id + branch), Prompt / plan, Scope, Depends on.
3. Set Status to `🔄 <branch>` **before** starting work.
4. Run `bash tools/status/refresh-indexes.sh` to regenerate the
   [Active claims index](#active-claims-index) below. The table is
   **generated from the claim files** — never hand-edit it (two agents
   hand-appending to the same table is exactly how parallel claims
   collide on merge).
5. On completion or blockers: flip Status in **your claim file** to `✅`
   (with evidence) or `⛔` (note why), append to `docs/logs/<branch>.md`,
   and re-run the refresh script so the index shows it.

Never edit another agent's claim file. Corrections are new entries in your
own branch's log that reference the old one.

## Active claims index

**This table is the canonical index** (status included) and it is
**generated** from the claim files by `bash tools/status/refresh-indexes.sh`
— do not hand-edit it. `docs/status.md` points here. The coordination
gate (`bash tools/verify-coordination.sh`, `just verify-coordination`, and
CI) fails if the table drifts from the claim files.

<!-- CLAIMS_INDEX:START -->
| Claim | Owner (branch) | Status |
|-------|----------------|--------|
| [0001-bad-handoff-gate](0001-bad-handoff-gate.md) | buffy (`agent/buffy/m2-badhandoff-fix`) | ✅ fixed 2026-08-06 |
| [0002-vz-serial-gate](0002-vz-serial-gate.md) | buffy (`agent/buffy/m15-vz-serial-gate`) | ⛔ blocked — gate re-run 2026-08-06 21:19, still zero serial bytes (blocker logged; no observed without a log) |
| [0003-m15-host-plumbing](0003-m15-host-plumbing.md) | buffy (`agent/buffy/m15-host-plumbing`) | ✅ 2026-08-06 — steps 4–7 landed |
| [0004-m15-console-shell-core](0004-m15-console-shell-core.md) | buffy (`freebuff/milestone-1-5-console-shell-core-agent-b-rx-read-p-2ee77bfe-eac9-4018-b5e1-ea38a0080268`) | ✅ 2026-08-06 — mock-tested loop (banner → prompt → lineedit → tokenize → exec); hardware unclaimed |
| [0005-m15-commands-personality](0005-m15-commands-personality.md) | buffy (`agent/buffy/m15-commands`) | ✅ 2026-08-06 — 14 commands host-tested, `kernel/src/main.zig` untouched |
| [0006-status-machinery](0006-status-machinery.md) | buffy (`agent/buffy/m2-kernel-proper`) | ✅ |
| [0007-status-sharding-hardening](0007-status-sharding-hardening.md) | buffy (`agent/buffy/m15-commands`) | ✅ 2026-08-06 — indexes generated; gate in just/CI; status.md pointers-only incl. gate work |
| [0008-m15-transcript-test](0008-m15-transcript-test.md) | buffy (`freebuff/m15-transcript-test`) | ✅ 2026-08-06 — mock-level transcript gate landed; live `vm-serial.log` assertion deferred to claim 0002 |
| [0009-m2-marker-fallback](0009-m2-marker-fallback.md) | buffy (`agent/buffy/m2-marker-fallback`) | ✅ done 2026-08-07 (gate work item 3 passes; evidence in |
| [0010-m2-mmu-takeover-fix](0010-m2-mmu-takeover-fix.md) | buffy (`freebuff/grab-newest-files-from-github-and-pick-something-t-a3eb337e-4b37-4bae-8548-242c49be7456`) | ✅ fixed 2026-08-07 — the MMU takeover completes on VZ; the |
| [0013-m15-serial-discovery](0013-m15-serial-discovery.md) | buffy (`freebuff/pull-the-latest-from-github-and-find-something-in--a639920e-ebe1-47a0-a380-54cece9b4c40`) | ⛔ blocked (closed honestly — discovery complete, gate not passed) |
| [0011-m15-machine-controls](0011-m15-machine-controls.md) | buffy (`agent/buffy/m15-machine-controls`) | ⛔ live gate blocked 2026-08-07 — real `ResetSystem` |
| [0012-m15-milestone-docs](0012-m15-milestone-docs.md) | buffy (`agent/buffy/m15-milestone-docs`) | ✅ done 2026-08-07 — README/roadmap/architecture/testing |
<!-- CLAIMS_INDEX:END -->
