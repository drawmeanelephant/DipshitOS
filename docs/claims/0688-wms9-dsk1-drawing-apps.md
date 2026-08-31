# Claim: WMS9 batcher global broke flat drawing apps — convert them to DSK3 segmented

- **Owner:** buffy (`agent/buffy/wms9-dsk1-drawing-apps`)
- **Prompt / plan:** freebuff session — "move on to fixing the other issues" (the batch class-B reds)
- **Scope:** root-cause + fix the pre-existing `verify-live-wm-ipc` / `verify-live-ps` / `verify-live-sys-kill` regressions (and every NOTEPAD-driving gate) on `origin/main`
- **Touches:** `build.zig`, `kernel/src/exec.zig`, `image/make-image.sh`, `docs/logs/agent-buffy-wms9-dsk1-drawing-apps.md`, `docs/claims/0688-wms9-dsk1-drawing-apps.md`
- **Depends on:** —
- **Heartbeat:** 2026-08-31
- **Status:** ✅ done

## Notes

Root cause: `a2df6a0` (WMS9 span batching, 2026-08-30 — one day after the 08-29 WMS7 Gate-A PASS) routed every toolkit draw through a NEW mutable `fill_batcher` global in `user/src/lib/ui.zig`. DSK1 flat images merge text+rodata+.data+.bss into ONE blob mapped as a single read-only W^X text aperture, so the first batched fill WRITES a read-only page — NOTEPAD data-aborted at its bss tail (`fault: NOTEPAD.BIN far=0x403d98 ec=0x24`), byte-identical on a clean `origin/main` baseline. Same class broke TOP/PS/CALC/CHAT/DESKTOP/FILE/SETTINGS/SYSMON.

Fix (the repo's own precedent — EDIT/GLOBALS/WND: "a writable global needs the DSK3 loader's RW data+bss aperture"):
- `build.zig`: the 9 flat drawing apps → DSK3 (`--segments` + `user/linker-segmented.ld`).
- `image/make-image.sh`: magic checks for those 9 updated DSK1→DSK3.
- `kernel/src/exec.zig`: DSK3 argv — the claim-3805 "later card" (pack argv into a reserved data tail after the app's bss; data aperture + task uaccess regions grow by arg_block_bytes), so NOTEPAD's `selfdemo` argv keeps working.

Verified live: `verify-live-wm-ipc` PASS (mail/config/ack/focus/rect/present all 1), `verify-live-ps` PASS, `verify-live-sys-kill` PASS; build + image + fmt + full unit suite green. Not in this class (still tracked): `verify-live-win` stale since arc2 2026-08-21 (clock migrated to tray, `Kind.clock id 1 deprecated`), `history` / `strace` kernel-shell markers, `net-dhcp` NAT pong.
