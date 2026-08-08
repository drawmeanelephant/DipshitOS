# Coordination logs (append-only, per branch)

**Why this exists:** the project changelog used to live entirely inside
`docs/status.md`. Every agent appended to that one file, so parallel work
collided on every merge — PR #8/#10 collided once, and PR #12/#13 collided
again on the same section. Coordination state is now **sharded by branch**:
each branch owns its own log file, and cross-branch merges never touch the
same lines.

**The rule is unchanged and still binding** (AGENTS.md): log files are
**append-only**. Never rewrite or delete an entry — including entries in
other branches' logs. Corrections are *new* entries that reference the old
one.

## How to log

1. Your branch's log file is `docs/logs/<branch-slug>.md` (e.g.
   `agent/buffy/m15-commands` → `docs/logs/agent-buffy-m15-commands.md`).
   Create it on your first entry.
2. **Append** an entry in this format:

   `- **YYYY-MM-DD** — *owner (branch)*: claim → what changed → evidence → status.`

   Status legend: ⬜ claimed · 🔄 in progress · ✅ done · ⛔ blocked.
3. Cite `artifacts/` evidence files. No observed claim without a saved log.
4. Do **not** edit `docs/status.md` for logging — only for milestone-level
   facts (position, gates). Per-step progress goes in the per-milestone
   tracker (`docs/march-m15.md`); per-work detail goes here and in your
   claim file. If you must touch `README.md`/`roadmap.md`/`testing.md`,
   prefer pointer-level changes.
5. Run `bash tools/status/refresh-indexes.sh` to regenerate the
   [Log index](#log-index) below — it is **generated from the log files**,
   so never hand-edit it (hand-appending rows to a shared table is how
   parallel branches collide on merge).

## Log index

**This table is generated** from the log files by
`bash tools/status/refresh-indexes.sh` — do not hand-edit it. The
coordination gate (`bash tools/verify-coordination.sh`, `just
verify-coordination`, and CI) fails if it drifts from the files.

<!-- LOGS_INDEX:START -->
| Branch | Log file |
|--------|----------|
| `agent/buffy/m15-commands` (PR #12) | [`agent-buffy-m15-commands.md`](agent-buffy-m15-commands.md) |
| `agent/buffy/m15-host-plumbing` (PR #13) | [`agent-buffy-m15-host-plumbing.md`](agent-buffy-m15-host-plumbing.md) |
| `agent/buffy/m15-machine-controls` | [`agent-buffy-m15-machine-controls.md`](agent-buffy-m15-machine-controls.md) |
| `agent/buffy/m15-milestone-docs` | [`agent-buffy-m15-milestone-docs.md`](agent-buffy-m15-milestone-docs.md) |
| `agent/buffy/m15-nvram-console` | [`agent-buffy-m15-nvram-console.md`](agent-buffy-m15-nvram-console.md) |
| M1.5 console & shell core (agent B) | [`agent-buffy-m15-shell-core.md`](agent-buffy-m15-shell-core.md) |
| `agent/buffy/m15-vz-serial-gate` | [`agent-buffy-m15-vz-serial-gate.md`](agent-buffy-m15-vz-serial-gate.md) |
| `agent/buffy/m2-badhandoff-fix` (PR #11) | [`agent-buffy-m2-badhandoff-fix.md`](agent-buffy-m2-badhandoff-fix.md) |
| `agent/buffy/m2-kernel-proper` (PR #10) | [`agent-buffy-m2-kernel-proper.md`](agent-buffy-m2-kernel-proper.md) |
| M2 fixed-memory-marker fallback (ADR 0004 D4, gate work item 3) | [`agent-buffy-m2-marker-fallback.md`](agent-buffy-m2-marker-fallback.md) |
| freebuff/docs-reconciliation-m15-status-20260808 | [`freebuff-docs-reconciliation-m15-status-20260808.md`](freebuff-docs-reconciliation-m15-status-20260808.md) |
| M2 MMU-takeover root cause & fix (claim 0010) | [`freebuff-grab-newest-files-from-github-and-pick-something-t-a3eb337e-4b37-4bae-8548-242c49be7456.md`](freebuff-grab-newest-files-from-github-and-pick-something-t-a3eb337e-4b37-4bae-8548-242c49be7456.md) |
| Status re-verification on merged main (claim 0014) | [`freebuff-let-s-get-the-latest-github-and-do-something-benef-e128807b-0418-4d4e-aebe-ba30b18c18c5.md`](freebuff-let-s-get-the-latest-github-and-do-something-benef-e128807b-0418-4d4e-aebe-ba30b18c18c5.md) |
| M1.5 transcript test automation (`freebuff/m15-transcript-test`) | [`freebuff-m15-transcript-test.md`](freebuff-m15-transcript-test.md) |
| freebuff/mainzig-modules | [`freebuff-mainzig-modules.md`](freebuff-mainzig-modules.md) |
| Coordination-tooling hardening (claim 1801) | [`freebuff-make-sure-git-is-current-first-18548850-6288-40ff-bca2-007971e567ac.md`](freebuff-make-sure-git-is-current-first-18548850-6288-40ff-bca2-007971e567ac.md) |
| `freebuff/mmu-debt-contract` | [`freebuff-mmu-debt-contract.md`](freebuff-mmu-debt-contract.md) |
| status-preflight review (claim 8592) | [`freebuff-pull-latest-dipshitos-main-after-all-preceding-rel-1fe779b0-133e-4303-81f1-397087634352.md`](freebuff-pull-latest-dipshitos-main-after-all-preceding-rel-1fe779b0-133e-4303-81f1-397087634352.md) |
| verification gate classification (claim 0594) | [`freebuff-pull-latest-dipshitos-main-ebe15999-a14a-4066-9551-00deb3d2323a.md`](freebuff-pull-latest-dipshitos-main-ebe15999-a14a-4066-9551-00deb3d2323a.md) |
| `freebuff/pull-the-latest-dipshitos-main-after-the-virtio-pc-fc4c7c03-1dba-4af3-857d-af8cfa2c1e91` | [`freebuff-pull-the-latest-dipshitos-main-after-the-virtio-pc-fc4c7c03-1dba-4af3-857d-af8cfa2c1e91.md`](freebuff-pull-the-latest-dipshitos-main-after-the-virtio-pc-fc4c7c03-1dba-4af3-857d-af8cfa2c1e91.md) |
| freebuff/pull-the-latest-from-github-and-find-something-in--a639920e (serial device discovery) | [`freebuff-pull-the-latest-from-github-and-find-something-in--a639920e-ebe1-47a0-a380-54cece9b4c40.md`](freebuff-pull-the-latest-from-github-and-find-something-in--a639920e-ebe1-47a0-a380-54cece9b4c40.md) |
| `freebuff/ragshit-impact` | [`freebuff-ragshit-impact.md`](freebuff-ragshit-impact.md) |
| `freebuff/ragshit-review` | [`freebuff-ragshit-review.md`](freebuff-ragshit-review.md) |
| stale-doc cleanup (claim 3109) | [`freebuff-stale-doc-cleanup.md`](freebuff-stale-doc-cleanup.md) |
| ragshit review coverage truncation (claim 0176) | [`freebuff-start-from-current-dipshitos-main-record-the-exact-af2bed0e-1f29-49ea-b233-bf528e5ce88e.md`](freebuff-start-from-current-dipshitos-main-record-the-exact-af2bed0e-1f29-49ea-b233-bf528e5ce88e.md) |
| freebuff/start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2 | [`freebuff-start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2.md`](freebuff-start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2.md) |
| `freebuff/t0sz16-startlevel-diag` | [`freebuff-t0sz16-startlevel-diag.md`](freebuff-t0sz16-startlevel-diag.md) |
| freebuff/you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d | [`freebuff-you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d.md`](freebuff-you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d.md) |
| M1.5 tracker origin (pre-branch era) | [`m1.5-tracker.md`](m1.5-tracker.md) |
<!-- LOGS_INDEX:END -->
