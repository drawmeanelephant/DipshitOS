---
title: Input
parent: capabilities
status: published
tags: [capabilities, input, usb]
---

# Input

Screen-side input is a real USB stack, because Virtualization.framework has no
virtio-input device. The keyboard and pointing device appear behind an **Apple
XHCI USB host controller**, so DipshitOS enumerates them itself.

## The three rungs

1. **XHCI transport** — map the controller's two MMIO BARs, parse the register
   map, set up the command + event rings, drive a NO-OP command to completion,
   and read port status.
2. **USB enumeration + HID** — port reset, Enable Slot, Address Device, config
   descriptors over the control endpoint, Set Configuration, interrupt-IN
   armed, and HID boot-protocol parsing.
3. **Event FIFO + keycode decode** — a bounded BSS FIFO decodes interrupt-IN
   reports into ASCII and feeds the Road Pops line editor.

## What was observed

- The controller is `VID=0x106b DID=0x1a06` (Apple XHCI), two MMIO BARs, 16
  slots / 32 interrupts / 16 ports.
- Ports 9 and 10 are the two attached HID devices.
- The **keyboard** (port 9) enumerates as VID 0x05ac PID 0x8105, boot
  protocol, 8-byte reports.
- The **pointer** (port 10) is VID 0x05ac PID 0x8106, an **absolute** pointer
  (not a boot mouse), 10-byte reports.
- The host delivers roughly one interrupt report per present cadence, so the
  scripted key surface types slowly; single-TRB arming re-armed per completion
  is the correct shape.

## What it proves

The live gate (`verify-live-input`) scripts a real key sequence through the
host — VZ has no programmatic keyboard API, so the launcher synthesizes one
NSEvent per key — and asserts the guest's own `input` report shows the typed
command ran end to end (`events=6`, Enter decoded, `dropped=0`).

<Aside kind="info">

**LIVE-GATED.** `verify-live-xhci`, `verify-live-usb`, and `verify-live-input`
cover the transport, the enumeration, and the end-to-end keystroke path,
respectively.

</Aside>

<Aside kind="warning">

**LIMITATION.** Boot-protocol HID only (no full report-descriptor parser), the
two known devices only, no hubs, and no pointer *consumption* yet — pointer
reports are parsed and recorded, but nothing clicks a window.

</Aside>
