# Milestone six march — graphics: Driving Award + Road Pops (living tracker)

## Where we are

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds only
> milestone-six's per-card detail and collision-free agent split, following
> the [`march-m3.md`](march-m3.md) / [`march-m4.md`](march-m4.md) /
> [`march-m5.md`](march-m5.md) pattern. It was created 2026-08-12 as the
> roadmap sketch for the last open virtio surface row (Graphics); a card's
> row flips to ✅ only with real observed class-B evidence, never
> code-complete alone.

Milestone six is the graphics milestone: the machine boots to a
**graphical interface**. The boot terminal — the M1.5 "Dipshit Monitor"
over the virtio serial console — becomes **Road Pops**, a graphical
terminal window, running under **Driving Award**, the window manager. The
rungs of the ladder, in order: **G1 virtio-gpu transport + framebuffer** →
G2 framebuffer text → G3 Road Pops (the boot terminal goes graphical) → G4
virtio keyboard/pointer input → G5 Driving Award (the window manager) → G6
a draw/window syscall seam (sketched only). The full milestone sketch with
non-goals is in [`docs/roadmap.md`](roadmap.md).

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| G1 | **Virtio-gpu transport + framebuffer.** `kernel/src/virtio_gpu.zig`: discover the gpu device (spec DID 0x1050 — **[inferred]** until observed on VZ), negotiate features, set up the scanout + resources, and give the kernel a writable framebuffer (virtio-gpu 2D command path / resource mapping — the exposure mode is a claim-time observation). Post-exit re-arm per the claim-6420 lesson (does VZ reset the gpu device at ExitBootServices? — observed, not assumed). `screen` monitor command + a solid-fill test. The runner gains a `--display` mode (the gpu device always attached; `--screenshot` stays the evidence path). | ✅ done (claim 6053, branch `agent/buffy/m6-gpu`) | [Claim 6053](claims/6053-gpu.md); prompt: [m6-gpu-prompt](m6-gpu-prompt.md) | **Landed 2026-08-12 on `agent/buffy/m6-gpu`: the FIRST NON-BLANK GUEST FRAMEBUFFER is live on VZ.** Runner `--display`/`--screenshot` attach `VZVirtioGraphicsDeviceConfiguration` (1280×720 scanout; OFF by default — the default VM stays byte-identical); `kernel/src/virtio_gpu.zig` drives the modern virtio-pci gpu (DID 0x1050, class 0x038000, dev 7), the control queue (queue 0, split rings, size 4) + cursor queue (queue 1 — armed for device compatibility), VER1-only accepted (the device offers RING_PACKED\|RING_EVENT_IDX\|RING_INDIRECT_DESC\|VERSION_1), post-exit re-arm (**VZ RESETS the gpu at ExitBootServices — `pre-rearm st=00` observed, like blk/entropy, unlike net**), and the spec 2D path GET_DISPLAY_INFO → CREATE_2D (B8G8R8X8) → ATTACH_BACKING (the 4K-aligned BSS framebuffer) → SET_SCANOUT → TRANSFER_TO_HOST_2D → RESOURCE_FLUSH. **Claim-time findings (recorded in `docs/hardware-contract.md` + claim 6053):** the 1.2 `display_one` (24-B pmodes — the pre-1.2 20-B shape wedged the queue with DEVICE_NEEDS_RESET 0x40); the tail descriptor's `next` must be 0, not 0xffff (VZ walks it); the command + framebuffer caches MUST be cleaned before the kick/transfer (an MMU-on kernel is not the reference drivers' caches-off world); the scanout composites with ALPHA — an X/A byte of 0 renders fully transparent (the final black-screen cause; the fill now writes X=0xff); the device config layout is common@+0x0000 / ISR@+0x1000 / notify@+0x4000 / devcfg@+0x8000 (claim-0013's decoded layout). **Class-B gate `tools/verify-live-screen.sh` PASS 1/1**: the transport report (did/feat/scanout/status/rearm/setup/counters), the guest-side fill bytes (`screen peek` p1=0xff), and the DECODED capture — 14400/14400 sampled pixels are the fill green (0x00ff00 renders ~(117,251,76) through the color-managed pipeline). Full class A green (fmt, 277+ unit tests, byte-identical transcript, build/image/inspect, swift build, context, coordination, mmu-debt); the **35-gate `verify-vz` aggregate re-ran green** (proof the `--display` mode left the default VM byte-identical; evidence `artifacts/m6-gpu-vz-sweep.log`). |
| G2 | **Framebuffer text rendering.** `kernel/src/text.zig`: a built-in bitmap font (fixed BSS glyph data), putc/puts, cursor, line wrap, scrollback, `clear`; pure logic host-tested against a mock canvas. The kernel paints its banner + `dipshit>` prompt on the framebuffer. | ✅ **live 2026-08-12 (claim 3194)** — the machine boots to words on the screen: text.zig (the public-domain 8x8 bitmap font, ASCII 0x20–0x7e, BSS glyph table + 128-line bounded scrollback ring; pure renderer host-tested against an injectable mock canvas — 21 tests: golden glyphs, wrap, scroll, clear, bounds, cursor) paints the SAME banner + prompt the serial log carries over G1's framebuffer (fg 0x00ff00 on bg 0x101418), pushed through G1's transfer/flush unchanged; `text` / `text put <string>` / `text clear` monitor commands (registry 35→36); boot evidence `text: boot banner presented`; live gate [verify-live-text.sh](tools/../tools/verify-live-text.sh) **PASS 1/1** — the decoded capture shows GREEN GLYPHS over the dark background in the banner region (fg=0.255 bg=0.745 sampled) with the region below all background; the 36-gate `verify-vz` aggregate re-ran **36/36 PASS** (G1's screen gate updated: `cmds=8` — the banner's TRANSFER+FLUSH sits on top of the 6 setup commands, still errors=0 timeouts=0). | [m6-text-prompt](m6-text-prompt.md) |
| G3 | **Road Pops — the boot terminal goes graphical.** Re-target the M1.5 console (line editor, tokenizer, command registry, shell idle loop) to render into a framebuffer region instead of the serial pipe; the machine still boots to a terminal — now on the screen. Serial stays as the evidence/log channel (the transcript gates keep passing). | ✅ **live 2026-08-12 (claim 1574)** — the boot terminal is ON THE SCREEN: `kernel/src/road_pops.zig` is a TEE console — every byte still reaches serial FIRST (the shared seam; the transcript gates keep passing byte-identical) AND G2's text layer paints the same banner + prompt + every reply on the framebuffer, drained ONE full-frame present per output batch by the shell idle loop. The G2 one-shot boot paint is replaced by the tee rendering the shell's OWN banner (its first present emits the G2 `text: boot banner presented` evidence). **Claim-time fix recorded**: a `Target` struct literal with all-constant fields was folded into `.rodata`, whose `&fn` entries hold LINK-TIME absolute addresses (claim-0015 redux — the tee's first write jumped to the link-time `rp_text_put_bytes` and faulted); the Target is now built in RAM like `ensure_vtable`. `roadpops` monitor command (registry 36→37: armed/dirty/presents). Live gate [verify-live-roadpops.sh](tools/../tools/verify-live-roadpops.sh) **PASS 1/1** — the decoded capture shows the banner (fg=0.255) AND the live session glyphs BELOW it (fg=0.124 — echoed commands + replies rendered; the screen is a working terminal, not a splash). G1/G2 gates updated honestly for the Road Pops reality (the terminal renders over the raw fill — G1's pixel phase now asserts the non-blank terminal frame with the fill proven guest-side; the `text` report's cur/lines are session-dynamic). The **37-gate `verify-vz` aggregate re-ran 37/37 PASS** (`artifacts/m6-roadpops-vz-sweep.log`) — the default VM stayed byte-identical. |
| G4 | **Input: virtio keyboard + pointer.** virtio-input transport (spec DID 0x1052; VZ exposes it via `VZUSBKeyboardConfiguration` + `VZUSBScreenCoordinatePointingDeviceConfiguration` — **[inferred]** until observed), a bounded event FIFO (pure BSS, the card-3d pattern), keycode decode into the terminal's line editor, pointer motion/buttons. `input` monitor command; the runner gains a scripted host key-injection mode. | ⬜ not started | — | Gate: live keystrokes drive Road Pops end to end (scripted host key events, asserted replies). Claim-time observation for the hardware contract: the input devices' DIDs and the event format on VZ. |
| G5 | **Driving Award — the window manager.** `kernel/src/driving_award.zig`: a bounded window registry (fixed BSS), z-order, focus, hit-testing, dirty-rect redraw, and a compositor blitting window buffers into the framebuffer. Road Pops is the FIRST window under Driving Award; a second demo window (mascot / memory-map viewer / clock) proves multiple windows with distinct contents + focus. `win` monitor command; host tests pin the hit-test and redraw contracts. | ⬜ not started | — | Gate: screenshots show two overlapping windows with the right z-order; input lands in the focused window. |
| G6 | **A draw/window syscall seam for user programs** (sketched only). The N6 pattern: bounded `sys_*` slots (ADR 0007 amendment) so an EL0 user program can open a window and render into it; a user demo program proves EL0 graphics. | ⬜ not started | — | Depends on G5's window surface. The ADR 0007 amendment is the card's ONE ABI change, like every follow-on before it. |

## Agent split / collision rules

- **G1** (future claim): owns `host/vm-runner/Sources/VMRunner/main.swift`
  (the `--display` mode), `kernel/src/virtio_gpu.zig`, the `screen`
  monitor command, the hardware-contract entries for the gpu device
  (DID / reset-at-EBS / framebuffer exposure — all claim-time
  observations), and `tools/verify-live-screen.sh`. No syscall numbering
  (ADR 0007 frozen), no heap, no scheduler/process changes.
- **G2** (future claim): owns `kernel/src/text.zig` (font + raster), the
  mock-canvas host tests, the banner-on-framebuffer wiring, and the class
  A glyph gate. Renders into G1's framebuffer only.
- **G3** (future claim): owns the console re-target (line editor + command
  registry → framebuffer region), the Road Pops session loop, and the
  class B screenshot-transcript gate. Serial stays untouched as the
  evidence channel.
- **G4** (future claim): owns the virtio-input transport (DID 0x1052
  observation), the bounded event FIFO, the keymap, the `input` command,
  the runner's host key-injection mode, and `tools/verify-live-input.sh`.
- **G5** (future claim): owns `kernel/src/driving_award.zig` (window
  registry, z-order, focus, hit-testing, dirty-rect compositor), the
  second demo window, the `win` command, and the class B multi-window
  screenshot gate.
- **G6+ (future cards)**: each later card claims on merged main per the
  repo workflow and owns its gate script; the G5 window surface is what
  G6 builds on.
