# Claim: M26 N2+N3 — NETSTAT.BIN network dashboard + FETCH.BIN terminal display

- **Owner:** Buffy (`agent/buffy/m26-netstat-fetch`)
- **Prompt / plan:** `docs/march-m26.md` (cards N2 + N3; GitHub issues
  #400 + #401)
- **Scope:** M26 (userland network applications) — N2 NETSTAT.BIN (one
  new syscall `sys_net_stats` slot 62 exposing the kernel's network
  state, plus a full-window 1 Hz dashboard app) and N3 fetch display
  (headers/body separation in FETCH.BIN's terminal output).
- **Touches:** `kernel/src/syscall.zig`, `user/src/netstat.zig` (new),
  `user/src/fetch.zig`, `build.zig`, `image/make-image.sh`,
  `image/mkfat32.py`, `docs/march-m26.md`
- **Depends on:** M26 N1 (PING.BIN, PR #506) for the gate pattern;
  M12 TCP syscall seam (slots 30–33); my own M23 branch's image wiring
  fixes (PR #541, stacked lineage — this branch is cut from it, so the
  ESP wiring for APP binaries exists here too).
- **Heartbeat:** 2026-08-24
- **Status:** 🔄 in progress

## Notes

**N2 — NETSTAT.BIN.** The tracker's "reads via the serial monitor
interface" premise predates the syscall era; the honest implementation
is one new ABI slot exposing the kernel's existing pub network state —
`sys_net_stats(buf_ptr, buf_len)` (slot 62), a fixed packed snapshot
(iface MAC/IP/gateway, DHCP state + lease, TCP connection state/peer/port
+ segment counters, UDP listeners + datagram counters, ARP table, RX/TX
device counters), copied OUT through uaccess, process snapshot-row style.
NETSTAT.BIN opens a user window and renders the dashboard sections at
1 Hz (`sys_sleep` + repaint + present), mirroring CALC/EDIT window
conventions.

**N3 fetch display.** FETCH.BIN already streams the raw response to the
console (M12 N3). N3 splits the terminal output: a "--- response
headers ---" section buffered through the header terminator
(`\r\n\r\n`), then a "--- body ---" section streamed as today, with
bounded header scratch (≤ 1,024 B) and a header/body splitter that is
pure and unit-testable.

Evidence: host unit tests (snapshot layout round-trip, header/body
splitter), `tools/verify-live-netstat.sh` (window + serial markers
`netstat: ready`, `netstat: tcp`/`netstat: arp`/`netstat: udp`/
`netstat: dhcp` sections), extended `tools/verify-live-fetch.sh`
(asserts `fetch: headers` and `fetch: body` markers).