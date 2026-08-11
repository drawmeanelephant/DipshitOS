# Milestone five, card N3 — ARP (resolve peers, answer for our address)

> **PLANNING-FIRST — card N3 of milestone five, split from the roadmap's
> network sketch (`docs/roadmap.md`) and the march-m5 tracker's N3 row.
> N1 (transport + TX) is MERGED at `53483f5` (PR #85, claim 1373) and N2
> (raw Ethernet RX) is MERGED at `c9fcb68` (PR #87, claim 6076); the
> OBSERVED contract below is the baseline this card builds on and the
> claim-time questions are the ones N1/N2 did NOT answer. ADR 0007 stays
> frozen — N3 is a DEVICE DRIVER / protocol-layer card, no syscall
> numbering anywhere. No libc/POSIX/heap anywhere. New branch
> `agent/buffy/m5-arp`; claim via branch + slug `arp` with
> `bash tools/status/claim-id.sh` (the number is TBD at claim time —
> every number in this doc is a suggestion to verify).

## Why

N2 made raw Ethernet frames flow both ways: the host injects known frames
(`--net-inject`, a serial trigger) and the guest receives them byte-exact
through the RX seam (queue-0 buffer supply, polled used-ring drain, MAC
filter, bounded FIFO, `net recv`). But the frames are inert — nothing
inside them is understood. The first protocol that makes a network usable
is ARP: a guest that can resolve a peer's MAC from its IP (send requests,
parse replies) and answer requests for its own protocol address can talk
to real peers, and IPv4/ICMP (N4) presupposes it. Every pattern N3 needs
is already proven: TX of a bounded frame (N1's `net_send`), RX of a
broadcast frame (N2's drain + filter — ARP requests are broadcast, so the
MAC filter already admits them), and bounded BSS state (the N2 FIFO). The
runner side is small: a deterministic host-side ARP answer is a few lines
in the existing capture thread. Lowest-risk rung after N2; N4 presupposes
it.

## The observed contract (the baseline — do NOT re-derive, do NOT regress)

Recorded in `docs/claims/1373-net-tx.md`, `docs/claims/6076-net-rx.md`,
`docs/hardware-contract.md` (net bullets, `[observed]` with saved logs),
`docs/march-m5.md`, and the driver comments in
`kernel/src/virtio_net.zig`. A fresh agent should read those FIRST. The
load-bearing facts for ARP:

1. **Device + transport** as pinned by N1: DID 0x1041 @ bus 0 dev 1,
   feature mask `feat=0x28/0x1` (VER1|MTU|MAC), MAC via the feature path
   `02:00:00:00:00:01`, no ExitBootServices reset (`pre-rearm st=0f`),
   queues 0/1 size 4, 16-bit queue-index notify.
2. **TX consumes a 12-byte `virtio_net_hdr` on every buffer** — the driver
   prepends a ZEROED header (`tx_hdr_len = 12`); the host capture carries
   the raw Ethernet frame. An ARP reply/request is a 42-byte frame built
   in `tx_staging[tx_hdr_len..]` and submitted with `net_send` — the N1
   one-request-at-a-time shape.
3. **RX writes a 12-byte `virtio_net_hdr` before every frame** — the
   device-written length is 12 + frame length (observed: 72 for a 60-byte
   frame, 58 for a 46-byte frame), `num_buffers=1` at bytes 10-11 of the
   header, and the frame's Ethernet header starts at `rx_hdr_len = 12`.
   `net_rx_drain()` hands the FIFO the RAW device bytes (header included);
   `net recv` prints them byte-exact and the rx-obs record pins the header.
4. **RX buffer minimum 1530 bytes** (observed: 1529 wedges the device) —
   production `rx_buf_len = 4096`; keep it.
5. **MAC filter accepts own + broadcast, drops the rest** — ARP requests
   are broadcast (`ff:ff:ff:ff:ff:ff`) so they pass; ARP replies are
   unicast to OUR MAC and pass; the guest's own outbound frames are
   unicast/broadcast by construction.
6. **The shell idle loop calls `net_rx_drain()` continuously** (polled —
   the net device's used-buffer IRQ remains unobserved). The ARP dispatch
   hooks the same drain, so an ARP frame is processed a moment after it
   lands, with no new wiring in `main.zig`.
7. **Runner flags:** `--net <capture-file>` (N1), `--net-inject <file>`
   with `--net-inject-after <marker>` (N2 — the marker is ALREADY
   configurable; the guest prints `net ip: ip=<a.b.c.d>` on the new
   command, which becomes the N3 injection trigger), and the capture
   thread that reads every guest TX datagram (the natural place for a
   host-side ARP answer).
8. **Gate shape:** `tools/verify-live-net-rx.sh` (3 phases, byte-exact
   captures, per-phase flag bookkeeping) is the template; the `verify-vz`
   aggregate is 29 gates (`zig-build-run` + 28 `verify-*`, including
   `verify-live-net-tx` + `verify-live-net-rx`) — N3 makes it 30 with
   `verify-live-net-arp`.

## Scope

1. **Guest ARP layer — `kernel/src/arp.zig` (new, the fat.zig pattern:
   pure logic + host tests; virtio_net.zig wires it to the transport).**
   RFC 826 over the N2 seam:
   - Constants: ethertype `0x0806`, htype Ethernet `0x0001`, ptype IPv4
     `0x0800`, hlen 6, plen 4, op request 1 / reply 2, frame length 42
     (14 + 28). IPv4 only — honest bounds.
   - **Static IP:** `net ip <a.b.c.d>` sets a fixed BSS `own_ip` (dotted-
     quad parse, no heap, zero = unset). DHCP is a later card. The
     command prints `net ip: ip=<a.b.c.d>` — the N3 injection marker.
   - **Requests:** a resolve action (`net arp <a.b.c.d>`) looks up the
     bounded table and, on a miss, builds + transmits an ARP request
     (broadcast dst, own MAC/IP as sender, zeroed target HW, target
     proto = the address). Refuses honestly when no IP is set.
   - **Replies:** the RX drain dispatches ARP frames — a REQUEST whose
     target proto address == `own_ip` is answered (reply built in
     `tx_staging`, transmitted via the N1 `net_send` path, one-request-
     at-a-time); a request for any other address is dropped (counter).
   - **Replies learned:** an incoming ARP reply upserts the sender
     (sha/spa) into the table.
   - **Bounded table:** fixed `table_slots` (recommend 4, BSS, no heap —
     DECIDE at claim time and document; recommend update-in-place on a
     hit, fill the first free slot, else drop-oldest via a simple
     cursor; host-tested). No cache expiry (entries live until replaced
     — documented, honest bound).
   - **Counters** (the `net` report + `net arp`): requests sent, replies
     answered, replies learned, dropped (malformed / not-for-us / no IP
     set), reply TX failures (honest — the polled send can time out).
2. **Monitor/shell wiring:** `net ip <a.b.c.d>` and `net arp [<a.b.c.d>]`
   are `net` SUBCOMMANDS (registry stays 34 — the N2 decision stands; a
   separate command grows it 34→35, DECIDE and document if you prefer).
   `net arp` with no arg prints the table + counters; `net` gains an
   `ip=`/`arp=` line. The shell help line + the transcript fixture +
   monitor help-string tests update together.
3. **Runner: a deterministic host-side ARP answer, flag-gated.** Add
   `--net-arp-respond <host-ip>` (OFF by default — the default VM is
   unchanged; requires `--net`, validated at parse time): when the
   capture thread reads a datagram that IS an ARP request (ethertype
   0x0806, op 1, htype 1, ptype 0x0800, hlen 6, plen 4), synthesize the
   reply (host MAC `02:00:00:00:00:02` — the same fixed address as the
   guest's `fallback_mac` — at the given IP) and write it into the SAME
   attachment socket end `--net-inject` writes (fds[1]; VZ reads fds[0] —
   the card-N2 observed direction). Deterministic: driven by the guest's
   actual request bytes, no sleep. The reply goes to the guest, NOT the
   capture file (the capture stays guest-TX-only, byte-exact).
4. **Host tests (class A):** `arp.zig` pure-logic tests (dotted-quad
   parse valid/invalid, build_request/build_reply byte-exact against the
   RFC fixtures, classify request/reply/not-ARP/short/malformed htype-
   ptype-hlen-plen, request-for-us vs not-for-us, reply upsert, bounded
   table eviction, counters) + a virtio_net wiring test over the existing
   mock (deliver an ARP request on the RX ring → the reply goes out on TX
   byte-exact; deliver an ARP reply → the table learns) + monitor tests
   (`net ip` output, `net arp` report shape, the help-string update).
   `swift build` covers the runner change.
5. **Live gate `tools/verify-live-arp.sh` (new, class B):** 3 phases on
   real VZ, byte-exact:
   - Phase 1 — **answer a request for our address:** guest sets
     `net ip 10.0.0.1`; the runner injects the 42-byte ARP request "who
     has 10.0.0.1, tell 10.0.0.2" (host 02:00:00:00:00:02) at the
     `net ip: ip=10.0.0.1` marker; the guest's reply must appear in the
     capture byte-exact (02:00:00:00:00:01/10.0.0.1 → target
     02:00:00:00:00:02/10.0.0.2); serial asserts the reply counter.
   - Phase 2 — **resolve a peer:** guest `net arp 10.0.0.2` (broadcast
     request captured byte-exact); the runner's `--net-arp-respond
     10.0.0.2` answers; `net arp` shows `10.0.0.2 -> 02:00:00:00:00:02`
     and the learned counter.
   - Phase 3 — **scope check:** inject an ARP request for 10.0.0.99 (not
     our address) — no reply (capture empty), dropped counter moves, the
     frame is still observable via `net recv` (the N2 seam regression).
   The FULL 30-gate `verify-vz` aggregate must stay green (the new flags
   are OFF by default). Evidence under `artifacts/live-net-arp-*`.
6. **Hardware contract:** no NEW device behavior is expected (ARP is a
   protocol layer over the observed N1/N2 contract) — record any surprise
   (e.g., the device padding/trimming ARP frames) with a saved VZ log as
   `[observed]`, never assumed.

## Sequence

1. Claim first (this prompt + `docs/claims/<id>-arp.md` +
   `docs/logs/agent-buffy-m5-arp.md` + `bash tools/status/refresh-indexes.sh`;
   start from merged main `c9fcb68` — fetch + verify before branching).
2. Class A first: fmt, unit tests, transcript byte-identical, build/image/
   inspect, swift build, context, coordination ×2, mmu-debt.
3. Class B on VZ: the new `verify-live-arp.sh` + the FULL shared-seam
   live sweep + the 30-gate aggregate, evidence under `artifacts/`.
4. Docs reconciliation: march-m5 (N3 row flip + N4 lane), roadmap (network
   bullet), status (milestone-five row + gate table), gate-inventory (new
   live-net-arp row + the 29→30 aggregate update), README, architecture,
   claim flip, log append, PR per the repo template (real observed
   evidence only).

## Do not

- Regress the N1/N2 observed contract (feature mask, MAC path, no-EBS
  reset, TX/RX 12-byte header, 1530-byte RX minimum, MAC filter) — read
  the claims + hardware contract + driver comments first.
- Build IPv4/IPv6/TCP/UDP/ICMP or DHCP in N3 — honest bounds: ARP + a
  static IP; N4 is the protocol rung.
- Change the default runner config: every existing gate stays byte-
  identical (the net flags are the only new surface).
- Add heap, allocation, or unbounded tables; touch the scheduler pool, the
  switching core, the lifecycle states, or the process registry.
- Touch syscall numbering at all (ADR 0007 frozen — no syscall in N3).
- Assume the net device's used-buffer IRQ behaves like the custom device's
  SPI 69 or the timer's PPI 30 without observing it; polled drain stays
  the RX default (the N2 claim records the IRQ as unobserved).
- Claim hardware behavior without a saved VZ log (`artifacts/`).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
