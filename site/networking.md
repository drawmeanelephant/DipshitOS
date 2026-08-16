---
title: Networking
parent: capabilities
status: published
tags: [capabilities, networking]
---

# Networking

The network stack is a from-scratch, RFC-shaped protocol tower over the
virtio-net transport, built in bounded fixed-BSS staging.

## The tower

| Layer | Implementation | Notes |
|-------|----------------|-------|
| Transport | `virtio_net.zig` | DID 0x1041; queues 0/1; 12-byte `virtio_net_hdr` on every buffer |
| ARP | `arp.zig` | RFC 826; static IP; bounded 4-slot table; answer + learn |
| IPv4 / ICMP | `ipv4.zig` | RFC 791/792; RFC 1071 checksums; echo answer + ping; fragments dropped (counted) |
| UDP | `udp.zig` | RFC 768; pseudo-header checksum always computed; bounded listen table; loopback |
| DHCP | `dhcp.zig` | RFC 2131 client: DISCOVER → OFFER → REQUEST → ACK, plus renew/rebind/expiry |
| DNS | `dns.zig` | RFC 1035 client: A-record queries over UDP, parse + extract, `net dns <hostname>` |
| TCP | `tcp.zig` | RFC 793 client: handshake, one in-flight segment, bounded retransmission |
| TCP seam | `syscall.zig` slots 30–33 | `sys_tcp_connect`/`sys_tcp_send`/`sys_tcp_recv`/`sys_tcp_close` for EL0 |

## What works end to end

- **Raw Ethernet** — `netsend` transmits known frames the host captures
  byte-exactly; `net recv` prints received frames (MAC-filtered).
- **ARP** — the guest answers requests for its IP and resolves peers.
- **ICMP** — the guest answers echo requests and pings peers.
- **UDP** — loopback (own-IP sends never touch the device), datagrams to/from
  peers, and the EL0 syscall seam (`sys_udp_listen/send/recv`).
- **DHCP** — a bounded client that binds a lease, then renews, rebinds, and
  expires it on the lease timer.
- **TCP** — a bounded client: connect, send, receive, close, plus fixed-RTO
  retransmission with an abort bound, exposed to EL0 through the slot 30–33
  syscall seam (`TCP.BIN` proves it from a user program).
- **DNS** — a bounded RFC 1035 resolver (`net dns <hostname>`) that queries
  port 53 and extracts A records, live-gated against a deterministic
  `--net-dns-respond` answer.
- **NAT** — the launcher's `--net-nat` mode attaches a real
  `VZNATNetworkDeviceAttachment`; the guest pings the NAT gateway.
- **Userland network apps** — `TCP.BIN` (echo client), `FETCH.BIN` (HTTP/1.0
  client), and `CHAT.BIN` (graphical UDP chat) run the seam end to end.

<Aside kind="info">

**VERIFIED.** Each layer has a class B gate with byte-exact host captures
where the attachment is deterministic (`verify-live-net-tx`, `-rx`, `-arp`,
`-icmp`, `-udp`, `-udp-syscall`, `-dhcp`, `-dhcp-renew`, `-tcp`, `-tcp-rto`,
`-nat`). Under NAT the evidence is guest-observed counters, because the host
translates the frames — that is the point of NAT.

</Aside>

## Honest bounds

- TCP is **outward-only**: no server/listen, no TCP loopback, no congestion
  control, fixed window 4096, payload ≤ 64 bytes in one segment.
- RTO is fixed (3 ticks) with no Karn/exponential backoff; 10 retransmissions
  then an honest abort.
- DHCP has no hostname/DNS options and no relay; the lease is enforced but the
  client is not a full DHCP implementation.
- DNS is bounded: A records only, one query at a time, no caching, no other
  record types.
- No routing beyond the NAT gateway; no IPv6 stack.

<Aside kind="warning">

**LIMITATION.** There is no TCP server/listen and no routing beyond the NAT
gateway. The stack is designed to prove the protocol shapes and the syscall
seam, not to be a drop-in userspace network library.

</Aside>
