# Claim: milestone ten, card F1 — kernel file handle table

- **Owner:** buffy (`agent/buffy/m10-fs`)
- **Prompt / plan:** `docs/march-m10.md`
- **Scope:** Milestone 10 card F1: bounded per-process file handle table (`kernel/src/file_table.zig`), tracking partition, path, cursor offset, file size, access mode, and lifecycle cleanup (`reset_process`).
- **Depends on:** F0 (claim 0662)
- **Status:** ✅ done (2026-08-15)

## Notes

Implements the kernel-side bounded in-memory file handle table (`kernel/src/file_table.zig`):
- 8 open file handles per process slot (`[process.max_processes][8]FileHandle`).
- 0 heap allocation; static kernel BSS.
- Tracks per-handle byte cursor offset, access mode, partition, and size.
- Process lifecycle cleanup auto-closes all handles on process exit.

## Verified

- Gate: Class A unit tests in `kernel/src/file_table.zig`.
