# Log — agent/buffy/m5-net-dhcp-renew

Branch: `agent/buffy/m5-net-dhcp-renew` · Slug: `dhcp-renew` · Claim: [9489](claims/9489-dhcp-renew.md)

## 2026-08-12 — claim N9 (DHCP lease lifecycle: renewal + rebinding + expiry)

- N8 (claim 0351) shipped as PR #104 (`agent/buffy/m5-net-dhcp`); the
  N9 claim branch is cut from the N8 head (`e645fd3`), the established
  sequential two-PR pattern.
- Claim id 9489 via `bash tools/status/claim-id.sh
  agent/buffy/m5-net-dhcp-renew dhcp-renew`.
- Scope: the RENEWING/REBINDING states + the lease timer in
  `kernel/src/dhcp.zig` (RFC 2131 §4.4.5 — T1 = lease/2, T2 =
  lease*7/8, expiry releases the address), the two new send seams, the
  monitor's `.bound` lifecycle drive + the `dhcp=` report counters, the
  runner's `--net-dhcp-respond <ip>[:<lease>]` + `--script2-delay` /
  `--script3-delay`, the new class-B live gate
  `tools/verify-live-net-dhcp-renew.sh` (two runs: renewing+rebinding,
  expiry+recovery), the 37-gate aggregate re-run, and the
  hardware-contract/march-m5/status/gate-inventory updates.

## 2026-08-12 — close-out

- **State machine `kernel/src/dhcp.zig`:** the `renewing` / `rebinding`
  states, `now_ticks`/`bound_ticks` (the caller stamps the 1 Hz
  `timer.ticks` — the shell idle loop + `net dhcp`), T1 = lease/2 and
  T2 = lease*7/8, `enter_renewing` / `enter_rebinding` (the built
  REQUEST carries `ciaddr` = the leased IP, RFC 2131 §4.4.5),
  `expire()` (arp.own_ip cleared — the address RELEASED honestly, the
  lease record zeroed, attempts reset), the counters `renew_sent` /
  `rebind_sent` / `renewed` / `expired`, and `handle_rx` accepts the
  ACK in RENEWING/REBINDING too (the lease restarts — `bound_ticks`
  re-stamped, `renewed` counts it). 6 new host tests (19 total in the
  module): T1/T2/elapsed math, the RENEWING transition (state + the
  ciaddr-patched REQUEST byte-exact), REBINDING, expiry (release +
  attempts reset), the renewal ACK restart, an out-of-state ACK still
  malformed.
- **Seams:** `net_dhcp_send_bound` (broadcast REQUEST, src = the
  leased IP) + `net_dhcp_send_unicast` (the RENEWING REQUEST to the
  server's IP + the caller-resolved MAC — the seam resolves nothing;
  `.no_peer` when unbound).
- **Monitor:** the `net dhcp` `.bound` branch checks the elapsed time
  each invocation — expiry → release + re-DISCOVER, T2 → REBINDING
  (broadcast), T1 → RENEWING (unicast; an unresolvable server MAC
  keeps the client BOUND until T2 — RFC-compliant degradation, never
  faked); `.renewing`/`.rebinding` branches (retry the transmit once /
  wait for the renewal ACK; a pending renewal never outlives its
  lease — expiry while waiting releases the address); `now_ticks`
  stamped in `cmd_net_dhcp` + the shell idle loop; the `dhcp=` report
  line gains `,renew=,rebind=,renewed=,expired=` at the END (the N8
  gate's substring assertions stay green). NO new commands — the
  registry stays 34, help/textures unchanged.
- **Runner:** `--net-dhcp-respond <ip>[:<lease-secs>]` (lease option
  51 configurable, default 3600 — backward compatible; the ENABLED
  print keeps the N8 gate's byte-identical prefix) +
  `--script2-delay` / `--script3-delay` (the claim-6684 settle,
  flag-gated, default 0.5). One live-boot bug found and fixed: the
  script3 marker-wait was hard-capped at 40 s, but the phase-3 marker
  appears only after the phase-2 delay — the wait deadline now extends
  with a configured settle (`max(40, settle + 60)`), the default
  unchanged.
- **Class A green:** fmt, the unit suite 58/58, byte-identical
  transcript, build/image/inspect, swift build, context, coordination.
- **Live gate `tools/verify-live-net-dhcp-renew.sh` PASS on VZ — 17/17
  assertions, TWO runs.** Run A (lease 100 s, delays 55/92): the
  RENEWING UNICAST REQUEST byte-exact in the capture (dst
  02:00:00:00:00:02, src/dst IP 10.0.0.2, ciaddr 10.0.0.2 — the
  1222-B capture's frame 3) vs the REBINDING broadcast (frame 4), the
  `renewing (T1, elapsed=…)` + `rebinding (T2, elapsed=…)` lines, the
  counters `renew=1,rebind=1,renewed=2,expired=0`. Run B (lease 100 s,
  delay 106): `lease expired (elapsed=… >= lease=100)`, the released
  report (`dhcp=idle,ip=0.0.0.0,…,expired=1`), and the client
  RECOVERS (a second DISCOVER → BOUND again). Exploratory runs
  (lease 8/12) pinned the exact output lines + the capture layout
  (saved under artifacts/live-net-dhcp-renew-explore/).
- **The 37-gate `verify-vz` aggregate re-ran green 37/37**
  (artifacts/m5-net-dhcp-renew-vz-sweep.log, the live-net-dhcp-renew
  gate 259 s); the N8 gate (verify-live-net-dhcp.sh) re-ran green.
- **Docs:** hardware-contract lease-lifecycle observation `[observed]`,
  march-m5 N9 row + the agent-split bullet, status.md milestone-five
  row + gate table (37-gate), gate-inventory live-net-dhcp-renew row +
  aggregate list, claim close-out.
