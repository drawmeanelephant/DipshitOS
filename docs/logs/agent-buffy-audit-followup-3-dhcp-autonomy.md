# Log — agent/buffy/audit-followup-3-dhcp-autonomy

## 2026-08-15 — claim 2616 (audit follow-up 3: the autonomous DHCP lease lifecycle)

Opened from the 2026-08-15 strong audit of `main` `3013b17` (issues #115–
#123 filed). This claim is the network-autonomy tranche per the
maintainer's go-ahead: `net_dhcp_poll` drives the RFC 2131 §4.4.5
lifecycle from the shell idle loop (T1/T2/expiry — no `net dhcp` needed),
the missing RENEWING→REBINDING escalation at T2 is added and unit-tested,
the runner gains the `--net-dhcp-respond-norenew`/-norebind refusal
knobs, and the N9 renew gate is reworked + a new
`verify-live-net-dhcp-autonomous` gate added (both in the `verify-vz`
aggregate).

Claim-time discovery: an autonomous client with an always-answering server
renews at every T1 and never reaches T2 (correct RFC behavior — the old
gate's REBIND was an artifact of command-gating). The refusal knobs make
the rungs testable honestly; both reworked live gates PASS on real VZ.
