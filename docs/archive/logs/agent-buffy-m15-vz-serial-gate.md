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
- **2026-08-06 21:19** — **Gate run (buffy, `agent/buffy/m15-vz-serial-gate`):**
  ran the full sequence on `main`@`26bbce8`; gates 1–8 pass
  (`artifacts/m2-vz-gates-20260806.txt` — fmt, all module unit tests incl.
  65 shell tests, `zig build`/`inspect`/`image`, swift release build,
  bad-handoff regression `kernel_rc=0x2`). `zig build run`
  (`artifacts/m2-vz-run-20260806.txt`): VM booted, screenshots captured,
  then `FAILURE: requested evidence not observed within 30s
  (serial=false, terminal=false)`; `artifacts/vm-serial.log` **0 bytes**.
  Observed: `BOOTED.TXT` exact, `LOADER.TXT`
  `base=0x7e4df000 size=0x823e8 entry_offset=0x18`,
  `ram_first8=0xaa0103eaaa0003e9` (= shim `mov x9,x0; mov x10,x1`),
  `RC.TXT` absent (good path, expected). → **blocked**: kernel dies after
  shim entry, before its first post-exit `uart_puts`; hypotheses
  `layout=none` (`M2_SERIA` halt) vs early post-exit crash. Updated
  `docs/status.md` (gate table, observe section, gate-work item 2),
  `docs/testing.md`, `docs/march-m15.md` step 8 ⛔; claim 0002 closed ⛔
  naming the D4 marker fallback (status.md gate work item 3) as the next
  step; no hardware-contract flips (no log lines to quote); no kernel/host
  code touched. ⛔ blocked.
