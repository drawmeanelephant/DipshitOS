# Log — agent/buffy/m26-netstat-fetch

## 2026-08-24 — claim 2799 filed: M26 N2+N3 (NETSTAT.BIN + fetch display)

- **Status:** 🔄 — kernel `sys_net_stats` slot 62 + NETSTAT.BIN + FETCH
  terminal headers/body split.
- **Branch:** `agent/buffy/m26-netstat-fetch` (cut from
  `agent/buffy/m23-text-editor` — carries the PR #541 ESP image-wiring
  fixes this work also needs).
- **Collisions checked:** no ACTIVE claims on M26 cards; issues #400/#401
  open and unclaimed; the only other M26 claim is N1 (PING.BIN, merged
  PR #506). M23 claim 7746 (same owner) is ✅ done.
- **Design notes:**
  - The tracker's "reads via the serial monitor interface" premise
    predates the syscall era — `sys_net_stats` (slot 62) is the one
    honest ABI amendment, exposing the kernel's existing pub network
    globals (virtio_net net_mac/net_dev.tx_*/rx_*, arp.own_ip/table,
    tcp.state/peer_ip/peer_port + counters, udp.listen + counters,
    dhcp.state/lease_*) as a fixed packed snapshot.
  - NETSTAT.BIN: CALC/EDIT-style window app, 1 Hz refresh via
    sys_sleep + win_fill/present.
  - FETCH.BIN: bounded header scratch (≤ 1 KiB) + pure header/body
    splitter with serial markers `fetch: headers` / `fetch: body`.
- **Next:** kernel syscall + tests, apps, image wiring, gates.