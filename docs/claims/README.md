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
| [0011-m15-machine-controls](0011-m15-machine-controls.md) | buffy (`agent/buffy/m15-machine-controls`) | ⛔ live gate blocked 2026-08-07 — real `ResetSystem` |
| [0012-m15-milestone-docs](0012-m15-milestone-docs.md) | buffy (`agent/buffy/m15-milestone-docs`) | ✅ done 2026-08-07 — README/roadmap/architecture/testing |
| [0013-m15-serial-discovery](0013-m15-serial-discovery.md) | buffy (`freebuff/pull-the-latest-from-github-and-find-something-in--a639920e-ebe1-47a0-a380-54cece9b4c40`) | ⛔ blocked (closed honestly — discovery complete, gate not passed) |
| [0014-status-reverify](0014-status-reverify.md) | buffy (`freebuff/let-s-get-the-latest-github-and-do-something-benef-e128807b-0418-4d4e-aebe-ba30b18c18c5`) | ✅ done 2026-08-07 — all gates re-run green on merged `main`; evidence saved under `artifacts/` and cited in `docs/status.md` |
| [0015-nvram-console](0015-nvram-console.md) | buffy (`agent/buffy/m15-nvram-console`) | ✅ done 2026-08-07 (gate passing — post-exit console bytes |
| [0016-virtio-pci-spec-review](0016-virtio-pci-spec-review.md) | buffy (`agent/buffy/m15-nvram-console`) | ✅ done 2026-08-07 (evidence under `artifacts/virtio-spec-review-20260807.txt`) |
| [0017-preexit-virtio-tx](0017-preexit-virtio-tx.md) | buffy (`freebuff/pull-the-latest-dipshitos-main-after-the-virtio-pc-fc4c7c03-1dba-4af3-857d-af8cfa2c1e91`) | ✅ done 2026-08-07 — **A. PRE-EXIT TX WORKS, OBSERVED** (evidence under `artifacts/preexit-tx-gate.txt`, `artifacts/preexit-tx-run.txt`, `artifacts/preexit-marker-dump.txt`, `artifacts/vm-serial.log`, `artifacts/efi-vars.bin`) |
| [0018-postexit-tx-bisect](0018-postexit-tx-bisect.md) | buffy (`freebuff/pull-the-latest-dipshitos-main-after-the-virtio-pc-fc4c7c03-1dba-4af3-857d-af8cfa2c1e91`) | ✅ done 2026-08-07 — **smallest confirmed failure interval: `M2_TXBR!` written, `M2_TXAR!` absent** — 10/12 boots stop at `M2_TXBR!` (evidence under `artifacts/tx-diag-gate.txt`, `tx-diag-run-N.txt`, `tx-diag-marker-N.txt`, `tx-diag-serial-N.log`, `tx-diag-report.txt`) |
| [0019-ragshit-impact](0019-ragshit-impact.md) | buffy (`freebuff/ragshit-impact`) | ✅ done 2026-08-07 — `ragshit impact . HEAD~5..HEAD` deterministic, provenance-backed; tests 99 passed, doctor ok, dogfood HEAD~1/~5/~10 saved under artifacts/ |
| [0020-tx-transition-matrix](0020-tx-transition-matrix.md) | buffy (`freebuff/pull-the-latest-dipshitos-main-after-the-virtio-pc-fc4c7c03-1dba-4af3-857d-af8cfa2c1e91`) | ✅ done 2026-08-07 — **the transition that destroys access is the MMU switch (B→C); ExitBootServices is exonerated** (evidence under `artifacts/transition-gate.txt`, `transition-report.txt`, `transition-matrix.txt`, `transition-run-{a,b,c,d}-*.txt`, `transition-serial-*.log`) |
| [0021-fw-mmu-capture](0021-fw-mmu-capture.md) | buffy (`freebuff/mmu-debt-contract`) | ✅ done 2026-08-07 — firmware MMU state + BAR-window walk captured; **firmware and kernel use byte-identical memory attributes** (evidence under `artifacts/fw-mmu-capture-gate.txt`, `fw-mmu-capture-lines.txt`, `fw-mmu-capture-efi-vars.bin`, `fw-mmu-capture-run.txt`) |
| [0022-mmu-debt-boundary](0022-mmu-debt-boundary.md) | buffy (`freebuff/mmu-debt-contract`) | ✅ done 2026-08-07 — ADR 0006 landed, ADR 0004 D3 addendum + hardware-contract updated, deterministic `verify-mmu-debt` gate wired into just verify + CI (evidence under `artifacts/mmu-debt-gate.txt`) |
| [0023-ragshit-review](0023-ragshit-review.md) | buffy (`freebuff/ragshit-review`) | ✅ done 2026-08-08 — `ragshit review . HEAD~5..HEAD --budget-chars 30000` deterministic budgeted packet; 124 passed, doctor ok, coordination ok, dogfood HEAD~1/~5/~10 at 10k/25k/50k under artifacts/review-packets/; baseline comparison measurably improved |
<!-- CLAIMS_INDEX:END -->
