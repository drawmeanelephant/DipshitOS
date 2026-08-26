# Log — agent/buffy/m21-window-depth

## 2026-08-26 — Buffy (claim 8777)

Resumed and expanded the M21 window management depth sweep across all 16 cards (W1–W16, GitHub milestone 9):
- Refined compositor semantics in `kernel/src/driving_award.zig` (always-on-top z-order and pin indicators, modal window input capture, transient auto-close, keyboard movement and resizing, notification center, close confirmation dialogs).
- Added comprehensive EL1h monitor inspection halves in `kernel/src/monitor.zig` under `dui` for all window operations (`minimize`, `restore`, `maximize`, `fullscreen`, `aot`, `kmove`, `kresize`, `title`, `modal`, `transient`, `notif`, `notif-center`, `notif-dismiss`, `notif-clear`, `ws`, `ws-cycle`, `unsaved`, `dialog-show`, `dialog-click`).
- Built 5 complete class-B Virtualization.framework live acceptance gates with full serial marker assertions and decoded pixel captures:
  1. `tools/verify-live-m21-tile-master.sh` (W1 tiling + W2 master swap)
  2. `tools/verify-live-m21-minimize-ws.sh` (W3 minimize/restore + W4 workspace Alt+Tab)
  3. `tools/verify-live-m21-max-fullscreen-aot.sh` (W6 maximize + W7 fullscreen + W8 always-on-top + W10 keyboard move)
  4. `tools/verify-live-m21-notif-dialog-transient.sh` (W5 notification center + W13 close dialog + W15 modal + W16 transient)
  5. `tools/verify-live-m21-persist-title-orphan.sh` (W11 persistence + W12 title updates + W14 orphan cleanup)
- Verified all unit tests, coordination checks, and live gates on Apple silicon hardware.
