# Claim: audit follow-up 3 — the autonomous DHCP lease lifecycle (issue #119)

- **Owner:** buffy (`agent/buffy/audit-followup-3-dhcp-autonomy`)
- **Prompt / plan:** the 2026-08-15 strong audit of `main` `3013b17` — issues
  #115–#123 filed; this claim is the network-autonomy tranche per the
  maintainer's go-ahead (audit rule 12 lifted). Issue #119: "DHCP
  renewal/rebinding/expiry … only when a shell command happens to poke it"
  — the N9 enforced lease ran on demand while `tcp.poll_rto` was already
  autonomous.
- **Scope:** (1) `kernel/src/virtio_net.zig` — `net_dhcp_poll()`: the
  autonomous lifecycle step (the pure `dhcp.step_lifecycle` decision +
  the apply/transmit glue) driven from the shell idle loop AFTER the RX
  drain, printing the SAME transition lines `net dhcp` prints; (2)
  `kernel/src/dhcp.zig` — `step_lifecycle()`: the pure RFC 2131 §4.4.5
  decision AND the missing RENEWING→REBINDING escalation at T2 (a client
  still in RENEWING when the unicast renewal went unanswered escalates to
  the broadcast REQUEST); (3) `kernel/src/monitor.zig` +
  `kernel/src/shell.zig` — the idle-loop wiring + the transition prints;
  (4) `host/vm-runner` — the `--net-dhcp-respond-norenew` /
  `--net-dhcp-respond-norebind` refusal knobs (a deterministic host that
  can refuse renewals, so the REBINDING/expiry rungs are testable against
  the autonomous client); (5) the reworked N9 renew gate + the new
  `verify-live-net-dhcp-autonomous.sh` class-B gate, both registered in
  the `verify-vz` aggregate.
- **Depends on:** — (the N9 lease clock + counters, claim 9489, are the
  base this builds on).
- **Status:** 🔄 agent/buffy/audit-followup-3-dhcp-autonomy

## Notes

The rework discovered an honest RFC consequence: with an always-answering
server an autonomous client RENEWS at every T1 forever and never reaches
T2 — the old gate only saw a REBIND because no command ran between T1 and
T2 (the command-gated behavior itself). The refusal knobs make the host
refuse renewals deterministically, so the gate proves the real rungs:
T1 RENEW (unicast REQUEST, refused) → T2 ESCALATION to REBINDING
(broadcast REQUEST, ACKed) in the renew run, and the refused REBINDING →
expiry → release → re-DISCOVER recovery in the expiry run. The
re-DISCOVER after expiry stays command-triggered (the bounded handshake;
the client honestly drops to idle at expiry — documented, not a gap).

## Evidence

- `dhcp.step_lifecycle` host tests: the T1/T2/expiry thresholds, the
  RENEWING→REBINDING escalation at T2, expiry beats the wait in
  REBINDING, the handshake states never auto-advance, zero-lease never
  fires.
- Live gate `verify-live-net-dhcp-renew.sh` (class B, VZ, reworked):
  Run A — the poll RENEWed at T1 (unicast REQUEST, 298 B, byte-exact in
  the 1222-B capture), the host REFUSED it (its own NET-DHCP line), and
  at T2 the client ESCALATED to REBINDING (broadcast REQUEST, ACKed);
  counters renew=1,rebind=1,renewed=1,expired=0. Run B — the REBINDING
  refused, the lease expired (the poll printed the release line),
  `dhcp=idle,…,rebind=1,renewed=0,expired=1`, and the client recovered
  with a fresh DISCOVER → BOUND. PASS.
- Live gate `verify-live-net-dhcp-autonomous.sh` (class B, VZ, NEW): the
  autonomy proof — phase 2 types NO `net dhcp` (a marker + a `net`
  REPORT only; the gate self-checks the script premise), and the renewing
  (T1) + rebinding (T2) transition lines appeared anyway, from the
  idle-loop poll; the report showed renew=1,rebind=1,renewed=1,expired=0
  and the capture held both REQUEST shapes byte-exact. PASS.
