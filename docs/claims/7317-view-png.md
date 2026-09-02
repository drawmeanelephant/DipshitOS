# Claim: VIEW.BIN PNG decode via stream-chunked IDAT workspace

- **Owner:** buffy (`agent/buffy/img5-png`)
- **Prompt / plan:** Freebuff session (IMG5 follow-on — VIEW.BIN is QOI-only
  because png.zig's 128 KiB IDAT staging + 256 KiB decompression BSS push
  the DSK3 `data_mem` segment past the 256 KiB exec cap)
- **Scope:** M36 IMG5 extension — PNG decode support in VIEW.BIN behind a
  png.zig stream-chunked IDAT path: `png.scan` (workspace sizing), the
  existing `decode_with_buffers` chunk-walk, small static workspace instead
  of 384 KiB BSS, caller-mmapped IDAT/decompress staging in the viewer, and
  live-gate coverage for a PNG file.
- **Touches:** user/src/lib/png.zig, user/src/view.zig,
  tools/verify-live-image-viewer.sh, tests/fixtures/png/viewer_160x120.png,
  user/src/lib/fixtures/png/viewer_160x120.png,
  docs/claims/7317-view-png.md, docs/logs/agent-buffy-img5-png.md
- **Depends on:** PR #833 (VIEW.BIN on main, claim 4574)
- **Heartbeat:** 2026-09-02
- **Status:** 🔄 agent/buffy/img5-png

## Notes

png.zig currently carries `bss_idat_buf` (128 KiB) + `bss_decomp_buf`
(256 KiB) statics referenced from the default `decode()` — 384 KiB of
.data/.bss, over the kernel's DSK3 256 KiB exec cap as soon as any binary
links the PNG path (observed on the IMG5 branch: VIEW.BIN refused to load).
This card:
1. Adds `png.scan(bytes)` — one chunk walk (signature + IHDR + per-chunk
   CRC) returning dims / color type / total IDAT length, so a caller can
   size an exact workspace without fixed caps.
2. Shrinks the default `decode()` static workspace to a modest convenience
   size (documented cap, same BufferTooSmall contract) and keeps
   `decode_with_buffers` as the caller-workspace path — IDAT chunks are
   walked and CRC'd one at a time, with no whole-file assumptions.
3. Switches VIEW.BIN's PNG branch to `png.scan` → mmap the exact IDAT +
   decompress workspaces (the file is already mmap'd) → decode into the
   mmap'd pixel buffer. Static data stays ~KiB-scale, well under the DSK3
   cap. QOI path unchanged; per-format sniff unchanged.
4. Fixtures: deterministic 160x120 PNG (two-tone, matching the QOI fixture
   colors) generated with a chunk-split IDAT so the multi-chunk path is
   exercised; host tests decode it and scan-checks it; the class-B gate
   gets a second boot exec'ing `/host/TEST.PNG`.

Verification: `zig test user/src/lib/png.zig` + `zig test user/src/view.zig`
(full graph 81+ tests), `zig build view` under the DSK3 cap, then
`tools/verify-live-image-viewer.sh` boots for both QOI and PNG fixtures on
real VZ.
