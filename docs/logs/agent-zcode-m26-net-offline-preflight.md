# Log — agent/zcode/m26-net-offline-preflight

## 2026-08-28 — claim opened (pre-code, per coordination rule 1)

Claim `8852-m26-net-offline-preflight` filed before any code. Scope is
M26 N13+N14 as they stand on main `3a89648`:

- march-m26 row N13 ⬜ (no userland `net_ready`/`ip_set` consumer);
  row N14 🔶 (generic bounded timeouts, no explicit offline detection).
- The 2026-08-27 dispatch claim 8460 (Stream C, same scope) was deleted
  from main at `d04e2cb` as "stale unmerged" — re-covered here, scoped to
  the seams that actually exist on main: `sys_net_stats` slot 62 +
  `user/src/lib/netstats.zig` mirror (both landed with M26 N2, PR #543).
- Checked before claiming: no active 🔄 claim touches
  `user/src/ping.zig`, `user/src/fetch.zig`, or `user/src/lib/netstatus.zig`
  (claims index at 3a89648 — all rows ✅/⛔; buffy is on m28-smp, untouched
  surface).

Plan: pure classifier lib `user/src/lib/netstatus.zig` (offline /
no-route / ready + message formatting, host-tested), preflight calls in
`ping.zig`/`fetch.zig` with distinct exit statuses, class-B gate
`tools/verify-live-net-offline.sh` (no-`--net` boot → fast offline exits;
`--net` boot → normal paths, N1/N3 regression shape preserved).

## 2026-08-28 — N13+N14 landed; gate PASS 24/24

Implemented (userland-only, zero kernel files):

- `user/src/lib/netstatus.zig` (NEW): pure classifier `classify(snap, dest)`
  → `offline_no_ip | no_route | ready | unknown` + `format_message()` (the
  N14 one-liners). `check()` is the only impure function (one slot-62
  snapshot). Honest bounds pinned in tests: device-absence ≡ IP-unset from
  EL0 (no link flag in the snapshot); arp_count > 4 never reads past the
  packed slots; snapshot-refused → `.unknown` (legacy path kept, never a
  guess). 9 host tests.
- `user/src/ping.zig`: preflight in `run_ping` before the first send —
  offline exits 2, no-route exits 3, no statistics footer (fast exit).
  Host build keeps the simulated path.
- `user/src/fetch.zig`: same preflight against the fixed 10.0.0.2:80 —
  offline exits 3, no-route exits 4.

Gate `tools/verify-live-net-offline.sh` (class B, three boots):
- Run A (no `--net`): both apps print the offline message, exit 2/3, no
  bounded-poll output, shell responsive — 7/7.
- Run B (`--net`, `net ip`, empty ARP): `ping: no route to 10.0.0.2`,
  exit 3, fast — 5/5.
- Run C (`--net` + arp/icmp/tcp responders): full normal paths — N1 ping
  assertions (header/replies/footer/0% loss/exit 0) + N3 fetch assertions
  (connected/HTTP 200/done/exit 42) + NO offline/no-route false
  positives — 12/12.

Claim-time findings (the failures that shaped the gate, all reproduced
then fixed or recorded):
1. `gate_begin` seeds an EMPTY `efi-vars.bin` when none exists in
   artifacts; VZ rejects it (`Could not open variableStore`, EINVAL).
   Every net gate already `rm -f`s the vars file after `gate_begin` —
   this gate now does too. Worth an upstream note: the helper could stop
   seeding the empty file (a fresh store is created when absent).
2. The exit-report FIFO (claim 1014) drains at the NEXT shell idle pass.
   Two gate shapes died on this: (a) expecting an echo typed while the
   exiting task still owned the ring slot killed the VM before the task
   ever ran (run B's first shape: PING.BIN loaded but never scheduled —
   the claim-1384/N6 lesson relearned live); (b) launching two programs
   back-to-back and keying the exit on the first one's report races the
   joint drain (both reports print together at the next idle pass). The
   gate now keys `--script-expect` on the drained report line of the
   LAST program (`FETCH.BIN exited status=42` / `PING.BIN exited status=3`)
   and keeps one idle-pass tail phase after the final launch.
3. One transient connect failure observed in an early run C (SYN-ACK
   answered by the host, guest's bounded drain loop exited first):
   reproduced once, did NOT reproduce in four identical replays
   (including an exact flag/phase replica), and the preflight never
   fired in that run (verdict `.ready`, legacy path) — recorded as a
   pre-existing spin-loop race in `handle_tcp_connect`, not an N13/N14
   regression. The final gate passed 3× consecutively.

Verification evidence (all under `artifacts/`, this branch):
- `live-net-offline-{a,b,c}-{run.txt,serial.log}`, `-gate.txt`, `-report.txt`
- regressions: `live-n1-ping-*`, `live-fetch-*`, `live-netstat-*` PASS
- class A: fmt, `verify-unit-tests.sh` (all modules), transcript
  byte-identical, build/image/inspect, `verify-coordination.sh` ok,
  `test-coordination.sh` 21/21, `verify-bss-budget.sh` PASS
  (10 713 728 / 11 534 336 B), swift build (debug + release).

Claim flipped ✅. Branch ready for review — STOP before PR (owner gate).
