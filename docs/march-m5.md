# Milestone five march — networking (living tracker)

## Where we are

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds only
> milestone-five's per-card detail and collision-free agent split, following
> the [`march-m3.md`](march-m3.md) / [`march-m4.md`](march-m4.md) pattern.
> It was created for card N1 (2026-08-11, claim 1373) per
> [`docs/m5-net-tx-prompt.md`](m5-net-tx-prompt.md); a card's row flips to
> ✅ only with real observed class-B evidence, never code-complete alone.

Milestone five is the network milestone: the last "Eventually" item in
[`docs/roadmap.md`](roadmap.md) (the virtio surface table's Network row).
Milestone four is CLOSED (claim 2839, tag `m4-processes`) — the process/IPC
foundations the network sketch depended on are landed. The rungs of the
ladder, in order: **N1 virtio-net transport + TX** → N2 raw Ethernet RX →
N3 ARP → N4 IPv4/ICMP (later cards sketched only).

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| N1 | **Virtio-net transport + TX.** The runner's flag-gated `--net <capture-file>` mode attaches `VZVirtioNetworkDeviceConfiguration` with a `VZFileHandleNetworkDeviceAttachment` (fixed host MAC 02:00:00:00:00:01; OFF by default — the default VM stays byte-identical). The guest's `kernel/src/virtio_net.zig` discovers the modern virtio-net device (DID 0x1041) pre-exit, negotiates features, arms queue 0 (RX) + queue 1 (TX), re-arms post-exit, and `netsend` drives TX end to end through bounded BSS staging with polled used-ring drain; `net`/`netsend` monitor commands (registry 32→34). Honest bounds: RX buffer supply + used-ring drain + MAC filtering + `net recv` are card N2. | 🔄 in progress (TX done + live-gated; claim close-out pending) | [Claim 1373](claims/1373-net-tx.md); prompt: [m5-net-tx-prompt](m5-net-tx-prompt.md) | Landed 2026-08-11 on `agent/buffy/m5-net-tx`: **runner** `--net <capture-file>` (socketpair attachment, reader thread appends every guest datagram to the capture file byte-exactly; `config.networkDevices = []` without the flag — the 29-gate aggregate re-ran green); **guest driver** `kernel/src/virtio_net.zig` (injectable transport ops — the fat.zig pattern — 19 unit tests): discovery finds DID 0x1041 class 0x020000 at D1 (the modern spec DID confirmed on VZ); feature negotiation walks a candidate ladder because the device REJECTS VER1-only and VER1\|MAC masks — it NEEDS `VIRTIO_NET_F_MTU` accepted (observed: `feat=0x28/0x1` = VER1\|MTU\|MAC; status readback 0x03 on the rejected attempts); the host-set MAC is read via the feature path (`mac=02:00:00:00:00:01 source=feature`, matching the raw config bytes `cfgmac=02:00:00:00:00:01`); queues 0/1 armed size 4; post-exit re-arm is idempotent and the device does NOT reset at ExitBootServices (**observed `net: pre-rearm st=0f` — differs from blk/entropy's `st=00`**); TX buffers carry a ZEROED 12-byte virtio_net_hdr prefix because the device consumes one on EVERY TX buffer (observed — the first live gate stripped exactly 12 bytes; corrected `tx_hdr_len` 0→12); `netsend` builds the known frame (broadcast dst, own MAC src, ethertype 0x0800, payload byte i = i & 0xff, honest 1500-byte truncation) in fixed BSS staging (no heap) and drains the used ring polled. **Class-B gate `tools/verify-live-net-tx.sh` PASS 2/2 on VZ**: phase 1 asserts the full `net` report (did/class/mac/feat/queues/status/rearm) and that the host capture is byte-exactly the 46-byte known frame; phase 2 asserts ring reuse + honest truncation (46 + 46 + 1514 bytes, `frames=3`). Full class A green (fmt, 19+230 unit tests, byte-identical transcript, build/image/inspect, swift build, context, coordination ×2, mmu-debt); the **29-gate `verify-vz` aggregate re-ran green** (proof the `--net` mode left the default VM byte-identical; evidence `artifacts/live-net-tx-*`, `artifacts/live-net-tx-vz-sweep.log`). |
| N2 | **Raw Ethernet RX.** Used-ring drain into a bounded frame FIFO (IRQ-context push + shell-idle drain, the card-3d pattern), MAC filtering (own MAC + broadcast), `net recv` prints the frame; the host injects a known frame and the guest echoes it byte-exact. Live gate `tools/verify-live-net-rx.sh` — "raw Ethernet frames back and forth" is the first hurdle; this is where it falls. | ⬜ not started | — | Queue 0 is already armed with ZERO buffers (N1's honest bound); the runner's attachment already has the host→guest socket direction available. |
| N3 | **ARP.** Resolve peers (send requests, parse replies) and answer requests for our protocol address. Static IP first (`net ip <a.b.c.d>`, bounded, no config heap); DHCP is a later card. Live gate: the host ARPs for the guest IP and the reply carries the right MAC; the guest resolves the host's MAC from a crafted reply. | ⬜ not started | — | Depends on N2 (an ARP reply must be transmitted, an ARP request received). |
| N4 | **IPv4.** Minimal IPv4 TX/RX with ones-complement checksums (host-testable); ICMP echo as the proof — the guest answers echo requests and can send its own; honest bounds: no fragmentation, no reassembly (drop fragments, documented). Live gate: the file-handle host sends an ICMP echo request to the guest IP and the reply is byte-exact; with NAT attached, the guest pings an outbound address. | ⬜ not started | — | Depends on N2/N3. |

## Agent split / collision rules

- **N1** (claim 1373, `agent/buffy/m5-net-tx`): owns `host/vm-runner/Sources/VMRunner/main.swift` (the `--net` mode), `kernel/src/virtio_net.zig`, the `net`/`netsend` registry rows + monitor commands, `kernel/src/shell.zig` help, the transcript fixture, `tools/verify-live-net-tx.sh`, the justfile `verify-vz` entry, and this tracker's N1 row. No syscall numbering (ADR 0007 frozen), no heap, no scheduler/process changes.
- **N2+ (future cards)**: each later card claims on merged main per the repo workflow and owns its gate script; the N1 driver's RX hook (queue 0) is the seam they extend.
- Cross-cutting docs (`status.md`, `gate-inventory.md`, `hardware-contract.md`) are updated per card at claim close-out, never during implementation.
