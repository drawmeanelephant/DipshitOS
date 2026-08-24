# Milestone twenty-six march — network experience (living tracker)

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts. This file holds M26's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

The network stack (M5) has ARP, IPv4, ICMP, UDP, TCP, DHCP, DNS, NAT,
and a TCP retransmission timer. FETCH.BIN and CHAT.BIN (M12) prove the
TCP client works. But there's no way to *diagnose* the network from the
shell — no ping, no connection listing, no bandwidth display. M26 makes
the network *visible* and *useful*.

**One new syscall slot (62)** — `sys_net_stats`, the network dashboard's
read-only snapshot seam (the tracker's "reads via the serial monitor
interface" premise predated the syscall era; N2/N3 land claim 7635). All
other cards use existing network and process syscalls.

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| N1 | **PING.BIN.** `ping 10.0.0.1` — sends ICMP echo requests, displays round-trip time, packet loss stats, and continuous mode (`ping -c 5 10.0.0.1`). Reports: packets sent/received/lost, min/avg/max RTT. Uses existing ICMP syscall seam (the kernel's `net ping` command reuses the same code path). | ⬜ | — | New userland app `user/src/ping.zig`. Uses existing ICMP infrastructure. Sends echo requests via UDP-like pattern (the kernel's ICMP send path). BSS: ping stats (sent/received/lost/rtt_min/rtt_max/rtt_sum). The `-c` flag limits count. Default: 5 pings, 1s interval. |
| N2 | **NETSTAT.BIN.** `netstat` — shows a dashboard of: active TCP connections (TCP, peer, port), UDP listeners (port), ARP table (IP → MAC), DHCP state (ip/mask/gw/server/lease), network interface info (IP, MAC, gateway). Updates at 1 Hz. | ✅ | claim 7635: `sys_net_stats` (slot 62) + window app; `verify-live-netstat.sh` PASS 1/1 boots (2026-08-24) | New userland app `user/src/netstat.zig` (SEGMENTED DSK3, GLOBALS pattern) + `user/src/lib/netstats.zig` (mirror + `read_stats`). `sys_net_stats(buf, len)` copies the kernel's existing pub network globals (virtio_net net_mac/net_dev/rx_*, arp.own_ip/table, tcp state+peer+counters, udp.listen+counter, dhcp state+lease) as a fixed packed snapshot through uaccess (process-snapshot pattern). 1 Hz refresh via EVENT_TIMER. |
| N3 | **HTTP fetch display.** `fetch http://site/path` — extends FETCH.BIN with a terminal output mode. When run from the shell (not from the desktop), displays the response body in the terminal with scrollback. Shows response headers and body separately. | ✅ | claim 7635: `verify-live-fetch.sh` PASS with headers-before-body ordering (2026-08-24) | `user/src/fetch.zig`: the terminal stream now buffers through the bare `\r\n\r\n` into a bounded 1 KiB header scratch, emits `--- response headers ---` then `--- response body ---` (serial markers `fetch: headers` / `fetch: body`), with the body tail of a shared TCP segment handled. Pure splitter `header_end` is host-tested. |
| N4 | **Bandwidth display.** TOP.BIN network tab showing bytes sent/received, packets, errors. Updated at 1 Hz using the existing net counters. Shows cumulative and per-second rates. | ⬜ | — | `user/src/top.zig` new tab. Uses existing `sys_procs` and monitor command data. The network tab shows: tx_bytes, rx_bytes, tx_packets, rx_packets, errors. Computed from the kernel's net counter globals. |
| N5 | **Connection manager.** `net connect ip:port` / `net disconnect` — manage TCP connections interactively from the shell. `net connect` establishes a connection and shows the state. `net disconnect` closes it. `net send data` sends through the active connection. `net recv` receives. | ⬜ | — | `kernel/src/shell.zig` new commands. Uses existing TCP syscalls (slots 30–33). The shell maintains a "current connection" state variable. Commands operate on the active connection. |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Network apps** | `user/src/ping.zig` (new) for N1. `user/src/netstat.zig` (new) for N2. `user/src/fetch.zig` (modify) for N3. `user/src/top.zig` (modify) for N4. | M18 done (scrollback for output display). |
| **B — Shell network commands** | `kernel/src/shell.zig` for N5 (connection manager). | M19 done (shell improvements). |

## Notes

1. **ABI budget:** Zero new syscall slots. All apps use existing network
   syscalls (ICMP via `net ping`, TCP via slots 30–33).
2. **BSS budget:** PING.BIN ~64 bytes (stats). NETSTAT.BIN ~512 bytes
   (dashboard state). FETCH.BIN terminal mode ~256 bytes. TOP.BIN network
   tab ~128 bytes. Shell connection state ~64 bytes. Total M26 BSS delta:
   ~1 KiB. Negligible.
3. **Gate shape:** N1: `verify-live-ping.sh` — ICMP round-trip observed.
   N2: `verify-live-netstat.sh` — dashboard output. N3:
   `verify-live-fetch-display.sh` — HTTP response in terminal. N4:
   `verify-live-top-network.sh` — bandwidth display. N5:
   `verify-live-net-connect.sh` — connection lifecycle.
4. **PING.BIN implementation:** The ICMP echo path reuses the kernel's
   existing ICMP infrastructure. The app sends echo requests through the
   kernel's `net ping` monitor command path (which already sends ICMP echo
   and prints the reply). The app wraps this with timing and statistics.
5. **Scope exclusions:** No HTTPS (no TLS stack). No HTTP server. No
   WebSocket. No network file system. No packet capture / tcpdump. This
   is diagnostics and basic interactivity, not infrastructure.
