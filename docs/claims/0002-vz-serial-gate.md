# Claim: VZ serial/MMU gate run (M1.5 step 8)

- **Owner:** buffy (`agent/buffy/m15-vz-serial-gate`)
- **Prompt / plan:** `docs/m2-vz-serial-gate-prompt.md` (refreshed 2026-08-06)
- **Scope:** M1.5 step 8 — confirm the serial console on a real VZ run
- **Depends on:** bad-handoff fix (landed 2026-08-06)
- **Status:** 🔄 in progress (agent/buffy/m15-vz-serial-gate, claimed 2026-08-06)

## Notes

Gate: exact banner `DipshitOS kernel has seized control.`,
`memory-map descriptors=0x...`, and `kernel terminal state` in
`vm-serial.log`; then flip matching `[inferred] → [observed]` entries in
`docs/hardware-contract.md`. The bad-handoff fix removed the shim/LR
suspect; this gate is a separate open question.

The refreshed prompt (`docs/m2-vz-serial-gate-prompt.md`) specifies the
exact verification sequence (build gates → `bash tools/verify-bad-handoff.sh`
regression → `zig build run`, which is itself the gate), the evidence
files to save (`artifacts/vm-serial.log` complete + `m2-vz-run-<date>.txt` /
`m2-vz-gates-<date>.txt`), the probe interpretation rules
(`layout=none` is a decisive result, not a failure), the hardware-contract
entries allowed to flip (MMIO/serial 1–4, conservative MMU entry 5 only),
and the honest blocked-run protocol (no kernel/host changes, no weakened
gate, quote log lines for every flip).
