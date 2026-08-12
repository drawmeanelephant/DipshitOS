# Log — audit-2026 maintenance: timer-gate evidence restore + doc drift fixes (claim 6204)

Append-only log for the maintenance branch that restores the claim-9187
timer-gate evidence and fixes doc drift surfaced by the audit-2026 audit
(issues #93/#94/#95).

## 2026-08-11 — evidence restore + doc drift fixes

- **Claim:** 6204 (`docs/claims/6204-audit-2026-maintenance.md`)
- **Gate re-run (#93):** `BOOTS=3 bash tools/verify-live-timer.sh` on
  revision `e838982` (branch `main`, dirty-files=0) — **PASS 3/3**,
  every boot `rc=0 serial-bytes=4028 banner=1 interrupts=1 cmd-armed=1
  echo=1 irq=1 heartbeat=1`, expected line
  `timer heartbeat ticks=5 irq=5 poll=0` observed each boot. Evidence
  saved: `artifacts/live-timer-gate.txt`, `live-timer-report.txt`,
  `live-timer-script.txt`, `live-timer-run-01..03.txt`,
  `live-timer-serial-01..03.log`.
- **AGENTS.md (#94):** `## Current milestone` rewritten from M3 wording
  to M4-closed / M5-active, pointing at `docs/status.md`.
- **Claim 7948 annotation (#95):** superseded-by pointer added
  (claims 9187/0828; guest GICR bug; only the no-injection-API fact
  survives).
- Coordination indexes refreshed; `verify-coordination.sh` +
  `test-coordination.sh` green. PR follows per repo template.
