# Claim: M25 Lane B — F3 create directory, F4 disk usage, F5 recent files

- **Owner:** ox-alpha (`agent/ox-alpha/m25-filemanager-depth`)
- **Prompt / plan:** `docs/march-m25.md` (cards F3, F4, F5; GitHub issues
  #383/#384/#385)
- **Scope:** M25 (file manager depth), Lane B — directory creation,
  disk usage, recent-files ring. Touches the kernel FAT seam (F3 needs
  real FAT32 directory creation: allocate a cluster, zero it, write `.`
  / `..` dot entries, emit a directory ATTR entry) plus
  `user/src/file_browser.zig` and a `du` builtin in `kernel/src/shell.zig`.
- **Depends on:** F1 selection state (same branch); mutating-FS syscalls
  from M13 (slots 34–37, landed); slot 25 create semantics (being
  extended for directories — see correction note below).
- **Status:** 🔄 agent/ox-alpha/m25-filemanager-depth

## Notes

**Correction to the card text:** F3's issue claims "uses existing
`sys_file_create` (slot 25)" with zero kernel work, but at claim time
`ATTR_DIRECTORY` appears nowhere under `kernel/src` — the FAT seam has no
directory-create path. This claim therefore adds kernel-side FAT32
directory creation (dot-entry initialization, cluster allocation reuse)
and extends slot 25 to take a directory flag rather than minting a new
syscall slot, honoring ADR 0013 D7 layering and the ABI budget note
(56/64 used).

F4: `du` shell builtin (bounded recursive scan, march note bounds depth
at 3) + FILE.BIN breadcrumb-bar directory size. Non-blocking intent is
met by bounding the walk; no threads exist to hide behind.

F5: recent-files ring (10 × 32 bytes) updated on open/create, persisted
as a plain file on the DATA volume so it survives reboot; surfaced as a
virtual first entry "Recent" in the root listing that opens the ring as
a navigable pseudo-listing.

Verification: host-side unit tests for ring behavior, path validation
rejection, du math on synthetic listings; portable gates; class-B live
gate shape named in march notes (`verify-live-filemanager-mkdir.sh`,
`-du.sh`, `-recent.sh`) — run if VZ available, otherwise honestly
reported not-run.

## Evidence

- (to be filled with artifacts paths / test output)
