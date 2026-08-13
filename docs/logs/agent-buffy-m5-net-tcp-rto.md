# Log — agent/buffy/m5-net-tcp-rto

- Claim id 5357 via `bash tools/status/claim-id.sh agent/buffy/m5-net-tcp-rto tcp-retransmit`.
- Scope: `kernel/src/tcp.zig` (bounded retransmission: the pending
  segment buffer, the fixed 3 s RTO, the 10-retransmission bound, the
  ACK-clears-pending paths, `poll_rto()`), the shell idle-loop RTO
  poll, the `net tcp` TX sites' `record_pending` + the appended
  `,retx=,abort=` report counters, the runner's `:handshake` responder
  mode, the class-B live gate `tools/verify-live-net-tcp-rto.sh`
  (three runs), the 39-gate aggregate re-run, and the
  hardware-contract/march-m5/status/gate-inventory updates.
- Status: IN PROGRESS.

## Progress

**2026-08-12 — claim + design.** The card's design closes N10's honest
"no retransmission" bound: ONE pending-unacked-segment buffer (the
polled-drain contract — at most one unacked TX in flight), a fixed RTO
(3 s of the card-N9 1 Hz guest clock, no adaptive estimation), a
retransmission bound (`retx_max = 10` — then the connection aborts
honestly, counted `retx_aborted`), and the ACK paths clear the pending
state. The 30 s connect timeout STAYS the SYN's outer bound
((10+1)·3 = 33 s > 30 s — the N10 gate's refusal is byte-exact), so
the retransmission abort bounds DATA/FIN. The RTO poll lives in the
shell idle loop (the time engine — it already stamps `now_ticks`): the
retransmit timer fires autonomously, printed `net tcp: <syn|data|fin>
retransmitted (n/10)`; the report appends `,retx=,abort=` (the N9
append-never-change convention). The runner's `--net-tcp-respond`
gains an optional `:handshake` mode (SYN-ACK yes, data/FIN silent) for
the gate's deterministic data black hole.

**2026-08-12 — implementation + close-out.** Kernel `tcp.zig` (5 new
host tests — 14 tcp total: the RTO math, the retransmitted SYN
byte-exact, the ACK clears the pending data, a stale ACK leaves it
armed, the bound aborts honestly, the FIN retransmission), the shell
idle-loop RTO poll (the timer fires autonomously — `net tcp:
<syn|data|fin> retransmitted (n/10)` + the abort print), the monitor
TX sites' `record_pending` (+ `clear_pending` on reset) and the
appended `,retx=,abort=` report counters, and the runner's
`:handshake` responder mode (`--net-tcp-respond <ip>:<port>[:handshake]`
— SYN-ACK yes, data/FIN silent; default unchanged). The live gate
PASS on VZ 34/34 across THREE runs: Run A the retransmission proof
(the idle loop retransmits the black-holed SYN — `retx=2,abort=0`,
the byte-identical SYN frames in the capture), Run B the recovery
(the SYN-ACK clears the pending state — `retx=0` despite the wait,
exactly ONE SYN), Run C the bound (the handshake-only data black hole
— ten `data retransmitted (n/10)` lines, `retransmission limit
reached (10) — connection aborted`, `tcp=idle,retx=10,abort=1`, the
ELEVEN byte-identical data frames in the capture). Class A green
(71/71 unit incl. the 5 new RTO tests, byte-identical transcript);
the N10 gate re-ran green; the **39-gate `verify-vz` aggregate re-ran
green 39/39** (`artifacts/m5-net-tcp-rto-vz-sweep.log`, the
live-net-tcp-rto gate 61s). One pre-existing N10-gate Run-C
ARP-learn flake (live-NAT ARP latency) reproduced on a clean-main
baseline worktree — recorded under
`artifacts/live-net-tcp-arp-flake-baseline/`, NOT an N11 regression;
the aggregate's N10 gate passed. Docs updated: hardware-contract TCP
retransmission observation, march-m5 N11 row + agent split, status
milestone-five row + gate table, gate-inventory row + aggregate,
claim close-out. PR to follow.
