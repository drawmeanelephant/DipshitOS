# Claim: audit-2026 maintenance — timer-gate evidence restore + doc drift fixes

- **Owner:** maintenance (`agent/maintenance/audit-2026-issues`)
- **Prompt / plan:** GitHub issues #93, #94, #95 (filed from the audit-2026
  class-A+SDK audit at `e838982`; full findings in the audit chat summary
  and `artifacts/audit-2026/vz-sdk-audit.txt`).
- **Scope:** (1) restore the claim-9187 live evidence set by re-running
  `tools/verify-live-timer.sh` 3/3 on this host and saving the
  `artifacts/live-timer-*` outputs (#93); (2) fix the stale `## Current
  milestone` paragraph in `AGENTS.md` (still describes M3 + "per-task user
  address spaces" as next; status.md says M4 closed `m4-processes` and M5
  active) (#94); (3) annotate `docs/claims/7948-gic-timer-interrupts.md`
  as superseded — its "VZ never delivers interrupts" conclusion was a
  guest-driver bug corrected by claims 9187/0828; only the
  no-injection-API fact survives the macOS 27.0 SDK re-audit (#95).
  Non-goal: no kernel/runner code changes, no status.md edits (owned by
  the active M5 cards).
- **Depends on:** — (docs-only + one local class-B gate run)
- **Heartbeat:** 2026-08-26
- **Status:** ✅ done — all three scope items landed 2026-08-11 via PR #98 (commit 90625fc, merged 4c51c4c): #93 timer-gate evidence restored (verify-live-timer.sh PASS 3/3, artifacts/live-timer-*), #94 AGENTS.md current-milestone drift fixed (verified on main), #95 claim 7948 annotated as superseded (later archived to docs/archive/claims/7948-gic-timer-interrupts.md by the claim-1601 hygiene prune, since the annotation's 14 lines rode 90625fc). The claim was left 🔄 at merge time (no completion flip, no heartbeat), which is why the coordination gate flagged it 14+ days later; flipped to ✅ 2026-08-26 by claim 0590's owner per the coordination rules (log entry in docs/logs/agent-buffy-input-poll-563.md).

## Notes

**Evidence restore (#93):** `bash tools/verify-live-timer.sh` (BOOTS=3)
ran 2026-08-11 on revision `e838982` (branch `main`, dirty-files=0):
**PASS 3/3** — every boot `rc=0 serial-bytes=4028 banner=1 interrupts=1
cmd-armed=1 echo=1 irq=1 heartbeat=1`. The gate's expected string
`timer heartbeat ticks=5 irq=5 poll=0` was seen each boot, i.e. five
CNTP PPIs entered the claim-9746 EL1 vector with zero poll-consumed
ticks. Evidence saved under `artifacts/`: `live-timer-gate.txt`,
`live-timer-report.txt`, `live-timer-script.txt`, `live-timer-run-01..03.txt`,
`live-timer-serial-01..03.log` — restoring the set claim 9187 cited but
which was absent from the checkout (artifacts/ is gitignored).

**Doc drift (#94):** `AGENTS.md` `## Current milestone` still said
milestone three with "uaccess is complete; per-task user address spaces
is the next milestone-three card", while `docs/status.md` (canonical)
has M4 closed (tag `m4-processes`) and M5 active (N1 net TX live claim
1373, N2 net RX live claim 6076, N3 ARP next). Fixed to point at M5 and
defer to status.md.

**Superseded annotation (#95):** claim 7948's "blocked by the VZ
platform — never delivers any interrupt" was overturned by claim 9187
(done 2026-08-09: real level-triggered CNTP PPI 30 into the EL1 vector,
3/3) and claim 0828 (real SPI INTID 0x45 into the claim-9746 vector via
the custom-virtio device). Root cause was the guest driver (wrong GICR
SGI-frame offsets GICR+0x80 vs GICR+0x10080, MADT type shift, ICFGR
RES0 bit). The macOS 27.0 SDK re-audit (`artifacts/audit-2026/vz-sdk-audit.txt`)
confirms only the narrower fact: Virtualization.framework still exposes
no guest-interrupt injection API and `VZVirtioQueue` has no
`signalUsedBuffers`; Hypervisor.framework exposes
`hv_gic_create`/`hv_gic_set_spi`/`hv_gic_send_msi`.

**Verification:** claim/log/index refresh via
`bash tools/status/refresh-indexes.sh` + `bash tools/verify-coordination.sh`
+ `bash tools/status/test-coordination.sh`; CI class-A green on the PR.
