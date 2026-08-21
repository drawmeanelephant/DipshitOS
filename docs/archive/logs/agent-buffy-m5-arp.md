# Log — agent/buffy/m5-arp

Branch: `agent/buffy/m5-arp` · Slug: `arp` · Claim: [7293](claims/7293-arp.md)
Prompt: [m5-arp-prompt](m5-arp-prompt.md) (PR #88) · Started from merged main `c9fcb68` (PR #87).

## 2026-08-11 — claim + implementation

- **Claim:** branch `agent/buffy/m5-arp` from the N3 prompt commit; claim
  ID 7293 via `tools/status/claim-id.sh`; claim doc + this log +
  `refresh-indexes.sh`.
- **`kernel/src/arp.zig` (new):** pure RFC 826 logic — dotted-quad parse,
  build_request / build_reply (byte-exact fixtures), classify
  request/reply/not-ARP, bounded 4-slot BSS table (upsert + drop-oldest
  cursor), counters (requests sent / replies answered / replies learned /
  dropped / reply TX failures). Host-tested in isolation.
- **`kernel/src/virtio_net.zig`:** RX drain now dispatches ARP — a
  request for our static IP is answered (reply built in `tx_staging` +
  `net_send`, one-request-at-a-time), a reply is learned into the table;
  `net_arp_request(target_ip)` transmits the resolve request; the `net`
  report gains `ip=` + `arp=` counters. Mock-transport wiring tests: ARP
  request on the RX ring → byte-exact reply on TX; ARP reply → table
  learn.
- **`kernel/src/monitor.zig` + `kernel/src/shell.zig`:** `net ip
  <a.b.c.d>` (prints the `net ip: ip=<a.b.c.d>` injection marker), `net
  arp [<a.b.c.d>]` (table + counters / resolve), report line, help +
  usage strings, monitor tests, transcript fixture.
- **Runner `main.swift`:** `--net-arp-respond <host-ip>` — the capture
  thread detects an ARP request datagram and writes the synthesized reply
  (host MAC 02:00:00:00:00:02 @ the IP) into the attachment's socket end
  VZ reads (the card-N2 direction); OFF by default; validated (requires
  `--net`) + banner.
- **Gates:** class A green (fmt, unit suite, transcript byte-identical,
  build/image/inspect, swift build, context, coordination ×2, mmu-debt);
  class B `tools/verify-live-arp.sh` PASS 3/3 on VZ; the 30-gate
  `verify-vz` aggregate 30/30 (`artifacts/m5-arp-vz-sweep.log`).
- **Docs:** march-m5 N3 row flip, roadmap, status, gate-inventory (new
  live-net-arp row + 29→30 aggregate), README, architecture, hardware
  contract (no new device behavior observed), claim flip, log append.
- **Live gate debug (recorded):** the first gate runs showed the captures byte-exact but the serial greps empty — the guest executes a forwarded script BURST in tens of ms while the host-side injection round trip takes ~30 ms, so observation commands in the same burst ALWAYS beat the frame (a marker that appears mid-script cannot use the boot-time rx-armed margin). Two fixes: the `--net-inject` marker poll tightened 0.5s→20ms (the frame then lands ≤25 ms after the marker), and the gate uses the `--script2` second phase (0.5s settle after the ready marker) for the observation commands — deterministic, not a sleep race. The runner's `--net-inject` marker mechanism itself was verified sound (thread-start + marker-match timing probes showed the poll loop fires within one 20ms tick of the marker appearing in the serial file).
- **Docs:** march-m5 N3 row flip + N3 ownership, roadmap (ARP bullet + surface-table Network row + `--net-arp-respond` in the host surface), status (milestone-five row + gate table + 29→31-gate aggregate), gate-inventory (live-net-arp row + GATE line + the verify-vz aggregate listing), README (virtio_net line + new arp.zig line), architecture (ARP section), hardware-contract (`[observed]`: the device delivers/transmits the 42-byte ARP frames UNPADDED, below the Ethernet 60-byte minimum — no new device behavior otherwise), claim flip, log append, refresh-indexes.
- **PR:** #89 → main.
