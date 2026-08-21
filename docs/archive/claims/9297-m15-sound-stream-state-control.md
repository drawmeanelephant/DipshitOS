# Claim: M15 follow-up — bounded kernel-side sound stream-state control (volume/mute), monitor command + EL0 seam

- **Owner:** buffy (`freebuff/hey-bestie-the-chat-got-lost-so-we-re-so-back-can--53baf792-c2f8-470d-a9f1-6344aa90847a`)
- **Prompt / plan:** direct feature request on top of milestone fifteen
  (audio) — "a bounded kernel-side volume/stream-state control (e.g. a
  `sound mute|volume` monitor command) and expose it through the EL0 seam"
- **Scope:** the stream-state control only: kernel-side bounded volume
  (0..100) + mute state applied at the TX submit choke point (shared by
  `beep`, the boot chime, and `sys_audio_play`), the `sound volume|mute`
  monitor subcommands, ADR 0007 slots 44/45 (`sys_audio_volume` /
  `sys_audio_mute`), ui.zig wrappers, CHIME.BIN proving the seam from EL0,
  and a live gate. No new device work, no later-milestone scope.
- **Depends on:** A1 (claim 6140), A2 (claim 5877), A3 (claim 7636),
  A4 (claim 3206) — all uncommitted in this worktree (the A1–A4 change set).
- **Status:** ✅ done (2026-08-18)

## What this delivers

- **Bounded stream state** — `stream_volume` (0..100, percent) and
  `stream_muted` (bool), plain kernel BSS. Setters reject out-of-range
  values honestly (no silent clamping).
- **Applied at the submit choke point** — `snd_audio_submit` scales the
  staged samples in place (gain = muted ? 0 : volume/100) before the kick,
  so `beep`, the boot chime, and every `sys_audio_play` call are all
  attenuated by the same state. Zero heap, bounded, and the
  submitted/drained accounting stays exact (mute zeroes samples — the
  stream keeps draining).
- **Monitor** — `sound volume <0-100>` and `sound mute <on|off>`; the
  `sound` report shows `vol=`/`mute=`.
- **EL0 seam** — ADR 0007 slots 44/45 (`sys_audio_volume` /
  `sys_audio_mute`), `implemented_count` 44 → 46, ui.zig wrappers, and
  CHIME.BIN calling both (vol=50, unmuted) before its first blip — the
  seam proven live in the composition session.

## Verification

- Class A: fmt, all unit tests (virtio_snd 20 incl. the gain math + the
  unarmed setters, syscall 331 incl. the slot 44/45 marshaling test,
  monitor 432 incl. the sound subcommand test), byte-identical transcript
  (the `sound` help row changed in shell.zig + the fixture), build/image,
  coordination, indexes refreshed.
- Class B: `verify-live-sound-control.sh` **PASS 1/1 on VZ** — evidence
  `artifacts/live-sound-control-*`:
  - `sound volume 30` → report `sound: vol=30 mute=0`;
  - `sound mute on` → `beep 440 200` drains EXACTLY
    (`submitted=76800 drained=76800 frames=9600 pcm_status=0x8000`) —
    mute zeroes samples, the stream keeps flowing;
  - `sound mute off` → `beep 660 150` drains 57600 B exactly;
  - CHIME.BIN calls slots 44/45 (`chime: vol=50 mute=0`) and the post-app
    report shows `sound: vol=50 mute=0` — the syscall MUTATED kernel
    state; `syscalls` reports `implemented=46` with `44 sys_audio_volume
    calls=1` / `45 sys_audio_mute calls=1` / `43 sys_audio_play calls=30`;
  - A1/A2/A3/A4 gates all re-ran green (the CHIME.BIN change + the
    `implemented=44` → 46 pins across the nine live gates).
