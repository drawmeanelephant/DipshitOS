# Claim: Milestone-three documentation & coordination sync

- **Owner:** Buffy (`agent/buffy/doc-sync-m3`)
- **Prompt / plan:** user-supplied doc-sync work order — claims 8215
  (EL0/SVC) and 3594 (syscall ABI) have landed; reconcile the canonical
  tracking docs, archive dead one-shot prompt files, label frozen history,
  and update the hardware contract (virtio entropy `0x1044`).
- **Scope:** Docs + coordination surface only: `AGENTS.md` milestone
  paragraph, `README.md` next-steps blurb, `docs/march-m3.md` step 2 note,
  `docs/testing.md` M3 gate entries, six prompt files moved to
  `docs/archive/`, eight frozen docs labeled `> ARCHIVED`,
  `docs/hardware-contract.md` `0x1044` stub, `docs/roadmap.md` CSPRNG
  sketch line, and the ragshit dogfood stale threshold. **No kernel, boot,
  or host changes.**
- **Depends on:** claims 8215 (EL0/SVC), 3594 (syscall ABI), 6120
  (uaccess) — landed; the coordination gate.
- **Status:** ✅ done 2026-08-10 — AGENTS/README/march-m3/testing synced (claims 8215/3594/6120 done, per-task address spaces next); 6 one-shot prompts archived to `docs/archive/`; 8 frozen docs labeled `> ARCHIVED`; hardware-contract `0x1044` entropy stub + roadmap CSPRNG sketch line; ragshit dogfood stale threshold 12→25; indexes regenerated, `verify-coordination.sh` green. Commit/PR deferred to the in-flight `agent/buffy/m3-addrspaces` lane (its uncommitted claims 5804/6120 are already in the generated indexes; see branch log).

## Notes

Deterministic claim ID from
`bash tools/status/claim-id.sh 'agent/buffy/doc-sync-m3' 'doc-sync-m3'`
= 8176.

Work-order state vs. working tree: the work order was written when claims
8215/3594 had landed and uaccess was the next target; by execution time the
uaccess card (claim 6120) had also landed and its live gate passes, so the
status sync reflects claims 8215/3594/6120 done and **per-task address
spaces as the next milestone-three card** (matching `docs/status.md` and
`docs/march-m3.md` rather than re-introducing staleness).

Verification: `bash tools/status/refresh-indexes.sh` regenerated the
claim/log indexes; `bash tools/verify-coordination.sh` green. Commit/PR
deferred to the shared in-flight `agent/buffy/m3-addrspaces` lane (its
uncommitted claims 5804/6120 are already indexed, so a coordination-green
PR cannot be cut from this tree until they commit; see the branch log).
