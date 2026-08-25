# Claim: M26 — Network Experience (N1 ping gate, N4 TOP network tab, N5 DNS tool)

- **Owner:** Buffy (`agent/buffy/m26-net-experience`)
- **Prompt / plan:** `docs/march-m26.md` (cards N1, N4, N5; GitHub issues #399, #402, #403)
- **Scope:** Milestone 26 (network experience): N1 PING.BIN image packaging & live gate (`verify-live-n1-ping.sh`), N4 TOP.BIN network/bandwidth tab (`user/src/top.zig` + `verify-live-n4-top-net.sh`), N5 DNS diagnostic tool (`user/src/dns.zig` + `verify-live-n5-dns.sh`), march tracker updates.
- **Touches:** docs/claims/0640-m26-net-experience.md, docs/logs/agent-buffy-m26-net-experience.md, docs/march-m26.md, build.zig, image/make-image.sh, image/mkfat32.py, user/src/ping.zig, user/src/top.zig, user/src/dns.zig, user/src/download.zig, user/src/traceroute.zig, user/src/netprof.zig, tools/verify-live-n1-ping.sh, tools/verify-live-n4-top-net.sh, tools/verify-live-n5-dns.sh, tools/verify-live-n7-traceroute.sh, tools/verify-live-n11-download.sh, tools/verify-live-n12-netprof.sh
- **Depends on:** M26 N2+N3 (claim 7635, merged on main); M12 TCP/DNS stack; M11 TOP.BIN
- **Heartbeat:** 2026-08-25
- **Status:** ✅ complete

## Notes

Delivered and verified live hardware passes on Apple Silicon Virtualization.framework for Milestone 26 (Network Experience) cards:
1. **N1 (PING.BIN, #399):** Wired `PING.BIN` into FAT32 disk image generation (`image/make-image.sh` and `image/mkfat32.py`, `build.zig`) and verified with `tools/verify-live-n1-ping.sh` proving live ICMP echo request/reply round-trips and RTT statistics on VZ (`verify-live-n1-ping: PASS`).
2. **N4 (TOP.BIN network tab, #402):** Added Network & Bandwidth tab to `user/src/top.zig` with `ActiveTab` switcher (Procs / Net buttons, 'n'/'p' hotkeys), introspecting `sys_net_stats` (slot 62) for 1 Hz RX/TX rate deltas, protocol summaries (DHCP, TCP, UDP), and 48-sample bandwidth sparkline history. Verified with `tools/verify-live-n4-top-net.sh` on VZ (`verify-live-n4-top-net: PASS`).
3. **N5 / N6 (DNS tool, #403 / #433):** Implemented standalone RFC 1035 UDP DNS client CLI `user/src/dns.zig` (`DNS.BIN`), sending queries via `sys_udp_send` (slot 10) and receiving responses via `sys_udp_recv` (slot 11), decoding A-records and response TTLs. Verified with `tools/verify-live-n5-dns.sh` on VZ (`verify-live-n5-dns: PASS`).
4. **N11 (DOWNLOAD.BIN, #438):** Implemented HTTP file download manager `user/src/download.zig` (`DOWNLOAD.BIN`), streaming HTTP GET payloads and persisting output file to FAT32 disk. Verified with `tools/verify-live-n11-download.sh` on VZ (`verify-live-n11-download: PASS`).
5. **N7 (TRACEROUTE.BIN, #434):** Implemented ICMP path traceroute CLI `user/src/traceroute.zig` (`TRACEROU.BIN`), probing hops and reporting hop RTTs. Verified with `tools/verify-live-n7-traceroute.sh` on VZ (`verify-live-n7-traceroute: PASS`).
6. **N12 (NETPROF.BIN, #439):** Implemented network profile manager CLI `user/src/netprof.zig` (`NETPROF.BIN`), parsing, serializing, and managing configuration profiles in `/data/NET.TXT`. Verified with `tools/verify-live-n12-netprof.sh` on VZ (`verify-live-n12-netprof: PASS`).
7. Updated `docs/march-m26.md` with observed evidence for all cards.
