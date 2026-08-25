# Log — `agent/buffy/m26-net-experience`

### 2026-08-25 — claim 0640: Milestone 26 (Network Experience) Complete

Implemented and verified the remaining cards of Milestone 26 (Network Experience: N1 ping gate, N4 TOP.BIN network tab, N5 DNS diagnostic tool):

- **N1 (`PING.BIN`, issue #399):**
  - Updated `user/src/ping.zig` timing loop to use `ui.yield_task()` for non-blocking ICMP reply polling and `ui.sleep_ticks(1)` for 1-second cadence.
  - Wired `PING.BIN` into `build.zig`, `image/make-image.sh`, and `image/mkfat32.py`.
  - Created class-B live hardware verification gate `tools/verify-live-n1-ping.sh`.
  - Executed on Apple silicon VZ: **PASS (`verify-live-n1-ping: PASS`)**, confirming 3 ICMP echo request/reply round-trips against host `--net-icmp-respond 10.0.0.2` with 0% packet loss and min/avg/max RTT statistics.

- **N4 (TOP.BIN Network & Bandwidth tab, issue #402):**
  - Extended `user/src/top.zig` with `ActiveTab { procs, network }` switcher, toolbar toggle buttons (`Procs` and `Net`), and keyboard shortcuts (`n`/`p`).
  - Added network inspection using `lib/netstats.zig` (`sys_net_stats`, slot 62):
    - Interface & protocol view: IP, gateway, MAC, DHCP state and lease, TCP state and peer, UDP listener count.
    - Traffic counters & rates: RX/TX 1 Hz transfer rates (B/s), frame/byte totals, error counters, TCP segment counts.
    - 48-sample bandwidth sparkline history graph with peak rate indicators.
  - Added unit test suite in `user/src/top.zig` (49/49 tests pass).
  - Created class-B live hardware verification gate `tools/verify-live-n4-top-net.sh`.
  - Executed on Apple silicon VZ: **PASS (`verify-live-n4-top-net: PASS`)**, confirming window open (id=3), tab switching via HID input chords `n,r,p`, network statistics introspection via slot 62 (`62 sys_net_stats calls=3`), and clean return to process tab.

- **N5 (`DNS.BIN` diagnostic tool, issue #403):**
  - Created standalone RFC 1035 UDP DNS client CLI `user/src/dns.zig` (`DNS.BIN`).
  - Implemented query encoder (`encode_query`), domain name compression pointer skipper, and response parser (`parse_response`) extracting resolved IPv4 addresses and TTLs.
  - Managed EL0 UDP socket communication via `ui.udp_listen`, `ui.udp_send` (slot 10), and `ui.udp_recv` (slot 11) with ARP resolution retry polling.
  - Wired `DNS.BIN` into `build.zig`, `image/make-image.sh`, and `image/mkfat32.py`.
  - Added unit test suite in `user/src/dns.zig` (37/37 tests pass).
  - Created class-B live hardware verification gate `tools/verify-live-n5-dns.sh`.
  - Executed on Apple silicon VZ: **PASS (`verify-live-n5-dns: PASS`)**, querying `example.com` against host `--net-dns-respond 10.0.0.2:53` and receiving resolved `93.184.216.34`.

- **Documentation & Coordination:**
  - Updated `docs/march-m26.md` with observed evidence for all cards (N1, N2, N3, N4, N5 all ✅).
  - Updated `docs/claims/0640-m26-net-experience.md` to `✅ complete`.

### 2026-08-25 — Extended Milestone 26 Cards (N7 Traceroute, N11 Download, N12 Netprof)

- **N7 (`TRACEROUTE.BIN` / `TRACEROU.BIN`, issue #434):**
  - Created `user/src/traceroute.zig` implementing ICMP hop-by-hop route traceroute CLI. Probes destinations, measures hop RTTs, formats reports.
  - Wired into `build.zig`, `image/make-image.sh`, and `image/mkfat32.py`.
  - 35/35 unit tests pass (`zig test user/src/traceroute.zig`).
  - Created and executed class-B live gate `tools/verify-live-n7-traceroute.sh`: **PASS (`verify-live-n7-traceroute: PASS`)** with 9/9 assertions on Apple silicon VZ.

- **N11 (`DOWNLOAD.BIN`, issue #438):**
  - Created `user/src/download.zig` implementing HTTP file download manager saving response payload to persistent disk storage.
  - Wired into `build.zig`, `image/make-image.sh`, and `image/mkfat32.py`.
  - 37/37 unit tests pass (`zig test user/src/download.zig`).
  - Created and executed class-B live gate `tools/verify-live-n11-download.sh`: **PASS (`verify-live-n11-download: PASS`)** with 10/10 assertions on Apple silicon VZ.

- **N12 (`NETPROF.BIN`, issue #439):**
  - Created `user/src/netprof.zig` implementing network configuration profile manager CLI persisting profiles to `/data/NET.TXT`.
  - Wired into `build.zig`, `image/make-image.sh`, and `image/mkfat32.py`.
  - 35/35 unit tests pass (`zig test user/src/netprof.zig`).
  - Created and executed class-B live gate `tools/verify-live-n12-netprof.sh`: **PASS (`verify-live-n12-netprof: PASS`)** with 9/9 assertions on Apple silicon VZ.

