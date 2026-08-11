# Log — agent/buffy/m5-ipv4

Branch: `agent/buffy/m5-ipv4` · Slug: `ipv4` · Claim: [0148](claims/0148-ipv4.md)
Prompt: [m5-ipv4-prompt](m5-ipv4-prompt.md) (PR #90) · Branched from the N3 claim head `5ed7eab` (PR #89, claim 7293 — the ARP seam is the foundation; the N4 PR base catches up when #89 merges).

## 2026-08-11 — claim + implementation

- **Claim:** branch `agent/buffy/m5-ipv4` from the N3 claim head, with the
  N4 prompt commit cherry-picked; claim ID 0148 via
  `tools/status/claim-id.sh`; claim doc + this log + `refresh-indexes.sh`.
- **`kernel/src/ipv4.zig` (new):** pure RFC 791/792 logic — 20-byte IPv4
  header parse/build, RFC 1071 one's-complement checksums (host-tested
  against known vectors), fragment / protocol / checksum / short-length
  drops (counted), ICMP echo request/reply with byte-exact id/seq/payload
  echo. Host-tested in isolation.
- **`kernel/src/virtio_net.zig`:** the RX drain's ethertype dispatch gains
  0x0800 → ipv4 (beside the N3 ARP dispatch): an ICMP echo request for
  our static IP is answered (reply built in `tx_staging` with a ZEROED
  virtio_net_hdr prefix + `net_send`, one-request-at-a-time); a fragment
  or non-ICMP protocol is dropped with a counter. `net_ping(target_ip)`
  transmits the echo request. Mock-transport wiring tests: echo request
  on the RX ring → byte-exact reply on TX; a fragment → drop counter.
- **`kernel/src/monitor.zig` + `kernel/src/shell.zig`:** `net ping
  <a.b.c.d>` subcommand (refuses honestly when the peer is unresolved),
  `net` report gains the ipv4/icmp counters, help/usage strings, monitor
  tests, transcript fixture.
- **Runner `main.swift`:** `--net-icmp-respond <host-ip>` — the capture
  thread detects an ICMP echo request datagram addressed to host-ip and
  writes the synthesized echo reply (swap src/dst, type 0, recomputed
  checksums, echoed id/seq/payload) into the attachment's socket end VZ
  reads (the card-N2/N3 direction); OFF by default; validated (requires
  `--net`) + banner.
- **Gates:** class A green (fmt, unit suite, transcript byte-identical,
  build/image/inspect, swift build, context, coordination ×2, mmu-debt);
  class B `tools/verify-live-net-icmp.sh` PASS 3/3 on VZ; the 32-gate
  `verify-vz` aggregate 32/32 (`artifacts/m5-ipv4-vz-sweep.log`).
- **Docs:** march-m5 N4 row flip, roadmap, status, gate-inventory (new
  live-net-icmp row + 31→32 aggregate), README, architecture, hardware
  contract (no new device behavior observed), claim flip, log append.
- **PR:** #91 → main.
- **Close-out (recorded):** the live gate's first fixture run silently
  built the injected echo request with ICMP type 0x00 (the type byte was
  never set in the generator) — the guest HONESTLY classified it as a
  reply (it WAS one: `pong=1 seq=22136`), never answered, and the phase
  1/3 counters stayed 0; the fixture was fixed (type 0x08) and the gate
  re-ran green 3/3. Claim-time observation: NO new device behavior — the
  46-byte IPv4/ICMP frames travel unpadded on both directions (device
  len 58 = 12-byte RX header + 46; the capture holds the exact 46-byte
  frames), consistent with N3's sub-60-byte observation; the byte-exact
  captures also pin question (a): the device touches NO IP/ICMP field
  (no offload). The used-buffer IRQ line remains unobserved — drain
  stays polled. `net ping` needed a `.no_peer` SendResult (an echo has a
  unicast dst — resolve first). The 32-gate aggregate re-ran green
  32/32 with the `--net-icmp-respond` mode; the default VM is
  byte-identical. → ✅ done, PR #91.
