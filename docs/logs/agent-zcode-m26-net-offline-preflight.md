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
