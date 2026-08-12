# Claim: Milestone five, card N9 — DHCP lease lifecycle: renewal (RENEWING/REBINDING) + expiry

- **Owner:** buffy (`agent/buffy/m5-net-dhcp-renew`)
- **Prompt / plan:** closes the honest bound N8 recorded ("no
  renewal/rebind/lease-expiry — the lease time is recorded, not
  enforced") — the RFC 2131 §4.4.5 lease lifecycle on the N5/N6 layer.
  N1 (claim 1373), N2 (6076), N3 (7293), N4 (0148), N5 (8552), N6
  (1384), N7 (4678) and N8 (0351) are DONE (N8 is the open PR #104);
  this card branches from the N8 claim head `e645fd3`. A GUEST
  PROTOCOL card — **NO ADR 0007 change, NO user program, NO new
  commands** (the `net` registry stays 34; the state machine + the
  `dhcp=` report line grow).
- **Scope:** (1) `kernel/src/dhcp.zig` gains the RENEWING / REBINDING
  states + the lease timer: `now_ticks`/`bound_ticks` (the timer is 1
  Hz — `timer.ticks`, seconds), `t1 = lease/2` and `t2 = lease*7/8`
  (RFC 2131 §4.4.5), `elapsed()`, `enter_renewing` / `enter_rebinding`
  (the built REQUEST now carries `ciaddr` = the leased IP, RFC 2131
  §4.4.5), `expire()` (state → idle, `arp.own_ip` cleared — the
  address is released honestly — attempts reset for a fresh INIT), and
  the counters `renew_sent` / `rebind_sent` / `renewed` / `expired`.
  `handle_rx` accepts the ACK in RENEWING/REBINDING too (the lease
  restarts — `bound_ticks = now_ticks`, `renewed += 1`). (2)
  `virtio_net.zig`: `net_dhcp_send_bound` (broadcast REQUEST, src =
  the leased IP) and `net_dhcp_send_unicast` (the RENEWING REQUEST to
  the server's IP + MAC — no ARP lookup performed by the seam; the
  caller resolves it). (3) monitor: the `net dhcp` `.bound` branch
  checks the elapsed time each invocation (T1 → RENEWING unicast, T2 →
  REBINDING broadcast, expiry → released); `.renewing`/`.rebinding`
  branches (transmit the built REQUEST once / wait for the renewal
  ACK); `now_ticks` stamped by the shell idle loop + `net dhcp`; the
  `dhcp=` report line gains `,renew=,rebind=,renewed=,expired=` at the
  END (the N8 gate's substring assertions stay green). (4) runner:
  `--net-dhcp-respond <lease-ip>[:<lease-seconds>]` (lease defaults to
  3600 — backward compatible; the OFFER/ACK option 51 carries the
  configured lease) and `--script2-delay <secs>` / `--script3-delay
  <secs>` (the claim-6684 settle becomes configurable — flag-gated,
  default 0.5 — so a gate can wait past T1/T2/expiry deterministically).
  (5) the new class-B live gate `tools/verify-live-net-dhcp-renew.sh`,
  TWO runs: Run A (renewing + rebinding — lease 80 s, delays 45 s / 74
  s: the RENEWING unicast REQUEST is byte-assertable in the capture —
  dst MAC 02:00:00:00:00:02, dst IP 10.0.0.2, ciaddr = the lease — vs
  the REBINDING broadcast); Run B (expiry — delay 85 s: `lease expired`
  + the address released (ip=0.0.0.0) + the client RECOVERS with a
  re-DISCOVER → bound again). (6) the FULL 36-gate `verify-vz`
  aggregate stays green (the N8 gate's fixed-lease assertions keep
  matching); the N6 seam regression green. (7) docs: hardware-contract
  lease-lifecycle observation `[observed]` with saved logs, the
  march-m5 N9 row, status / gate-inventory (37-gate aggregate).
- **Depends on:** N1–N8 DONE (the N8 DHCP client + `net_dhcp_send` +
  the runner's `--net-dhcp-respond` are the baseline). Branched from
  the N8 claim head `e645fd3` (the open PR #104) — the sequential
  two-PR pattern.
- **Status:** ✅ DONE 2026-08-12 on `agent/buffy/m5-net-dhcp-renew` (from the N8 claim head `e645fd3` — PR #104; claim PR pending)

## Notes

**Why this card:** N8 recorded the honest bound — the lease time was
recorded but never enforced. A real DHCP client must renew before T1,
rebind before T2, and release the address at expiry (RFC 2131 §4.4.5).
This card closes that bound on the SAME monitor-driven polled-drain
contract: each `net dhcp` invocation checks the elapsed lease time and
advances the lifecycle one step. The timer is the guest's 1 Hz generic
timer (`timer.ticks` — seconds), so the lease math is integer seconds.

**The claim-time question:** whether the RENEWING unicast (the server
MAC must be in the ARP table — the seam resolves nothing) works through
the file-handle attachment when the server id = the lease IP (the N8
fixture). The guest resolves the server with `net arp 10.0.0.2` (the
host's `--net-arp-respond` answers 02:00:00:00:00:02), and the
responder's ports-only datagram check answers a unicast REQUEST. If the
server MAC is unresolvable, the client honestly stays BOUND until T2
(REBINDING by broadcast — RFC-compliant degradation) — recorded, never
faked.

## Close-out (2026-08-12)

**All scope items done; the live gate PASS on VZ (17/17 assertions, TWO
runs).**

**Run A — the renewal rungs (9/9):** lease 100 s (`--net-dhcp-respond
10.0.0.2:100`), `--script2-delay 55` then `--script3-delay 92`. The
guest bound, resolved the server MAC (`net arp 10.0.0.2` →
02:00:00:00:00:02), and at elapsed ~57 (T1 = 50) RENEWed: `net dhcp:
renewing (T1, elapsed=55) request sent to the server (298 bytes)` —
the UNICAST REQUEST byte-exact in the capture (dst 02:00:00:00:00:02,
src/dst IP 10.0.0.2, ciaddr 10.0.0.2 — the 1222-B capture's frame 3,
pinned by the claim-time exploratory capture) — the ACK restarted the
lease (`renewed=1`). At elapsed ~93-95 (T2 = 87) it REBINDed: `net
dhcp: rebinding (T2, elapsed=…) request sent (298 bytes)` — the
BROADCAST REQUEST (frame 4, dst ff:ff:ff:ff:ff:ff). The counters
`renew=1,rebind=1,renewed=2,expired=0`.

**Run B — expiry + recovery (8/8):** lease 100 s, `--script2-delay
106`. At elapsed ~108-109 ≥ lease the client EXPIRED: `net dhcp: lease
expired (elapsed=… >= lease=100) — address released, re-DISCOVER with
`net dhcp`` — the address RELEASED honestly (the report shows
`dhcp=idle,ip=0.0.0.0,…,expired=1`; `arp.own_ip` cleared), and the
client RECOVERED: a fresh DISCOVER (a second 286-byte broadcast in the
capture) → OFFER → REQUEST → ACK → BOUND again with the same lease.

**One live-boot issue found and fixed at claim time (never assumed):**
`--script3-after`'s marker wait was hard-capped at 40 s from the
forwarder start, but the phase-3 marker legitimately appears only after
the phase-2 delay (55 s) — the script3 forwarder gave up and the gate
failed honestly with the runner's own ERROR line. Fixed: the
forwarder's wait deadline extends with a configured settle
(`max(40, settle + 60)`) — the default 40 s is unchanged for every
existing gate.

**Evidence:** `tools/verify-live-net-dhcp-renew.sh` PASS on VZ — 17/17
assertions (Run A: runner rc, the bound lease, the renewing (T1) line,
the rebinding (T2) line, the counters, the host's NET-DHCP ACK lines,
the capture byte-exact at the load-bearing offsets, the gate echo, the
runner flag; Run B: runner rc, the lease-expired line, the released
report, the re-DISCOVER, the recovery BOUND, the gate echo, the runner
flag, the capture ≥ 870 B); evidence under `artifacts/live-net-dhcp-renew-*`
(runner outputs, serial logs, the captures) and
`artifacts/live-net-dhcp-renew-explore/` (the exploratory lease-8 /
lease-12 runs that pinned the exact output lines and the capture
layout). Full class A green (fmt, the unit suite 58/58 incl. the 6 new
lifecycle tests — T1/T2 math, the RENEWING/REBINDING transitions with
ciaddr, expiry releasing the address + attempts reset, the renewal ACK
restarting the lease, an out-of-state ACK still malformed; byte-identical
transcript, build/image/inspect, swift build, context, coordination);
the N8 gate (verify-live-net-dhcp.sh) re-ran green — the lifecycle
counters append AFTER `mal=` and the `--net-dhcp-respond` ENABLED
prefix is unchanged; the **37-gate `verify-vz` aggregate re-ran green
37/37** (evidence `artifacts/m5-net-dhcp-renew-vz-sweep.log`, the
live-net-dhcp-renew gate 259 s) — proof the N9 changes left the default
VM byte-identical. The next rung: the roadmap's TCP sketch (a FUTURE
card — out of scope here).
