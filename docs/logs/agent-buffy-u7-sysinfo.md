# Log — sysinfo support snapshot (claim 2990)

**Branch:** `agent/buffy/u7-sysinfo`

- **2026-08-15** — *buffy*: claimed and implemented Milestone Eight Card U7
  (`sysinfo` support snapshot per ADR 0008 D5):
  - Registered `sysinfo` in `kernel/src/monitor.zig` under `.machine_identity`
    (growing `registry_count` 42 -> 43).
  - Implemented `cmd_sysinfo` printing structured diagnostic sections across
    all kernel subsystems (system, cpu, memory, allocator, scheduler,
    processes, storage, network, graphics, input).
  - Added unit tests asserting `sysinfo` output fields and formatting.
  - Updated e2e mock transcript tests in `kernel/src/shell.zig` and regenerated
    canonical fixture `tests/transcript-console.txt`.
  - Re-ran transcript gate (`tools/verify-transcript.sh`), live help gate
    (`tools/verify-live-help.sh`), and coordination checks green.
