# Claim: Milestone ten march — userland filesystem & storage ABI (living tracker)

- **Owner:** buffy (`agent/buffy/m10-tracker`)
- **Prompt / plan:** `docs/roadmap.md` milestone ten
- **Scope:** `docs/march-m10.md`, `docs/claims/2412-m10-march-tracker.md`, `docs/logs/agent-buffy-m10-tracker.md`
- **Depends on:** `docs/claims/9328-e6-interactive-user-app.md`
- **Status:** ✅ done

## Notes

Defines the living tracker and collision-free agent split for **Milestone Ten (Userland Filesystem & Storage ABI)**:
1. **Cards F0–F4**: ADR 0010 storage contract, kernel per-process file handle table (`kernel/src/file_table.zig`), safe path canonicalization and volume routing (`/data/...`, `/esp/...`), file syscall seam slots 23–27 (`sys_file_open`, `sys_file_read`, `sys_file_write`, `sys_file_close`, `sys_dir_list`), and userland file utilities (`SAVETEXT.BIN`, `TYPE.BIN`, `DIR.BIN`).
2. **Authoritative Spec**: Exposes FAT32 ESP and DATA volumes to EL0 user programs through a bounded, safe handle table.
