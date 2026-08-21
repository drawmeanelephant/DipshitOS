# Claim: Docs-only reconciliation follow-up — post-MMU blocker wording + newest landed evidence (claim 6460) across stable-context docs

- **Owner:** buffy (`freebuff/start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2`)
- **Prompt / plan:** task prompt 2026-08-08 — docs-only reconciliation of the canonical stable-context documents against evidence ALREADY landed, starting from the latest `main` (`c7d9644`). Prior reconciliation claims (8592 preflight, 8623 status/march reconcile, 3109 stale-doc cleanup, 0594 gate-inventory) are already merged; this claim audits the merged state and fixes what they left stale, including evidence merged after 8623 (claim 6460, PR #42).
- **Scope:** docs only — `docs/status.md`, `docs/march-m15.md`, `docs/roadmap.md`, `docs/architecture.md`, `docs/testing.md`, `README.md`, `docs/hardware-contract.md` (pointer/annotation only). No kernel, host, build, verification, or hardware code changes. No milestone-scope change, no invented results, no `[inferred]`→`[observed]` upgrades beyond what claims already record.
- **Depends on:** main `c7d9644`; claims 0013/0015/0017/0018/0020/0021/0022/6460; ADRs 0004/0005/0006; prior reconciliation claims 8592/8623/3109/0594
- **Status:** ✅ done 2026-08-08 — stable-context docs reconciled at main `c7d9644`; every targeted phrase corrected (post-exit→post-MMU blocker wording, claim-0015-executed "Next step", item-3 "no usable device" superseded pointer, "block device register layout" typo, march steps 8/9/19, claim 6460 cited in the canonical blocker); coordination gate, index check, link check (103 links + 14 anchors, 0 broken), and before/after stale grep all pass (audit under `artifacts/docs-reconciliation-20260808-followup/`)

## Notes

Deterministic claim ID `7256` derived via
`bash tools/status/claim-id.sh "freebuff/start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2" "status-postmmu-reconcile"`
(0024 + cksum % 9976); verified no collision with existing claims (0001–0023, 0594, 1801, 3109, 3320, 6460, 8592, 8623, 9112).

**Context:** claim 8623 (PR #41) reconciled `docs/status.md` / `docs/march-m15.md` against claims
0013/0015/0017/0018/0020/0021/0022 at main `fff37a5`, and claim 3109 (PR #38) cleaned stale blocker
snapshots from README/roadmap/architecture/testing/hardware-contract. PR #42 (claim 6460, T0SZ start-level
diagnostic) landed afterwards and is NOT reflected anywhere in the status docs. This claim audits the merged
state at `c7d9644` and fixes the remaining stale/contradictory blocker wording:

1. The canonical blocker is "reliable **post-MMU** access to the already-discovered virtio-pci console
   transport" (claims 0018/0020: the MMU switch B→C destroys access; ExitBootServices is exonerated — phase B
   post-exit-on-firmware-translation works). Several gate-table rows and the outer docs still describe the
   blocker as "post-exit access ... hangs", which claim 0020's phase B contradicts (post-exit access works on
   the firmware translation).
2. `docs/status.md`'s claim-0013 paragraph still ends with a "Next step: carry the console bytes over a
   post-exit-safe channel ..." sentence that claim 0015 already executed (next paragraph).
3. `docs/status.md` "Immediate gate work" item 3 ends with "the probe runs to completion finding no usable
   device" — superseded by claim 0013 (the console exists, outside the declared windows).
4. `docs/status.md` Assumptions bullet says "the **block device** register layout stays [inferred]" — the
   console is a virtio-pci communications device, not a block device; align wording with
   `docs/hardware-contract.md`.
5. `docs/march-m15.md` step 8 still says the wall is "post-exit ... the same wall that blocks post-exit MMIO
   reads of the declared windows"; step 19 says `readByte` is a stub "until the VZ serial gate proves a device"
   (the device is already proven, claim 0013); step 9 carries the 2026-08-06 blocker reason, refined
   2026-08-07 by claims 0018/0020.
6. The canonical blocker and next-work ordering must also cite claim 6460 (PR #42, the newest landed evidence):
   T0SZ 25→16 restored end-to-end post-MMU virtio TX in 6/18 boots across three runs — hypothesis
   strengthened, not reproducible; production T0SZ stays 25.

Verification (saved under `artifacts/docs-reconciliation-20260808-followup/`): coordination gate
(`bash tools/verify-coordination.sh`), generated-index check (`bash tools/status/refresh-indexes.sh --check`),
relative-link check over changed docs, and a before/after stale/contradiction grep for the corrected phrases
(`post-exit access ... hangs`, `proves a device`, `block device register layout`, `Next step: carry the
console bytes`, `no usable device`).

**No claim conflicts expected:** no landed claim is rewritten; corrections are annotations/pointers in
status-facing docs only, and all cite the claims that already carry the evidence. If two landed claims were
found to conflict, this claim would stop and report the gap rather than resolve by preference (none found).
