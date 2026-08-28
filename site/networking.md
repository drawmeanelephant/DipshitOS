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
| TCP | `tcp.zig` | RFC 793: client (handshake, one in-flight segment, bounded retransmission) + passive-open server |
| TCP seam | `syscall.zig` slots 30–33 | `sys_tcp_connect`/`sys_tcp_send`/`sys_tcp_recv`/`sys_tcp_close` for EL0 |
| HTTPD | `user/src/httpd.zig` | in-guest HTTP/1.1 web server over the passive-open listener (claim 0750) |

## What works end to end

- **Raw Ethernet** — `netsend` transmits known frames the host captures
  byte-exactly; `net recv` prints received frames (MAC-filtered).
- **ARP** — the guest answers requests for its IP and resolves peers.
- **ICMP** — the guest answers echo requests and pings peers.
- **UDP** — loopback (own-IP sends never touch the device), datagrams to/from
  peers, and the EL0 syscall seam (`sys_udp_listen/send/recv`).
- **DHCP** — a bounded client that binds a lease, then renews, rebinds, and
  expires it on the lease timer.
- **TCP** — a bounded client (connect, send, receive, close, plus fixed-RTO
  retransmission with an abort bound) **and a passive-open server**, exposed
  to EL0 through the slot 30–33 syscall seam (`TCP.BIN` proves the client;
  `HTTPD.BIN` proves the server).
- **DNS** — a bounded RFC 1035 resolver (`net dns <hostname>`) that queries
  port 53 and extracts A records, live-gated against a deterministic
  `--net-dns-respond` answer.
- **NAT** — the launcher's `--net-nat` mode attaches a real
  `VZNATNetworkDeviceAttachment`; the guest pings the NAT gateway.
- **HTTP server** — `HTTPD.BIN` accepts a connection on the passive-open
  listener and serves the guest's own files over HTTP/1.1 (claim 0750).
- **Userland network apps** — `TCP.BIN` (echo client), `FETCH.BIN` (HTTP/1.0
  client), `PING.BIN`, `NETSTAT.BIN`, `TRACEROUTE.BIN`, and `CHAT.BIN`
  (graphical UDP chat) run the seam end to end.

<Aside kind="info">

**VERIFIED.** Each layer has a class B gate with byte-exact host captures
where the attachment is deterministic (`verify-live-net-tx`, `-rx`, `-arp`,
`-icmp`, `-udp`, `-udp-syscall`, `-dhcp`, `-dhcp-renew`, `-tcp`, `-tcp-rto`,
`-nat`). Under NAT the evidence is guest-observed counters, because the host
translates the frames — that is the point of NAT.

</Aside>

## Honest bounds

- TCP is **single-connection**: one client connect and one passive-open
  listener; no TCP loopback, no congestion control, fixed window 4096,
  payload ≤ 64 bytes in one segment.
- RTO is fixed (3 ticks) with no Karn/exponential backoff; 10 retransmissions
  then an honest abort.
- DHCP has no hostname/DNS options and no relay; the lease is enforced but the
  client is not a full DHCP implementation.
- DNS is bounded: A records only, one query at a time, no caching, no other
  record types.
- No routing beyond the NAT gateway; no IPv6 stack.

<Aside kind="warning">

**LIMITATION.** No routing beyond the NAT gateway and no IPv6. TCP is a
single-connection client + passive-open listener, not a general-purpose
network stack — the tower proves the protocol shapes and the syscall seam.

</Aside>
