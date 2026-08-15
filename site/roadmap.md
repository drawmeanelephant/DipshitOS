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

**Milestone eight — usability & human interface (ADR 0008)** is active. Its
normative contract pins one command grammar + grouped `help`, one prompt and
editing model, one `error:`/`usage:` shape, a visible-focus window model, and
an `about`/`welcome`/`sysinfo`/settings support surface. Landed so far:

- **U0** — the human-interface guidelines themselves (ADR 0008).
- **U1** — grouped `help`, `help <cmd>`, and `help <topic>`.
- **U2** — shell line editing & history (cursor movement, Ctrl chords, tab
  completion) over the USB keyboard path.
- **U3** — the one `usage:`/`error:`/`unknown command` error contract,
  byte-exact in the transcript and fuzzed for panics.

Defined next (the U4–U8 ladder, per `docs/march-m8.md`): pointer-driven focus
+ cursor, window title bars/focus rings, the first-boot tour, `sysinfo`, and
persistent settings on the DATA partition.

Honest-bound edges that remain planned regardless of milestone:

- **The balloon device** — the last unattached virtio surface (low priority
  while the guest is a fixed 256 MiB).
- **Networking edges** — TCP server/listen, DNS, adaptive RTO.

<Aside kind="note">

**PLANNED.** U4–U8 are defined with gates in `docs/march-m8.md`; nothing is
shipped until it has a gate. The tracker, not this page, is the live
per-card status.

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
