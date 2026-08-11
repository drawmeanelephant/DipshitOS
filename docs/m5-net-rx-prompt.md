# Milestone five, card N2 — virtio-net raw Ethernet RX (the round-trip card)

> **PLANNING-FIRST — card N2 of milestone five, split from the roadmap's
> network sketch (`docs/roadmap.md`) and the march-m5 tracker's N2 row.
> N1 is MERGED at `53483f5` (PR #85, claim 1373, tag-free — milestone five
> stays open) and its OBSERVED contract below is the baseline this card
> builds on; the claim-time questions are the ones N1 did NOT answer. ADR
> 0007 stays frozen — N2 is a DEVICE DRIVER card, no syscall numbering
> anywhere. No libc/POSIX/heap anywhere. New branch `agent/buffy/m5-net-rx`;
> claim via branch + slug `net-rx` with
> `bash tools/status/claim-id.sh` (the number is TBD at claim time —
> every number in this doc is a suggestion to verify).

## Why

N1 proved the transport + TX: the guest sends known frames the host
captures byte-exactly. But the seam is one-way — the runner's attachment
has no host→guest direction wired, and the guest arms queue 0 (RX) with
ZERO buffers. "Raw Ethernet frames back and forth" is the first real
network hurdle, and it is exactly where N2 falls: RX buffer supply,
used-ring drain, MAC filtering, and a guest-visible receive path. ARP (N3)
and IPv4/ICMP (N4) presuppose it — an ARP reply must be transmitted (N1 ✓)
and an ARP request received (N2), and an ICMP echo exchange needs both
directions on the same device. Every RX pattern N2 needs is proven on this
platform: used-ring completion (claims 0828/4374/9492), polled drain
(claim 6420's blk shape — N1's own TX drain), FIFO push-from-context +
shell-idle drain (claim 1014's card-3d report rings), and bounded BSS
staging (N1's `tx_staging`). The runner side is a few lines: the
attachment already holds ONE connected datagram socketpair — the host
writes frames into ITS end of the same socket and VZ delivers them to the
guest's RX queue (the `fileHandleForReading` side N1 deliberately left
nil). Lowest-risk rung after N1; N3/N4 presuppose it.

## N1's OBSERVED contract (the baseline — do NOT re-derive, do NOT trust
## the pre-N1 assumptions)

Recorded in `docs/claims/1373-net-tx.md`, `docs/hardware-contract.md`
(net bullet, `[observed]` with the saved logs), `docs/march-m5.md`, and
the driver comments in `kernel/src/virtio_net.zig`. A fresh agent should
read those FIRST. The load-bearing facts:

1. **Device:** bus 0 device 1, `VID=0x1af4 DID=0x1041 class=0x020000`
   (the modern spec virtio-net DID — the 2026-08-11 correction confirmed).
   64-bit BAR0 at `0x100020000` (common/notify/devcfg), 32-bit BAR2 at
   `0x50003000`.
2. **Feature negotiation REQUIRES `VIRTIO_NET_F_MTU` (bit 3) accepted.**
   VER1-only and VER1|MAC masks are rejected (device clears FEATURES_OK;
   status readback 0x03). The landed mask is **`feat=0x28/0x1`** =
   VER1|MTU|MAC — `kernel/src/virtio_net.zig` walks a negotiated-mask
   ladder; keep that machinery, do not regress it.
3. **MAC:** bit 5 = the host-set MAC (legacy xnu/Linux numbering), read
   via the feature path from device-config offset 0: `02:00:00:00:00:01`
   (`net: mac=02:00:00:00:00:01 source=feature`, `cfgmac` agrees). The
   fixed BSS fallback (`02:00:00:00:00:02`) exists but is NOT used on VZ.
4. **No ExitBootServices reset on the net device** — `net: pre-rearm
   st=0f` (DRIVER_OK intact), unlike blk/entropy (`st=00`). `net_rearm`
   is unconditional and idempotent; it must STAY that way (a reset at EBS
   on some future VZ version must not strand the transport).
5. **TX consumes a 12-byte `virtio_net_hdr` on EVERY buffer** even with
   no offload feature — the driver prepends a ZEROED header
   (`tx_hdr_len = 12`), the host capture carries the raw Ethernet frame.
   Whether RX buffers must likewise be sized/padded for a header is an
   N2 claim-time question (the RX descriptor is device-WRITE; the device
   writes the frame — and possibly its own header — into the buffer;
   observe, don't assume).
6. **Queues:** split rings, size 4; queue 0 = RX (armed, ZERO buffers),
   queue 1 = TX (proven). Notify is 16-bit queue-index kicks
   (`net_queue_notify_off`). `net_send`'s one-request-at-a-time drain is
   the pattern to mirror for RX.
7. **Runner attachment:** `VZFileHandleNetworkDeviceAttachment` over ONE
   connected `SOCK_DGRAM` socketpair. The runner currently only READS its
   end (guest TX → capture file, appended per datagram, closed at exit).
   Host→guest = writing the known frame bytes into the runner's end of
   the SAME socket; VZ then delivers them to the guest RX queue. Timing
   must be deterministic (a serial trigger, not a sleep).
8. **Gate shape:** `tools/verify-live-net-tx.sh` (2 phases, byte-exact
   captures, the `net` report assertions) is the template; the `verify-vz`
   aggregate is now 29 gates including `live-net-tx`.

## Scope

1. **Runner: a host→guest injection surface, flag-gated and deterministic
   (recommended — DECIDE at claim time and document it).** Following the
   `--script`/`--script-expect` precedent, add e.g. `--net-inject <file>`
   (write the file's bytes into the runner's socket end ONCE, when a
   serial trigger appears — the trigger should be the guest's
   RX-armed marker, so buffers are guaranteed supplied; a plain
   after-N-seconds injection is the fallback, documented). OFF by default
   (default VM byte-identical — the 29-gate aggregate must stay green).
   The injected bytes are the KNOWN frame the guest must receive; the
   guest's `net recv` reply is the byte-exact echo.
2. **Guest driver `kernel/src/virtio_net.zig` — the RX path.** Supply
   queue-0 buffers from fixed BSS (one bounded RX buffer pool; the
   one-request-at-a-time discipline keeps the ring invariant trivial —
   mirror N1's TX), kick the queue so the device knows buffers are
   available, drain the used ring when the device fills a buffer, and push
   the frame into a bounded frame FIFO (fixed slots, no heap — the card-3d
   push-from-context + shell-idle-drain pattern; drop-oldest overflow,
   documented + host-tested). MAC filtering: accept own MAC (the observed
   `02:00:00:00:00:01`) + broadcast (`ff:ff:ff:ff:ff:ff`), drop the rest
   (a counter in the `net` report). POLLED drain first (the proven N1/blk
   shape, lowest risk); the net device's used-buffer INTERRUPT line is NOT
   yet observed on this platform — whether the device delivers one (and
   via what INTID) is a claim-time finding to record; IRQ-context push is
   the card-3d pattern if the line is observed and wired.
3. **`net recv`:** print the most recent received frame(s) byte-exact
   (hex, the `netsend`-style report) — the live gate asserts the exact
   bytes the host injected. `net` gains the RX counters (frames received,
   filtered/dropped, FIFO occupancy). Registry: `net recv` is a `net`
   subcommand (registry stays 34) — DECIDE at claim time; a separate
   command grows it 34→35. Honest bounds: raw Ethernet frames only — no
   ARP/IP parsing, no protocol layer (N3/N4).
4. **Host tests (class A):** MAC-filter logic (own/broadcast/other),
   FIFO push/drain/overflow, RX used-ring drain accounting (the N1
   `drain_delta` shape — note the RX `len` is the DEVICE-WRITTEN frame
   length, the TX `len` was ~0), the `net recv` output shape, registry
   rows. `swift build --package-path host/vm-runner` covers the runner
   change; the transcript fixture must stay byte-identical (default runner
   unchanged).
5. **Hardware contract:** the RX direction (and any used-buffer IRQ
   observation) gets `[observed]` ONLY with a saved VZ log under
   `artifacts/` — record the header-on-RX question (item 5 of the
   baseline) and the IRQ question up front as `[inferred]`/unknown.
6. **Live gate `tools/verify-live-net-rx.sh` (new, class B):** run with
   the net mode; the guest signals RX-armed (its `net recv` / buffer
   report), the host injects the known frame, and the guest's `net recv`
   must print EXACTLY those bytes (the round trip: host inject → guest
   receive → guest echo/report → host serial). Add a guest→host leg if it
   strengthens the gate (receive then `netsend` the same bytes back — the
   capture file must then hold them too): "raw Ethernet frames back and
   forth" is the gate's title. The FULL shared-seam live sweep + the
   29-gate `verify-vz` aggregate must stay green. Evidence under
   `artifacts/live-net-rx-*`.

## Sequence

1. Claim first (this prompt + `docs/claims/<id>-net-rx.md` +
   `docs/logs/agent-buffy-m5-net-rx.md` + `bash tools/status/refresh-indexes.sh`;
   start from merged main `53483f5` — fetch + verify before branching).
2. Class A first: fmt, unit tests, transcript byte-identical, build/image/
   inspect, swift build, context, coordination ×2, mmu-debt.
3. Class B on VZ: the new `verify-live-net-rx.sh` + the FULL shared-seam
   live sweep + the 29-gate aggregate, evidence under `artifacts/`.
4. Docs reconciliation: march-m5 (N2 row flip + N3 lane), roadmap (surface
   table Network row TX→TX+RX), status (milestone-five row + gate table),
   gate-inventory (new live-net-rx row + aggregates), README,
   hardware-contract (`[observed]` RX/IRQ flips with saved logs only),
   architecture, claim flip, log append, PR per the repo template (real
   observed evidence only).

## Do not

- Trust the pre-N1 assumptions over the N1 OBSERVED contract (item list
  above) — read the claim/hardware-contract/driver comments first.
- Change the default runner config: every existing gate stays byte-identical
  (the net flags are the only new surface).
- Build ARP/IPv4/ICMP/UDP/TCP in N2 — honest bounds: raw Ethernet RX;
  the protocol ladder (N3/N4) is separate.
- Add heap, allocation, or unbounded tables; touch the scheduler pool, the
  switching core, the lifecycle states, or the process registry.
- Touch syscall numbering at all (ADR 0007 frozen — no syscall in N2).
- Assume the net device's used-buffer IRQ behaves like the custom device's
  SPI 69 or the timer's PPI 30 without observing it; polled drain is the
  N2 default until an IRQ line is observed and recorded.
- Claim hardware behavior without a saved VZ log (`artifacts/`).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
