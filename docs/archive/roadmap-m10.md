# Roadmap archive — Milestone ten — userland filesystem & storage ABI

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).

---

### Milestone ten — userland filesystem & storage ABI

> Expose the kernel's FAT32 ESP and DATA volumes to EL0 user programs through
> a bounded, safe handle table (no POSIX file descriptor baggage).

- **F1 — Process file handle table.** Bounded per-process handle table (e.g.
  8 open files per process) tracking partition (ESP or DATA), current cluster,
  byte offset, and access mode (read/write).
- **F2 — File syscall ABI (ADR 0007 slots 23–27).**
  - `sys_file_open(path_ptr, path_len, flags) -> handle`
  - `sys_file_read(handle, buf_ptr, count) -> bytes_read`
  - `sys_file_write(handle, buf_ptr, count) -> bytes_written`
  - `sys_file_close(handle) -> status`
  - `sys_dir_list(path_ptr, path_len, buf_ptr, max_entries) -> count`
- **F3 — Safe path canonicalization & bounds.** Path validation
  (`/data/...`, `/esp/...`), bounds checking, and directory traversal
  guarantees.
- **F4 — Userland file utilities (`TYPE.BIN`, `TOUCH.BIN`, `SAVETEXT.BIN`).**
  **[Capstone Gate]** Userland applications reading and writing persistent files
  on the DATA partition, verified across reboot. Live gate: `verify-live-user-fs.sh`.
