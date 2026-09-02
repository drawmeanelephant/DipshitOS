# Log — `agent/buffy/img5-view`

- **2026-09-02** — *buffy (agent/buffy/img5-view)*: Claimed IMG5 (issue #826,
  M36) — VIEW.BIN image viewer with pan & zoom. Dependencies IMG1 (image.zig)
  and IMG4 (draw_image) landed in PR #827 on main; worktree reattached to
  fresh origin/main (98a5478). Plan: new `user/src/view.zig`, `zig build view`
  step, APPS.TXT row, live gate `tools/verify-live-image-viewer.sh`. No
  kernel changes planned.

- **2026-09-02** — *buffy (agent/buffy/img5-view)*: Implemented. The decode is
  QOI-only by design: importing IMG1's `image.decode()` (→ png.zig) blew the
  DSK3 256 KiB `data_mem` exec cap (observed live: kernel refused the
  binary — `image larger than the 0x40000-byte load buffer`); the viewer
  imports `lib/qoi.zig` directly and blits nearest-neighbor itself. File
  bytes + decoded pixels live in M29 anonymous mmap regions (MAP_POPULATE,
  `zig build view` bss tail = 872 B), state in BSS; zero heap. PNG deferred
  to a stream-chunked IDAT card (noted in the code header).

- **2026-09-02** — *buffy (agent/buffy/img5-view)*: Fixed the live-gate read
  failure: `sys_file_read`'s `copy_out` validates only the apertures armed at
  SVC entry (text/stack + the exec-armed data segment) — M29 mmap regions are
  armed transiently inside the mmap syscall only, so reading straight into
  the mmap'd `file_bytes` returned EFAULT (`view: read err`, observed live
  twice). The load now stages each ≤2048-byte chunk (the kernel cap) on the
  stack and `@memcpy`s into the mmap'd buffer — no syscall boundary crossed.
  No kernel change (IMG5 is userland-only).

- **2026-09-02** — *buffy (agent/buffy/img5-view)*: Gate-shape corrections
  after the first full live runs: the desktop never boots in a direct
  monitor-exec gate, so the `desktop: manifest apps=22` assertion was dropped
  (the DESKTOP-booting gates carry the count; both bumped 19→22 — the real
  parse count of image/apps.txt with the VIEW.BIN row). The pan announce is a
  single combined `view: pan ox=X oy=Y` line (the old separate-oy grep could
  never match); added a one-time `view: title set` marker; chords end zoomed
  IN so pan genuinely engages (at ≤100% the image fits the viewport and
  pan_max clamps to 0); `--script-expect` waits for the reaped
  `user-exec exited status=43` so teardown doesn't cut the reap line off.

- **2026-09-02** — *buffy (agent/buffy/img5-view)*: Repaired a main defect
  found while running class-A: flate.zig (landed in PR #827) `@embedFile`s
  `fixtures/deflate/uncompressed.bin` + `hello_raw.bin`, but a broad `*.bin`
  .gitignore rule means they were never committed — any `zig test` reaching
  flate.zig fails to compile on a fresh clone (CI's verify-unit-tests.sh only
  covers kernel modules, so main stayed green). Generated the two tiny
  deterministic fixtures (10/44 bytes) and force-add them to the branch so
  this claim's class-A test evidence is reproducible.

- **2026-09-02** — *buffy (agent/buffy/img5-view)*: Merged origin/main
  (PR #829 desktop-quality, #830 desktop-manifest-21, #831 indexes) into the
  branch after the PR flagged CONFLICTING. Two content conflicts, both the
  manifest-needle in tools/verify-live-desktop.sh + verify-live-file-browser.sh:
  #830 had bumped 19 → 21 for main's 21-row APPS.TXT (closing #729); this
  branch's row makes 22. Resolved to 22, folding #830's richer comment prose
  (the M19 sexiburger rows, 5845d7f) plus the IMG5 VIEW.BIN note. No other
  hunks conflicted; the coord/index regeneration tables from #831 merge
  cleanly.

- **2026-09-02** — *buffy (agent/buffy/img5-view)*: Class-A green — `zig
  build view` (VIEW.BIN, DSK3 segmented, bss tail 872 B) and `zig test
  user/src/view.zig` 81/81 (viewer pure-logic tests + transitively imported
  qoi/flate suites). Class-B live gate 2/2 boots PASS on real VZ:
  banner, exec, open 328x264, `loaded TEST.QOI 160x120 QOI bytes=340`,
  ready, title, zoom 150%/100%/66%, pan ox/oy, quit, reaped exit status=43,
  and sys_win_set_title in the syscalls report — evidence in
  `artifacts/live-image-viewer-*`. One earlier boot parked on the tracked
  #810 boot-probe EL1 flake (far=0 walk abort, unrelated to this code) and
  passed cleanly on rerun.
