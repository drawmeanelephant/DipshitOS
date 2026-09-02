# Claim: IMG5 — VIEW.BIN image viewer app with pan & zoom

- **Owner:** buffy (`agent/buffy/img5-view`)
- **Prompt / plan:** Freebuff session, issue #826 (M36 IMG5)
- **Scope:** M36 Raster Graphics — the VIEW.BIN userland image viewer: argv file
  path, QOI decode, aspect-ratio window (clamped to the user back-buffer
  bounds), zoom (keys `+`/`-`/`0`, scroll wheel) and pan (arrow keys,
  click-drag when zoomed), title bar with filename/dims/format/zoom,
  `zig build view` step, APPS.TXT row, live gate
  `tools/verify-live-image-viewer.sh`.
- **Touches:** user/src/view.zig, build.zig, image/apps.txt,
  tools/verify-live-image-viewer.sh, tools/verify-live-desktop.sh,
  tools/verify-live-file-browser.sh, tests/fixtures/qoi/viewer_160x120.qoi,
  user/src/lib/fixtures/qoi/viewer_160x120.qoi,
  user/src/lib/fixtures/deflate/uncompressed.bin,
  user/src/lib/fixtures/deflate/hello_raw.bin,
  docs/claims/4574-img5-view.md, docs/logs/agent-buffy-img5-view.md
- **Depends on:** IMG1/IMG4 raster engine (landed in PR #827 on main); the
  `exec <path>` argv contract (claim 4636, shell `exec` path)
- **Heartbeat:** 2026-09-02
- **Status:** ✅ agent/buffy/img5-view

## Notes

Per issue #826: exec `VIEW.BIN <path>` (e.g. `/host/TEST.QOI`); no-args opens
an empty state. The decode is **QOI-only by design**: IMG1's `image.decode()`
dispatch pulls in png.zig, whose 128 KiB IDAT staging BSS pushes the DSK3
`data_mem` segment past the kernel's 256 KiB exec cap (observed live: the
kernel refused to load the binary). The viewer imports `lib/qoi.zig` directly
into its own mmap'd pixel buffer and blits nearest-neighbor via batched
fills; PNG lands with a stream-chunked IDAT path in a separate card (noted in
the code header). Zero heap: file bytes + pixels live in M29 anonymous mmap
regions (MAP_POPULATE), state is BSS; the file read is staged through a
2048-byte stack buffer because sys_file_read's copy_out only validates
against the apertures armed at SVC entry (text/stack/exec data) — not mmap
regions (observed live: `view: read err` reading straight into the mmap'd
buffer). The live gate is a direct monitor `exec` (like verify-live-exec /
verify-live-sexiburger-actions), so the desktop-manifest marker is not
asserted here; the manifest count bumps to `apps=22` live only in the
DESKTOP-booting gates. Verification: class-A `zig build view` (BSS tail 872
bytes) + 81/81 host unit tests; class-B gate 2/2 boots PASS (one run hit the
tracked #810 boot-probe flake — unrelated EL1 park — and passed on rerun).
Artifacts: artifacts/live-image-viewer-{gate,report,run-boot-*,serial-boot-*}
plus the gpu screenshots.
