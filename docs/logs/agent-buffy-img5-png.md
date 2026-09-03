# Log — `agent/buffy/img5-png`

- **2026-09-02** — *buffy (agent/buffy/img5-png)*: Claimed the VIEW.BIN PNG
  follow-on (claim 7317): png.zig's default decode statics are 384 KiB
  (128 KiB IDAT staging + 256 KiB decompress buffer), which blows the DSK3
  256 KiB `data_mem` exec cap for any binary linking the PNG path —
  observed on the IMG5 branch (claim 4574), where VIEW.BIN went QOI-only
  with PNG deferred to "a stream-chunked IDAT path in a separate card".
  Plan: `png.scan` workspace sizing + caller-workspace decode (the existing
  `decode_with_buffers`), small default statics, VIEW.BIN mmaps the exact
  IDAT + decompress workspaces, 160x120 PNG fixture + live-gate boot.
- **2026-09-02** — *buffy (agent/buffy/img5-png)*: png.zig reworked — added
  `scan()` (one signature+IHDR+per-chunk-CRC walk returning dims, IDAT
  total, and the exact decompressed-scanline size) and replaced the 384 KiB
  default statics (`bss_idat_buf` 128 KiB + `bss_decomp_buf` 256 KiB) with
  small convenience caps (`DEFAULT_IDAT_CAP` 32 KiB, `DEFAULT_DECOMP_CAP`
  96 KiB, rows unchanged). `decode_with_buffers` (the caller-workspace,
  chunk-streamed path) is unchanged; large images scan-then-decode with
  caller memory. Convenience `decode()` still serves small images and the
  host fixtures. Class-A: `zig test user/src/lib/png.zig` 16/16, including
  four new tests — scan sizing on the split-IDAT 160x120 fixture, workspace
  decode of it (asserting pixel colors at the vertical split), scan
  error paths, and a 400x200 RGBA image whose 320200-byte scanline stream
  exceeds the old convenience caps (proving the workspace path has no fixed
  caps).

- **2026-09-02** — *buffy (agent/buffy/img5-png)*: VIEW.BIN now decodes PNG
  (claim 4574's QOI-only carve-out lifted). decode dispatch is by magic:
  `qoif` → qoi.zig, the PNG signature → png.scan + png.decode_with_buffers
  with exact IDAT + scanline workspaces mmap'd per load (two new M29
  regions; the pixel-extent pre-check bounds them), plus the static 4 KiB
  row-buffer pair. `zig build view`: image 20664 B, bss tail 9080 B (the
  two PNG row buffers) — DSK3 `data_mem` ~9 KiB, far under the 256 KiB cap
  (the default-decode statics are never linked: only scan /
  decode_with_buffers are referenced). Host suite `zig test
  user/src/view.zig` 85/85.

- **2026-09-02** — *buffy (agent/buffy/img5-png)*: Fixtures — generated a
  deterministic 160x120 RGB PNG (vertical amber/gray split matching the QOI
  gate fixture's look, filter bytes cycling 0..4 per row, compressed IDAT
  split across two chunks so the chunk-streamed path is exercised) and a
  400x200 RGBA PNG for the over-cap workspace test; committed under
  user/src/lib/fixtures/png/ (+ tests/fixtures/png/ copy for the live gate
  share). Live gate verify-live-image-viewer.sh now boots both fixtures:
  boot 1 execs /host/TEST.QOI, boot 2 execs /host/TEST.PNG, same window /
  zoom / pan / quit assertions, per-boot loaded marker (`TEST.PNG 160x120
  PNG bytes=420`). Class-B on real VZ: 2/2 PASS (boot-2 PNG: loaded, title,
  ready, zoom 150/100/66%, pan ox/oy, quit, reaped status=43, win_set_title
  in the syscalls report). Two earlier full runs each died on pre-existing
  harness flakes unrelated to this work (one tracked-#810 boot-probe EL1
  park at elr=0x7def2a90; one VM-teardown race that cut the serial tail
  before the reap line) and passed cleanly on rerun.
