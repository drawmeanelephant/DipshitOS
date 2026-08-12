# Claim: Milestone five, card N11 — bounded retransmission + a retransmit timer for the TCP client

- **Owner:** buffy (`agent/buffy/m5-net-tcp-rto`)
- **Prompt / plan:** the user's card N11 request — "add bounded
  retransmission + a retransmit timer to the TCP client, closing the
  honest N10 bound (no retransmission)". N1 (1373), N2 (6076), N3
  (7293), N4 (0148), N5 (8552), N6 (1384), N7 (4678), N8 (0351), N9
  (9489) and N10 (7026) are ALL MERGED — the observed contract below is
  the baseline this card builds on. A GUEST PROTOCOL card on the N5/N6
  layer — **NO ADR 0007 change, NO user program** (monitor surface +
  the shell idle loop, like N10/N9).
- **Scope:** (1) `kernel/src/tcp.zig` — bounded retransmission: ONE
  pending-unacked-segment buffer (the polled-drain contract: at most
  ONE unacked TX in flight), a fixed RTO (`rto_ticks = 3` guest
  seconds — the card-N9 1 Hz timer clock, no adaptive estimation/Karn —
  honest bound), a retransmission bound (`retx_max = 10` — a segment
  is retransmitted at most 10 times, then the connection aborts
  honestly, counted), the ACK paths clear the pending state (a peer
  ACK covering `snd_una` clears it — no retransmission when the peer
  answers), the SYN/FIN/data each retransmit their exact bytes
  (byte-identical frames), bare ACKs are NEVER retransmitted (the
  honest bound). The 30 s connect timeout STAYS the SYN's outer bound
  ((retx_max+1)·rto = 33 s > 30 s — the N10 gate's refusal stays
  byte-exact; the retransmission abort bounds DATA/FIN, which have no
  other clock). `poll_rto()` returns none/retransmit/abort; the
  retransmit rebuilds `msg` from the pending copy, the abort releases
  the connection honestly (no RST, no TX — the N10 `abort_timeout`
  pattern, counted `retx_aborted`). (2) the shell idle loop — the RTO
  poll (the idle loop is the time engine — it already stamps
  `now_ticks`; a real retransmit timer fires autonomously, printed
  `net tcp: <syn|data|fin> retransmitted (n/10)`). (3) the `tcp=`
  report line APPENDS `,retx=,abort=` at the end (the N9 "append,
  never change" convention — the N10 gate's substring assertions stay
  green). (4) runner `--net-tcp-respond <ip>:<port>[:handshake]` — the
  optional `:handshake` mode answers the SYN-ACK but goes SILENT on
  data/FIN (a deterministic data black hole for the abort run);
  default unchanged. (5) the new class-B live gate
  `tools/verify-live-net-tcp-rto.sh`, THREE runs: Run A the
  retransmission proof (black-hole SYN — the retransmitted SYNs are
  byte-identical in the capture, `retx=2`, the `(1/10)`/`(2/10)` lines),
  Run B the recovery (the responder answers — the ACK clears the
  pending state, `retx=0` despite the wait, ONE SYN in the capture),
  Run C the retransmission bound (handshake-only responder — the data
  is retransmitted 10 times byte-identical then the connection aborts
  honestly: `retx=10,abort=1,tcp=idle`). (6) the FULL 39-gate
  `verify-vz` aggregate stays green (the N10 gate re-runs byte-exact).
  (7) docs: hardware-contract TCP-retransmission observation, march-m5
  N11 row, status / gate-inventory updates.
- **Depends on:** N10 MERGED (the TCP client this card extends; the
  N10 gate re-runs byte-exact), N9 MERGED (the 1 Hz timer + the shell
  idle-loop clock-stamp pattern; the runner `--script2-delay`/`-after`
  settle pattern for the gate's waits). Branched from main after the
  N10 merge.
- **Status:** ✅ DONE 2026-08-12 on `agent/buffy/m5-net-tcp-rto` (from merged main `6a8ec41` — the N10 merge; claim PR pending)

## Notes

**Why this card:** N10 documented "NO retransmission (every segment is
sent exactly ONCE when the caller commands it — a lost segment is the
caller's observation)". N11 closes that honest bound: the client now
retransmits an unacknowledged segment on a fixed 3 s timer, bounded at
10 retransmissions (an unacked data/FIN aborts the connection honestly
after 33 s — counted; the SYN's outer bound stays the N10 30 s connect
timeout, so the N10 gate's refusal is unchanged). Every retransmission
is byte-identical (the pending segment copy) and counted (`retx=`); an
ACK that covers everything the client sent clears the pending state —
the client never retransmits a segment the peer acknowledged.

**The honest-bounds list (this card's documented, never-assumed-away
bounds):** a FIXED RTO (3 s of guest ticks — no adaptive estimation,
no Karn's algorithm, no exponential backoff, no congestion control —
the card-N9 clock pattern); at most `retx_max = 10` retransmissions
(11 transmissions total) before the honest abort; ONE pending segment
(the polled-drain contract: at most one unacked TX in flight — the
retransmission buffer is the bounded `segment_max` copy); bare ACKs
are NEVER retransmitted (the handshake ACK, the echo ACK, the final
ACK — a lost one is the peer's observation; the client does not run
TIME_WAIT re-ACK); the retransmission abort RELEASES the connection
honestly without transmitting (the N10 `abort_timeout` pattern — no
RST, counted `retx_aborted`); the 30 s connect timeout remains the
SYN's outer bound (the retransmission abort at 33 s never beats it —
the N10 gate stays byte-exact).

**The claim-time question (Run C):** does the VZ NAT gateway / a real
host listener acknowledge a retransmitted segment? The observation is
Run C's deterministic file-handle proof (the handshake-only responder
is the black hole); the real-NAT behavior was already observed by N10
Run C (the gateway RSTs the SYN). No new NAT observation needed.

## Progress

**2026-08-12 — implementation.** `kernel/src/tcp.zig` (pure logic, 5
new host tests — 14 tcp total: the RTO retransmits the pending SYN
byte-exact + the SYN-ACK stops the timer, a peer ACK covering
`snd_una` clears the pending data, a stale ACK leaves it armed, the
retransmission bound aborts honestly, the FIN retransmission);
`shell.zig`'s idle loop gains the RTO poll (the retransmit timer fires
autonomously — `net tcp: <syn|data|fin> retransmitted (n/10)` + the
`retransmission limit reached (10) — connection aborted` print);
`monitor.zig` — the `net tcp` TX sites (connect/send/close) call
`record_pending`, `reset` clears it, and the `tcp=` report line
appends `,retx=,abort=` (the N10 gate's substrings stay green); the
runner's `--net-tcp-respond` gains the optional `:handshake` mode
(SYN-ACK yes, data/FIN silent). The RTO poll is polled in the idle
loop AFTER the RX drain (a peer ACK processed by the drain clears the
pending state — never a retransmission of an acknowledged segment).
Exploratory live runs: the black-hole SYN retransmits byte-exact, the
recovery run stays retx=0, and the handshake-only data black hole
retransmits 10× then aborts honestly (the live gate's Run A/B/C shape
confirmed).

## Close-out (2026-08-12)

**All scope items done; the live gate PASS on VZ (34/34 assertions,
THREE runs).**

**Run A — the retransmission proof (deterministic file-handle,
black-hole SYN, 9/9):** `--net` + `--net-arp-respond 10.0.0.2` ONLY
(the host answers ARP but NEVER TCP): connect → the SYN is recorded
pending → the shell idle loop's RTO poll fires at 3 s of guest ticks
and retransmits the SYN AUTONOMOUSLY — `net tcp: syn retransmitted
(1/10)` then `(2/10)` — the phase-1 report reads `retx=0,abort=0`, the
phase-2 report reads `retx=2,abort=0` (still `tcp=syn_sent` — the 30 s
connect timeout has not expired), and the capture (204+ bytes) holds
the byte-identical 54-byte SYN frames — the SAME seq (the ISN drawn
once at connect; the retransmissions reuse the exact pending bytes),
the same flags/ports/MACs, and the IPv4 + TCP checksums, all verified
by the gate's python walk. (The exact retransmission count is the
honest 1 Hz-tick observation — a third RTO can fire depending on the
boot/settle timing; the gate asserts retx >= 2 + the byte-exactness,
never a brittle count.)

**Run B — the ACK-clears-pending recovery (deterministic file-handle
+ the full responder, 10/10):** the responder answers the SYN-ACK; the
idle drain delivers it and the accepted SYN-ACK clears the pending
state — despite the 7 s wait (past the RTO) NOTHING is retransmitted:
`retx=0,abort=0` in both reports, no `retransmitted` lines, and the
capture (150 B) holds EXACTLY ONE SYN + the handshake ACK (the
handshake completes — `established`). The honest proof that an
acknowledged segment is never retransmitted.

**Run C — the retransmission bound (deterministic file-handle + the
`:handshake` responder, 15/15):** the responder answers the SYN-ACK
then goes SILENT on data (the card's deterministic black hole):
connect → established → `net tcp send 5` (the data never gets its
ACK) → the idle loop retransmits the data TEN times, one per 3 s RTO
(`net tcp: data retransmitted (1/10)` … `(10/10)`) → at the bound
`net tcp: retransmission limit reached (10) — connection aborted` —
the connection released honestly (no RST, no TX — the N10
`abort_timeout` pattern): `tcp=idle,peer=0.0.0.0:0,…,retx=10,abort=1`,
the next `net tcp` reads `no connection`, and the capture (799 B)
holds the ELEVEN byte-identical data frames (the initial + the 10
retransmissions, the same seq/payload `01 02 03 04 05`/checksum — a
python walk).

**Evidence:** `tools/verify-live-net-tcp-rto.sh` PASS on VZ — 34/34
assertions across the three runs (evidence under `artifacts/live-net-tcp-rto-*`:
runner outputs, serial logs, the captures — and
`artifacts/live-net-tcp-rto-explore/` for the exploratory runs). Full
class A green (fmt, the unit suite 71/71 incl. the 5 new RTO tests,
byte-identical transcript, build/image/inspect, swift build, context,
coordination ×2, mmu-debt); the N10 gate re-ran green; the **39-gate
`verify-vz` aggregate re-ran green 39/39** (evidence
`artifacts/m5-net-tcp-rto-vz-sweep.log`, the live-net-tcp-rto gate
61s) — proof the N11 changes left the default VM byte-identical.

One honest process note: the N10 gate's Run-C "real gateway MAC
learned" assertion flaked twice at claim time on this host (the ARP
reply through the real VZ NAT attachment arrived during the connect's
drain instead of the `net arp` report's window — the learned MAC + the
RST observation both still PASSED). A clean-main baseline worktree
REPRODUCED the flake identically (`artifacts/live-net-tcp-arp-flake-baseline/`
— `entries=0` then `learn=1` later), so it is a pre-existing
live-NAT ARP-latency timing variance, NOT an N11 regression; the
aggregate's own N10-gate re-run passed green. Recorded, not hidden.
The N10 gate itself was left untouched.
