# Milestone five, card N5 — UDP datagrams over the N4 IPv4 seam (bounded listen/send + loopback)

> **PLANNING-FIRST — card N5 of milestone five, split from the roadmap's
> network sketch (`docs/roadmap.md` — \"UDP datagrams behind a bounded
> syscall seam\" is LATER) and this tracker. N1 (transport + TX, `53483f5`,
> PR #85, claim 1373), N2 (raw RX, `c9fcb68`, PR #87, claim 6076), N3 (ARP,
> PR #89, claim 7293) and N4 (IPv4/ICMP, PR #91, claim 0148 — merged
> `e685586`) are ALL MERGED — the OBSERVED contract below is the baseline
> this card builds on, and the claim-time questions are the ones N1–N4 did
> NOT answer. ADR 0007 stays frozen — N5 is a DEVICE DRIVER /
> protocol-layer card delivered over the monitor `net` surface (the N3/N4
> pattern); the roadmap's \"bounded syscall seam\" is a SEPARATE later card.
> No libc/POSIX/heap anywhere. New branch `agent/buffy/m5-udp`; claim via
> branch + slug `udp` with `bash tools/status/claim-id.sh` (the number is
> TBD at claim time — every number in this doc is a suggestion to verify).**

## Why

N4 put the guest on the internet layer: it answers ICMP echo requests
byte-exact and pings a resolved peer. But the only protocol it speaks is
ICMP — everything else (protocol ≠ 1) is dropped with a counter. UDP
(RFC 768) is the natural next rung: the smallest real transport, no
connection state, a bounded port space, and a checksum that is pure math
(fully host-testable, like N4's RFC 1071 machinery). It also gives the
stack its first **demultiplexing** surface — ports — which is what the
later syscall seam will need. Every pattern N5 needs is proven: bounded
TX (N1 `net_send`), IPv4 validation + ethertype/protocol dispatch (N4's
`ipv4.handle_rx`), bounded BSS state (the N3 table / N2 FIFO), the
runner's capture-thread packet inspection (`--net-arp-respond` /
`--net-icmp-respond`), and the script1/script2 settle gate pattern.

## The observed contract (the baseline — do NOT re-derive, do NOT regress)

Recorded in `docs/claims/1373-net-tx.md`, `docs/claims/6076-net-rx.md`,
`docs/claims/7293-arp.md`, `docs/claims/0148-ipv4.md`,
`docs/hardware-contract.md` (net bullets, `[observed]` with saved logs),
`docs/march-m5.md`, and the driver comments in `kernel/src/virtio_net.zig`
/ `arp.zig` / `ipv4.zig`. A fresh agent should read those FIRST. The
load-bearing facts for UDP:

1. **Device + transport** as pinned by N1: DID 0x1041 @ bus 0 dev 1,
   feature mask `feat=0x28/0x1` (VER1|MTU|MAC), MAC via the feature path
   `02:00:00:00:00:01`, no ExitBootServices reset (`pre-rearm st=0f`),
   queues 0/1 size 4, 16-bit queue-index notify.
2. **TX consumes a 12-byte `virtio_net_hdr` on every buffer** — the
   driver prepends a ZEROED header (`tx_hdr_len = 12`); the host capture
   carries the raw Ethernet frame. A UDP datagram is a small frame built
   in `tx_staging[tx_hdr_len..]` and submitted with `net_send` — the N1
   one-request-at-a-time shape (zero the header first — the claim-7293
   lesson).
3. **RX writes a 12-byte `virtio_net_hdr` before every frame** — the
   frame's Ethernet header starts at `rx_hdr_len = 12`; the device
   refuses RX buffers under 1530 bytes (production 4096); MAC filter
   accepts own + broadcast; the used-buffer IRQ remains unobserved —
   drain is POLLED (shell idle loop + monitor commands).
4. **N3's ARP layer is the peer-resolution seam:** `arp.own_ip` (set by
   `net ip <a.b.c.d>` — the ONE copy of our address), the bounded 4-slot
   table, `arp.lookup(ip) -> ?mac`. `net_ping_request` (N4) already
   transmits a small IPv4 frame to a resolved peer and refuses `.no_peer`
   when the MAC is unknown — UDP send is the same shape.
5. **N4's IPv4 layer is the internet seam:** `kernel/src/ipv4.zig` owns
   all IPv4 validation (ethertype 0x0800, version 4 / IHL 5, header
   checksum, fragment drop, dst-IP check) and dispatches protocol 1
   (ICMP). Today protocol ≠ 1 is counted in `dropped_proto` — N5 changes
   that ONE branch: protocol 17 (UDP) is handed to `udp.handle_rx`
   (already-validated frames), everything else stays `dropped_proto`.
   `ipv4.src_ip(frame)` / `dst_ip(frame)` (bytes 26..34) exist for the
   pseudo-header.
6. **Runner surface:** `--net <capture-file>` (N1), `--net-inject <file>`
   (+ `--net-inject-after`, 20 ms marker poll — the claim-7293 finding),
   `--net-arp-respond <host-ip>` (N3), `--net-icmp-respond <host-ip>`
   (N4 — the capture thread inspects each guest TX datagram and
   synthesizes a reply into the attachment's fds[1] end). The N5 UDP
   answer is the same thread, same shape. The script1/script2 gate
   pattern (0.5 s settle after the ready marker) is the template.
7. **Gate shape / aggregates:** `tools/verify-live-net-icmp.sh` (3 phases,
   byte-exact captures, per-phase flags, script1/script2) is the
   template; the `verify-vz` aggregate is 32 gates including
   `verify-live-net-icmp` — N5 makes it 33 with the new gate.

## Scope

1. **Guest UDP layer — `kernel/src/udp.zig` (new, the fat.zig pattern:
   pure logic + host tests; `ipv4.zig` wires it to validated IPv4
   frames).** RFC 768, IPv4 only, minimal:
   - **Header (8 bytes):** src port, dst port, length (8 + payload),
     checksum. The checksum is over the IPv4 PSEUDO-HEADER (src IP, dst
     IP, zero, protocol 17, UDP length) + the UDP header + payload, RFC
     1071 one's-complement — computed ALWAYS (the IPv4 \"may be zero\"
     escape is not used; byte-exact gates pin the real value). Pseudo-
     header src/dst come from the IPv4 frame (bytes 26..34) — pure math,
     host-testable against known vectors AND the built datagrams.
   - **Honest bounds (drop, counted — never assumed away):** a UDP
     length < 8 (or exceeding the frame's remaining bytes), a bad
     checksum, a datagram for a port with NO listener (see the table).
     Each has its own counter in the report.
   - **A bounded LISTEN table** (4 slots, pure BSS — the ARP-table
     pattern): `net udp listen <port>` adds (refuse: full table,
     duplicate), `net udp close <port>` removes. A datagram for a
     listening port is delivered into that port's bounded datagram
     buffer; for any other port it is dropped (`dropped_closed`).
   - **A bounded per-listener datagram buffer** (4 datagrams × 80 bytes
     = 8-byte UDP header + ≤ 64-byte payload, drop-oldest, the N2 FIFO
     pattern): `net udp recv [<port>]` prints the datagram(s) byte-exact
     (hex, `net recv` style) and drains; the shell idle loop also drains.
   - **Loopback:** `net udp send` to OUR OWN IP (`arp.own_ip`) delivers
     the datagram DIRECTLY into the local receive path (no device round
     trip) — a real, host-testable loopback (class A: send to self → the
     datagram appears in the listener's buffer, `received` counts it, TX
     does not fire). This is the \"bounded loopback test surface\".
   - **`net udp send <ip> <dst-port> <len>`** (`net` SUBCOMMAND, registry
     stays 34): look up the peer MAC in the ARP table (refuse honestly
     when unresolved — `net arp <ip>` first; own-IP sends take the
     loopback path), build + transmit ONE UDP datagram from a FIXED
     source port (7000 — deterministic, gate-assertable), payload bytes
     01 02 03 04… (the byte-index pattern, bounded ≤ 64), count it.
   - **Counters** (the `net` report + the gate): datagrams received,
     sent, dropped (bad checksum / closed port / bad length), loopbacked.
2. **Wiring:** `ipv4.zig`'s `handle_rx` gains ONE dispatch branch —
     protocol 17 calls `udp.handle_rx(frame)` (which needs no reply
     buffer: N5's guest RECEIVES and SENDS; it does not answer UDP — the
     host answers, `--net-udp-respond`). The UDP path reuses the
     already-validated frame (IPv4 checksum/fragment/dst checks stay in
     ipv4 — do not duplicate them). `virtio_net.zig` gains
     `net_udp_send(target_ip, dst_port, payload) -> SendResult` (the
     `net_ping_request` shape, `.no_peer` on an unresolved MAC) +
     `udp_send_loopback` handling for own-IP sends. The RX drain needs NO
     change (IPv4 already dispatches); the per-frame counters flow from
     ipv4 → udp.
3. **Runner: a deterministic host-side UDP answer, flag-gated.** Add
   `--net-udp-respond <host-ip>:<host-port>` (OFF by default — the
   default VM is unchanged; requires `--net`, validated at parse time):
   when the capture thread reads a datagram that IS a UDP datagram
   (ethertype 0x0800, IPv4 proto 17, non-fragment) addressed to
   `host-ip:host-port`, synthesize a UDP datagram FROM `host-ip:host-port`
   TO the sender's ip:src-port carrying the SAME payload byte-exact
   (checksum recomputed with the pseudo-header) and write it into the
   attachment's fds[1] end — the card-N2/N3/N4 direction. Deterministic:
   driven by the guest's actual datagram bytes, no sleep. The reply goes
   to the guest, NOT the capture file.
4. **Host tests (class A):** `udp.zig` pure-logic tests (checksum
   vectors with the pseudo-header, parse/classify, bad-checksum /
   closed-port / short-length drops, listen table full/duplicate, build
   send byte-exact against the fixture, LOOPBACK — send to own IP
   delivers locally without TX) + an ipv4 dispatch test (protocol 17 →
   udp, protocol 6 → still `dropped_proto`) + monitor tests (`net udp`
   output shapes, the report line) + the transcript fixture. `swift
   build` covers the runner change.
5. **Hardware contract:** NO new device behavior is expected (UDP is a
   protocol layer over the observed N1–N4 contract — the device sees the
   same raw Ethernet frames) — record any surprise with a saved VZ log as
   `[observed]`, never assumed.
6. **Live gate `tools/verify-live-net-udp.sh` (new, class B):** 4 phases
   on real VZ, byte-exact, the script1/script2 settle pattern:
   - Phase 1 — **loopback (no host involvement):** `net udp listen 7000`
     then `net udp send 10.0.0.1 7000 4` (our OWN IP) → `net udp recv`
     shows the 4-byte datagram byte-exact, `received` counts it, the
     capture is EMPTY (nothing hit the device). The bounded loopback
     test surface, live.
   - Phase 2 — **host → guest:** guest `net ip 10.0.0.1` + `net udp
     listen 7000`; the runner injects a UDP datagram 10.0.0.2:9999 →
     10.0.0.1:7000 (payload 01 02 03 04, pseudo-header checksum) at the
     ip-set marker → `net udp recv` prints it byte-exact (device len 58
     = 12-byte RX header + 46-byte frame), `net recv` also observes the
     raw frame (the N2 seam), the received counter moves.
   - Phase 3 — **guest → host round trip:** `net arp 10.0.0.2` (resolve)
     + `net udp send 10.0.0.2 9999 4` → the 46-byte datagram is
     byte-exact in the capture AND `--net-udp-respond 10.0.0.2:9999`'s
     answer (same payload, src 10.0.0.2:9999 → 10.0.0.1:7000) lands in
     the guest's listener buffer (observed via `net udp recv`, `sent`
     and `received` counters move).
   - Phase 4 — **scope check:** inject a UDP datagram to a CLOSED port
     (10.0.0.1:9998) → no reply (capture empty), `dropped_closed` moves,
     and the frame is still observable via `net recv` (the N2 seam
     regression — a drop is a counter, not a swallowed frame).
   The FULL 33-gate `verify-vz` aggregate must stay green (the new flags
   are OFF by default). Evidence under `artifacts/live-net-udp-*`.

## Sequence

1. Claim first (this prompt + `docs/claims/<id>-udp.md` +
   `docs/logs/agent-buffy-m5-udp.md` + `bash tools/status/refresh-indexes.sh`).
   N1–N4 are MERGED (main `e685586`) — the N5 claim branches from merged
   main, carrying the N5 prompt commit (the two-PR pattern: prompt PR
   first, then the claim PR; the prompt commits are already on the claim
   branch, so either merge order self-cleans).
2. Class A first: fmt, unit tests, transcript byte-identical, build/image/
   inspect, swift build, context, coordination ×2, mmu-debt.
3. Class B on VZ: the new `verify-live-net-udp.sh` + the FULL shared-seam
   live sweep + the 33-gate aggregate, evidence under `artifacts/`.
4. Docs reconciliation: march-m5 (add the N5 row + flip; agent-split N5
   line), roadmap (UDP bullet + surface-table row + the \"later, sketched
   only\" syscall-seam language stays), status (milestone-five row + gate
   table), gate-inventory (new live-net-udp row + the 32→33 aggregate
   update), README, architecture, claim flip, log append, PR per the repo
   template (real observed evidence only).

## Do not

- Regress the N1–N4 observed contract (feature mask, MAC path, no-EBS
  reset, TX/RX 12-byte header, 1530-byte RX minimum, MAC filter, the ARP
  seam, the IPv4 validation + ICMP path) — read the claims + hardware
  contract + driver comments first.
- Build TCP, DHCP, DNS, or a syscall seam in N5 — the roadmap's \"UDP
  behind a bounded syscall seam (an ADR 0007 amendment)\" is a SEPARATE
  later card; N5 delivers UDP over the monitor `net` surface (ADR 0007
  stays frozen).
- Make the guest ANSWER UDP (no server replies) — N5's guest receives and
  sends; the HOST answers (`--net-udp-respond`). A later card can add
  guest-side responders.
- Change the default runner config: every existing gate stays byte-
  identical (the net flags are the only new surface).
- Add heap, allocation, or unbounded tables; touch the scheduler pool, the
  switching core, the lifecycle states, or the process registry.
- Touch syscall numbering at all (ADR 0007 frozen — no syscall in N5).
- Assume the net device's used-buffer IRQ behaves like the custom device's
  SPI 69 or the timer's PPI 30 without observing it; polled drain stays
  the RX default (recorded in the N2/N3/N4 claims).
- Claim hardware behavior without a saved VZ log (`artifacts/`).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
