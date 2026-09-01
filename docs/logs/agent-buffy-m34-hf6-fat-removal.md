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
