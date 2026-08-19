---
title: Roadmap & status
status: published
tags: [roadmap, status]
---

# Roadmap & status

This page summarizes the milestone plan. The repository's
[`docs/status.md`](https://github.com/drawmeanelephant/DipshitOS/blob/main/docs/status.md)
is the canonical, always-current source; this is the readable summary.

## Shipped

| Milestone | What landed |
|-----------|-------------|
| 0–2 | Boot pipeline, kernel handoff, `ExitBootServices`, identity-map MMU, polled serial console |
| 1.5 | The interactive `dipshit>` monitor: shell, filesystem, reboot/shutdown |
| 3 | Allocator, GIC + timer, scheduler, EL0 + syscalls, uaccess, address spaces, exec |
| 4 | Entropy/ChaCha20 + ASLR, general filesystem, process registry, IPC, wait, kill, scale |
| 5 | Networking N1–N11: net TX/RX, ARP, IPv4/ICMP, UDP, the UDP syscall seam, NAT, DHCP, DHCP renew, TCP, TCP retransmission |
| 6 | Graphics G1–G6: framebuffer, text, Road Pops, Driving Award, the draw/window syscall seam |
| 7 | Input I1–I3: XHCI transport, USB enumeration + HID, the event FIFO + keycode decode |
| 8 | Usability U0–U8: ADR 0008 HIG, grouped `help`, line editing + history, the one error contract, window chrome (focus rings + title bars), `welcome`/`about`/`motd`, `sysinfo`, persistent settings on the DATA partition |
| 9 | Events E0–E6: per-process event queues, keyboard/pointer/window events to focused EL0 apps, `sys_poll_event`/`sys_wait_event` (slots 21/22), `KEYTEST.BIN` |
| 10 | Files & storage F0–F4: ADR 0010, per-process file table, `/esp/` + `/data/` routing, file syscalls (slots 23–27), `SAVETEXT.BIN`/`TYPE.BIN`/`DIR.BIN` |
| 11 | Desktop platform A0–A5: ADR 0011, the zero-heap `ui.zig` toolkit, `CALC.BIN`/`NOTEPAD.BIN`/`TOP.BIN`, the `DESKTOP.BIN` launcher, `sys_exec`/`sys_kill` (slots 28/29) |
| 12 | Network apps N0–N3: TCP syscall seam (slots 30–33), RFC 1035 DNS, `TCP.BIN`/`FETCH.BIN`/`CHAT.BIN` |
| 13 | Files & applications B1–B4: mutating filesystem seam (B1, slots 34–37), `APPS.TXT` identity manifest (B2), the `FILE.BIN` graphical data browser (B3), and manifest-driven desktop composition (B4) |
| 14 | Shared user services S1–S4: the clipboard (slots 38–39), app timers (slots 40–41), the NOTEPAD composition capstone, and security/isolation hardening (the TCP owner fix + the hostile-EL0 gate) |
| 15 | Audio A1–A4: virtio-snd transport, PCM playback + `beep`, the EL0 audio seam (slots 42–45), `JINGLE.BIN`, the boot chime, and `CHIME.BIN` |

Every milestone through fifteen is **done** and live-gated; milestone
sixteen is the active stream.

## Current

**Milestone sixteen — the kernel grows up (internals consolidation)** is the
active milestone. It is the internals-consolidation milestone the M11–M15
apps now force — the M15-era claims recorded the pressure directly: a 33 KB
`JINGLE.BIN` would not load (the 16 KiB exec bound), a global BSS buffer
faulted on write from EL0 (the W^X single-segment layout), and the fixed
pools refused a fifth concurrent user program. Its cards:

- ⬜ **C1 — multi-segment user image.** Real writable globals and a lifted
  16 KiB load bound (wishlist 15).
- ⬜ **C2 — guard pages + per-segment permissions.** The wishlist-14 address
  space depth.
- ⬜ **C3 — measured pools.** The fixed pools grown only where the demo apps
  actually hurt (wishlist 13).
- ⬜ **C4 — composition capstone.** All three proven in one session.

Issues #190–#193 are filed (one per card, the M14 way); the march deck is
`docs/march-m16.md`.

Honest-bound edges that remain planned regardless of milestone:

- **The balloon device** — the last unattached virtio surface (low priority
  while the guest is a fixed 256 MiB).
- **Networking edges** — TCP server/listen and any routing beyond the NAT
  gateway; RTO stays fixed (no adaptive estimation).
- **Deeper filesystem semantics** — wishlist 17 stays deferred: M13's B1
  already shipped delete/rename/truncate/free and no app has produced new
  pressure.
- **The M8 U4 pointer-focus live seam** — the window manager's pointer-driven
  focus is guest-complete and host-tested, but the live proof rides a
  real-mouse class-C gate (`verify-pointer-manual`) and a class-B CG gate
  (`verify-live-pointer-cg`) that self-gates on Accessibility trust.

<Aside kind="note">

**PLANNED.** C1–C4 are defined with gates in `docs/march-m16.md`; nothing is
shipped until it has a gate. The tracker, not this page, is the live per-card
status.

</Aside>

## How to read the status

- **Shipped** = landed, merged, and gated.
- **In progress** = claimed on a branch, not yet merged.
- **Planned** = sketched, with no gate yet.

The repository distinguishes these strictly: claims are only flipped to
observed when the matching live gate passes, and the [[evidence]] page
explains the classification.

<Aside kind="warning">

**LIMITATION.** Do not read the repository's `docs/` planning prompts as
shipped features. The planning tree is an engineering warehouse; this site is
the public index of what actually landed.

</Aside>
