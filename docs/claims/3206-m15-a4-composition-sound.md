# Claim: M15 A4 — composition capstone: boot chime + event-triggered sound through the EL0 seam, with a one-session live gate

- **Owner:** buffy (`freebuff/hey-bestie-the-chat-got-lost-so-we-re-so-back-can--53baf792-c2f8-470d-a9f1-6344aa90847a`)
- **Prompt / plan:** `docs/march-m15.md` card A4 (milestone fifteen — audio)
- **Scope:** M15 A4 — the composition capstone only: a boot chime, and a
  sound that fires on an existing event (window focus, a clipboard copy,
  or a timer tick) through the proven EL0 audio seam, plus the
  `verify-live-m15-composition.sh` gate proving device + playback + EL0
  + the hearable composition in ONE VM session. No new syscalls, no new
  device work, no later-milestone scope.
- **Depends on:** A1 (claim 6140), A2 (claim 5877), A3 (claim 7636) —
  all uncommitted in this worktree (the A1–A3 change set).
- **Status:** ✅ done (2026-08-18)

## What A4 delivers

- **Boot chime** — a short, recognizable sound played once at boot when
  the sound device is present (flag-gated like the device itself; absent
  with no `--sound` device, honest ENXIO path).
- **Event-triggered sound** — one existing event (window focus,
  clipboard copy, or timer tick) fires a sound through the EL0 seam, so
  audio composes with the M14 shared services.
- **Live gate** `verify-live-m15-composition.sh` — ONE VM session that
  proves the whole stack: device present (the A1 `sound` report),
  playback drains (the A2 accounting), the EL0 seam works (the A3
  syscall counts), and the event-triggered sound fired.

## Verification

- Class A: fmt, all unit tests (virtio_snd 18 incl. the new unarmed-chime
  refusal), byte-identical transcript, build/image/inspect, swift build,
  coordination green.
- Class B: `bash tools/verify-live-m15-composition.sh` **PASS 1/1 on VZ**
  (evidence `artifacts/live-m15-composition-*`): boot chime + 3
  timer-driven blips + lifecycle + syscall counts in ONE session, and
  the A1/A2/A3 gates re-ran green with the chime in the boot path.

## Claim-time findings (2026-08-18, live on VZ)

1. **The boot chime is flag-gated on the device, so the default boot is
   byte-identical.** `snd_chime()` (two `snd_beep` calls: 660 Hz 150 ms +
   880 Hz 220 ms) runs only inside the existing `if (snd_ready)` rearm
   block; with no `--sound` device the whole block is skipped and the
   unarmed refusal is host-tested (no hang, honest reason). The A1/A2/A3
   gates (which boot with `--sound`) still pass — their greps are
   marker-based, and the chime adds lines without disturbing them.
2. **The composition is the M14 shared service firing the M15 sound:**
   CHIME.BIN arms `sys_timer_set` (slot 40) and blocks in
   `sys_wait_event`; the scheduler's TIMER event (kind 9) is the trigger
   for `sys_audio_play` (slots 42/43). The live accounting: 3 ticks, 10
   chunks per blip, 38400 B each, `sys_timer_set calls=3`, `sys_audio_info
   calls=1`, `sys_audio_play calls=30`, exit 0 — all in the same boot as
   the boot chime and the `sound` device report.
