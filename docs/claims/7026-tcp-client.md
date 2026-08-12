# Claim: Milestone five, card N10 — a bounded TCP client on the N5/N6 layer

- **Owner:** buffy (`agent/buffy/m5-net-tcp`)
- **Prompt / plan:** the user's card N10 request — "implement a bounded
  TCP client on the N5/N6 layer, following the DHCP card's honest-bounds
  pattern" (the roadmap's "then TCP — far future" rung, docs/roadmap.md;
  N8's claim recorded "the next rung: the roadmap's TCP sketch — a FUTURE
  card — out of scope here"). N1 (claim 1373), N2 (6076), N3 (7293), N4
  (0148), N5 (8552), N6 (1384), N7 (4678), N8 (0351) and N9 (9489) are
  ALL MERGED — the observed contract below is the baseline this card
  builds on. A GUEST PROTOCOL card on the N5/N6 layer — **NO ADR 0007
  change, NO user program** (monitor surface, like N3/N4/N5/N8/N9).
- **Scope:** (1) NEW `kernel/src/tcp.zig` — the bounded RFC 793 TCP
  CLIENT, pure logic (the dhcp.zig pattern): the four-segment lifecycle
  SYN → SYN-ACK → (data ↔ echo) → FIN → FIN-ACK → final ACK; the TCP
  checksum over the IPv4 pseudo-header (protocol 6); honest bounds
  (recorded, never assumed away): no retransmission (every segment sent
  exactly once on the caller's command), ONE bounded connect timeout
  (30 s guest ticks — the card-N9 timer pattern), no options (a bare
  20-byte header, no MSS/window-scaling/SACK), a FIXED window 4096, no
  segmentation (payload ≤ 64), no reassembly (ONE bounded RX segment),
  no TCP loopback (connections are outward-only — an own-IP connect is
  refused), no server, no port listening. (2) the ONE seam change: the
  TCP frame builder + `virtio_net.net_tcp_send` + the ipv4 protocol-6
  dispatch to `tcp.handle_rx` (the checksum/fragment/dst checks stay in
  ipv4 — never duplicated). (3) monitor surface: the `net tcp`
  subcommands (connect / (drive) / send <len> / recv / close / reset),
  the `tcp=` report line + counters. (4) runner `--net-tcp-respond
  <host-ip>:<host-port>` (OFF by default, requires `--net`): the capture
  thread runs a tiny deterministic TCP server — SYN → SYN-ACK (fixed
  gate-assertable server ISN), data → ACK + echoed payload, FIN →
  FIN-ACK, byte-exact fixtures. (5) the new class-B live gate
  `tools/verify-live-net-tcp.sh`, TWO phases: phase 1 deterministic
  file-handle (the full lifecycle byte-exact in the capture + the
  counters + the echoed payload); phase 2 real NAT (rides `--net-nat`:
  a connect to the NAT gateway's IP on the test port — claim-time
  observation whether any TCP service answers through the VZ NAT,
  honestly recorded if blocked, never faked; the bounded connect timeout
  refuses honestly). (6) the FULL 38-gate `verify-vz` aggregate stays
  green. (7) docs: hardware-contract TCP observation `[observed]` with
  saved logs, the march-m5 N10 row, status / gate-inventory updates.
- **Depends on:** N1–N6 MERGED (the N1 TX seam + the N2 RX drain + the
  N4 IPv4 validation + the N5 send-seam pattern), N7 MERGED (`--net-nat`
  for phase 2), N8/N9 MERGED (the DHCP honest-bounds pattern this card
  follows; the card-N9 `now_ticks` timer pattern for the connect
  timeout). Branched from main after the N7/N8/N9 merge chain.
- **Status:** ✅ DONE 2026-08-12 on `agent/buffy/m5-net-tcp` (from merged main `4bf455d` — the N7/N8/N9 merge chain; claim PR pending)

## Notes

**Why this card:** the guest speaks Ethernet (N1/N2), ARP (N3),
IPv4/ICMP (N4), UDP (N5/N6), leases an address (N8) and enforces the
lease (N9) — but the milestone's last sketched rung, TCP, is untouched:
the ipv4 dispatch still counts protocol 6 as `dropped_proto`. N10 is the
bounded RFC 793 CLIENT on the N5/N6 layer — the honest-bounds pattern
N8/N9 established: pure logic + host tests, ONE fixed BSS state machine,
no heap, every drop counted, the questionable things observed live and
recorded, never assumed.

**The honest-bounds list (this card's documented, never-assumed-away
bounds):** no retransmission (each segment is sent exactly once when the
caller commands it — a lost segment is the caller's observation, and a
`net tcp reset` aborts), ONE fixed connect timeout (30 s — a SYN with no
SYN-ACK refuses honestly, counted `timed_out`, the card-N9 timer
pattern), no TCP options (a bare 20-byte header — no MSS, no
window-scaling, no SACK, no timestamps), a FIXED window 4096, no
segmentation (payload ≤ 64 — the N5 payload_max bound), no reassembly
(ONE bounded RX segment buffer — a second unread segment is dropped,
counted), no TCP loopback (the client connects OUTWARD only; an own-IP
connect is refused `.no_peer` like an unresolved peer), no server
surface, no port listening, no urgent data, no congestion control. The
close is client-driven (FIN → FIN-ACK → final ACK); a server FIN in
ESTABLISHED is ACKed and counted (`finack_recv`), and the client's own
`net tcp close` then finishes the close honestly.

**The claim-time question (phase 2):** does any TCP service answer
through the VZ NAT attachment on this host? The common VZ NAT shape
serves the 192.168.64.0/24 pool from the host; whether the NAT gateway
or a host listener accepts a TCP connect on the test port is the
observation. If one does, phase 2 proves the client's handshake against
a REAL TCP service; if NOT, phase 2 is honestly blocked with the
observation recorded — the SYN goes out (`syn=1`) and the bounded
connect timeout refuses (`timedout=1`) — never faked.

**Deterministic phase 1:** the host responder answers with a FIXED
server ISN (0x12345678) and echoes data byte-exact; the gate asserts the
counters (syn=1, synack=1, ack=3, data_s=1, data_r=1, fin=1, finack=1,
rst=0, timedout=0, mal=0), the echoed payload, and the capture's full
six-frame handshake byte-exact (SYN → ACK → data → ACK → FIN → final
ACK, the seq/ack chain + TCP checksums verified by a python walk).

## Progress

**2026-08-12 — implementation.** `kernel/src/tcp.zig` (pure logic, 9
host tests: build_segment/build_frame byte-exact against the fixtures,
the four-segment lifecycle, the malformed/badsum/options/oversize/port
drops, the ONE-slot RX buffer, the bounded connect timeout, the
server-FIN path, the bare-SYN drop); `ipv4.zig` gains the protocol-6
dispatch to `tcp.handle_rx` (the checksum/fragment/dst checks stay in
ipv4 — the two dispatch tests re-derived: TCP is no longer
`dropped_proto`); `virtio_net.net_tcp_send` (the thin seam on the N1
TX path — the peer MAC resolved at connect, stored in the client
state); the monitor `net tcp` subcommands (connect / drive / send /
recv / close / reset) + the `tcp=` report line + help/usage (registry
stays 34); the shell idle loop + `net tcp` stamp `now_ticks` (the
card-N9 timer pattern); the transcript fixture re-derived (one line,
line endings preserved); `tools/verify-unit-tests.sh` gains the tcp
module. The runner gains `--net-tcp-respond <host-ip>:<host-port>`:
`isTcpSegment` + `tcpFlags`/`tcpSeq`/`tcpAck` + `hex32` (the
manual-hex pattern — Swift's String(format:) vararg bridge mismatch)
+ `tcpChecksum` (@Sendable, the N5 helper pattern) + `buildTcpReply`
in the capture thread — SYN → SYN-ACK (the FIXED gate-assertable
server ISN 0x12345678, ack = the guest's ISN+1), data → ACK + the
payload ECHOED byte-exact, FIN → FIN-ACK, RST → observed. Two
live-boot bugs found at claim time (both by the exploratory run, never
assumed): (1) `isTcpSegment` compared the IPv4 SRC address (bytes
26..30 — 10.0.0.1) to the host IP instead of the DST (bytes 30..34) —
the SYN was never recognized and no SYN-ACK came back; fixed to the
`isUdpDatagram` offset shape; (2) the monitor's `seq=0x` + `print_hex_min`
(which already prints the prefix) produced `seq=0x0x…` — the extra
prefix dropped. Exploratory live runs: the full lifecycle green on VZ
(SYN → SYN-ACK → ACK → established → data → echoed `01 02 03 04 05` →
FIN → FIN-ACK → final ACK → closed, plus the second connect + reset:
`tcp=closed,peer=10.0.0.2:9999,syn=2,synack=2,ack=4,data_s=1,
data_r=1,fin=1,finack=1,rst_s=1,rst_r=0,timedout=0,mal=0`), the
bounded timeout live (31 s black hole → `connect refused (no SYN-ACK
after 30s)` → `timedout=1`), and the real-NAT observation (the
gateway RSTs the SYN — `rst_r=1`).

## Close-out (2026-08-12)

**All scope items done; the live gate PASS on VZ (36/36 assertions,
THREE runs).**

**Run A — the full lifecycle + reset (deterministic file-handle,
20/20):** the guest's `net tcp` ran the complete RFC 793 lifecycle
against the host's crafted server: SYN (54 B byte-exact in the capture
— dst 02:00:00:00:00:02, src 02:00:00:00:00:01, proto 6, src 8000 →
dst 9999, flags 0x02) → SYN-ACK (the FIXED server ISN 0x12345678, ack
= the guest's ISN+1) → the handshake ACK (ack 0x12345679 —
deterministic) → ESTABLISHED → `net tcp send 5` (the data segment 01
02 03 04 05) → the host's ACK + echo (ack 0x1234567e) → `net tcp recv`
prints `01 02 03 04 05` → `net tcp close` (FIN) → FIN-ACK → the final
ACK (0x1234567f) → `net tcp: connection closed` → a SECOND connect +
`net tcp` (established) + `net tcp reset` (a real RST, flags 0x14);
the report counters `syn=2,synack=2,ack=4,data_s=1,data_r=1,fin=1,
finack=1,rst_s=1,rst_r=0,timedout=0,mal=0`; the host's NET-TCP
SYN-ACK / data-echo / FIN-ACK lines; and the 533-byte capture's NINE
guest-TX frames pass the gate's python walk — the seq/ack chain (the
SYN seq → ISN+1 → +5 → +6 → +7), the flags (0x02 / 0x10 / 0x11 /
0x14), the ports, the MACs, the payload, and EVERY TCP checksum
(pseudo-header + segment) byte-exact.

**Run B — the bounded connect timeout (deterministic black hole,
8/8):** `--net` + `--net-arp-respond` ONLY (the host answers ARP but
NEVER TCP): connect → `tcp=syn_sent,peer=10.0.0.2:9999,syn=1,
synack=0,timedout=0` → 31 s (`--script2-delay`, the card-N9 pattern) →
`net tcp: connect refused (no SYN-ACK after 30s) — run 'net tcp
connect <addr> <port>' to retry` → `tcp=idle,peer=0.0.0.0:0,…,
timedout=1` — the bounded timeout refuses honestly and releases the
connection state.

**Run C — the real-NAT observation (8/8):** `net tcp connect
192.168.64.1:9999` against `--net-nat`. **CLAIM-TIME OBSERVATION,
honestly recorded: the VZ NAT gateway answers the SYN with a RST**
(macOS 27 arm64 — the gateway, MAC ae:07:75:20:da:64 learned via the
N7-proven ARP path, actively refuses the connection: no TCP listener
on the test port), so the client's RST-RX path fires — `rst_r=1`,
`tcp=closed`, and the `net tcp` drive returns the client to idle
(`connection closed — idle again`). Never faked; if a future host's
NAT gateway silently drops the SYN instead, the honest timeout path
fires (`timedout=1` — proven by Run B; the Run-C assertion set
documents where to flip). Pinned in the hardware contract `[observed]`
with the saved logs under `artifacts/live-net-tcp-explore/`.

**Evidence:** `tools/verify-live-net-tcp.sh` PASS on VZ — 36/36
assertions across the three runs (evidence under `artifacts/live-net-tcp-*`:
runner outputs, serial logs, the Run-A capture — and
`artifacts/live-net-tcp-explore/` for the exploratory lifecycle /
timeout / NAT runs). Full class A green (fmt, the unit suite 66/66
incl. the 9 new tcp tests + the re-derived ipv4 dispatch tests,
byte-identical transcript, build/image/inspect, swift build, context,
coordination); the N8/N9 gates re-ran green; the **38-gate `verify-vz`
aggregate re-ran green 38/38** (evidence
`artifacts/m5-net-tcp-vz-sweep.log`, the live-net-tcp gate 39s) —
proof the N10 changes left the default VM byte-identical. The
milestone-five network rung is complete: N1–N6 (transport → UDP
syscall), N7 (NAT), N8 (DHCP), N9 (lease lifecycle), N10 (TCP client)
— all live-gated on real VZ.
