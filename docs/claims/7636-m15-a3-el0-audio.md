# Claim: M15 A3 — EL0 audio seam: sys_audio_info/sys_audio_play (ADR 0007 slots 42–43) + JINGLE.BIN melody app

- **Owner:** buffy (`freebuff/hey-bestie-the-chat-got-lost-so-we-re-so-back-can--53baf792-c2f8-470d-a9f1-6344aa90847a`)
- **Prompt / plan:** `docs/march-m15.md` card A3 (milestone fifteen — audio)
- **Scope:** M15 A3 — the EL0 audio seam only: ADR 0007 slots 42/43
  (`sys_audio_info`, `sys_audio_play`; `implemented_count` 42→44), the
  userlib wrappers, and the `JINGLE.BIN` melody app. A4 (composition) is
  the next card.
- **Depends on:** A2 (claim 5877, uncommitted in this worktree — the PCM
  playback path + the virtio-1.3 protocol pins)
- **Status:** ✅ done (2026-08-18)

## What A3 delivers

- **`sys_audio_info(out)` — slot 42:** returns the device's negotiated
  playback state as a 24-byte struct {ready, format, rate, channels,
  period_bytes, max_len} via uaccess copy-out. The app learns the
  format/rate/channels it must synthesize in (FLOAT 19 / 48000 7 /
  stereo 2 on the observed VZ device).
- **`sys_audio_play(ptr, len)` — slot 43:** copies the caller's PCM
  samples in through the uaccess window in bounded periods (4096 B —
  the A2 period buffer, zero heap), runs the proven control flow
  (PCM_INFO → SET_PARAMS → PREPARE → START → submit/drain per period →
  STOP → RELEASE), and returns the bytes played. Errors: EINVAL
  non-process caller / zero len, ENAMETOOLONG over `audio_max_len`
  (64 KiB), EFAULT bad pointer, ENXIO no device / device-level refusal.
- **userlib** (`ui.zig`): `audio_info` / `audio_play` wrappers.
- **`JINGLE.BIN`** (`user/src/jingle.zig`): asks `sys_audio_info`,
  synthesizes a recognizable melody (the "Twinkle Twinkle" phrase —
  C C G G A A G) as per-note PCM in the negotiated format, plays each
  note with `sys_audio_play`, prints gate markers.
- **Live gate** `verify-live-sound-app.sh`: execs JINGLE.BIN, asserts
  the info markers, the per-note played accounting, the melody done
  marker, and the `syscalls` report (slots 42/43 counted, implemented=44).

## Errors / ABI (ADR 0007 amendment)

- Slots 42/43 (the next free range; M14 ended at 41, implemented_count
  was 42). `ENXIO` (-9) is added to the ErrorCode enum for "no audio
  device" (the standard errno — the seam refuses honestly when the
  default VM has no `--sound` device).

## Verification

- Class A: syscall unit tests for the new slots (marshaling, honest
  no-device refusals), jingle.zig host test (note table + sine math),
  fmt, full suite green (implemented=44 updates in the nine class-B
  scripts that pinned 42).
- Class B: `bash tools/verify-live-sound-app.sh` **PASS 1/1 on VZ**
  (evidence `artifacts/live-sound-app-*`): JINGLE.BIN execs from EL0,
  `sys_audio_info` reports the negotiated FLOAT(19)/48000(7)/stereo(2)
  state (period=4096 max=65536) via the FIRST-call probe+SET_PARAMS,
  then all 14 notes of Twinkle Twinkle Little Star play with exact
  accounting — 96000 B per 250 ms quarter (24 chunks of 4 KiB), 192000 B
  per 500 ms half (47 chunks), **382 `sys_audio_play` calls total**,
  `jingle: done`, exit 0. Same-boot syscalls report: implemented=44,
  `42 sys_audio_info calls=1`, `43 sys_audio_play calls=382`.

## Claim-time findings (2026-08-18, live on VZ)

1. **The app's writable data must be a STACK local.** A global BSS
   `chunk_buf` faults on write from EL0 — the process's text page is W^X
   (read-only to EL0), so globals live in the RO image. Moved the chunk
   buffer into `_start` as a 4 KiB stack local (16 KiB user stack), the
   pattern every other user program already uses. Also shrunk the image
   under the 16 KiB (0x4000) exec load buffer: 33160 → 8624 B.
2. **`sys_audio_info` must drive the negotiation on first call.** Before
   any play, `beep_format` is 0xff — the app cannot learn what to
   synthesize from a cached value that was never set. Split the
   probe+SET_PARAMS half out of `snd_audio_start` into
   `snd_audio_negotiate`; `snd_audio_info` runs it when not yet
   negotiated (later calls report the cache).
