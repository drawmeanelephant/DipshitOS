# Claim: VZ serial/MMU gate run (M1.5 step 8)

- **Owner:** buffy (`agent/buffy/m15-vz-serial-gate`)
- **Prompt / plan:** `docs/m2-vz-serial-gate-prompt.md` (refreshed 2026-08-06)
- **Scope:** M1.5 step 8 — confirm the serial console on a real VZ run
- **Depends on:** bad-handoff fix (landed 2026-08-06)
- **Status:** ⛔ superseded (historical block) — the VZ serial gate now **PASSES**: claim 1517 (T0SZ=16 + TLBI at the switch) put the exact banner + `memory-map descriptors=0x…` + `kernel terminal state` + the `dipshit>` prompt in `vm-serial.log`, re-verified at `4ca9fb4` by claim 7392. This claim's own 2026-08-06 block is the historical record; keep this file as history and track the live gate in `docs/status.md`.

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

## Run of 2026-08-06 21:19 (blocked — no output at all)

Ran the full verification sequence on this commit (`main`@`26bbce8` +
claim 0002 docs): zig 0.16.0, Swift 6.2.3, macOS 27.0 (26A5388g),
arm64. Gates 1–8 all pass (`artifacts/m2-vz-gates-20260806.txt`: fmt,
module unit tests incl. 65 shell tests, `zig build` / `inspect` / `image`,
swift release build, bad-handoff regression `kernel_rc=0x2`).

`zig build run` (`artifacts/m2-vz-run-20260806.txt`): VM booted, runner
reported `SUCCESS` for three framebuffer screenshots then `FAILURE:
requested evidence not observed within 30s (serial=false,
terminal=false)`, exit 1. `artifacts/vm-serial.log` = **0 bytes**.
`BOOTED.TXT` present, exact content; `LOADER.TXT` present
(`base=0x7e4df000 size=0x823e8 entry_offset=0x18`,
`ram_first8=0xaa0103eaaa0003e9` = shim's `mov x9,x0; mov x10,x1`);
`RC.TXT` absent (good path, expected).

**Conclusion:** the loader→shim jump is proven; the kernel dies **after
shim entry, before its first post-exit `uart_puts`**. No hardware tag
flips — everything stays `[inferred]` per the honest-blocked protocol
(no log lines exist to quote). No kernel/host code was touched.

**Blocker:** discriminating the two hypotheses (`layout=none` →
`M2_SERIA` BSS-marker halt vs. early post-exit crash in map/MMU/probe)
needs the ADR 0004 D4 fixed-memory-marker fallback — a host-side dump of
the kernel's BSS `takeover_marker` (`docs/status.md` gate work item 3,
unclaimed). A bare re-run of this gate adds nothing until that exists.
