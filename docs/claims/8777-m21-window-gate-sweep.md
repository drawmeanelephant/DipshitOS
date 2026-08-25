# Claim: M21 window-management gate sweep (W1–W16)

- **Owner:** t3code (`t3code/milestone-nine-triage`)
- **Prompt / plan:** `docs/march-m21.md` (W1–W5 card detail; W6–W16 specs live in issues #321–#432)
- **Scope:** Milestone twenty-one (GitHub milestone 9) — verification-first sweep of all 15 open cards: per-card class-B gates, small implementation gaps fixed as found (known: W14 orphan cleanup unimplemented; W15/W16 modal/transient appear unwired), march/status doc flips, issue close-outs with observed evidence.
- **Touches:** docs/march-m21.md docs/status.md kernel/src/monitor.zig kernel/src/driving_award.zig kernel/src/input.zig kernel/src/shell.zig user/src/m21demo.zig tools/verify-live-m21*
- **Depends on:** #488 (W1–W5 implementation) + 1a8dedf (W9/W11/W12 polish) — both already on main
- **Heartbeat:** 2026-08-24
- **Status:** 🔄 t3code/milestone-nine-triage

## Notes

State survey at sweep start (HEAD `9bc0ec2`): every W-card's core logic is
already merged (#488 landed W1–W5 plus W6–W10 primitives; 1a8dedf landed
W9/W11/W12) but **no card has observed evidence**: zero M21 gate scripts
exist, `docs/march-m21.md` rows are all ⬜ (and lack W6–W16 rows), and all
milestone issues are open except W9.

Gate strategy follows the `verify-live-win-move.sh` (claim 0487) pattern:
EL0 marker program + scripted session through the private-disk run
isolation (`tools/lib/gate-run.sh`) + serial-marker assertions + PNG
pixel-decode proofs. Chord-driven entries (Ctrl+T/F11/Ctrl+Shift+M/
Alt+arrows) cannot be typed through the serial script path, so each gate
drives the same `driving_award.zig` functions through new EL1h `dui`
monitor halves (`dui tile`, `dui maximize N`, …) — the established
`dui move`/`dui raise` precedent — with the real chord wiring asserted by
code inspection and the existing shell.zig edge consumers left untouched.
Fixing the synthesized keyboard seam (#179) so gates could drive the true
chord path was considered and deferred as its own work item.

Gates land as `tools/verify-live-m21-<group>.sh` (grouping follows the
march doc's agent split for W1–W5, natural clusters for W6–W16); the
march doc gains W6–W16 rows pointing at the actual gate names. Class B
(Apple silicon + VZ): every claim here is live-boot observed or it does
not flip to ✅.
