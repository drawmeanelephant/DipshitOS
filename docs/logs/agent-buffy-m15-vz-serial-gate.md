# Log — `agent/buffy/m15-vz-serial-gate`

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-06** — **Claim (buffy, `agent/buffy/m15-vz-serial-gate`):**
  claimed the VZ serial/MMU gate run (M1.5 march step 8, claim 0002) per
  AGENTS.md. Branch created from `main` (`498f6f5`, post PR #14) carrying
  the refreshed prompt doc `docs/m2-vz-serial-gate-prompt.md` (rewritten
  2026-08-06: stale "run after the bad-handoff fix" condition removed —
  the fix landed and the shim is no longer a suspect; the gate is now the
  only unpassed milestone-two gate). Plan: run the verification sequence
  in the refreshed prompt (fmt → unit tests → build gates → bad-handoff
  regression → `zig build run`, which is itself the gate), save
  `artifacts/vm-serial.log` complete + `m2-vz-run-<date>.txt` /
  `m2-vz-gates-<date>.txt`, interpret the probe against `probe_serial` in
  `kernel/src/main.zig` (`layout=none` is a decisive result), flip only
  the matching `[inferred] → [observed]` hardware-contract entries (MMIO/
  serial 1–4, conservative MMU entry 5), and report a blocked run
  honestly — no kernel/host changes, no weakened gate. 🔄 in progress —
  gate run to follow.
