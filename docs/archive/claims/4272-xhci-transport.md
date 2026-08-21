# Claim: Milestone seven, card I1 — XHCI host-controller transport

- **Owner:** buffy (`freebuff/can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc`)
- **Prompt / plan:** `docs/march-m7.md` I1 row (the G4 input card was split into
  milestone seven after the claim-3868 observation). No planning-first prompt
  doc exists for I1 yet — it is the first milestone-seven rung.
- **Scope:** (1) DISCOVERY FIRST — the XHCI device identity is **[observed]**
  (claim 3868: `VID=0x106b DID=0x1a06 CLS=0x0c0330`, two MMIO BARs
  `0x50001000` + `0x50000000`), but which BAR is the register base, the
  HCSPARAMS values, the doorbell/runtime offsets, the port count, and whether
  VZ resets the controller at ExitBootServices are all claim-time
  observations, recorded not assumed. (2) `kernel/src/xhci.zig`: pre-exit PCI
  discovery (DID 0x1a06), post-MMU MMIO init — CAPLENGTH/HCIVERSION/
  HCSPARAMS1-3/HCCPARAMS1/DBOFF/RTSOFF parse, command ring + event ring +
  ERST + primary interrupter setup, a NO-OP command TRB driven to a Command
  Completion Event, and port-status reads (USBSTS/PORTSC). NO HID, NO
  enumeration, NO transfer rings (I2). Polled event-ring drain (the
  claim-6076 net lesson — the XHCI event IRQ is observed, not assumed).
  (3) `usb` monitor command (registry 37→38): device/DID/class/BARs,
  HCSPARAMS, ring state, reset + NO-OP result, per-port status. (4) live gate
  `tools/verify-live-xhci.sh` riding the runner's flag-gated `--input` mode.
  (5) hardware-contract `[observed]` flips with saved logs only.
- **Depends on:** the runner's `--input` mode (claim 3868, already merged);
  the virtio/blk/gpu PCI discovery + post-MMU MMIO patterns (claims
  0013/6420/6053) and the polled-drain DMA discipline (claim 6076).
- **Status:** ✅ done 2026-08-13 — live-gated on VZ (`verify-live-xhci.sh` PASS 1/1, 14/14 assertions); the XHCI host-controller transport works end to end

## Notes

**Why this card:** milestone six's G4 hypothesized virtio-input (DID 0x1052);
claim 3868 observed VZ actually exposes keyboard/pointer as an Apple XHCI USB
controller with HID devices behind it. Before any keystroke can reach Road
Pops (I3), the guest needs a working XHCI host-controller transport — the
MMIO register map, the command/event ring machinery proven by a completed
NO-OP, and a port-status read that shows the two HID devices are connected.
That is the "rings work" hurdle.

**Confirm at claim time (record whatever is observed):** which BAR is the
register base (capability regs at offset 0); CAPLENGTH/HCIVERSION/
HCSPARAMS1 (MaxSlots/MaxIntrs/MaxPorts)/HCSPARAMS2/HCSPARAMS3/HCCPARAMS1
(64-bit, context size)/DBOFF/RTSOFF; the controller's post-exit USBSTS/USBCMD
state (does VZ reset it at ExitBootServices — the gpu/blk/entropy `st=00` vs
net `st=0f` question); whether HCRST completes; whether the NO-OP command
completes with a Command Completion Event (completion code 1); the port
count + each port's CCS/PED/PS bits. A differing device or a stuck bit is a
finding, recorded honestly.

**Verification:** class A first (fmt, 341 unit tests, test-console +
byte-identical transcript, build/image/inspect, swift build, context,
coordination ×2, mmu-debt); then class B on VZ (the new
`verify-live-xhci.sh`, riding `--input`); then the docs reconciliation
(march-m7 I1 row, roadmap, status.md, gate-inventory, hardware-contract
`[observed]` XHCI flips with saved logs),the justfile `verify-vz` entry (38→39), the claim flip, the log append, and
the PR per the repo template with real observed evidence only.

## Claim-time observations (recorded, never assumed)

- **Device identity:** bus 0 **dev 8**, `VID=0x106b DID=0x1a06 CLS=0x0c0330`
  (Apple XHCI USB host controller — confirms claim 3868).
- **BARs/base:** BAR0 `0x50001000` holds the capability registers (the
  sane-CAPLENGTH pick won over BAR1 `0x50000000`); both below the 4 GiB
  identity-map blanket — no extra Device window.
- **Register map:** CAPLENGTH=0x20, HCIVERSION=0x110, DBOFF=0x940,
  RTSOFF=0x520, HCSPARAMS1=0x10002010 (MaxSlots=16, MaxIntrs=32,
  MaxPorts=16), HCSPARAMS2=0x0f, HCSPARAMS3=0x0, HCCPARAMS1=0x02610801.
- **The interrupter offset fix:** the interrupter register set i lives at
  RTSOFF+0x20+(0x20×i); MFINDEX occupies RTSOFF+0x00. Writing ERSTSZ into
  the MFINDEX region **wedged the emulation** (a boot hang with no fault) —
  moving the writes to interrupter 0 (+0x20) fixed it. Recorded for I2.
- **Reset-at-EBS:** VZ does **NOT** reset/run the controller at
  ExitBootServices — pre-reset USBSTS=0x9 (HCHalted + Port Change Detect)
  and USBCMD=0x0 (the XHCI answer to the gpu/blk/entropy `st=00` vs net
  `st=0f` question).
- **Rings + NO-OP:** after HCRST + RS, USBSTS=0x0 (running) and the NO-OP
  command completed with CC=1 (Success) — the command/event ring transport
  proven end to end.
- **Ports:** ports **9 and 10** report CCS=1 (connected) — exactly the two
  attached HID devices (keyboard + pointer); ports 1-8 and 11-16 report
  CCS=0. This is the I2 handoff.

Evidence: `artifacts/live-xhci-*` (gate output + serial), and the discovery
boots `artifacts/xhci-discovery-run*.txt` / serial copies.

