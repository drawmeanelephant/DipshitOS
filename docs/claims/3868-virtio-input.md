# Claim: Milestone six, card G4 — virtio keyboard + pointer input

- **Owner:** buffy (`freebuff/can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc`)
- **Prompt / plan:** `docs/march-m6.md` G4 row (no planning-first prompt doc exists yet —
  G4 is the next milestone-six rung after G1/G2/G3, sketched only). G1–G3 are
  ALL MERGED (claims 6053/3194/1574): the guest boots to a graphical Road Pops
  terminal on the virtio-gpu framebuffer, but INPUT still arrives only over the
  serial console (road_pops.zig notes "Input stays on serial until card G4").
  This card lands the FIRST screen-side input path.
- **Scope:** (1) DISCOVERY FIRST — the input device identity + event format are
  **[inferred] until observed** (the march-m6 G4 row hypothesizes a virtio-input
  device, spec DID 0x1052, exposed by the runner's
  `VZUSBKeyboardConfiguration` + `VZUSBScreenCoordinatePointingDeviceConfiguration`;
  a differing device — e.g. a USB XHCI controller with HID devices — is a
  claim-time finding recorded as the 6420/2665 corrections were). (2) runner:
  a flag-gated `--input` mode attaching the keyboard + pointing configs (OFF by
  default — the default VM stays byte-identical), plus a scripted host key-
  injection surface for the live gate. (3) guest `kernel/src/virtio_input.zig`:
  the virtio-input transport (discovery pre-exit, feature negotiation, the
  eventq/statusq, polled used-ring drain, the claim-6420 post-exit re-arm
  lesson), a bounded BSS event FIFO (the card-3d pattern), keycode → ASCII
  decode into the terminal's line editor, pointer motion/buttons. (4) `input`
  monitor command (device/DID/queues + FIFO occupancy + last events). (5) live
  gate `tools/verify-live-input.sh`: scripted host key events drive Road Pops
  end to end — the typed command is echoed/answered on the screen (and serial
  stays the evidence channel). (6) hardware-contract `[observed]` flips with
  saved logs only.
- **Depends on:** G1–G3 merged (virtio-gpu framebuffer + text + Road Pops tee);
  the virtio transport patterns are proven on this platform (claims
  0013/6420/2665/1373/6053).
- **Status:** ⛔ **finding recorded — card premise corrected (see Notes), scope handed back for re-scoping**

## Notes

**CLAIM-TIME FINDING (2026-08-13, decisive):** the march-m6 G4 hypothesis is
WRONG on this host. The runner's `VZUSBKeyboardConfiguration` +
`VZUSBScreenCoordinatePointingDeviceConfiguration` do **not** present a
virtio-input device (spec DID 0x1052). Observed on VZ: `--input` adds exactly
one PCI device — an **Apple XHCI USB host controller**
(`VID=0x106b DID=0x1a06 CLS=0x0c0330`, two MMIO BARs `0x50001000` +
`0x50000000`) — with the keyboard/pointer as **USB HID devices behind it**.
No 0x1052 device exists anywhere on the bus (0 matches across the boot).

The Virtualization.framework SDK confirms this structurally: the ONLY
keyboard/pointer configs are `VZUSBKeyboardConfiguration`,
`VZUSBScreenCoordinatePointingDeviceConfiguration` (both explicitly USB HID),
`VZMacKeyboardConfiguration`, and `VZPointingDeviceConfiguration`. There is
**no virtio-input device config** in the framework. (The only escape hatch is
`VZCustomVirtioDeviceConfiguration` — macOS 27+, host-implemented virtio
device — a completely different, much larger lift.)

**Consequence:** G4 as written (virtio-input transport + eventq/statusq +
keycode decode) is not implementable against this hardware. Screen-side input
requires a **USB XHCI host-controller driver + USB HID enumeration + boot-protocol
keyboard/pointer** stack in the guest — a substantially larger scope. The card
was therefore **split into milestone seven** (2026-08-13, same day):
**I1 XHCI host-controller transport** (MMIO + command/event rings + port
status, no HID) → **I2 USB enumeration + HID** (port reset, address
assignment, config descriptors, interrupt-IN endpoints, HID boot-protocol
parsing) → **I3 event FIFO + keycode decode** (bounded BSS FIFO feeding Road
Pops' line editor + pointer). The per-card tracker is
[`docs/march-m7.md`](../march-m7.md). This claim is therefore handed back as
a finding with the `--input` runner flag left in place (OFF by default, so
the default VM stays byte-identical; the flag is what makes the XHCI
controller observable). Evidence: `artifacts/g4-discovery/input-boot-serial.log`
vs `artifacts/g4-discovery/noboot-serial.log` (4 PCI devices without
`--input`, 5 with — the 5th is the XHCI controller).

## Original notes (superseded scope)

**Why this card:** Road Pops (G3) is a working graphical terminal, but nothing
drives it from the screen side — keystrokes still come from the serial console.
G4 is the input rung that makes the graphical terminal a real machine: a
virtio-input transport + event FIFO + keycode decode feeding the line editor.
G5 (Driving Award) depends on it (input lands in the focused window).

**Confirm at claim time (record whatever is observed):** the input device DID
(0x1052 expected per the march-m6 G4 hypothesis) and the VZ input event format
on this host; whether VZ resets the input device at ExitBootServices (the
gpu/blk/entropy reset, net does not — the input answer is OBSERVED, not
assumed); the eventq's used-buffer delivery shape. A differing device (USB
controller vs virtio-input) is a finding, recorded honestly.

**Verification:** class A first (fmt, unit tests, test-console + byte-identical
transcript, build/image/inspect, swift build, context, coordination ×2,
mmu-debt); then class B on VZ (the new `verify-live-input.sh`); then the docs
reconciliation (march-m6 G4 row, roadmap virtio surface + G4 card, status.md
milestone-six row + gate table, README, gate-inventory, hardware-contract
`[observed]` input flips with saved logs only), the claim flip, the log append,
and the PR per the repo template with real observed evidence only.
