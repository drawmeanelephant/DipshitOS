# Milestone forty-three march — device depth: USB beyond HID (living tracker)

> [`docs/status.md`](status.md) is the canonical milestone-level source. This
> file holds M43's per-card detail, order, and gate notes. A card's row flips
> to ✅ only with real observed evidence.
> Umbrella issue: **#1031** (M43: Device depth — USB beyond HID).
> GitHub milestone: **30 — M43 — Device depth: USB beyond HID**.

## Where we are

M43 was scoped 2026-09-06 (claim #1038) with the tracker at zero open issues —
the first milestone planned from a fully-green board since M40. The theme was
chosen by the user from the post-arc5 roadmap's "distant mountains"
([`roadmap-post-arc5.md`](roadmap-post-arc5.md), "What this roadmap does NOT
cover"): most of that list has since been climbed (SMP → M28, VM depth → M29,
dynamic linking → M30/M31, browser-class HTTP → `HTTPD.BIN`, claim 0750), and
**USB-everything** is the last one that needs no new host capability — the
mass-storage device class is already attachable
(`VZUSBMassStorageDeviceConfiguration`, macOS 13.0+; existence verified at
scoping time against Apple's documentation).

What exists today (the honest starting line):

- **`kernel/src/xhci.zig` (1,536 lines)** — the M7 driver: probe, init,
  command/event rings, device enumeration, and **interrupt-IN only**
  (`xhci_poll_intr_nb` + `xhci_report`, consumed by `kernel/src/input.zig`
  for HID keyboard/pointer). No bulk endpoints, no control transfers beyond
  the enumeration minimum, no device lifecycle after boot.
- **The hardware contract** (`docs/hardware-contract.md`) documents the VZ
  XHCI emulation in detail: the controller is `0x106b/0x1a06` (VZ leaves it
  halted; the driver HCRSTs), keyboard = port 9 (`0x05ac/0x8105`), pointer =
  port 10 (`0x05ac/0x8106`), the interrupter-register trap (ERSTSZ must go to
  `RTSOFF+0x20+(0x20×i)`, never the MFINDEX region), the **arm-ONE-transfer-
  TRB** rule (multi-TRB depth wraps the ring and drops reports), and the
  delivery cadence (≈ one report per full-frame present).
- **The runner** attaches exactly two USB device classes
  (`VZUSBKeyboardConfiguration` +
  `VZUSBScreenCoordinatePointingDeviceConfiguration`, `main.swift` ~line
  1117, behind the `--input` flag gate).
- **No FAT stack** — HF6 (M34) deleted `fat.zig`/`esp.zig`/`virtio_blk.zig`;
  the userland filesystem is the host-file channel. A USB disk therefore has
  no ready-made filesystem consumer; U3 scopes that honestly.

M43 makes USB a *device family* instead of an input substrate: bulk
transfers, mass storage end to end with a real consumer, an honest
lifecycle, and — probe permitting — serial. Every card lands with a class-B
spec (the M40 GF rule) and `[observed]` hardware-contract rows.

## The cards, in order

> **U6 rides with the first consumer → U1 bulk engine → U2 MSC probe → U3 seam+consumer → U4 lifecycle → U5 serial (parallel after U1).**

| Card | Issue | Phase | Depends on | Status | Touches | Notes |
|:-----|:------|:------|:-----------|:-------|:--------|:------|
| **U6** | [#1037](https://github.com/drawmeanelephant/DipshitOS/issues/1037) **Runner `--usb-msd` / `--usb-serial` flags** | host | — | ⬜ open | `host/vm-runner/Sources/VMRunner/main.swift` | `VZUSBMassStorageDeviceConfiguration` (macOS 13+) with a staged disk image; `--usb-serial` for U5. Flag-gated, OFF by default — the default VM byte-identical (the M9/N7 rule). Lands with the first consuming gate, not last. |
| **U1** | [#1032](https://github.com/drawmeanelephant/DipshitOS/issues/1032) **XHCI bulk transfer engine** | kernel | U6 (evidence) | ⬜ open | `kernel/src/xhci.zig`, `kernel/src/input.zig`, one spec | Bulk OUT/IN endpoint discovery at enumeration, transfer rings, doorbells, Transfer-Event service on the existing event-ring discipline. Proven by raw bulk evidence — no SCSI in this card. The arm-ONE-TRB lesson applies doubled. |
| **U2** | [#1033](https://github.com/drawmeanelephant/DipshitOS/issues/1033) **USB MSC probe: BOT + minimal SCSI** | kernel | U1 | ⬜ open | new `kernel/src/usb_msc.zig`, `kernel/src/xhci.zig`, `docs/hardware-contract.md` | Bulk-Only Transport (CBW → data → CSW) + INQUIRY / READ CAPACITY(10) / TEST UNIT READY / READ(10) / WRITE(10). Sector write/read byte-exact. **Probe-and-record card**: LUNs, INQUIRY string, quirks → `[observed]` contract rows before anything builds on them (the N5 exploration pattern). |
| **U3** | [#1034](https://github.com/drawmeanelephant/DipshitOS/issues/1034) **Block-device userland seam + a real consumer** | kernel+user | U2 | ⬜ open | `kernel/src/file_table.zig`, consumer module, one spec | The USB disk reaches EL0 through the per-process handle family. Consumer chosen by evidence: (a) bounded read-only FAT32 reader (8.3 names, revivable from the claim-6420 lineage) or (b) a raw-block consumer. Composition test: host-staged content observed by the guest. |
| **U4** | [#1035](https://github.com/drawmeanelephant/DipshitOS/issues/1035) **Honest device lifecycle** | kernel | U2 | ⬜ open | `kernel/src/xhci.zig`, `kernel/src/input.zig`, one monitor verb, one spec | Rescan/attach/detach with observability; removal fails gracefully (clean errors, no registry ghosting — the close_owner lesson). Port-change interrupts only if polled rescan proves insufficient. If full teardown is unbounded, scope to the honest error path and record the limitation. |
| **U5** | [#1036](https://github.com/drawmeanelephant/DipshitOS/issues/1036) **USB serial (CDC-ACM), probe-first** | kernel | U1 | ⬜ open | `kernel/src/xhci.zig`, possible `kernel/src/usb_serial.zig`, contract doc | **Premise UNVERIFIED at scoping time** — the card opens with the probe (attach, class/interface descriptors, what VZ actually emulates). If emulated: a two-way char device with a round-trip gate. If not: the observation lands in the hardware contract and the card closes as an honest negative. |

## Scoping-time ground truth (so no card re-derives it)

- `VZUSBMassStorageDeviceConfiguration` — **exists**, macOS 13.0+ (Apple
  documentation, checked 2026-09-06). Not yet attached by any gate; first
  observed facts land in U6/U2.
- VZ CDC-ACM emulation — **unknown**. U5's first deliverable is the probe.
- The Apple XHCI emulation **resets nothing at ExitBootServices for USB**
  (unlike virtio-blk, which resets and needs `blk_rearm`) — the M7 contract
  row records the halted-at-boot state; whether a post-boot device arrival
  behaves like the boot-time devices is exactly what U4 observes.
- The per-gate class-B fleet runs on ONE shared read-only image with
  per-gate private shares (HF6) — the MSD is a **second, additive** disk;
  the share model is untouched.

## Invariants & design principles

1. **Zero-Regression**: the HID keyboard/pointer paths and every class-B
   gate stay green; the default VM stays byte-identical; new devices attach
   behind runner flags that are OFF by default.
2. **Driver-scoped kernel work**: new code lives in `kernel/src/xhci.zig` +
   one device module per class; nothing crosses the block/char-device seam
   without its own card.
3. **Every card ends in an observed gate** — a spec under
   `tools/gate/specs/` (never a one-off `verify-*.sh`), with the M40
   rotation-audit rules applied: no speed-calibrated holds, report rings
   sized for the choreography.
4. **Hardware contract first**: every VZ-observed behavior gets an
   `[observed]` row with claim refs — observed facts, never the spec's
   promise, are what later cards build on.

## Out of scope (recorded at scoping time)

- USB hubs; isochronous devices (USB audio/video); USB3 speeds.
- A second filesystem family (exFAT/NTFS) — if FAT revives at all it is the
  bounded read-only 8.3 reader of U3(a).
- Network-over-USB (CDC-NCM/EEM) — virtio-net is the network story.
- Rewriting the HID paths — U1 generalizes the transport without touching
  the HID consumers' behavior.

## Next actions (when M43 opens)

1. U6 + U1 together: the flag lands with a raw-bulk probe spec — the first
   `[observed]` rows for a third USB device class.
2. U2 immediately after, on the same device: BOT/SCSI probe-and-record.
3. U5's probe can run in parallel with U2 (one boot, one flag, an honest
   contract row either way).
4. U3's consumer decision (FAT reader vs raw-block) is made **on U2's
   evidence**, not before.
