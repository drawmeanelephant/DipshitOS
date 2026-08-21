# Log — agent/buffy/m5-net-tcp

- Claim id 7026 via `bash tools/status/claim-id.sh agent/buffy/m5-net-tcp tcp-client`.
- Scope: `kernel/src/tcp.zig` (the bounded RFC 793 client), the
  protocol-6 dispatch + `net_tcp_send` seam, the `net tcp` subcommands +
  `tcp=` report line, the runner's `--net-tcp-respond`, the class-B live
  gate `tools/verify-live-net-tcp.sh` (phase 1 deterministic file-handle,
  phase 2 real NAT), the 38-gate aggregate re-run, and the
  hardware-contract/march-m5/status/gate-inventory updates.
- Status: IN PROGRESS.

## Progress

**2026-08-12 — claim + design.** The card's claim was filed with the
slug `net-tcp` first — that hash collided with the existing N4 claim
0148 (both (branch, slug) pairs map to the same ID; the coordination
check would have failed) — re-filed with the slug `tcp-client` → 7026,
free and descriptive. The design mirrors the N8/N9 honest-bounds
pattern end to end (module + seam + monitor + runner responder + live
gate), with the card's own documented bounds (see the claim).

**2026-08-12 — implementation + close-out.** Kernel `tcp.zig` (9 host
tests), the ipv4 protocol-6 dispatch (TCP is no longer `dropped_proto`
— the two dispatch tests re-derived), `net_tcp_send`, the `net tcp`
subcommands + `tcp=` report line + the shell `now_ticks` stamp, the
transcript fixture (one line, line endings preserved), the unit-module
list, and the runner's `--net-tcp-respond` (SYN → SYN-ACK with the
fixed server ISN 0x12345678, data → ACK + echoed payload, FIN →
FIN-ACK). Two live-boot bugs found and fixed at claim time (both by
the exploratory run, never assumed): `isTcpSegment` checked the IPv4
SRC bytes (26..30) instead of the DST (30..34) — no SYN-ACK ever
came back — and the monitor's `seq=0x` prefix doubled against
`print_hex_min`'s own prefix. The live gate PASS on VZ 36/36 across
THREE runs: Run A the full lifecycle + reset byte-exact (the 533-B
capture's NINE frames python-walked — the seq/ack chain + every TCP
checksum; counters `syn=2,synack=2,ack=4,data_s=1,data_r=1,fin=1,
finack=1,rst_s=1,rst_r=0,timedout=0,mal=0`), Run B the bounded
connect timeout (31 s black hole → `connect refused`, `timedout=1`),
Run C the real-NAT observation (the VZ NAT gateway RSTs the SYN —
`rst_r=1`, connection refused — recorded `[observed]`, never faked).
Class A green (66/66 unit incl. the 9 new tcp tests, byte-identical
transcript); the N8/N9 gates re-ran green; the **38-gate `verify-vz`
aggregate re-ran green 38/38** (`artifacts/m5-net-tcp-vz-sweep.log`,
the live-net-tcp gate 39s). Docs updated: hardware-contract TCP
observation, march-m5 N10 row + agent split, status milestone-five row
+ gate table, gate-inventory row + aggregate, claim close-out. PR
to follow.
