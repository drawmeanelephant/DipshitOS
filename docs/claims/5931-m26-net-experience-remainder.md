# Claim: M26 — Network Experience Remainder (N8 net status, N9 live netstat, N10 error UX, N13/N14 offline status, N15 net log, N16 net route)

- **Owner:** Buffy (`agent/buffy/m26-net-experience`)
- **Prompt / plan:** `docs/march-m26.md` (cards N8, N9, N10, N13, N14, N15, N16; GitHub issues #435, #436, #437, #440, #441, #442, #443)
- **Scope:** Milestone 26 (network experience): N8 `net status` monitor command, N9 live connection viewer in `NETSTAT.BIN`, N10 human-readable network error UX, N13/N14 offline network status handling, N15 `net log` kernel event ring buffer & monitor viewer, N16 `net route` routing table inspection, and class-B verification gate (`tools/verify-live-n8-netstatus.sh`).
- **Touches:** docs/claims/5931-m26-net-experience-remainder.md, docs/logs/agent-buffy-m26-net-experience.md, docs/march-m26.md, kernel/src/net_log.zig, kernel/src/monitor.zig, kernel/src/dhcp.zig, kernel/src/tcp.zig, kernel/src/arp.zig, user/src/fetch.zig, user/src/ping.zig, user/src/netstat.zig, tools/verify-live-n8-netstatus.sh
- **Depends on:** M26 baseline (claim 0640 / claim 7635); M5 virtio-net / TCP / DHCP / ARP stack
- **Heartbeat:** 2026-08-25
- **Status:** ✅ complete

## Notes

Rounding out all remaining open issues of Milestone 26 (Network Experience) to complete the milestone:
1. **N8 (net status, #435):** Monitor subcommand printing summary of IP, Gateway, DNS, DHCP state, and connectivity.
2. **N9 (live connection viewer, #436):** Extend `NETSTAT.BIN` with live state refresh and transitions.
3. **N10 (error UX, #437):** Standardized user-facing error strings across network stack and apps.
4. **N13/N14 (network-aware app status & offline handling, #440, #441):** Check link and IP status before operations; immediate failure without hang when offline.
5. **N15 (net log, #442):** Bounded kernel network log ring buffer capturing DHCP/TCP/ARP events; viewable via `net log`.
6. **N16 (net route, #443):** Monitor command inspecting active routing table.
