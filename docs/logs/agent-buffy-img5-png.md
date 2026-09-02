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
