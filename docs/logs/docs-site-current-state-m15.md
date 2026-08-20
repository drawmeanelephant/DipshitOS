# Log — `docs/site-current-state-m15`: refresh the public GitHub Pages site to current reality (claim 7489)

## 2026-08-20 — milestone sixteen card C2

- **2026-08-20** — *Muse Spark (`docs/site-current-state-m15`)*: claim 4722 → M16 C2 (guard pages + per-segment perms, issue #191) claimed — guard at 0x401000 (text@0x400000 4K, gap, data@0x402000 32K), stack guard below random stack, data RW+PXN+UXN (not executable), text RO+PXN, fault dispatcher + scheduler.handle_el0_fault (exit 139) so hostile EL0 fault is reaped not parked. Status 🔄 claimed. Progress: linker guard + fault path + BIGTEST re-verified PASS with data at 0x402000. Next: wire GUARDTEST.BIN, gate `verify-live-m16-guards.sh`, full sweep.

## 2026-08-20 — milestone sixteen card C1

- **2026-08-20** — *Muse Spark (`docs/site-current-state-m15`)*: claim 3900 → milestone sixteen card C1 (multi-segment user image, issue #190) claimed — DSK2 second loader path, writable data/BSS, lifted 64 KiB bound. Status 🔄 claimed.
- **2026-08-20** — *Muse Spark (`docs/site-current-state-m15`)*: claim 3900 → M16 C1 done — DSK2 loader live on VZ: BIGTEST.BIN 28768 B (>16 KiB) 2 seg RX@0x400000 + RW@0x401000 (32 KiB RW file + BSS zero), exec at EL0 with per-segment W^X (RX vs RW+PXN+UXN), uaccess data+stack, process data pages, 64 KiB staging, gate `verify-live-m16-image.sh` PASS 1/1 (markers all green, exit 42, sys_write 11, size 0x7000). Evidence `artifacts/live-m16-image-serial.log`, `zig-out/bin/BIGTEST.BIN` DSK2, `artifacts/bigtest-info.txt`. → ✅ done.

## 2026-08-19 — branch work

- **opencode (`docs/site-current-state-m15`)**: claim 7489 → the public
  `site/` tree had stopped at the milestone-thirteen status sweep; updated 9
  pages to reflect M14 (shared user services) + M15 (audio) shipped complete,
  M16 (the kernel grows up, issues #190–#193) as the planned stream, the
  46-slot syscall ABI (slots 0–45: clipboard 38/39, app timers 40/41, audio
  42/43, audio volume/mute 44/45), the 27 ESP `.BIN` programs (added
  TIMER/VICTIM/HARDEN/JINGLE/CHIME), the virtio-snd driver (DID 0x1059), the
  71-gate live set, and the 47-command monitor registry. Evidence: the
  docs-gate sequence re-ran green locally against the pinned Boris revision
  (`boris validate` + full compile, rendered HTML contains the new content).
  No `docs/status.md` or planning-tree edits. → ✅ done.