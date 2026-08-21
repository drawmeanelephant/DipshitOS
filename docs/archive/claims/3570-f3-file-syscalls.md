# Claim: milestone ten, card F3 — file syscall seam (slots 23–27)

- **Owner:** buffy (`agent/buffy/m10-fs`)
- **Prompt / plan:** `docs/march-m10.md`
- **Scope:** Milestone 10 card F3: implement `sys_file_open` (slot 23), `sys_file_read` (slot 24), `sys_file_write` (slot 25), `sys_file_close` (slot 26), and `sys_dir_list` (slot 27) in `kernel/src/syscall.zig` with fault-safe uaccess integration.
- **Depends on:** F1, F2
- **Status:** ✅ done (2026-08-15)

## Notes

Wires the ADR 0007 filesystem syscall slots 23–27 to the underlying `file_table` engine:
- `sys_file_open` (slot 23): copies path in via `uaccess.copy_in`, opens handle.
- `sys_file_read` (slot 24): reads bytes and copies out via `uaccess.copy_out`.
- `sys_file_write` (slot 25): copies bytes in via `uaccess.copy_in`, writes to file.
- `sys_file_close` (slot 26): closes handle.
- `sys_dir_list` (slot 27): lists directory entries and copies out array of 40-byte `DirEntry` records.
- Updates `implemented_count` from 23 to 28.

## Verified

- Gate: Class A unit test suite in `kernel/src/syscall.zig` testing all 5 syscall slots and error codes.
