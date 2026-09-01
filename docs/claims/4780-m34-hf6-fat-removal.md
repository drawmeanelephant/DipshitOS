# Claim: M34 HF6 — FAT removal: slim to a boot volume, gate fleet simplification (issue #740)

- **Owner:** buffy (`agent/buffy/m34-hf6-fat-removal`)
- **Prompt / plan:** implement M34 HF6 (#740): delete the guest's FAT
  surface entirely — `kernel/src/fat.zig` (2,260 lines), the post-exit
  `virtio_blk.zig` path (491), `kernel/src/esp.zig` (554), and the
  one-time migration (`migrate.zig`, its job is done) — plus the DATA
  partition and the embedded-apps image machinery. The image becomes a
  boot volume only (loader + kernel + boot assets, a few MiB), parsed by
  Apple's firmware pre-exit: zero guest code speaks FAT after boot. The
  gate fleet collapses to ONE shared read-only boot image (kill private
  writable copies + `gate_shared_disk_lock`); a gate's storage fixture
  becomes a private host directory (`--cvc-file` share seeded from the
  app bundle + fixtures).
- **Kernel rework:** `file_table.zig` becomes host-only (`.host` is the
  only partition; bare paths route to the share); `exec.zig` loads apps
  from the share only (ESP fallback gone); `monitor.zig` drops the
  ESP/DATA commands (`ls`/`cat`/`write`/`mount`/`du` re-pointed or
  deleted — the `vf` family is the FS surface); `settings.zig` /
  `shell.zig` share-only (DATA/ESP fallbacks gone); `tombstone.zig`
  writes crash logs to the share when armed; `scheduler.zig` /
  `syscall.zig` / `main.zig` lose the blk/esp wiring; `redirect.zig`
  host tests reworked.
- **Userland:** delete `fstest.zig` (FAT mutation test binary); re-point
  `asm.zig` routes and remaining `/esp`/`/data` display strings to
  `/host`.
- **Image:** `image/mkfat32.py` + `make-image.sh` slim to a single boot
  volume (no DATA partition, no embedded apps); `zig build image`
  produces the boot image; the app bundle for gates comes from
  `zig-out/bin` (+ a generated `APPS.TXT`).
- **Gate infra:** `tools/lib/gate-run.sh` attaches the shared read-only
  image directly (no overlay base, no disk copy, no shared-disk locks);
  a `gate_seed_share` helper copies the app bundle + writes APPS.TXT
  into `$RUN_DIR/share`; every gate that execs an app or boots the
  desktop arms `--cvc-file`; gates that used monitor `ls`/`cat`/`write`/
  `mount`/`du` re-point to `vf`.
- **Touches:** deletions (`kernel/src/{fat,esp,virtio_blk,migrate}.zig`,
  `user/src/fstest.zig`) · `kernel/src/{file_table,exec,monitor,settings,
  shell,tombstone,scheduler,syscall,main,redirect}.zig` ·
  `user/src/{asm,desktop,sysmon,wnd}.zig` · `image/{mkfat32.py,
  make-image.sh}` · `build.zig` · `tools/lib/gate-run.sh` ·
  `tools/verify-live-*.sh` (fleet re-point) · `docs/hardware-contract.md`,
  `docs/host-file-channel-scoping.md`, `docs/status.md`,
  `docs/claims/4780-m34-hf6-fat-removal.md`,
  `docs/logs/agent-buffy-m34-hf6-fat-removal.md`
- **Depends on:** HF4 (app delivery), HF5 (user-data migration) — landed
- **Heartbeat:** 2026-09-01
- **Status:** 🔄

## Notes

Acceptance gate (issue #740): `verify-vz` full fleet green with FAT gone;
boot image ≤ a few MiB; zero references to `fat.zig`/`mount`/`/data` in
gates or docs; image build is a single-volume build. Verification:
class-A (fmt/build/unit/transcript/BSS/vf-wire) + a representative
live-gate sweep (exec, desktop, vf family, persistence re-points) + as
much of the fleet as the session allows, recorded in the log.
