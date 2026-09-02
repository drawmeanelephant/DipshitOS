# Log — `agent/buffy/m34-hf7-clone-dedup`

Branch: Freebuff worktree `freebuff/get-git-up-to-date-...`

## 2026-09-02 — claim 1312 filed; facts pinned, implementation next

- Repo brought up to date (fast-forward 65 commits to `7e8a087`): M34
  HF1–HF6 all landed (PRs #745/#747/#749/#792/#806); the HF6 flake #803
  root-caused and fixed in PR #808 (monitor.cmd_write 32 KiB on the 16 KiB
  boot stack → BSS); plus the parallel wasm/zc/line-of-sight workstreams.
- Issue #741 surveyed; touchpoints read (virtio_file.zig 938 lines,
  VFWire.swift, main.swift serveFileRequest family, monitor vf dispatch,
  verify-live-vf.sh).
- **Empirical measurement facts established on this host (observed, saved
  for the gate design):** (1) `clonefile(2)` clones an ENTIRE directory
  tree COW (rc=0; man page: "the directory hierarchy is cloned as if each
  item was cloned individually" but explicitly recommends `copyfile(3)`
  for directories); dst must not exist → `EEXIST` maps to st_exists.
  (2) Swift `copyfile(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_RECURSIVE)`
  clones a directory tree COW (rc=0 verified via `swift -e`). (3) `du`
  CANNOT see clone savings — repo + clone + cp all report 6148 KB (logical
  st_blocks), so the gate measures PHYSICAL volume used-space deltas
  (statvfs): clone ~0, single cp +6.0 MiB for a 6 MiB fixture.
- Plan: opcode 0x0c additive; wire = RENAME-shaped `[from][0x00][to]`;
  serveClone resolves both subpaths with VFWire.resolveSubpath, pre-checks
  src-exists/dst-absent, file → Darwin.clonefile, dir → copyfile(3)
  COPYFILE_CLONE; `vf clone <from> <to>` monitor command; gate gains
  clone/edit phases with the copy control + volume deltas + sibling
  byte-compare under `artifacts/m34-hf7-measurement.txt`; docs (hardware-
  contract CLONE row, scoping §4 status + ZFS alternative, status.md).