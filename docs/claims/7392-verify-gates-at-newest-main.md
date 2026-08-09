# Claim: verify gates at newest main (post-5162, 4ca9fb4)

- **Owner:** buffy (`freebuff/grab-most-current-git-and-let-s-continue-on-with-o-bd839138-534f-40b1-97b3-220d1b1c9a61`)
- **Prompt / plan:** "grab most current git and let's continue on with our status" — sync to the
  newest `origin/main`, review the coordination surface, and confirm the status is real by
  re-running the full gate set at the merged HEAD. Claim 5162 (alloc loader/boot-services
  pooling, PR #51) landed after the last full class-B pass (claim 7873 at the M1.5 tag), so the
  merged HEAD `4ca9fb4` had never itself been gate-verified end to end.
- **Scope:** class A (portable/build, 11 gates) + class B (Apple-silicon VZ hardware, 9 gates)
  at HEAD `4ca9fb4`; record evidence; flag the one remaining platform blocker and the stale
  coordination rows honestly.
- **Depends on:** claims 5162, 7873, 7948 (all at `origin/main`).
- **Status:** ✅ done 2026-08-09 — full class A (11/11) + class B (9/9) green at the merged
  HEAD `4ca9fb4` (summary evidence `artifacts/gates-reverify-20260809-4ca9fb4.txt`; per-run
  logs `artifacts/classB-chunk1-*.log`).

## Notes

Ran the justfile's `verify-portable` set command-by-command (just is not installed on this host)
and the `verify-vz` set (split across two runs because backgrounded shells do not survive the
Freebuff terminal session — reran the live gates in the foreground). Everything passed:

- Class A 11/11: fmt, unit tests (all modules incl. 25 alloc tests with the new exclusion
  cases), byte-identical transcript, `zig build`/`image`/`inspect`, swift runner build,
  context, coordination, coordination tooling (15/15), mmu-debt.
- Class B 9/9 on real VZ hardware: serial takeover (exact banner + `dipshit>` prompt in
  `vm-serial.log`), bad-handoff (`kernel_rc=0x2`), marker ladder (`M2_TXOK!`), nvram-console
  (post-exit console bytes; first attempt failed the serial-evidence poll and the gate's
  up-to-3-boots retry passed — designed behavior), host-console (PTY + SIGINT restore),
  live-transcript (live RX, 1/1), live-fs (persistence through reboot, 1/1 pair),
  live-timer (GIC + CNTP programmed, comparator fired/re-armed ≥5× via the idle-loop poll,
  1/1), live-reboot (`reboot` resets / `shutdown` powers off, 2/2).

Blocker check for claim 7948: the Virtualization.framework headers on this host (macOS 27.0,
SDK 26.2) contain **no** GIC/interrupt configuration API (no `VZGICConfiguration` or similar —
`ls` of the framework headers shows no gic/interrupt/timer/irq symbols), confirming the
claim's evidence that VZ's GIC is a config-accepting stub and IRQ delivery cannot be enabled
from the guest side on this platform. The poll-driven heartbeat remains the honest shipped
form; the IRQ-vector delivery requirement stays open for a platform that actually signals.

Coordination-surface note (recorded here, not edited — other agents' claim files are
append-only): claims 0002/0011/0013 still carry ⛔ rows that are superseded by landed work
(0002 → serial gate passes via claim 1517; 0011 → live reboot/shutdown observed via claim
0527; 0013 → discovery complete, superseded by claims 0015/0017/1517). The canonical live
status lives in `docs/status.md` and the ✅ rows above; the stale rows are a hygiene item for
the owning branches.
