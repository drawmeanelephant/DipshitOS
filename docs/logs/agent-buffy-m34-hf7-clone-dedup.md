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

## 2026-09-02 — implementation + live: PASS 6/6; measurement + flake #810

- **Implemented + committed (30efba2):** guest `virtio_file.clone` +
  G13, host `VFWire.opClone`/`buildClonePayload` + S11, `serveClone`
  (Darwin.clonefile(2) for files, copyfile(3) COPYFILE_ALL|COPYFILE_CLONE
  |COPYFILE_RECURSIVE for trees — the man page's recommended dir path;
  both subpaths through resolveSubpath; dst-absent pre-check + EEXIST
  race fallback), `vf clone <from> <to>` monitor command, docs
  (hardware-contract row, scoping §4 + ZFS/APFS-snapshot alternatives,
  status.md M34 close-out). Class-A green: fmt/build/image, unit 24/24,
  swift 12/12, BSS headroom 541,960 B.
- **Gate hardening (iterate-guess → robust):** (1) the share lives on a
  private APFS sparseimage (`hdiutil create/attach`, no admin) — the
  FIRST run's volume deltas were swamped by ~300 MiB/boot of ambient
  volume writers (322/295 MiB measured for 3 clones / a 512 B edit, both
  should be ~0); a tight manual window measured a clean 34.3 MiB/boot,
  and the sparseimage isolates the signal completely. (2) flake #810
  (filed — boot-time EL0 probe hangs/parked 8/24 boots this session,
  silent-stop and parked-exception variants; second variant shows
  corrupted frames: sp=0, far=0x80000178, x2=0x8000, `#808`-family) made
  the runner never forward scripts; the gate retries each phase up to 3
  attempts when the boot marker is absent (bounded + logged). (3) runner
  exit-1 tolerance: the runner's post-script poll can misfire ("VM ended
  before the expected transcript appeared") while serial provably
  contains the marker and all needles pass — accepted as pass.
- **Live gate PASS 6/6 (run 6)** on VZ; measurement artifact
  (`artifacts/m34-hf7-measurement.txt`, deduped to the successful
  attempts):
  ```
  HF7_COPY_3_DELTA=22061056    (3 cp -R worktrees ≈ 22.06 MiB)
  HF7_COPY_CLEAN_DELTA=12288   (≈ 0 after rm)
  HF7_CLONES_3_DELTA=0         (3 guest vf-clone worktrees ≈ 0 B — COW)
  HF7_DU_*=7172 KB each        (du blind to COW: clone == copy == repo)
  HF7_EDIT_512B_DELTA=4096     (one 4 KiB block for the 512 B append)
  ```
  plus `HF7-TREE` proof: wt2/wt3 sha256-identical to repo after the edit
  (untouched siblings), wt1 differs ONLY in README (529 B, cksum 0xda53
  matches the guest's exact pattern append). Passed runs 3 (measurement
  + tree proof) and 4 partially before the flake; runs 1/2 polluted by
  ambient-volume deltas (fixed by the sparseimage) and the pre-retry
  flake.
- **Quality pass (post-mortem):** G13 moved after G12 (numbering);
  clone() doc notes the combined-frame request-buffer cap (parity with
  RENAME); claim Owner now carries the backticked branch (coordination
  gate); measurement publication dedupes retry-attempt noise (the LAST
  attempt's values are the evidence).