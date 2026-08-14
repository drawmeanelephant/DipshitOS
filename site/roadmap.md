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

Every milestone through seven is **done** and live-gated.

## Current

There is no milestone eight defined yet. The open work is the honest-bound
list at the edges of what shipped:

- **Pointer-driven focus** — pointer reports are parsed, but nothing clicks a
  window; focus is keyboard/monitor-driven.
- **A focus syscall** — windows can hide/show, but focus is not settable from
  EL0.
- **The balloon device** — the last unattached virtio surface (low priority
  while the guest is a fixed 256 MiB).
- **Networking edges** — TCP server/listen, DNS, adaptive RTO.

<Aside kind="note">

**PLANNED.** The next milestone is expected to complete the window manager:
pointer-driven focus, a focus syscall, and a clickable desktop. That is a
direction, not a commitment — nothing here is shipped until it has a gate.

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
