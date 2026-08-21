# Claim: M1.5 — VZ serial device discovery (march step 8 remaining; claims 0002/0009/0010 successor)

- **Owner:** buffy (`freebuff/pull-the-latest-from-github-and-find-something-in--a639920e-ebe1-47a0-a380-54cece9b4c40`)
- **Prompt / plan:** inline in this file; the discovery proceeds on a live Apple M4 host (VZ guest boots + NVRAM marker channel are the evidence path)
- **Scope:** M1.5 march step 8 remaining work — find the VZ virtio-console register file (or document why it is unfindable), so the serial probe can select a console and the VZ serial gate can pass
- **Depends on:** claim 0010 (MMU takeover fixed — the probe now runs to completion; ladder reaches `M2_SERIA`)
- **Status:** ✅ done 2026-08-07 — discovery complete (the VZ console is a virtio-pci device, decoded + transport armed pre-exit); the remaining post-MMU TX gate this claim could not pass was **resolved by claim 1517** (T0SZ=16 + TLBI — the VZ serial gate now passes; this claim's ⛔ is historical)
- **Closed:** 2026-08-07 — evidence in `artifacts/efi-vars.bin` (this branch's runs), claim text below; ladder reaches `M2_READY` (console discovered + armed) then TX hangs post-exit

## Notes

The blocker as of 2026-08-07: with the MMU takeover fixed (claim 0010), the
kernel's `probe_serial` runs to completion and finds **no usable
PL011/16550/virtio device in the two declared MMIO windows**
(`0x01000000..0x01010000`, `0x20050000..0x20051000`), halting at
`layout=none`. Two hypotheses drive this claim:

1. **Window-offset blindness:** `probe_serial` inspects only each declared
   window's **base address**. The 64 KiB window at `0x01000000` is large
   enough for many virtio-mmio devices (each occupies 0x200 bytes). If VZ
   places the console at an offset (e.g. block at base, console at
   `base+0x200*n`), the probe never sees it.
2. **Signature edge cases:** the PL011 branch requires `(FR & 0x80) == 0`
   (TXFE clear) to select — a fresh UART reports TXFE set, so a real PL011
   may be rejected; probe records are only printed to the (silent) serial
   log, so none of this is observable today.

Method: extend the kernel to persist the probe records (base, magic,
version, device, vendor) plus the selection into the **NVRAM marker
channel** (the proven post-exit channel, claim 0009) as a second variable,
and scan declared windows at virtio-page granularity (every 0x200) plus
0x1000-aligned offsets for PL011/16550. Then read `artifacts/efi-vars.bin`
for ground truth. If a console device is found, select it and re-run to test
for actual serial TX (`DipshitOS kernel has seized control.` → the VZ
serial gate, claim 0002).

Gate: observed serial output in `vm-serial.log` from a real VZ run, or a
precise, evidence-backed statement of what the windows contain and why no
console is reachable (blocked, honest).

## Outcome (2026-08-07) — discovery complete, gate blocked at post-exit TX

**The VZ console is a virtio-pci device, not a PL011 and not virtio-mmio.**
Bus 0 device 5: `VID=0x1af4 DID=0x1043 class=0x078000` — the *modern*
virtio-console (0x1003 legacy), class 0x07/0x80 communications controller
(exactly what Linux shows for virtio-console). ECAM base `0x40000000`
(MCFG). Evidence persisted through the NVRAM channel per run:
`artifacts/efi-vars.bin` (see log entries on this branch).

### What the declared MMIO windows actually contain (decoded, not guessed)

1. `0x01000000..0x01010000` — **Apple's EFI variable-store region.** Raw
   bytes spell the literal string `efivars\0`. Not a serial device; reading it
   post-exit hangs the kernel (the fivars controller).
2. `0x20050000..0x20051000` — **a PL011-family PrimeCell UART**, but not the
   runner's serial attachment. Full component IDs observed: CID0-3
   `0x0d 0xf0 0x05 0xb1` (standard `0xb105f00d`), PID1=0x10, PID2=0x04
   (JEDEC), PID3=0x00, PID0=0x31 (the odd one that made the old rigid probe
   reject it). Writing DR after proper PL011 init (CR=UARTEN|TXE, IBRD/FBRD,
   LCR_H) produced **zero bytes** in `vm-serial.log` — so this is Apple's
   internal EFI debug UART, a dead end for the gate.

### Why no ACPI/devicetree shortcut exists

- Config table has 8 entries; entry 4 is `RSD ` (ACPI RSDP @ `0x7fb9f018`);
  entries 5/6 are `_SM_`/`_SM3_` (SMBIOS). No flattened device tree
  (`0xd00dfeed` nowhere).
- XSDT = 4 tables: **FACP, GTDT, APIC, MCFG** — **no SPCR, no DBG2** (Apple
  names no console UART).
- DSDT is Apple's own (`OEM "APPLE "`, `OEMTableID "Apple Vz"`, 858 bytes
  AML): declares only `PCI0` (root complex, `_CRS` = the ECAM window) and an
  `efivars` device. **No UART, no virtio device named in AML** — the console
  is behind PCI, which is why MCFG exists.

### Transport decode + pre-exit arming (all evidence-backed)

- BAR0 is a **64-bit BAR** firmware-assigned to `0x100010000` (low dword
  `0x10004`, high dword `0x1`) — *above* the 4 GiB identity-map blanket.
  Firmware's PCI resource assignment varies across boots (BAR0 read `0x4`
  unassigned on one boot) and the device moves with the BAR — another
  reason the old probe's fixed windows never saw it.
- Capability list via aligned **u32** config reads (byte reads of VZ config
  space return garbage — observed; unaligned reads alignment-fault, which
  killed the first cap walk with no exception vectors):
  common cfg @ BAR0+`0x0000` (len 0x38), ISR @ `+0x1000`, notify @ `+0x4000`
  (multiplier 4), device cfg @ `+0x8000`.
- Pre-exit, the transport **arms completely**: features
  `0x30000000`/`0x5` (VERSION_1 present), queue 1 configured (qsz 1, desc
  `0x7e561080`, avail `0x7e561010`, used `0x7e561070`), DRIVER_OK `0xf`.
  `SEL=VIRTIO base=0x100010000`. The kernel reaches `M2_READY`.

### The wall: post-exit access to the transport hangs on VZ

Everything pre-exit works. **Post-exit, access to the virtio-pci window
hangs** (no exception vectors, so a hang is the observable symptom): the
first banner TX dies somewhere in the first flush — the death site is
boot-variable (one run stopped between the flush markers, at the status
read / notify write; the final gate run stopped before the flush's first
marker) — and `vm-serial.log` stays 0 B. This is the same VZ wall that
made post-exit reads of the declared MMIO windows hang in every prior
claim: VZ's MMIO emulation is not reliably reachable from the guest's
post-MMU-switch page tables (the runtime SetVariable NVRAM channel is the
*only* proven post-exit device channel). Rebasing the BAR below the
blanket was tried and abandoned: the BAR write *does* move the transport,
but to an address the firmware never mapped pre-exit, and post-exit config
writes aren't reliable — so mapping the firmware-assigned base in place
(now in `build_identity_map`) is the approach that keeps the transport
armed; it just can't be TX'd from the guest post-exit.

### What this means for the milestone

- **Discovery is done:** the VZ serial attachment is a modern virtio-pci
  console at D5 with a decoded, pre-exit-armed transport. This was the
  milestone's headline unknown (claims 0002/0009/0010 successor work).
- **The gate is not passed:** no serial bytes post-exit. Honest, precise
  blocker: *"post-MMU-switch access to the VZ virtio-pci console transport
  window hangs on VZ"*.
- **Next step for a successor claim:** make TX work through the host side
  (e.g. a runtime-service or memory-marker channel the runner can turn into
  serial bytes — the marker ladder already proves the NVRAM channel is
  alive post-exit) or find a VZ configuration that keeps the transport
  reachable post-exit (e.g. map the window before exit and never touch
  config space after). The named gate artifact is
  `artifacts/m15-serial-discovery-gate.txt` (this branch's final run:
  ladder `… → M2_RAW! → M2_READY`, `SEL=VIRTIO base=0x100010000`).
