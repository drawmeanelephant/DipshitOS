# Claim: fleet-remainder — last verify-live-* gates to run isolation + tabs race + reds baselines

- **Owner:** gates (`agent/gates/fleet-remainder`)
- **Prompt / plan:** issue #537 (actionable remainder of #528 after claim 5069 / PR #531)
- **Scope:** (1) migrate the remaining unmigrated `tools/verify-live-*.sh` class-B gates to `tools/lib/gate-run.sh` run isolation (private RUN_DIR/disk/vars/serial per boot; persistence gates boot the canonical artifacts/disk.img under gate_shared_disk_lock), each with its own expectation audit against current serial bytes — expectation changes quote observed bytes, changed semantics cite the claiming march doc/claim; small related batches, every gate rc=0 end-to-end before the next batch. (2) Investigate the live-tabs probe-decode race under isolated boots (reproduce, root-cause, fix or document precisely). (3) Reproduce the pre-existing reds (win family, asm/disas, calc-prog) on an unmodified origin/main DETACHED baseline worktree before any fixture-drift fix; never paper over regressions. (4) Class-B canary CI job: DESIGN NOTES ONLY in the branch log — runner/TCC tradeoffs belong to the maintainer.
- **Touches:** tools/verify-live-history.sh, tools/verify-live-desktop.sh, tools/verify-live-file-browser.sh, tools/verify-live-fs-mutation.sh, tools/verify-live-hardening.sh, tools/verify-live-m14-composition.sh, tools/verify-live-m15-composition.sh, tools/verify-live-m16-composition.sh, tools/verify-live-m16-guards.sh, tools/verify-live-m16-image.sh, tools/verify-live-m16-resources.sh, tools/verify-live-sound-app.sh, tools/verify-live-sound-control.sh, tools/verify-live-sound-device.sh, tools/verify-live-sound-playback.sh, tools/verify-live-timers.sh, tools/verify-live-net-dhcp.sh, tools/verify-live-net-dhcp-renew.sh, tools/verify-live-net-dhcp-autonomous.sh, tools/verify-live-net-dns.sh, tools/verify-live-net-tcp-rto.sh, tools/verify-live-net-tcp-syscall.sh, tools/verify-live-net-udp-syscall.sh, tools/verify-live-sys-kill.sh, tools/verify-live-unicode.sh, tools/verify-live-fetch.sh, tools/lib/gate-run.sh, docs/gate-inventory.md
- **Depends on:** PR #529 (tools/lib/gate-run.sh) + PR #531 (claim 5069 fleet migration) — already on origin/main
- **Heartbeat:** 2026-08-24
- **Status:** 🔄 `agent/gates/fleet-remainder`

## Notes

Fleet ground truth at claim time (2026-08-24): 96 `tools/verify-live-*.sh`
scripts, 27 without `tools/lib/gate-run.sh`. Issue #537's headline says 24
but its own enumeration lists 23; the tree reconciles the difference as the
23 enumerated gates PLUS three strays outside the enumeration
(sys-kill, unicode, fetch). `pointer-cg` stays unmigrated BY DESIGN
(class-C-only per issue #151). This claim migrates all 26 non-excluded
gates so #537 closes completely.

The kickoff commit 2f8a191 created only the branch-log entry; this claim
file completes the claim-before-code requirement (same claim number 2259,
verified with tools/status/claim-id.sh).

Verification bar (inherited from claim 5069): every migrated gate rc=0
individually on this host post-migration; ≥2 different gates demonstrated
running CONCURRENTLY (distinct DIPSHIT_GATE_SUFFIXes, both rc=0) with
evidence under artifacts/; verify-coordination.sh + test-coordination.sh
green before push.
