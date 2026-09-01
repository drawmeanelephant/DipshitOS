# Claim: M34 HF4 — app delivery from the host folder (issue #738)

- **Owner:** buffy (`agent/buffy/m34-hf4-exec`)
- **Prompt / plan:** M34 (milestone #21) issue #738; HF1+HF2 (PR #745,
  claim 7710) and HF3 (PR #747, claim 9459) are merged — queue 5 wire +
  `vf ls`/`vf cat` + mutation verbs are live-proven. Tracker
  `docs/host-file-channel-scoping.md`.
- **Scope:** kill the image-rebuild iteration loop — a `.ELF` compiled on
  the host and dropped into the `--cvc-file` share is `exec`'d in the
  guest with NO `make-image.sh` rebuild. The kernel `exec` path gains the
  host share as its PRIMARY app source (stat + chunked READ round trips
  into the existing 256 KiB staging buffer; ESP stays the fallback — dual
  path until HF6 deletes the FAT app path, so default boots stay
  byte-identical). A read-only `/host` volume is added to the kernel file
  table (userland file seam → vf LIST/READ/STAT), and the desktop manifest
  loader re-points to `/host/APPS.TXT` first, `/esp/APPS.TXT` fallback —
  so a dropped manifest + ELF changes the launcher catalog with no image
  rebuild. Live gate extends `verify-live-vf.sh` with an app-delivery
  phase: the gate compiles a tiny freestanding ELF on the host AFTER the
  image is baked, drops it + a 2-entry `APPS.TXT` into the share, and the
  boot asserts `vf ls` lists it, `exec HF4APP.ELF` runs it (marker +
  exit status), and `exec DESKTOP.BIN` prints `desktop: manifest apps=2`
  from the HOST manifest (vs 19 on the ESP) — the re-point proof.
- **Touches:** `kernel/src/exec.zig` (host-folder app source), `kernel/src/
  virtio_file.zig` (`read_into` chunked stream), `kernel/src/file_table.zig`
  (`.host` partition: parse route + read-only open/read/dir_list +
  mutation guards), `user/src/desktop.zig` (manifest re-point),
  `tools/verify-live-vf.sh` (HF4 app-delivery phase), `tools/
  verify-vf-class-a.sh` (comment), `docs/host-file-channel-scoping.md`
  (HF4 row done), claim + branch log; claim id via `bash tools/status/
  claim-id.sh`.
- **Not touching:** HF5/HF6/HF7 cards — no user-data migration, no FAT
  removal, no CLONE. The host share stays read-only for userland (writes
  remain monitor `vf` commands until HF5 re-homes user data). The wire
  format is unchanged (no new opcodes); `main.swift` serving stays.
- **Heartbeat:** 2026-09-01
- **Status:** ✅ done
