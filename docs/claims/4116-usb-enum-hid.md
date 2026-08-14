# Claim: Milestone seven, card I2 — USB enumeration + HID

- **Owner:** buffy (`freebuff/can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc`)
- **Prompt / plan:** `docs/march-m7.md` I2 row — the second milestone-seven rung,
  on top of the I1 XHCI transport (claim 4272).
- **Scope:** enumerate the two USB HID devices (keyboard + pointing) that I1
  observed behind the Apple XHCI controller (ports 9 + 10): port reset →
  Enable Slot → Address Device → read the device + config descriptors over
  the default control endpoint (Setup/Data/Status transfer TRBs) → select
  configuration 1 → arm the interrupt-IN endpoint, and parse the HID
  boot-protocol reports (8-byte keyboard report; absolute-coordinate pointer
  report — shapes observed byte-exact at claim time). `usb` gains `usb
  devices` (enumerated table: address/VID/PID/class + descriptor summary) and
  `usb report` (last raw report bytes + decode). Honest bounds: boot protocol
  only (no full HID report-descriptor parser), the two known devices, no
  hubs/mass-storage/isochronous; interrupt-IN drained POLLED (the I1/claim-
  6076 discipline — the XHCI event IRQ stays observed, not assumed).
- **Depends on:** I1 (claim 4272, merged on this branch) — the DCBAA/device
  contexts/transfer rings are added to the I1-owned `kernel/src/xhci.zig`
  (or a sibling `kernel/src/usb.zig` for the HID parse — per the agent-split,
  the XHCI transport stays I1-owned; I2 adds the enumeration + transfer
  paths).
- **Status:** ✅ done 2026-08-13 — live-gated on VZ (`verify-live-usb.sh` PASS 1/1, 11/11 assertions); both USB HID devices enumerate end to end and a synthesized host keyDown produced the observed HID report

## Notes

**Why this card:** I1 proved the controller's register map + command/event
ring machinery (NO-OP CC=1) and read port status — ports 9 and 10 report
connected (CCS=1), the two attached HID devices. I2 makes those devices
actually speak: enumerate them and receive a real keyboard/pointer report.

**Key input question (recorded at claim time):** VZ exposes NO programmatic
keyboard-injection API — `VZUSBKeyboardConfiguration` is only driven by a
`VZVirtualMachineView` forwarding the HOST's key/mouse events (SDK header
verified). The runner already creates a `VZVirtualMachineView` window under
`--display`. I2 adds the MINIMAL injection seam needed for its gate (a single
synthesized `keyDown` NSEvent dispatched to the view → one HID report); the
full scripted key-sequence surface that types into Road Pops stays I3.

**Confirm at claim time (record whatever is observed):** the per-port device
speed (PORTSC PS field after reset), the actual VID/PID/class of the two
devices, the device-descriptor bytes (bMaxPacketSize0, bNumConfigurations),
the config + endpoint descriptors (the interrupt-IN endpoint number +
bInterval + wMaxPacketSize), the HID report-descriptor lengths, and the raw
HID boot-protocol report bytes a key event produces (modifier byte + keycode;
pointer button/absolute-coordinate report shape). A differing device or a
stuck command is a finding, recorded honestly.

**Verification:** class A first (fmt, unit tests, test-console + byte-identical
transcript, build/image/inspect, swift build, context, coordination ×2,
mmu-debt); then class B on VZ (the new `verify-live-usb.sh` riding `--input`
+ `--display`); then the docs reconciliation (march-m7 I2 row, roadmap,
status.md, gate-inventory, hardware-contract `[observed]` HID flips with saved
logs), the justfile `verify-vz` entry (39→40), the claim flip, the log append,
and the PR per the repo template with real observed evidence only.

## Claim-time observations (recorded, never assumed)

- **Port speed:** both devices come up FULL speed (PORTSC PS=1 after reset).
- **Keyboard (port 9, slot 1):** VID `0x05ac` (Apple) PID `0x8105`,
  `bDeviceClass` 0 (class lives in the interface descriptor), HID
  boot-protocol KEYBOARD (`bInterfaceProtocol` 1), interrupt-IN EP1
  `maxpkt=8`, `bInterval=8`, `Set_Protocol(boot)` ACCEPTED (`boot=1`).
- **Pointing device (port 10, slot 2):** VID `0x05ac` PID `0x8106`,
  `bInterfaceProtocol` 0 — **NOT** a boot-protocol mouse (the absolute
  screen-coordinate pointer) — interrupt-IN EP1 `maxpkt=10`, `bInterval=8`,
  `Set_Protocol(boot)` **REFUSED** (`boot=0`; recorded honestly — the raw
  report is the ground truth).
- **Report shape (observed byte-exact):** a synthesized host keyDown (macOS
  keyCode 0 = 'a') produces the 8-byte keyboard boot report
  `00 00 04 00 00 00 00 00` — modifier byte 0, HID usage `0x04` in byte 2.
- **The injection seam:** VZ has NO programmatic keyboard API (SDK-verified
  before the seam was written) — the runner dispatches ONE synthesized
  `NSEvent` keyDown into its `VZVirtualMachineView` via the new minimal
  `--input-key <mac-keycode>` + `--input-key-after <marker>` flags (OFF
  without `--input`). The full scripted key-sequence surface that types
  into Road Pops stays I3.
- **Shared-control-ring fix (the claim-time bug):** the first pass shared
  one EP0 control transfer ring across both slots; the second device's
  descriptor read failed because the two slots' dequeue pointers diverged.
  Per-slot control rings fixed it.

Evidence: `artifacts/live-usb-*` (gate output + serial) and the discovery
boots `artifacts/usb-discovery-*`.

