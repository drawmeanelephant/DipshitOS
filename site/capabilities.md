---
title: Current capabilities
status: published
tags: [capabilities, overview]
---

# Current capabilities

What is actually landed and live-gated today — subsystem by subsystem. This is
generated from the repository's own status, not from a roadmap. Where a
capability is partial or hardware-specific, the page says so.

- [[networking|Networking]] — raw Ethernet up through ARP, IPv4/ICMP, UDP, DHCP, DNS, and a bounded TCP client, plus the TCP syscall seam.
- [[graphics|Graphics]] — the framebuffer, the Road Pops terminal, and the Driving Award window manager with a window syscall seam.
- [[input|Input]] — USB XHCI, HID enumeration, keyboard events, and pointer/click events routed to focused applications.
- [[storage|Storage & filesystem]] — FAT32 over virtio-blk, ESP + a second data partition, and a userland file syscall ABI.
- [[processes|Processes & IPC]] — concurrent EL0 programs, mailboxes, wait, kill, `sys_exec`/`sys_kill`.
- [[programs|User programs & demos]] — the 21 `.BIN` images exec'd from the disk, from seam proofs to the desktop apps.

## The headline capability: a real machine

Put together, a single boot proves the whole stack in sequence:

1. Firmware hands a UEFI app a machine; the kernel takes it over.
2. A serial `dipshit>` shell answers commands with deterministic replies.
3. The screen shows a working graphical terminal (**Road Pops**) composited by
   a window manager (**Driving Award**).
4. User programs run at EL0 as processes, with syscalls, IPC, and exit statuses.
5. The machine talks Ethernet — ARP, ICMP, UDP, DHCP, DNS, TCP — and types
   from a real USB keyboard.
6. A desktop launcher starts real applications — calculator, editor, process
   monitor, file browser — that paint windows, receive events, and talk to
   the network.

<Aside kind="tip">

**LIVE-GATED.** The strongest single piece of evidence is the aggregate
`verify-vz` sweep: a class B run that boots the VM and re-checks the shared
seam across every subsystem. See [[live-gates]].

</Aside>

## Not there yet

- SMP, multi-display, accelerated/3D graphics, and the balloon device.
- Filesystem *mutation* from userland — the M13 B1 card
  (`sys_file_delete`/`rename`/`truncate`/`free`, ADR 0007 slots 34–37).
- TCP server/listen and any routing beyond the NAT gateway.
- The window manager's pointer-driven focus is guest-complete but its live
  proof is a manual/CG-gated seam; DNS is shipped, but the resolver is bounded
  (A records only, no caching).

Those are honest gaps, not secrets — the [[roadmap]] page and the repository's
`docs/status.md` track them.
