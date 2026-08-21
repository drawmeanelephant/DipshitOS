# Milestone five, card N4 — IPv4/ICMP (minimal IPv4 TX/RX + ICMP echo)

> **PLANNING-FIRST — card N4 of milestone five, split from the roadmap's
> network sketch (`docs/roadmap.md`) and the march-m5 tracker's N4 row.
> N1 (transport + TX) is MERGED (`53483f5`, PR #85, claim 1373), N2 (raw
> Ethernet RX) is MERGED (`c9fcb68`, PR #87, claim 6076), and N3 (ARP) is
> MERGED (PR #89, claim 7293) — the OBSERVED contract below is the
> baseline this card builds on, and the claim-time questions are the ones
> N1/N2/N3 did NOT answer. ADR 0007 stays frozen — N4 is a
> DEVICE DRIVER / protocol-layer card, no syscall numbering anywhere. No
> libc/POSIX/heap anywhere. New branch `agent/buffy/m5-ipv4`; claim via
> branch + slug `ipv4` with `bash tools/status/claim-id.sh` (the number is
> TBD at claim time — every number in this doc is a suggestion to
> verify).

## Why

N3 made the guest understand ARP — it knows a peer's MAC from its IP and
answers for its own static address. But the frames are still
Ethernet-raw: nothing above ARP is parsed. The first INTERNET layer is
IPv4, and the canonical first proof on top of it is ICMP echo — "ping".
A guest that answers an ICMP echo request byte-exact (the reply carrying
the echoed identifier, sequence, and payload with a recomputed ones-
complement checksum) is a guest that is genuinely on the internet
layer, and every pattern N4 needs is already proven: TX of a bounded
frame (N1's `net_send`), RX dispatch by ethertype (N3's ARP dispatch in
the polled drain), bounded BSS state (the N3 table/FIFO), the runner's
capture-thread packet inspection (`--net-arp-respond` — an ICMP answer
is the same shape), and the script1/script2 settle gate pattern. The
checksum machinery is pure math — fully host-testable without a device.
Lowest-risk rung after N3; the protocol ladder (DHCP, UDP, TCP) is
later, sketched only.

## The observed contract (the baseline — do NOT re-derive, do NOT regress)

Recorded in `docs/claims/1373-net-tx.md`, `docs/claims/6076-net-rx.md`,
`docs/claims/7293-arp.md`, `docs/hardware-contract.md` (net bullets,
`[observed]` with saved logs), `docs/march-m5.md`, and the driver
comments in `kernel/src/virtio_net.zig` / `kernel/src/arp.zig`. A fresh
agent should read those FIRST. The load-bearing facts for IPv4/ICMP:

1. **Device + transport** as pinned by N1: DID 0x1041 @ bus 0 dev 1,
   feature mask `feat=0x28/0x1` (VER1|MTU|MAC), MAC via the feature path
   `02:00:00:00:00:01`, no ExitBootServices reset (`pre-rearm st=0f`),
   queues 0/1 size 4, 16-bit queue-index notify.
2. **TX consumes a 12-byte `virtio_net_hdr` on every buffer** — the
   driver prepends a ZEROED header (`tx_hdr_len = 12`); the host capture
   carries the raw Ethernet frame. An ICMP echo reply is a small frame
   built in `tx_staging[tx_hdr_len..]` and submitted with `net_send` —
   the N1 one-request-at-a-time shape (and the reply path MUST zero the
   header first — the claim-7293 lesson).
3. **RX writes a 12-byte `virtio_net_hdr` before every frame** — the
   frame's Ethernet header starts at `rx_hdr_len = 12`; the device
   refuses RX buffers under 1530 bytes (production 4096); MAC filter
   accepts own + broadcast and drops the rest; the net device's
   used-buffer IRQ remains unobserved — drain is POLLED (the shell idle
   loop + the monitor commands).
4. **N3's ARP layer is the peer-resolution seam:** `kernel/src/arp.zig`
   holds `own_ip` (set by `net ip <a.b.c.d>`), the bounded 4-slot table,
   and the RX-drain dispatch (ethertype 0x0806). N4's dispatch sits
   BESIDE it in the same drain (ethertype 0x0800) and REUSES `arp.own_ip`
   (our source address) — do not introduce a second copy of the IP.
   `net ip`/`net arp` stay as they are (registry 34).
5. **Runner surface:** `--net <capture-file>` (N1), `--net-inject <file>`
   with `--net-inject-after <marker>` (N2; marker poll is 20 ms — the
   claim-7293 finding) and `--net-arp-respond <host-ip>` (N3 — the
   capture thread inspects each guest TX datagram and synthesizes a
   reply into the attachment's fds[1] end). The N4 ICMP answer is the
   same thread, same shape. The script1/script2 gate pattern (0.5 s
   settle after the ready marker) is the deterministic gate template.
6. **Gate shape / aggregates:** `tools/verify-live-net-arp.sh` (3 phases,
   byte-exact captures, per-phase flags, script1/script2) is the
   template; the `verify-vz` aggregate is 31 gates including
   `verify-live-net-arp` — N4 makes it 32 with the new gate.

## Scope

1. **Guest IPv4/ICMP layer — `kernel/src/ipv4.zig` (new, the fat.zig
   pattern: pure logic + host tests; virtio_net.zig wires it to the
   transport).** RFC 791 + RFC 792, IPv4-only, minimal:
   - **Header (20 bytes, no options):** version 4 / IHL 5, total length,
     identification, flags + fragment offset, TTL, protocol, header
     checksum (RFC 1071 one's-complement sum — host-tested against
     known vectors AND the built packets), src/dst addresses.
   - **Honest bounds (drop, counted — never assumed away):** IP
     fragments (MF set or a nonzero fragment offset), any protocol other
     than ICMP (1), a bad header checksum, a length that does not cover
     the header. Each has its own counter in the report.
   - **ICMP echo (RFC 792):** echo request (type 8) / echo reply (type
     0), code 0, checksum over the whole ICMP message, identifier +
     sequence + payload ECHOED BYTE-EXACT from the request into the
     reply. A reply swaps the src/dst addresses and the Ethernet MACs,
     recomputes both checksums, and transmits on the N1 TX path.
   - **`net ping <a.b.c.d>`** (`net` SUBCOMMAND, registry stays 34):
     looks up the peer's MAC in the ARP table (refuse honestly when the
     peer is unresolved — `net arp <ip>` resolves it first, documented;
     no hidden ARP state machine in N4), builds + sends one ICMP echo
     request (identifier from a counter, sequence from a counter),
     counts it. The reply is learned/observed asynchronously by the RX
     drain (a `pong` counter + the last echoed sequence in the report).
   - **Counters** (the `net` report + the gate): ipv4 frames received,
     dropped (fragments / checksum / protocol / short), ICMP echo
     replies answered, echo requests sent, replies observed.
2. **Wiring:** the RX drain's ethertype dispatch gains 0x0800 → ipv4
   (BESIDE the N3 ARP dispatch — same frame, same FIFO observation via
   `net recv`). The reply path zeroes the virtio_net_hdr prefix (the
   claim-7293 rule) and uses `net_send` one-request-at-a-time.
3. **Runner: a deterministic host-side ICMP answer, flag-gated.** Add
   `--net-icmp-respond <host-ip>` (OFF by default — the default VM is
   unchanged; requires `--net`, validated at parse time): when the
   capture thread reads a datagram that IS an ICMP echo request (ethertype
   0x0800, IPv4 proto 1, type 8) addressed to `host-ip`, synthesize the
   echo reply (swap src/dst, type 0, recomputed checksums, echoed
   id/seq/payload) and write it into the attachment's fds[1] end — the
   card-N2/N3 direction. Deterministic: driven by the guest's actual
   request bytes, no sleep. The reply goes to the guest, NOT the capture
   file.
4. **Host tests (class A):** `ipv4.zig` pure-logic tests (RFC 1071
   checksum vectors, header parse/classify, fragment + protocol +
   checksum drops, build echo request / reply byte-exact against the
   fixtures) + a virtio_net wiring test over the mock (deliver an ICMP
   echo request on the RX ring → the byte-exact reply goes out on TX;
   deliver a fragment → the drop counter, no reply) + monitor tests
   (`net ping` output shape, the report line) + the transcript fixture.
   `swift build` covers the runner change.
5. **Hardware contract:** NO new device behavior is expected (IPv4 is a
   protocol layer over the observed N1/N2/N3 contract) — record any
   surprise (e.g., the device touching IP fields) with a saved VZ log as
   `[observed]`, never assumed.
6. **Live gate `tools/verify-live-net-icmp.sh` (new, class B):** 3
   phases on real VZ, byte-exact, the script1/script2 settle pattern:
   - Phase 1 — **answer an echo request for our address:** guest sets
     `net ip 10.0.0.1`; the runner injects the ICMP echo request "ping
     10.0.0.1 from 10.0.0.2" (host MAC 02:00:00:00:00:02, a known
     id/seq/payload) at the ip-set marker; the guest's echo REPLY must
     be byte-exact in the capture (src 02:00:00:00:00:01/10.0.0.1 → dst
     02:00:00:00:00:02/10.0.0.2, type 0, echoed id/seq/payload, valid
     checksums); serial asserts the reply counter.
   - Phase 2 — **the guest pings a peer:** `net ip 10.0.0.1` +
     `net arp 10.0.0.2` (resolve) + `net ping 10.0.0.2`; the guest's
     echo request is byte-exact in the capture AND the runner's
     `--net-icmp-respond 10.0.0.2` answer completes the round trip
     (the report shows the pong counter / observed sequence).
   - Phase 3 — **scope check:** inject a fragment (MF set) or a
     non-ICMP protocol — no reply (capture empty), the drop counter
     moves, and the frame is still observable via `net recv` (the N2/N3
     seam regression).
   The FULL 32-gate `verify-vz` aggregate must stay green (the new flags
   are OFF by default). Evidence under `artifacts/live-net-icmp-*`.

## Sequence

1. Claim first (this prompt + `docs/claims/<id>-ipv4.md` +
   `docs/logs/agent-buffy-m5-ipv4.md` + `bash tools/status/refresh-indexes.sh`).
   N3 (PR #89, claim 7293) is the dependency — the N4 claim branches
   from the N3 claim HEAD (the ARP seam + `net ip` are the foundation);
   when PR #89 merges, the N4 PR's base catches up and its diff cleans.
2. Class A first: fmt, unit tests, transcript byte-identical, build/image/
   inspect, swift build, context, coordination ×2, mmu-debt.
3. Class B on VZ: the new `verify-live-net-icmp.sh` + the FULL shared-seam
   live sweep + the 32-gate aggregate, evidence under `artifacts/`.
4. Docs reconciliation: march-m5 (N4 row flip), roadmap (network bullet +
   surface-table row), status (milestone-five row + gate table), gate-
   inventory (new live-net-icmp row + the 31→32 aggregate update), README,
   architecture, claim flip, log append, PR per the repo template (real
   observed evidence only).

## Do not

- Regress the N1/N2/N3 observed contract (feature mask, MAC path, no-EBS
  reset, TX/RX 12-byte header, 1530-byte RX minimum, MAC filter, the ARP
  seam) — read the claims + hardware contract + driver comments first.
- Build fragmentation, reassembly, TCP, UDP, DHCP, or DNS in N4 — honest
  bounds: minimal IPv4 + ICMP echo; the rest is later, sketched only.
- Change the default runner config: every existing gate stays byte-
  identical (the net flags are the only new surface).
- Add heap, allocation, or unbounded tables; touch the scheduler pool, the
  switching core, the lifecycle states, or the process registry.
- Touch syscall numbering at all (ADR 0007 frozen — no syscall in N4).
- Assume the net device's used-buffer IRQ behaves like the custom device's
  SPI 69 or the timer's PPI 30 without observing it; polled drain stays
  the RX default (recorded in the N2/N3 claims).
- Claim hardware behavior without a saved VZ log (`artifacts/`).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
