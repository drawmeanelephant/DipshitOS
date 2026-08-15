# Log — First-boot experience (claim 8323)

**Branch:** `agent/buffy/u6-first-boot`

- **2026-08-15** — *buffy*: claimed and implemented Milestone Eight Card U6
  (first-boot experience per ADR 0008 D5):
  - Refreshed `about` in `kernel/src/monitor.zig` with full, current
    architectural description of the modern kernel subsystems.
  - Added `welcome` command and alias `tour` under `.machine_identity` in
    `kernel/src/monitor.zig` to walk new users through the interactive monitor.
  - Added deterministic boot MOTD line in `monitor.banner` summarizing live
    subsystems.
  - Updated e2e mock transcript tests in `kernel/src/shell.zig` and regenerated
    canonical fixture `tests/transcript-console.txt`.
  - Re-ran transcript gate (`tools/verify-transcript.sh`), unit test battery,
    and coordination checks green.
