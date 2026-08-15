# Log — persistent settings (claim 2649)

**Branch:** `agent/buffy/u8-persistent-settings`

- **2026-08-15** — *buffy*: claimed and implemented Milestone Eight Card U8
  (persistent settings per ADR 0008 Card U8):
  - Created `kernel/src/settings.zig` managing in-memory key-value configuration
    backed by `SETTINGS.TXT` on the DATA FAT32 partition.
  - Added `settings` command to `kernel/src/monitor.zig` under `.system`
    (growing `registry_count` 43 -> 44) with `list`, `get`, `set`, `reset` verbs.
  - Connected boot initialization in `kernel/src/main.zig` and dynamic prompt
    in `kernel/src/shell.zig`.
  - Added unit test suite in `kernel/src/settings.zig` and updated shell tests.
  - Implemented Class-B live persistence gate `tools/verify-live-settings.sh`
    verifying two-boot persistence across real reboot under VZ.
  - Updated milestone trackers `docs/march-m8.md` and `docs/status.md`.
