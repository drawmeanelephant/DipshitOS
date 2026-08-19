# Log — `docs/site-current-state-m15`: refresh the public GitHub Pages site to current reality (claim 7489)

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