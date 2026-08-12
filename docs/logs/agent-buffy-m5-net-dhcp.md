# Log — agent/buffy/m5-net-dhcp

Branch: `agent/buffy/m5-net-dhcp` · Slug: `net-dhcp` · Claim: [0351](claims/0351-dhcp.md)

## 2026-08-12 — claim N8 (DHCP: the guest obtains its address from a server)

- N7 (claim 4678) shipped as PR #103 (`agent/buffy/m5-net-nat`); the
  N8 claim branch is cut from the N7 head (`dd354d6`), the established
  sequential two-PR pattern.
- Claim id 0351 via `bash tools/status/claim-id.sh
  agent/buffy/m5-net-dhcp net-dhcp` (the claim file was first written
  with a wrong hand-picked id 9949 and renamed to the deterministic
  0351 at registration — the coordination check caught it).
- Scope: `kernel/src/dhcp.zig` (the bounded RFC 2131 client), the
  broadcast-dst send seam (`net_dhcp_send`), the `net dhcp` subcommand
  + `net`'s `dhcp=` line, the runner's `--net-dhcp-respond`, the new
  class-B live gate `tools/verify-live-net-dhcp.sh` (phase 1
  deterministic file-handle, phase 2 real NAT), the 36-gate aggregate
  re-run, and the hardware-contract/march-m5/status/gate-inventory
  updates.

## 2026-08-12 — close-out

- **Kernel `kernel/src/dhcp.zig` (NEW):** the bounded RFC 2131 client,
  pure logic (the arp.zig/udp.zig pattern) — DISCOVER (broadcast, a
  CSPRNG xid) → parse OFFER (cookie 0x63825363, option 53 = 2, server
  id 54, yiaddr) → REQUEST (options 50 + 54) → parse ACK (option 53 =
  5) → BOUND {ip, mask, gateway, server id, lease time}; honest bounds
  (recorded, not enforced): no renewal/lease-expiry, no hostname/DNS,
  no DHCPv6, no relay/giaddr, ONE fixed BSS state machine + one fixed
  256-byte packet buffer, no heap; src 68 → dst 67, broadcast dst.
  13 host tests byte-exact against the fixtures.
- **Seam change:** `virtio_net.net_dhcp_send` — the broadcast-dst send
  path (dst MAC ff:ff:ff:ff:ff:ff, dst IP 255.255.255.255, no ARP);
  the N5 `net_udp_send` semantics unchanged. `udp.zig` gained the
  generalized frame builder + the port-68 dispatch to dhcp.handle_rx
  (the datagram already checksum-validated).
- **Monitor:** the `net dhcp` subcommand (registry stays 34), the
  `dhcp=` report line, the counters + bounded retry (max_attempts = 3
  then an honest refuse), on BOUND it sets arp.own_ip (THE one copy).
  Help/usage + the transcript fixture re-derived; the shell.zig inline
  expected transcript updated.
- **Runner `--net-dhcp-respond <lease-ip>` (OFF by default, requires
  `--net`):** the capture thread answers DISCOVER → OFFER (2) and
  REQUEST → ACK (5) with the FIXED lease {ip 10.0.0.2, mask
  255.255.255.0, gw 10.0.0.1, server = the lease IP, lease 3600s}, the
  guest's xid echoed byte-exact, both checksums recomputed (RFC 1071).
- **Two live-boot bugs found and fixed at claim time (exploratory
  run, never assumed):** (1) the reply's total/UDP-length fields
  overflowed UInt8 (16-bit fields — the high byte added); (2) the
  reply echoed the CLIENT's message type instead of the server's
  answer — the kernel honestly counted it malformed (mal=1); fixed by
  mapping DISCOVER → 2, REQUEST → 5. Also fixed: a `String(format:
  %08x)` vararg crash in the NET-DHCP print (the xid hex is built
  manually, like the N5 ports).
- **Class A green:** fmt, the unit suite (52/52 incl. dhcp), the
  byte-identical transcript, build/image/inspect, swift build,
  context, coordination.
- **Live gate `tools/verify-live-net-dhcp.sh` PASS on VZ — 16/16
  assertions, TWO phases.** Phase 1 (deterministic file-handle,
  9/9): the full handshake BOUND — DISCOVER 286 B byte-exact in the
  capture → OFFER → REQUEST 298 B (the same xid) → ACK → `net: dhcp
  bound ip=10.0.0.2 mask=255.255.255.0 gw=10.0.0.1 server=10.0.0.2
  lease=3600`, counters discover=1,offer=1,request=1,ack=1,nack=0,
  timeout=0,mal=0, the host's NET-DHCP OFFER + ACK lines, the capture
  byte-exact (584 B = both client messages). Phase 2 (real NAT, 7/7):
  the CLAIM-TIME OBSERVATION — the VZ NAT attachment serves NO DHCP
  server on this host (the DISCOVER went out, offer=0, mal=0;
  rx=frames=1,filtered=3 — no DHCP frames at all); honestly recorded
  in the hardware contract [observed] (saved log under
  artifacts/live-net-dhcp-nat-explore/), never faked; the guest is NOT
  stranded — the static fallback still pings the NAT gateway (pong=1
  seq=1).
- **The 36-gate `verify-vz` aggregate re-ran green 36/36**
  (artifacts/m5-net-dhcp-vz-sweep.log, the live-net-dhcp gate 12s);
  the N6 seam regression (UDP.BIN) green.
- **Docs:** hardware-contract DHCP observation `[observed]`, march-m5
  N8 row + the agent-split bullet flipped to done, status.md
  milestone-five row + gate table (36-gate), gate-inventory
  live-net-dhcp row + aggregate list, claim close-out.
