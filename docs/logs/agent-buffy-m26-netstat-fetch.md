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

## 2026-08-24 — CI/CD failures root-caused and fixed (both PR-side and main-side)

Two CI failures surfaced after this branch's PR opened; both fixed in
commit 0b15021, pushed to the branch, and the PR re-verified green:

1. **PR #543 "Build (macOS + Swift Launcher)" failed** in FOUR module
   test binaries (machine, monitor, shell, syscall — all transitively
   include monitor.zig's tests): the monitor `syscalls` command test
   still expected `implemented=62`. Found the stale copy at
   `kernel/src/monitor.zig:7432` (my syscall.zig report test was
   updated but monitor.zig's duplicate expectation wasn't). Fixed to
   implemented=63 + the `62 sys_net_stats calls=0` row; the full
   `verify-unit-tests.sh` sweep (the exact CI script) now passes
   locally, and CI passed on the re-run (6m26s).
2. **Indexes workflow failed after EVERY main push** once PR #535
   (auto-merged) left its head branch behind: `--force-with-lease=
   refs/heads/$BRANCH:refs/heads/$BRANCH` leased against the JUST-RESET
   local branch instead of the surviving remote branch, so the push
   rejected `(stale info)`, and the plain-push fallback rejected
   (non-fast-forward) — #541/+ #542 merges both failed it, leaving the
   claim/log index tables stale on main. Fixed `.github/workflows/
   indexes.yml`: lease against the freshly fetched remote-tracking ref,
   deterministic `--force` fallback (bot-owned branch, history always
   discarded), and an explicit OPEN-PR check (merged-PR ghost branch now
   gets a fresh `gh pr create`). Rehearsed the exact push sequence
   against a scratch branch (create + second-run update both rc=0,
   scratch deleted). The fix ships with this PR; the next merge's Indexes
   run will force-update `indexes/bot-regenerate` and open a fresh
   auto-merge PR.

Verification: `bash tools/verify-unit-tests.sh` full sweep green;
`gh pr checks 543`: Build (macOS + Swift Launcher) pass 6m26s, spike
pass, site-publication pass ×2; `gh pr mergeable` still MERGEABLE.
