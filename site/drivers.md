---
title: Device drivers
parent: architecture
status: published
tags: [architecture, drivers, virtio]
---

# Device drivers

The kernel drives hardware through two families: the **virtio** PCI surface and
one **memory-mapped USB controller**. Every driver below is observed against
the real host, and its device identity is recorded as observed, not assumed.

## The virtio surface

| Device (observed DID) | Driver | Status |
|-----------------------|--------|--------|
| Console (0x1043) | `virtio_console.zig` — queue 1 TX, queue 0 RX | done, live-gated |
| Block (0x1042) | `virtio_blk.zig` — modern virtio-blk, post-exit re-arm | done, live-gated |
| Entropy (0x1044) | `virtio_entropy.zig` + `csprng.zig` (ChaCha20) | done, live-gated |
| Network (0x1041) | `virtio_net.zig` — TX/RX + ARP/IPv4/UDP/TCP above it | done, live-gated |
| Graphics (0x1050) | `virtio_gpu.zig` — spec 2D path, B8G8R8X8 framebuffer | done, live-gated |
| Sound (0x1059) | `virtio_snd.zig` — control queue, PCM_INFO/SET_PARAMS/PREPARE/START/STOP/RELEASE, bounded playback | done, live-gated |
| Balloon | `VZMemoryBalloonDeviceConfiguration` | not started — low priority |

## USB: the XHCI controller

Input is the one non-virtio story. Virtualization.framework's keyboard +
pointing-device configs present as an **Apple XHCI USB host controller**
(`VID=0x106b DID=0x1a06`, two MMIO BARs) with the keyboard and pointer as USB
HID devices behind it — there is no virtio-input device in the framework.

`kernel/src/xhci.zig` maps the MMIO registers, drives the command and event
rings, enumerates both devices (Enable Slot → Address Device → descriptors →
Set Configuration → interrupt-IN armed), and parses HID boot-protocol reports.
The [[input]] page has the full story.

## What "observed" means here

The host's behavior is not taken on faith. Wherever a device reset question
existed, the answer was observed and pinned:

- The block and entropy devices **reset** at `ExitBootServices` (`st=00`).
- The network device does **not** reset (`st=0f`).
- The XHCI controller does **not** reset (pre-reset `USBSTS=0x9`/`USBCMD=0x0`).
- The graphics device **resets** (`st=00`).
- The sound device does **not** reset (`st=0f`, like net/gpu).

Those observations live in
[`docs/hardware-contract.md`](https://github.com/drawmeanelephant/DipshitOS/blob/main/docs/hardware-contract.md)
and drive the per-device post-exit re-arm logic.

<Aside kind="note">

**PLANNED.** The balloon device is the last unattached virtio surface. It is
explicitly low priority while the guest stays at a fixed 256 MiB with no
demand paging.

</Aside>
