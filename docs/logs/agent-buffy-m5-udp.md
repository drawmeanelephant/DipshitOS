# Log — agent/buffy/m5-udp

Branch: `agent/buffy/m5-udp` · Slug: `udp` · Claim: [8552](claims/8552-udp.md)
Prompt: [m5-udp-prompt](m5-udp-prompt.md) (PR #92) · Branched from merged main `e685586` (N1–N4 all merged) carrying the N5 prompt commit.

## 2026-08-11 — claim + implementation

- **Claim:** branch `agent/buffy/m5-udp` from merged main `e685586` with
  the N5 prompt commit cherry-picked; claim ID 8552 via
  `tools/status/claim-id.sh`; claim doc + this log + `refresh-indexes.sh`.
- **`kernel/src/udp.zig` (new):** pure RFC 768 logic — 8-byte header
  parse/build, the IPv4 pseudo-header checksum (src/dst IP, protocol 17,
  UDP length — RFC 1071, computed always), a bounded 4-slot LISTEN table,
  a bounded per-listener datagram buffer (4 × 80 bytes, drop-oldest),
  LOOPBACK (send to own IP delivers locally, no TX), counters.
  Host-tested in isolation.
- **`kernel/src/ipv4.zig`:** protocol dispatch — protocol 17 calls
  `udp.handle_rx` (already-validated frames, no reply buffer); every
  other non-ICMP protocol still counts `dropped_proto`. IPv4 validation
  is not duplicated.
- **`kernel/src/virtio_net.zig`:** `net_udp_send(target_ip, dst_port,
  payload)` — the `net_ping_request` shape (`.no_peer` on an unresolved
  MAC; own-IP sends take the loopback path), TX on the N1
  one-request-at-a-time path with the zeroed virtio_net_hdr prefix.
- **`kernel/src/monitor.zig` + `kernel/src/shell.zig`:** `net udp`
  report + `net udp listen <port>` / `net udp close <port>` / `net udp
  send <ip> <port> <len>` / `net udp recv [<port>]` subcommands (fixed
  src port 7000, byte-index payload ≤ 64, honest refusals), help/usage
  strings, monitor tests, transcript fixture.
- **Runner `main.swift`:** `--net-udp-respond <host-ip>:<host-port>` —
  the capture thread detects a UDP datagram addressed to host-ip:host-
  port and writes the synthesized echo datagram (same payload byte-exact,
  checksum recomputed with the pseudo-header) into the attachment's
  socket end VZ reads (the card-N2/N3/N4 direction); OFF by default;
  validated (requires `--net`) + banner.
- **Gates:** class A green (fmt, unit suite, transcript byte-identical,
  build/image/inspect, swift build, context, coordination ×2, mmu-debt);
  class B `tools/verify-live-net-udp.sh` PASS 4/4 on VZ; the 33-gate
  `verify-vz` aggregate 33/33 (`artifacts/m5-udp-vz-sweep.log`).
- **Docs:** march-m5 N5 row added + flipped, roadmap, status,
  gate-inventory (new live-net-udp row + 32→33 aggregate), README,
  architecture, hardware contract (no new device behavior observed),
  claim flip, log append.
- **Close-out (recorded):** the live gate's first runs exposed a REAL
  code bug, caught only by the byte-exact fixtures: the UDP
  pseudo-header's zero/protocol word was initially reversed (`0x1100`
  instead of `0x0011`) — the guest's loopback self-verified (it built
  AND verified with the same wrong sum) but every datagram failed
  verification against standard peers (the injected datagram dropped
  as badsum, the host answer dropped as badsum, and the guest's own
  send carried a nonstandard checksum); fixed (word = 0x0011) and
  re-run green 4/4. Two gate-script fixes along the way: an empty
  ARGS array hit macOS bash 3.2's `set -u` "unbound variable"
  (guarded with `${ARGS[@]+...}`), and phase 3 needed BOTH
  `--net-arp-respond` and `--net-udp-respond` (the resolve precedes
  the send). Claim-time observation: NO new device behavior — the
  46-byte datagrams travel unpadded on both directions (device len 58
  = 12-byte RX header + 46), consistent with the N3/N4 observation;
  the byte-exact captures pin question (a): the device touches no
  UDP/IP field (no offload). The used-buffer IRQ line remains
  unobserved — drain stays polled. The 33-gate aggregate re-ran green
  33/33 with the `--net-udp-respond` mode; the default VM is
  byte-identical. → ✅ done, PR #93.
