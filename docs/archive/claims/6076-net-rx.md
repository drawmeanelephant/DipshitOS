# Claim: Milestone five, card N2 — virtio-net raw Ethernet RX (the round-trip card)

- **Owner:** buffy (`agent/buffy/m5-net-rx`)
- **Prompt / plan:** `docs/m5-net-rx-prompt.md` (planning-first; card N2 of
  milestone five, split from the roadmap's network sketch — the N2 row of
  `docs/march-m5.md`). N1 is MERGED (PR #85, claim 1373) and its OBSERVED
  contract (below) is the baseline this card builds on; the claim-time
  questions are the ones N1 did NOT answer. ADR 0007 stays frozen: N2 is a
  DEVICE DRIVER card, no syscall numbering. No libc/POSIX/heap anywhere.
- **Scope:** (1) runner `--net-inject <file>` flag-gated host→guest
  surface in `host/vm-runner/Sources/VMRunner/main.swift`: writes the
  file's bytes into the EXISTING `--net` attachment's socket end ONCE,
  when a serial trigger appears (the guest's RX-armed marker —
  deterministic, not a sleep); OFF by default (default VM byte-identical —
  the 29-gate aggregate must stay green). (2) guest driver
  `kernel/src/virtio_net.zig` — the RX path: supply queue-0 buffers from
  fixed BSS (one bounded RX buffer, one-request-at-a-time like N1's TX),
  kick, drain the used ring (POLLED first — the proven N1/blk shape), push
  frames into a bounded frame FIFO (fixed BSS slots, no heap, the card-3d
  push/drain pattern, drop-oldest overflow, documented + host-tested), MAC
  filtering (own MAC + broadcast, drop the rest — a counter in the `net`
  report). (3) `net recv` — prints the received frame(s) byte-exact (hex,
  the netsend-style report) as a `net` SUBCOMMAND (registry stays 34);
  `net` gains the RX counters (frames received, filtered/dropped, FIFO
  occupancy). (4) host tests (class A): MAC filter (own/broadcast/other),
  FIFO push/drain/overflow, RX used-ring drain accounting (the RX `len` is
  the DEVICE-WRITTEN length — the TX `len` was ~0), `net recv` output
  shape, registry rows. (5) hardware contract: the RX direction (and any
  used-buffer IRQ observation) gets `[observed]` ONLY with a saved VZ log
  under `artifacts/`; the header-on-RX question (item 5 of the baseline —
  does the device write a 12-byte virtio_net_hdr into RX buffers?) and the
  IRQ question are recorded up front as `[inferred]`/unknown, observed and
  pinned at claim time (the claim-1373 `tx_hdr_len` 0→12 correction
  pattern). (6) new class B gate `tools/verify-live-net-rx.sh`: run with
  `--net` + `--net-inject`; the guest signals RX-armed, the host injects
  the known frame, `net recv` prints EXACTLY those bytes, and the gate
  asserts the round trip (receive then `netsend` the same bytes back — the
  capture file must hold them too) plus the filter (own/broadcast accepted,
  other-MAC dropped); the FULL shared-seam live sweep + the 29-gate
  `verify-vz` aggregate must stay green.
- **Depends on:** N1 merged (claim 1373, `53483f5` / current main
  `0a3139e`) — the transport, feature negotiation (feat=0x28/0x1), MAC
  read (feature path, `02:00:00:00:00:01`), queues 0/1, post-exit re-arm
  (`net: pre-rearm st=0f`), the 12-byte TX header contract, the runner's
  `--net` attachment (its host→guest socket direction is the N2 seam), and
  `tools/verify-live-net-tx.sh` as the gate template.
- **Status:** ✅ DONE 2026-08-11 on `agent/buffy/m5-net-rx` (from merged main `0a3139e` — PR #86's N2 prompt doc landed on main; merged via PR #87)

## Notes

**Why this card:** N1 proved the transport + TX — the guest sends known
frames the host captures byte-exactly. But the seam is one-way: the runner
has no host→guest direction wired and queue 0 (RX) is armed with ZERO
buffers. "Raw Ethernet frames back and forth" is the first real network
hurdle, and N2 is exactly where it falls: RX buffer supply, used-ring
drain, MAC filtering, and a guest-visible receive path. ARP (N3) and
IPv4/ICMP (N4) presuppose it. Every RX pattern N2 needs is proven on this
platform: used-ring completion (claims 0828/4374/9492), polled drain
(claim 6420's blk shape — N1's own TX drain), FIFO push-from-context +
shell-idle drain (claim 1014's card-3d report rings), and bounded BSS
staging (N1's `tx_staging`). The runner side is a few lines: the
attachment already holds ONE connected datagram socketpair.

**Observe, don't assume (claim-time questions):** (a) does the device
write a 12-byte virtio_net_hdr into RX buffers? — N1 observed the device
CONSUMES one on TX; the RX descriptor is device-WRITE, so the buffer is
sized with header headroom and the first received frame's device-written
`len` + first bytes are dumped (`net: rx-obs`) so the contract is pinned
from observation, with `rx_hdr_len` corrected like `tx_hdr_len` was
(0→12) if the observation differs. (b) does the device deliver a
used-buffer IRQ line (and via what INTID)? — N2 defaults to polled drain;
the IRQ line is recorded as unobserved/not wired unless the live run
shows one.

**Verification (DONE):** class A all green (fmt, 30-module unit suite
incl. 23 virtio_net tests, byte-identical transcript, build/image/inspect,
swift build, context, coordination ×2, mmu-debt); class B on VZ: the new
`verify-live-net-rx.sh` **PASS 3/3** (phase 1 broadcast round trip —
recv byte-exact + the guest re-sends the SAME 60 bytes, capture
byte-identical to the fixture; phase 2 own-MAC received byte-exact;
phase 3 foreign-MAC dropped — `filtered=1`, rx-obs still records the
delivery) and the **29-gate `verify-vz` aggregate re-ran green 29/29**
(evidence `artifacts/live-net-rx-*`, `artifacts/m5-net-rx-vz-sweep.log`);
the docs reconciliation (march-m5 N2 row flip + N1 row completed, roadmap
network row TX→TX+RX, status.md milestone-five row + gate table, README,
gate-inventory live-net-rx row + aggregates, hardware-contract `[observed]`
RX flips with the saved live-net-rx serial logs, architecture, justfile +
sweep GATES) landed with the claim, then the claim flip, the log append,
and the PR per the repo template (real observed evidence only).

**Claim-time observations (pinned, not assumed):** (a) the RX-header
question — the device DOES write a 12-byte virtio_net_hdr into RX
buffers (`rx_hdr_len=12`, `num_buffers=1` at bytes 10-11, all
flags/gso fields zero; first received frame device-len 72 for 60 bytes;
first 16 bytes `00 00 00 00 00 00 00 00 00 00 01 00 ff ff ff ff`), so
`net recv` prints header headroom + the raw frame and the MAC filter
reads the dst at `rx_hdr_len`; (b) the minimum RX buffer question — the
device REFUSES a buffer under **1530 bytes** (1526/1528/1529 wedged the
device: no frame written, used ring never advanced, subsequent TX
completions stalled; 1530 works; production 4096 — page-rounded
headroom); (c) the IRQ question — the net device's used-buffer IRQ line
is NOT yet observed on this platform, so drain is polled (the N1/blk
shape), recorded in the hardware contract as unobserved rather than
assumed.
