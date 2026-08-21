# Claim: Milestone eight, card U8 — persistent settings

- **Owner:** buffy (`agent/buffy/u8-persistent-settings`)
- **Prompt / plan:** `docs/march-m8.md`
- **Scope:** `kernel/src/settings.zig`, `kernel/src/monitor.zig`, `kernel/src/main.zig`, `kernel/src/shell.zig`, `tools/verify-live-settings.sh`, `docs/march-m8.md`, `docs/status.md`
- **Depends on:** `docs/claims/8938-hig-adr-0008.md`, `docs/claims/2990-u7-sysinfo-snapshot.md`
- **Status:** ✅ done

## Notes

Implements ADR 0008 Card U8: persistent configuration management (`settings get/set/list/reset`) backed by `SETTINGS.TXT` on the secondary FAT32 partition (`DATA` partition, Linux-FS GUID):

1. **Configurable Keys**: `hostname` (default: `dipshit`), `prompt` (default: `dipshit> `), `theme` (default: `default`), `scrollback` (default: `1000`).
2. **Boot Integration**: Kernel loads `SETTINGS.TXT` from the DATA partition on boot after block device initialization and configures the interactive shell prompt dynamically.
3. **Storage Isolation**: Settings write to the DATA partition using `fat.mount_data` and `fat.write_file`, cleanly separating runtime configuration from boot assets on the ESP.
4. **Live Reboot Persistence Gate**: `tools/verify-live-settings.sh` tests setting custom hostname and prompt in run 1, rebooting into the same disk image, and asserting that run 2 booted with the custom prompt and persisted settings.
