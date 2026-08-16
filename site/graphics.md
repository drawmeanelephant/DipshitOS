---
title: Graphics
parent: capabilities
status: published
tags: [capabilities, graphics]
---

# Graphics

The machine boots to a graphical interface: a framebuffer, a text renderer, a
graphical terminal, and a window manager with a compositor.

## The four layers

1. **virtio-gpu framebuffer** (`virtio_gpu.zig`) — the spec 2D path:
   GET_DISPLAY_INFO → CREATE_2D (B8G8R8X8) → ATTACH_BACKING → SET_SCANOUT →
   TRANSFER → FLUSH, into a 4K-aligned BSS framebuffer at 1280×720.
2. **Text** (`text.zig`) — a built-in 8×8 bitmap font, putc/puts, cursor, line
   wrap, and a bounded 128-line scrollback ring.
3. **Road Pops** (`road_pops.zig`) — a tee console: every byte still reaches
   serial first (the shared evidence seam), and the same banner, prompt, and
   replies are painted on screen, one present per output batch.
4. **Driving Award** (`driving_award.zig`) — a bounded window registry,
   z-order, focus, topmost hit-testing, and a dirty-rect compositor that
   repaints from the lowest dirty window up.

## Driving Award

The window manager makes Road Pops window 0 (the full-screen terminal) and a
1 Hz clock overlay window 1 (amber title bar, navy body). `win` reports the
registry; `win focus`/`win raise`/`win hit` manipulate it, and the keyboard
read path is gated on terminal focus.

The compositor paints one transfer + flush per dirty batch. Windows are
fixed-BSS back-buffers; the fixed terminal and clock are kernel-owned.

## Windows from EL0

The [[userspace|syscall seam]] exposes windows to user programs through slots
12–20: open, fill, present, close, move, raise, get, query, and set_visible —
all owner-restricted, with per-process ownership and auto-close on exit.

## A desktop on top

Milestone eleven built the zero-heap `ui.zig` micro-widget toolkit (buttons,
text inputs, list views — pure static BSS, no allocation) on top of the
window seam, and four applications on top of that: `CALC.BIN` (calculator),
`NOTEPAD.BIN` (editor), `TOP.BIN` (process monitor with click-to-kill), and
the `DESKTOP.BIN` launcher — later joined by the `FILE.BIN` file browser
(milestone thirteen). Windows and clicks reach these apps as events through
milestone nine's per-process event queues (`sys_poll_event`/`sys_wait_event`).

<Aside kind="info">

**LIVE-GATED.** The pixel gates decode the actual framebuffer captures against
the kernel's own font table. The mirror-tripwire gate (`verify-live-glyphs`)
decodes both the terminal and the clock overlay in both orientations, so a
mirrored-text regression fails mechanically. The window gates decode the
window's own content at its composited position.

</Aside>

<Aside kind="warning">

**LIMITATION.** Single display, 2D blits only, no accelerated/3D path.
Pointer events are routed to focused applications (milestone nine), and the
window chrome — title bars + focus rings — is live-gated, but the window
manager's own pointer-driven focus still lacks a live hardware proof: the
guest side is complete and host-tested, and the live seam is a real-mouse
class-C gate plus a class-B CG gate that self-gates on Accessibility trust.

</Aside>
