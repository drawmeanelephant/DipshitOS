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

## Claim numbers (deterministic, collision-resistant)

Claims used to be numbered sequentially ("next NNNN"). That collided when
two agents claimed concurrently: claim 0013 was claimed by serial-discovery
at 10:27 and by status-reverify at 15:18 on the same day, and the loser had
to be manually renumbered to 0014 (commit `be811cb`).

Numbers are now derived from the claim itself, so concurrent claimers pick
different IDs without editing any shared file:

```sh
bash tools/status/claim-id.sh "<branch>" "<slug>"
```

The ID is `0024 + (cksum("<branch>:<slug>") % 9976)` — deterministic,
reproducible on any machine, and always in `[0024, 9999]`. Claims
`0001–0023` are grandfathered sequential numbers; `0024+` is enforced by
`verify-coordination.sh`, which recomputes the ID from each claim file
(owner branch + filename slug) and fails on a mismatch, so a hand-picked
"next" number cannot slip through. If the extremely rare hash collision
happens (same ID from different branch/slug pairs), the duplicate-number
check fails the gate — change the slug and the ID changes.

## How to claim

1. Pick a kebab-case slug for the work and derive the number:
   `bash tools/status/claim-id.sh "<branch>" "<slug>"` → `NNNN`. Copy
   [`TEMPLATE.md`](TEMPLATE.md) to `docs/claims/<NNNN>-<slug>.md`.
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
| [0023-mainzig-module-split](0023-mainzig-module-split.md) | buffy (`freebuff/mainzig-modules`) | ✅ done 2026-08-07 — main.zig split into mmio/mmu/pci/evidence/virtio_console (2508 → 758 lines); KERNEL.BIN byte-identical (580312 B, sha 55325752…) across every extraction; verify-marker + verify-nvram-console ladders unchanged (final M2_TXST!); all portable gates + all 9 diagnostic builds pass (evidence under artifacts/mainzig-*) |
| [0176-ragshit-review-coverage-truncation](0176-ragshit-review-coverage-truncation.md) | buffy (`freebuff/start-from-current-dipshitos-main-record-the-exact-af2bed0e-1f29-49ea-b233-bf528e5ce88e`) | ✅ done 2026-08-08 — anchor-aware truncation + weak/truncated coverage landed (`tools/ragshit/src/ragshit/review/{candidates,coverage,selection,report}.py`, framing-loop plateau fix in `cli.py`); full suite 147 passed / 1 skipped, doctor ok, dogfood at 20k/30k/40k/60k with exact size accounting and byte-identical duplicate runs; before/after packets under `artifacts/ragshit-0176/` |
| [0594-verify-gate-classification](0594-verify-gate-classification.md) | buffy (`freebuff/pull-latest-dipshitos-main-ebe15999-a14a-4066-9551-00deb3d2323a`) | ✅ done 2026-08-08 — classification + inventory + aggregates landed; full class-A set green, coordination gate green |
| [1801-coordination-hardening](1801-coordination-hardening.md) | buffy (`freebuff/make-sure-git-is-current-first-18548850-6288-40ff-bca2-007971e567ac`) | ✅ done 2026-08-08 — escaping, deterministic claim IDs (gate-enforced 0024+), structural table validation, and 15 positive/negative tests landed; all coordination gates + verify-mmu-debt pass (log entry documents exact before/after) |
| [3109-stale-doc-cleanup](3109-stale-doc-cleanup.md) | buffy (`freebuff/stale-doc-cleanup`) | ✅ done 2026-08-08 — stale blocker snapshots removed/corrected across README, roadmap, architecture, testing, hardware-contract, march-m15; before/after stale-phrase report in `artifacts/stale-doc-report.txt` (26 → 0 hits); link check clean; `docs/status.md` untouched |
| [3320-ragshit-dogfood-hardening](3320-ragshit-dogfood-hardening.md) | buffy (`freebuff/you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d`) | ✅ done 2026-08-08 — A/B/C/D/F/G landed; stale BAR-rebase comment corrected (E); suite 137 passed + 1 skipped, doctor/coordination/portable gates green; evidence under `artifacts/ragshit-dogfood-20260808/` |
| [4922-verify-ragshit-0176-landing](4922-verify-ragshit-0176-landing.md) | buffy (`freebuff/make-sure-git-main-is-current-7f307de5-d3c0-4d90-966c-3a4221ad4d24`) | ✅ done 2026-08-08 — verification complete: pre-fix defect reproduced exactly (`p…` one-line `virtio_pci_init` + `changed_symbols: 40 / 40 (100%)`), post-fix packet renders signature + changed region with 13 weak symbols (27/40, never 100% while weak exist); full suite 147 passed / 1 skipped, doctor ok, dogfood at 20k/30k/40k/60k with exact size accounting (`len(md)` == `actual_size` == `selection_summary.actual_chars`) and byte-identical duplicate runs, envelope never used; new weak-coverage regression tests fail on the pre-fix code (8 failed / 2 passed). Evidence committed to the repo under `artifacts/ragshit-0176/` (force-added over the `artifacts/*` gitignore, docs-reconciliation precedent): `before-40000.{md,json}`, `after-40000.{md,json}`, `dogfood-{20000,30000,40000,60000}.md`, `verification-summary.txt` (the dogfood `.json` copies are byte-reproducible and kept out of the repo) |
| [6460-t0sz16-start-level](6460-t0sz16-start-level.md) | buffy (`freebuff/t0sz16-startlevel-diag`) | ✅ done 2026-08-08 — **T0SZ=16 lets the first post-MMU virtio-pci TX complete end-to-end in 6/18 boots across three independent runs (2/6, 3/6, 1/6): phase C returns, `used.idx` advances, exact payload in `vm-serial.log`, kernel reaches the live `dipshit>` shell; 12/18 still hang at the same boundary — hypothesis strengthened, not reproducible** (evidence under `artifacts/t0sz16-compare-final.txt`, `t0sz16-report-baseline.txt`, `t0sz16-report-candidate-18.txt`, `t0sz16-gate.txt`, `t0sz16-{baseline,candidate}-{run,marker,serial}-*.{txt,log}`, `t0sz16-run{1,2,3}/` per-run batches) |
| [7256-status-postmmu-reconcile](7256-status-postmmu-reconcile.md) | buffy (`freebuff/start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2`) | ✅ done 2026-08-08 — stable-context docs reconciled at main `c7d9644`; every targeted phrase corrected (post-exit→post-MMU blocker wording, claim-0015-executed "Next step", item-3 "no usable device" superseded pointer, "block device register layout" typo, march steps 8/9/19, claim 6460 cited in the canonical blocker); coordination gate, index check, link check (103 links + 14 anchors, 0 broken), and before/after stale grep all pass (audit under `artifacts/docs-reconciliation-20260808-followup/`) |
| [8592-status-preflight](8592-status-preflight.md) | buffy (`freebuff/pull-latest-dipshitos-main-after-all-preceding-rel-1fe779b0-133e-4303-81f1-397087634352`) | ✅ done 2026-08-08 — report at `artifacts/status-preflight.md`; all class-A + class-B gates re-run at HEAD `5160eef` (evidence `artifacts/status-preflight-*.txt`); snapshots regenerated |
| [8623-docs-reconciliation-m15-status](8623-docs-reconciliation-m15-status.md) | buffy (`freebuff/docs-reconciliation-m15-status-20260808`) | ✅ done 2026-08-08 — docs/status.md and docs/march-m15.md reconciled against claims 0013/0015/0017/0018/0020/0021/0022 and ADRs 0004/0005/0006; verification gates pass (see artifacts/docs-reconciliation-20260808/) |
| [9112-ragshit-review](9112-ragshit-review.md) | buffy (`freebuff/ragshit-review`) | ✅ done 2026-08-08 — `ragshit review . HEAD~5..HEAD --budget-chars 30000` deterministic budgeted packet; 124 passed, doctor ok, coordination ok, dogfood HEAD~1/~5/~10 at 10k/25k/50k under artifacts/review-packets/; baseline comparison measurably improved |
<!-- CLAIMS_INDEX:END -->
