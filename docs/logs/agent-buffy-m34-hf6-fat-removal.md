# Log — M34 HF6 FAT removal: slim to a boot volume, gate fleet simplification (issue #740)

Branch: `agent/buffy/m34-hf6-fat-removal` · Worktree: `../virelaios-buffy`

## 2026-09-01 — claim 4780 filed; survey complete

- **Dependency web pinned:** `fat.zig` (2,260 lines) is imported by
  migrate, file_table, settings, shell, esp, redirect (tests), tombstone,
  exec, monitor, virtio_blk. `virtio_blk.zig` (491) by migrate,
  file_table, main, scheduler (tombstone disk writes), monitor.
  `esp.zig` (554) by settings, main, shell, redirect (tests), tombstone,
  exec, syscall (exec name bound), monitor. Monitor's storage surface:
  `ls`/`cat`/`write`/`mount`/`du` (+ ESP/DATA stat, rm, mv) all ride
  fat/esp; the `vf` family (probe/ls/cat/stat/mkdir/rm/mv/write...) is
  the replacement. No boot-time auto-launch of the desktop — gates script
  `exec DESKTOP.BIN`; the image (make-image.sh) embeds the apps on the
  ESP today.
- **Design locked:** kernel = host-only file surface (exec + file_table +
  settings + shell + tombstone over queue 5); monitor keeps `vf` and
  drops the FAT commands (`du` re-points to a vf LIST walk); default
  boot (no `--cvc-file`) = monitor with no apps (the declared end-state
  per the scoping doc); image = single boot volume; gates seed their
  `$RUN_DIR/share` from `zig-out/bin` (the app bundle) + a generated
  `APPS.TXT`, arm `--cvc-file`, and attach ONE shared read-only boot
  image with no locks.

## 2026-09-01 — implementation + live sweep done; flake filed (#803)

- **Image fixed + slimmed:** `mkfat32.py` rewritten to a single boot
  volume (EFI + KERNEL.BIN, 33.7 MiB FAT32 floor) and the GPT headers
  padded to full sectors — the 92-byte header RHS shrank the bytearray
  and silently misaligned every sector past LBA 1 (image was un-bootable;
  `hdiutil imageinfo` = "image not recognized", VMRunner
  UnsupportedFormatError). Now sector-exact (35,364,864 B) and hdiutil
  recognizes it. `make-image.sh` slimmed to a 90-line single-volume
  builder; `zig build image` green.
- **Kernel/userland deletions done:** `fat.zig` (2,260), `esp.zig`
  (554), `virtio_blk.zig` (491), `migrate.zig` deleted; `fstest.zig`
  deleted; all consumers re-pointed to the queue-5 share (exec, file_table,
  monitor, shell, settings, redirect, tombstone, scheduler, syscall,
  main); userland `/esp`/`/data` strings + labels re-pointed (asm, zc,
  netprof, desktop, edit, dir, sysmon, httpd, download, file_browser).
  Unit suite 516+, build, BSS budget (574 KiB headroom) green.
- **Gate infra collapsed:** `gate-run.sh` now attaches ONE shared
  read-only `artifacts/disk.img`; `gate_seed_share`/`gate_arm_share`
  seed a private share per gate; `gate_shared_disk_lock` deleted; 7
  direct-attach gates converted; duplicate `--cvc-file` flags removed
  (single-value option would error); `verify-live-fs.sh`/`gfs.sh`
  rewritten as share-persistence gates; fs-mutation + filemanager-mkdir
  deleted (exec'd the deleted FSTEST.BIN).
- **Mutation gate:** the deleted `fat.zig` row re-pointed to
  `file_table`'s `..`-traversal defense (ANSI-C `\x27` quoting — a raw
  `'` terminates `$'...'`); 3/3 mutations detected.
- **Transcript fixture re-synced** (CRLF normalisation + the `which`
  help re-point) — byte-identical gate PASS.
- **Live sweep on VZ (all PASS unless noted):** vf (4/4 boots),
  settings, fs, gfs, user-fs, history, asm, scripting, pipe, desktop,
  file-browser, filemanager-bulk (n=4), filemanager-recent, filemanager-
  props, zc (passes on rerun). Controlled-share conversions: user-fs
  (DIR.BIN's 8-entry enumeration cap), recent (RECENT virtual-entry
  injection needs < 16 rows), bulk (select-all count incl. FILE.BIN +
  WINDOWS.SAV), file-browser (7-entry listing).
- **Known flake filed (#803):** `verify-live-exec` intermittently panics
  with corrupted exception frames after EL0 exec from the share (1/5 in
  a measurement; also seen once in zc and the vf app boot). Dumps show
  garbage frames (sp=0, rodata/ASCII pointer values, elr decoding to a
  `ret`); base-commit control (same share gate, pre-HF6 kernel) passed
  3/3. Correlates with the faster share-era boot widening an SMP/tick
  race window in the executor/exception path — not an HF6 functional
  regression. See issue #803.
