# Roadmap archive — Milestone five: network stack (N1–N6)

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).
>
> The network-stack sketch + landed rungs N1–N6 lived under `docs/roadmap.md`'s
> "Later milestones" section. Closed 2026-08-12 (claim 5357). Per-card tracker:
> [`docs/march-m5.md`](../march-m5.md).

---

- **Network stack (in progress — N1 + N2 + N3 + N4 + N5 + N6 landed 2026-08-12, claims 1373/6076/7293/0148/8552/1384).** The
  last "Eventually" item, and the one the virtio surface table below maps
  to. The transport it needs was already proven (virtio
  console/blk/entropy/custom drivers: discovery, queues, IRQ delivery,
  post-exit re-arm), the runner change was one config line
  (`config.networkDevices`, now flag-gated behind `--net <capture>`),
  and **N1 — the virtio-net TRANSPORT + TX — is DONE** (claim 1373,
  branch `agent/buffy/m5-net-tx`): the guest's `kernel/src/virtio_net.zig`
  discovers the device (DID 0x1041 — the modern spec DID confirmed on
  VZ), negotiates features (claim-time finding: the device NEEDS
  `VIRTIO_NET_F_MTU` accepted — VER1-only and VER1\|MAC masks are
  rejected with FEATURES_OK cleared), reads the host-set MAC via the
  feature path, arms queues 0 (RX) + 1 (TX), re-arms post-exit
  (claim-time finding: the net device does NOT reset at
  ExitBootServices, unlike blk/entropy), prepends the 12-byte
  virtio_net_hdr the device consumes on every TX buffer (observed
  contract), and `netsend` drives TX end to end with bounded BSS staging
  and polled used-ring drain. `net`/`netsend` monitor commands; live
  gate `tools/verify-live-net-tx.sh` PASS 2/2 (byte-exact host
  captures: 46-byte known frame, ring reuse, honest truncation). Card
  order:
  - ~~**N1 — virtio-net transport + TX.**~~ **DONE 2026-08-11 (claim
    1373).** Runner attaches `VZVirtioNetworkDeviceConfiguration` under
    the flag-gated `--net <capture-file>` mode;
    `VZFileHandleNetworkDeviceAttachment` gives the deterministic gates
    (host reads exact Ethernet frames, like the custom-virtio spike),
    with a FIXED host MAC (02:00:00:00:00:01) the guest reads via the
    feature path; `VZNATNetworkDeviceAttachment` for real outbound
    connectivity stays a later card's option. Guest
    `kernel/src/virtio_net.zig`: discover the device (modern virtio-net
    DID 0x1041 — confirmed at claim time), post-exit re-arm (the
    claim-6420/2665 lesson; the net device does not reset — observed
    st=0f), MAC via VIRTIO_NET_F_MAC negotiation (worked — the fallback
    is the fixed BSS MAC), TX + RX queues, bounded frame staging (no
    heap), 12-byte virtio_net_hdr prepended (observed contract). `net`
    monitor command (device/DID/MAC/queues/features); `netsend` proving
    the host receives known frames byte-exact. Live gate
    `tools/verify-live-net-tx.sh` PASS 2/2.
  - ~~**N2 — raw Ethernet RX.**~~ **DONE 2026-08-11 (claim 6076).**
    Queue 0 supplied with one fixed BSS buffer, used-ring drain into a
    bounded 4-slot frame FIFO (card-3d push/drain pattern), MAC filtering
    (own MAC + broadcast, drop the rest with a counter), `net recv`
    prints the frame byte-exact. The host injects a known frame via the
    runner's `--net-inject <file>` (a serial trigger, not a sleep) and
    the guest receives it and re-sends the SAME bytes — raw Ethernet
    frames back and forth. Live gate `tools/verify-live-net-rx.sh` PASS
    3/3 (broadcast round trip + byte-exact capture, own-MAC receive,
    foreign-MAC drop); claim-time observations pinned in the hardware
    contract: the device writes a 12-byte virtio_net_hdr into RX buffers
    (num_buffers=1, the RX-header question answered) and REFUSES an RX
    buffer under 1530 bytes; the used-buffer IRQ line is not yet
    observed — drain is polled.
  - **N3 — ARP.** Resolve peers (send requests, parse replies) and answer
    requests for our protocol address. Static IP first (`net ip
    <a.b.c.d>`, bounded, no config heap); DHCP is a later card. Live
    gate: the host ARPs for the guest IP and the reply carries the right
    MAC; the guest resolves the host's MAC from a crafted reply. **LIVE
    2026-08-11 (claim 7293)** — `kernel/src/arp.zig` (pure RFC 826 logic:
    static IP, build request/reply, bounded 4-slot table, counters) wired
    into the RX drain (answer requests for our IP, learn replies, drop
    the rest) + `net ip`/`net arp` subcommands + the runner's
    `--net-arp-respond <host-ip>` (deterministic host-side answer, OFF by
    default). Live gate `tools/verify-live-net-arp.sh` PASS 3/3 (answer
    a request for our IP — 42-byte reply byte-exact in the capture;
    resolve a peer — request byte-exact in the capture + the host answer
    lands in the table; a foreign-address request is dropped with a
    counter while still observable via `net recv`). Observed: the device
    delivers/transmits the 42-byte ARP frames unpadded (below the
    Ethernet 60-byte minimum).
  - **N4 — IPv4.** Minimal IPv4 TX/RX with ones-complement checksums
    (host-testable); ICMP echo as the proof — the guest answers echo
    requests and can send its own; honest bounds: no fragmentation, no
    reassembly (drop fragments, documented). Live gate: the file-handle
    host sends an ICMP echo request to the guest IP and the reply is
    byte-exact; with NAT attached, the guest pings an outbound address.
    **LIVE 2026-08-11 (claim 0148)** — `kernel/src/ipv4.zig` (pure RFC
    791/792 logic: RFC 1071 checksums, parse/build, ICMP echo
    request/reply byte-exact, fragments dropped counted — no
    reassembly) wired into the RX drain BESIDE the ARP dispatch (answer
    an echo for our static IP, observe echo replies — pong + seq, drop
    the rest counted) + `net ping <a.b.c.d>` subcommand + the runner's
    `--net-icmp-respond <host-ip>` (deterministic host-side echo
    answer, OFF by default). Live gate
    `tools/verify-live-net-icmp.sh` PASS 3/3 (answer an injected echo
    request — the 46-byte reply is byte-exact in the capture with the
    identification + id/seq/payload echoed; ping a peer — resolve +
    echo request byte-exact in the capture and the host's answer lands
    as pong=1 with seq=1; a foreign-address echo request is dropped
    with a counter while still observable via `net recv`).
  - **N5 — UDP.** Minimal UDP TX/RX over the N4 IPv4 seam (RFC 768):
    datagrams in/out with the IPv4 pseudo-header checksum, a bounded
    4-slot LISTEN table + bounded per-listener datagram buffers (`net
    udp listen/close/send/recv`), and a real LOOPBACK path (a send to
    our OWN IP delivers directly into the local receive path — no
    device round trip; the bounded host/loopback test surface). **LIVE
    2026-08-11 (claim 8552)** — `kernel/src/udp.zig` (pure RFC 768
    logic: header parse/build, the pseudo-header checksum computed
    ALWAYS, bad-checksum / closed-port / short-length drops counted)
    wired into ipv4.zig's protocol dispatch (protocol 17 → udp on
    already-validated frames) + `net udp` subcommands + the runner's
    `--net-udp-respond <host-ip>:<host-port>` (deterministic host-side
    echo answer, OFF by default). Live gate
    `tools/verify-live-net-udp.sh` PASS 4/4 (loopback — send to our
    own IP delivers locally byte-exact with an EMPTY capture; host→
    guest — the injected datagram is delivered to the listener
    byte-exact; guest→host — the datagram is byte-exact in the capture
    and the host answer lands in the listener buffer; a datagram to a
    closed port is dropped with a counter while still observable via
    `net recv`).
  - **N6 — UDP behind a bounded syscall seam.** **LIVE 2026-08-12
    (claim 1384)** — the ADR 0007 amendment slots 9/10/11
    (`sys_udp_listen` / `sys_udp_send` / `sys_udp_recv`): the N5 UDP
    layer exposed to EL0 user programs through the claim-6120 uaccess
    window (implemented 9 → 12), driven end to end by UDP.BIN (a new
    EL0 program: listen on 7000, LOOPBACK send+recv, peer round trip
    with the host's `--net-udp-respond` answer, the `EINVAL` error
    mapping from EL0 for an unbound-port recv + an unresolved-peer
    send, `sys_exit(17)`). The recv drains the device FIRST (the
    claim-6076 polled-drain contract) so an EL0 polling loop is
    self-sufficient. Live gate `tools/verify-live-net-udp-syscall.sh`
    PASS 4/4; the 34-gate `verify-vz` aggregate re-ran green 34/34.
  - **Later, sketched only:** DHCP, loopback-as-a-device, then TCP —
    far future, and
    the "only when the ones below it are demonstrably working" rule
    applies at every rung. The driver starts single-CPU (boot CPU, the
    claim-9187/0828 IRQ pattern); SMP is a separate future card.
