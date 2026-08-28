# Claim: M26 N13+N14 — network-aware offline preflight for PING.BIN / FETCH.BIN

- **Owner:** zcode (`agent/zcode/m26-net-offline-preflight`)
- **Prompt / plan:** `docs/march-m26.md` rows N13/N14 (issues #440/#441
  superseded by the tracker rows; the 2026-08-27 dispatch claim 8460 was
  removed from main as stale-unmerged — this claim re-covers its Stream C
  scope against the seams that exist on main)
- **Scope:** N13 — `exec PING.BIN` / `exec FETCH.BIN` read one
  `sys_net_stats` (slot 62) snapshot before their first network operation
  and exit fast with an explicit offline diagnosis instead of burning the
  bounded timeout / printing generic send failures. N14 — the offline /
  no-route / refused cases print user-facing one-line messages
  (`ping: offline — no IP address (set one: net ip <a.b.c.d> or net dhcp)`
  &c) and distinct exit statuses, mapped from the existing bounded error
  returns; no kernel change, no new syscall slots, no timeout changes.
- **Touches:** `user/src/lib/netstatus.zig` (new), `user/src/ping.zig`,
  `user/src/fetch.zig`, `tools/verify-live-net-offline.sh` (new),
  `docs/march-m26.md`, `docs/gate-inventory.md`
- **Depends on:** — `sys_net_stats` (slot 62, M26 N2) and the userland
  mirror `user/src/lib/netstats.zig` are on main
- **Heartbeat:** 2026-08-28
- **Status:** 🔄 `agent/zcode/m26-net-offline-preflight`

## Notes

Honest bounds, stated up front:

- **Device-absence vs IP-unset are indistinguishable from EL0.** Slot 62
  carries no link flag, and `net_mac` falls back to a nonzero constant
  when no device answered, so `own_ip == 0.0.0.0` is the only honest
  offline signal. The preflight reports `offline — no IP address` for
  both; the message suggests `net ip … / net dhcp`, never guesses which.
- **No-route ≠ offline.** With an IP set but the destination absent from
  the ARP table, PING.BIN reports `no route to <ip> (resolve first:
  net arp <a.b.c.d>)` and exits fast — the kernel's
  `handle_tcp_connect`/`net_ping_request` return generic EINVAL on an
  unresolved peer, so the classification comes from the userland snapshot
  (arp_count/arp_ips), not a new errno.
- FETCH.BIN takes no arguments (fixed 10.0.0.2:80), so its preflight is
  IP-set + ARP-entry-for-10.0.0.2, same pure classifier.

Verification: host unit tests for the pure classifier + message format;
class-B gate `tools/verify-live-net-offline.sh` boots WITHOUT `--net`,
asserts the fast offline exits (no 30 s hang, exit statuses distinct),
then boots WITH `--net` + responders and asserts the normal paths still
pass (the N1/N3 regressions stay green).
