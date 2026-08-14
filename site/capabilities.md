---
title: Current capabilities
status: published
tags: [capabilities, overview]
---

# Current capabilities

What is actually landed and live-gated today — subsystem by subsystem. This is
generated from the repository's own status, not from a roadmap. Where a
capability is partial or hardware-specific, the page says so.

- [[networking|Networking]] — raw Ethernet up through ARP, IPv4/ICMP, UDP, DHCP, and a bounded TCP client.
- [[graphics|Graphics]] — the framebuffer, the Road Pops terminal, and the Driving Award window manager.
- [[input|Input]] — USB XHCI, HID enumeration, and keyboard events reaching the terminal.
- [[storage|Storage & filesystem]] — FAT32 over virtio-blk, ESP + a second data partition.
- [[processes|Processes & IPC]] — concurrent EL0 programs, mailboxes, wait, kill.
- [[programs|User programs & demos]] — the `.BIN` images exec'd from the disk.

## The headline capability: a real machine

Put together, a single boot proves the whole stack in sequence:

1. Firmware hands a UEFI app a machine; the kernel takes it over.
2. A serial `dipshit>` shell answers commands with deterministic replies.
3. The screen shows a working graphical terminal (**Road Pops**) composited by
   a window manager (**Driving Award**).
4. User programs run at EL0 as processes, with syscalls, IPC, and exit statuses.
5. The machine talks Ethernet — ARP, ICMP, UDP, DHCP, TCP — and types from a
   real USB keyboard.

<Aside kind="tip">

**LIVE-GATED.** The strongest single piece of evidence is the aggregate
`verify-vz` sweep: a class B run that boots the VM and re-checks the shared
seam across every subsystem. See [[live-gates]].

</Aside>

## Not there yet

- SMP, multi-display, accelerated/3D graphics, and the balloon device.
- A pointer that actually clicks windows (motion is parsed; focus is still
  keyboard/monitor-driven).
- TCP server/listen, DNS, and any routing beyond the NAT gateway.

Those are honest gaps, not secrets — the [[roadmap]] page and the repository's
`docs/status.md` track them.
