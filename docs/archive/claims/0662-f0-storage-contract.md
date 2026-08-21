# Claim: milestone ten, card F0 — storage contract & ADR 0010

- **Owner:** buffy (`agent/buffy/m10-fs`)
- **Prompt / plan:** `docs/march-m10.md`
- **Scope:** Milestone 10 card F0: normative specification for userland filesystem access, path routing syntax, access mode bitmasks, 40-byte DirEntry layout, error codes, and ADR 0007 syscall slots 23–27 (sys_file_open, sys_file_read, sys_file_write, sys_file_close, sys_dir_list). Docs only — no code.
- **Depends on:** M9
- **Status:** ✅ done (2026-08-15)

## Notes

Milestone ten turns DipshitOS into a persistent storage platform for user
applications. This card defines ADR 0010, freezing the userland storage ABI
and syscall contract before kernel and userspace implementations land.

**ADR 0010** defines:
- D1. Path syntax, volume prefix routing (`/data/...`, `/esp/...`, bare paths -> DATA), and traversal rejection (`..`).
- D2. Access mode bitmasks (`MODE_READ=1`, `MODE_WRITE=2`, `MODE_CREATE=4`, `MODE_APPEND=8`).
- D3. 40-byte packed `DirEntry` layout for directory enumeration.
- D4. Syscall ABI amendments for slots 23–27 (`sys_file_open`, `sys_file_read`, `sys_file_write`, `sys_file_close`, `sys_dir_list`).
- D5. Return error codes (`EINVAL`, `EBADF`, `EFAULT`, `ENOSYS`, `ENOSPC`, `ENOENT`, `EACCES`, `ENAMETOOLONG`).
- D6. Process isolation and handle table lifecycle discipline.

## Verified

- Gate: ADR 0010 accepted in `docs/decisions/0010-userland-filesystem-abi.md`.
