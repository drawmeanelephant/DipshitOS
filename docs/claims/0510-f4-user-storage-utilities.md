# Claim: milestone ten, card F4 — userland storage utilities & live gate

- **Owner:** buffy (`agent/buffy/m10-fs`)
- **Prompt / plan:** `docs/march-m10.md`
- **Scope:** Milestone 10 card F4: standalone EL0 user applications (`SAVETEXT.BIN`, `TYPE.BIN`, `DIR.BIN`), disk image embedding, and capstone live VZ verification gate (`tools/verify-live-user-fs.sh`).
- **Depends on:** F3
- **Status:** ✅ done (2026-08-15)

## Notes

Authors the first persistent EL0 storage user utilities:
- `user/src/savetext.zig` (`SAVETEXT.BIN`): opens `/data/hello.txt` with `MODE_CREATE | MODE_WRITE`, writes persistent string, closes, prints marker, exits 0.
- `user/src/type.zig` (`TYPE.BIN`): opens `/data/hello.txt` with `MODE_READ`, reads contents, echoes to console via `sys_write`, prints marker, exits 0.
- `user/src/dir.zig` (`DIR.BIN`): lists `/data` directory entries via `sys_dir_list`, formats and prints to console via `sys_write`, prints marker, exits 0.
- Builds and embeds binaries onto ESP volume via `build.zig`, `image/make-image.sh`, and `image/mkfat32.py`.
- Authors capstone live gate `tools/verify-live-user-fs.sh` proving persistence across reboot.

## Verified

- Gate: `tools/verify-live-user-fs.sh` — PASS on live Virtualization.framework hardware.
