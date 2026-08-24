# Log — agent/buffy/m26-netstat-fetch

## 2026-08-24 — claim 7635 filed: M26 N2+N3 (NETSTAT.BIN + fetch display)

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
## 2026-08-24 — claim 7635 done: both M26 cards live-verified

- **sys_net_stats (slot 62):** fixed packed snapshot of the kernel's
  existing pub network state (interface MAC/IP/GW, DHCP state+lease,
  TCP state/peer/counters, UDP listeners/counters, ARP table, RX/TX
  device counters); uaccess copy-out, whole-snapshot truncation,
  EFAULT contract; implemented_count 62→63; layout pinned in kernel
  tests + mirrored in `user/src/lib/netstats.zig` (dual-sided offset
  pins).
- **NETSTAT.BIN:** DSK3 segmented window dashboard (GLOBALS pattern),
  1 Hz EVENT_TIMER refresh, all six sections drawn; one-time serial
  markers `netstat: section iface/dhcp/tcp/udp/arp/counters` +
  `netstat: ready`.
- **FETCH.BIN N3:** bounded 1 KiB header scratch, `header_end` splitter
  (pure, host-tested), `--- response headers ---` / `--- response body
  ---` sections with serial markers + ordering assertion; fixed a real
  bug where header+body bytes sharing one TCP segment dropped the body
  tail (the live gate caught it: the responder's 46-byte response fits
  one chunk).
- **Image wiring:** discovered + fixed the same latent make-image.sh /
  mkfat32.py gap for RESMON.BIN/DEVCONS.BIN (build.zig passed them at
  args 39/40 but neither script wired them; PING_BIN="${39}" was a
  mislabeled alias of RESMON and never landed). All three now land on
  the ESP; netstat is DSK3, resmon/devcons DSK1.
- **Gates:** `tools/verify-live-netstat.sh` (new) PASS 1/1 boots on
  Apple silicon: banner, all six section markers, `netstat: ready`,
  screenshot at artifacts/netstat-screen-5s. `verify-live-fetch.sh`
  extended with N3 markers + headers-before-body byte-order check —
  PASS.
- **Tests:** 428/428 kernel syscall tests (incl. the new net-stats
  layout/marshal test), 35 fetch, 38 netstat, 2 netstats-lib; `zig
  fmt --check` clean; `verify-coordination.sh` ok.
- **Touches:** kernel/src/syscall.zig, user/src/netstat.zig (new),
  user/src/lib/netstats.zig (new), user/src/lib/ui.zig, user/src/
  fetch.zig, build.zig, image/make-image.sh, image/mkfat32.py,
  tools/verify-live-netstat.sh (new), tools/verify-live-fetch.sh,
  docs/march-m26.md.
