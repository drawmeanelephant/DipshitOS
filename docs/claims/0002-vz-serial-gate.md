# Claim: VZ serial/MMU gate run (M1.5 step 8)

- **Owner:** —
- **Prompt / plan:** `docs/m2-vz-serial-gate-prompt.md`
- **Scope:** M1.5 step 8 — confirm the serial console on a real VZ run
- **Depends on:** bad-handoff fix (landed 2026-08-06)
- **Status:** ⬜ unclaimed

## Notes

Gate: exact banner `DipshitOS kernel has seized control.`,
`memory-map descriptors=0x...`, and `kernel terminal state` in
`vm-serial.log`; then flip matching `[inferred] → [observed]` entries in
`docs/hardware-contract.md`. The bad-handoff fix removed the shim/LR
suspect; this gate is a separate open question.
