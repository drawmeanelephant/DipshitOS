# Claim: M15 A2 — PCM playback: control-queue stream enumeration + bounded zero-heap beep

- **Owner:** buffy (`freebuff/hey-bestie-the-chat-got-lost-so-we-re-so-back-can--53baf792-c2f8-470d-a9f1-6344aa90847a`)
- **Prompt / plan:** `docs/march-m15.md` card A2 (milestone fifteen — audio)
- **Scope:** M15 A2 — the PCM playback path: CONTROL-queue stream
  enumeration (the A1-finding workaround), SET_PARAMS/PREPARE/START/STOP
  flow, a bounded zero-heap PCM buffer + `beep <freq> <ms>` monitor
  command, and TX-queue submission with drained-frame accounting.
- **Depends on:** A1 (claim 6140, uncommitted in this worktree — the
  virtio-snd transport + `--sound` host mode)
- **Status:** ✅ done (2026-08-18)

## What A2 delivers

- **Control-queue protocol** (queue 0): request/response exchanges for
  JACK_INFO / PCM_INFO / PCM_SET_PARAMS / PCM_PREPARE / PCM_START /
  PCM_STOP / PCM_RELEASE, following the virtio-snd spec §5.14.6. Stream
  topology is enumerated via PCM_INFO (the A1 finding — VZ does not
  populate the le32 config counts, so `streams` reads 0 and the driver
  must ASK).
- **PCM TX queue** (queue 2 = stream 0 playback): armed like the control
  queue; buffers submitted as [pcm_xfer hdr][samples][pcm_status
  writable] descriptor chains; used-ring drain accounting.
- **`beep <freq> <ms>`** monitor command: synthesizes a sine into a
  fixed BSS buffer (zero heap), negotiates the stream params from what
  the device advertises, submits, drains, and stops. Reports the
  negotiated format/rate/channels + bytes submitted/drained + every
  control status — the gate's evidence.
- **Live gate** `verify-live-sound-playback.sh`: the serial report shows
  the full flow; the guest's own counters prove N frames submitted and
  drained on VZ.

## Protocol facts — OBSERVED (the empirical truth, not the header)

The Linux uapi header (read 2026-08-18) gave the struct shapes, but the
live runs pinned the protocol the way only a device can:

- **VZ speaks the virtio-1.3 control renumbering.** A first attempt used
  the 1.2 codes (PCM_INFO=3, status OK=0 — the hypothesis that VZ's
  device predates the renumbering). The device answered code 3 with
  **BAD_MSG 0x8001**, pinning the 1.3 set: PCM_INFO=0x0100,
  SET_PARAMS=0x0101, PREPARE=0x0102, RELEASE=0x0103, START=0x0104,
  STOP=0x0105; status OK=0x8000.
- **Control replies are [status hdr][entries]** — status FIRST (the live
  reply bytes: 0x8000 then the pcm_info). The Linux driver reads
  [entries][status]; VZ writes it first. Recorded, not assumed.
- **Two transport lessons pinned live:** the used ring's cache line MUST
  be invalidated on every poll (without it the exchange times out — the
  device's DMA completion is cache-invisible), and the 16-bit kick is
  the QUEUE-INDEX write (Virtio 1.3 §4.1.5.2.1 — the net driver's shape;
  the first attempt kicked with the avail index).
- **PCM_INFO(0)** advertises formats bits 5/17/19 (S16|S32|FLOAT),
  rates bits 7/10 (48000|96000), channels 1..2, direction OUTPUT. (My
  first FMT constants used 16/18 — off by one against the enum; the live
  bitmap pinned S32=17, FLOAT=19.)
- **Negotiated:** FLOAT (19), 48000 (7), stereo (2). SET_PARAMS +
  PREPARE + START + STOP + RELEASE all S_OK.
- **TX:** queue 2 (notify offset 2, multiplier 4), buffers as
  [pcm_xfer][samples] + writable [pcm_status]; a 300 ms beep = 115200 B
  submitted in 4096-B periods, ALL drained, pcm_status 0x8000,
  latency 4096.
- Struct shapes (from the uapi header, unchanged across the renumbering):
  query_info {hdr, start_id, count, size}; pcm_info {hda_fn_nid,
  features, formats le64, rates le64, direction, ch_min, ch_max,
  padding[5]} (32 B); set_params {hdr, buffer_bytes, period_bytes,
  features, channels, format, rate, padding} (20 B); pcm_status
  {status, latency_bytes}.

## Verification

- Class A: all green (fmt; 18-module unit tests incl. the five
  virtio_snd tests — spec shapes, honest unarmed refusals, format/rate
  math, pick_params preference order, phase-continuous sine synthesis;
  byte-identical transcript; build/image/inspect; swift; context;
  coordination ×2; mmu-debt; glyph-raster; mutations).
- Class B: `bash tools/verify-live-sound-playback.sh` — **PASS 1/1 on
  VZ** (2026-08-18T22:26Z; evidence `artifacts/live-sound-playback-*`):
  the guest's own accounting proves 115200 B submitted / 115200 drained
  / 14400 frames with every control status S_OK. The audible
  confirmation is the A4 composition; the gate proves the device
  consumed every frame.
