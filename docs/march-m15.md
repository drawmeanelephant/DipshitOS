# Milestone fifteen march — audio (living tracker)

## Where we are

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds milestone-
> fifteen's per-card detail and collision-free agent split, following the
> [`march-m14.md`](march-m14.md) pattern.
> A card's row flips to ✅ only with real observed class-B evidence, never
> code-complete alone.

## Why audio (wishlist item 18)

Every "bridge the maintainer would be most disappointed to see omitted" is
now shipped — EL0 application events (M9), userland filesystem access
(M10), consumer GUI apps + a launcher (M11), and the shared-services arc
(M14). The next **concrete, non-conditional** wishlist item is **audio**
(item 18, "DipshitOS becomes a computer"): another real device/service
pipeline exactly like the virtio-net work, but for sound. The host side
exists — Apple's Virtualization.framework has shipped virtio-snd
(`VZVirtioSoundDeviceConfiguration` with PCM stream configs) since macOS
13 — so this is greenfield *guest* work, not a host capability gap.

Deferred (wishlist order, still on the map as M16+ candidates): item 13
resource-model cleanup ("keep them bounded until real apps expose actual
pain" — the pools are still comfortably bounded), items 14/15 richer VM +
executable-format ("only when applications force it" — the DSK1 apps are
still small), item 17 better filesystem semantics (pressure-driven; B1
already added delete/rename/truncate/free). Distant mountains (item 20:
SMP, 3D, dynamic linking, POSIX) stay visible, not climbed.

**Meta-requirement (roadmap):** every infrastructure card names the small
experience that consumes it, and the milestone ends in a composition test
a human can perceive. Audio's composition test is audible — the strongest
"DipshitOS is a computer" signal yet.

## The cards, in order

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| A1 | **virtio-snd transport.** Host: `VMRunner` attaches `VZVirtioSoundDeviceConfiguration` (one output PCM stream) behind a new flag-gated `--sound` mode — the default VM stays byte-identical, the `--net`/`--input` precedent. Guest: discover the virtio-snd PCI device (virtio device type 25; expected non-transitional DID `0x1059` = `0x1040+25`, the same convention as net `0x1041` / entropy `0x1044` / gpu `0x1050` — **pinned at claim time**), negotiate features (jacks, PCM, chmap), drive the control queue, and arm the stream. Live gate: `verify-live-sound-device.sh` — the guest's own `sound` report (`sound: device armed`, jack/PCM counts). Consuming experience: the `sound` monitor command (the `usb`/`net` pattern). | ⬜ | — | Wishlist 18. |
| A2 | **PCM playback + the shared sound buffer.** A bounded PCM ring (fixed BSS, zero heap — the M14 constraint) fed by a `beep <freq> <ms>` (or `tone`) monitor command that synthesizes a sine wave; the driver submits buffers to the device and VZ routes them to the Mac's output. Live gate: `verify-live-sound-playback.sh` — N frames submitted/drained (the guest's own accounting, the single-pending-report honesty the input card established). Consuming experience: a beep the human hears. | ⬜ | — | Wishlist 18. |
| A3 | **EL0 audio seam + a melody app.** ADR 0007 slots 42+ (`sys_audio_play` / `sys_audio_info`, `implemented_count` 42→44): `copy_in` samples into the shared PCM ring — the shared-service model M14's clipboard/timers established (machine-global buffer, per-process safety via the S4 ownership discipline). A new userland image `JINGLE.BIN` plays a recognizable melody. Live gate: `verify-live-sound-app.sh`. Consuming experience: the melody from EL0. | ⬜ | — | Wishlist 18. |
| A4 | **Composition capstone.** Sound joins the desktop: a boot chime, and a sound fires on an existing event (window focus, a clipboard copy, or a timer tick) — audio composes with the M14 shared services. Live gate: `verify-live-m15-composition.sh` — one session proves device + playback + EL0 + the hearable composition, human-verified on VZ. | ⬜ | — | Depends on A1+A2+A3. |

## Notes

- Zero heap allocation stays a hard constraint for every new kernel
  resource (fixed BSS tables only) — the M14 rule carried forward.
- The host device is flag-gated (`--sound`); without it
  `config.soundDevices` stays empty and every existing gate stays
  byte-identical (the `--net`/`--input` precedent).
- ADR 0007 slots 42+ are the next free range (M14 ended at 41,
  `implemented_count` 42). Each ABI addition is a one-line ADR amendment
  with the exact error-code contract, per the existing pattern.
- Wishlist mapping: item 18 (audio). Items 13/14/15/17 remain M16+
  candidates; item 20 stays a distant mountain.
- Known unrelated threads: U4's pointer proof is class-C-only (issue
  #151, closed as a documented limitation); the synthesized-keyboard seam
  is session-dependent (claim 8844 diagnostic).
- When the milestone is picked up, file issues #A1–#A4 the way M14 filed
  #175–#178, and claim each card before writing code.

## Next action

Approve the theme (or substitute), then start A1 — the host `--sound`
mode + virtio-snd device discovery, with the device DID pinned by direct
observation before any playback code.
