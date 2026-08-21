# Claim: Milestone five, card N1 — virtio-net transport + TX (the network keystone)

- **Owner:** buffy (`agent/buffy/m5-net-tx`)
- **Prompt / plan:** `docs/m5-net-tx-prompt.md` (planning-first; split from
  the roadmap's network sketch, the last "Eventually" item). Milestone four
  is CLOSED and tagged `m4-processes` at `9d7e4d5` (merged main
  `bc310ef`) — the roadmap's precondition is satisfied. ADR 0007 stays
  frozen: N1 is a DEVICE DRIVER card, no syscall numbering. No
  libc/POSIX/heap anywhere.
- **Scope:** (1) runner `--net <capture-file>` flag-gated mode in
  `host/vm-runner/Sources/VMRunner/main.swift`: attach
  `VZVirtioNetworkDeviceConfiguration` with a
  `VZFileHandleNetworkDeviceAttachment` (guest TX frames captured
  byte-exactly to the file), FIXED host-set MAC so the guest address is
  deterministic and gate-assertable, OFF by default so the default VM and
  every existing gate stay byte-identical. (2) guest driver
  `kernel/src/virtio_net.zig`: PCI discovery via the claim-0013 pre-exit
  path expecting the modern virtio-net DID 0x1041 (confirmed at claim
  time — whatever is observed is recorded), post-exit re-arm (the
  claim-6420/2665 lesson, verified DRIVER_OK), MAC via
  `VIRTIO_NET_F_MAC` negotiation (host-set address) with a fixed BSS MAC
  fallback, queue 0 (RX) + queue 1 (TX) per the virtio-net spec, TX
  completion drained from the used ring POLLED (no IRQ for N1), injectable
  transport ops so the logic is host-testable (the fat.zig
  injected-sector-I/O pattern). (3) bounded BSS staging for one TX frame
  (Ethernet header: dst/src MAC + ethertype 0x0800; payload bounded and
  truncated honestly) — `netsend` builds the frame, submits, drains,
  reports byte counts. (4) monitor commands `net` (registry 32→34, two
  commands: device/DID/MAC/queues/feature bits) and `netsend <bytes>`.
  Honest bounds: RX buffer supply + used-ring drain + MAC filtering + net
  recv are card N2. (5) class A host tests: feature-negotiation parsing,
  MAC read (feature path + fallback), frame build byte-exact against a
  known fixture, staging-buffer bounds/truncation, used-ring drain
  accounting, net/netsend output shapes, registry rows; `swift build`
  covers the runner change; the transcript fixture is updated byte-exactly
  (help gains the two commands). (6) hardware contract: the net device
  gets NO `[observed]` claim without a saved VZ log — DID (0x1041
  expected), MAC feature, and post-exit re-arm behavior are `[inferred]`
  until the live gate observes them; the expectation + the
  ExitBootServices-reset prediction are recorded up front. (7) new class B
  gate `tools/verify-live-net-tx.sh`: run with `--net`; `net | netsend
  <known-frame> | echo` — the host attachment's capture file must contain
  the EXACT frame bytes the guest submitted, and `net` reports the
  observed DID/MAC/queues; the FULL shared-seam live sweep + the 28-gate
  `verify-vz` aggregate stay green (proof the `--net` mode did not disturb
  the default VM); evidence under `artifacts/live-net-tx-*`.
- **Depends on:** milestone four CLOSED and tagged `m4-processes`
  (`9d7e4d5`, merged main `bc310ef`); the virtio patterns N1 needs are
  proven on this platform (claims 0013/6420/2665/0828/9737). The
  2026-08-11 DID correction (net = spec's modern 0x1041) is established;
  its doc propagation is completed on this branch (commit 7606d00).
- **Status:** ✅ done 2026-08-11 — the virtio-net TRANSPORT + TX is live
  on VZ, byte-exact on the host: `tools/verify-live-net-tx.sh` **PASS
  2/2** (phase 1: the full `net` report + the host capture byte-exactly
  the 46-byte known frame; phase 2: ring reuse + honest truncation — 46 +
  46 + 1514 bytes, frames=3), the full class-A set is green, and the
  **29-gate `verify-vz` aggregate re-ran green** (proof the `--net` mode
  left the default VM byte-identical). Claim-time findings recorded:
  the device DID is 0x1041 as predicted (class 0x020000, D1); the device
  REQUIRES `VIRTIO_NET_F_MTU` accepted (VER1-only and VER1|MAC masks are
  rejected — status readback 0x03); the host-set MAC is readable via the
  feature path (`mac=02:00:00:00:00:01 source=feature`); the net device
  does NOT reset at ExitBootServices (pre-rearm st=0f, unlike blk/entropy);
  and every TX buffer must carry a 12-byte virtio_net_hdr (the device
  consumes one even with no offload feature — `tx_hdr_len` corrected
  0→12). Hardware-contract flips are `[observed]` with the saved serial
  logs + captures under `artifacts/live-net-tx-*`.

## Notes

**Why this card:** the OS has proven virtio console/block/entropy/custom
devices and a full process/IPC seam, but it is on NO network — the runner
attaches none. Networking is the roadmap's last open milestone and N1 is
its keystone: the transport must exist before RX (N2), ARP (N3), or
IPv4/ICMP (N4) can. Every virtio pattern N1 needs is already proven on
this exact platform; the file-handle attachment gives deterministic
byte-exact gates in the shape of the custom-virtio spike. Lowest-risk rung
of the network ladder; every later card presupposes it.

**Confirm at claim time (record whatever is observed):** the device DID
(0x1041 expected per the correction), the MAC feature bit
(`VIRTIO_NET_F_MAC`), the post-exit re-arm behavior (VZ resets virtio
devices at ExitBootServices — the claim-6420/2665 lesson), and whether the
device consumes a 12-byte virtio_net_hdr on TX when checksum offload
features are NOT negotiated. A differing observation is a claim-time
finding, recorded as the 6420/2665 corrections were — the hardware
contract flips to `[observed]` only with the saved VZ log under
`artifacts/`.

**Verification:** class A first (fmt, unit tests, test-console +
byte-identical transcript, build/image/inspect, swift build, context,
coordination ×2, mmu-debt); then class B on VZ (the new
`verify-live-net-tx.sh` + the full shared-seam live sweep + the 28-gate
`verify-vz` aggregate, evidence under `artifacts/`); then the docs
reconciliation (new `docs/march-m5.md` tracker, roadmap network row flip +
virtio surface table, status.md milestone-five row + gate table, README,
gate-inventory, hardware-contract `[observed]` flips with saved logs only,
architecture), the claim flip, the log append, and the PR per the repo
template with real observed evidence only.
