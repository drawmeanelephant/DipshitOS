# Milestone five, cards N7/N8 — outbound connectivity (NAT) + DHCP (the next set after the N6 seam)

> **PLANNING-FIRST — the next two rungs of milestone five, split from the
> roadmap's network sketch (`docs/roadmap.md` — "DHCP, loopback-as-a-
> device, then TCP" is the later, sketched-only rung) and the N6 claim's
> recorded next rung (`docs/claims/1384-udp-syscall.md`: "outbound with
> `VZNATNetworkDeviceAttachment`, or DHCP/TCP on the N6 seam"). N1
> (transport + TX, claim 1373), N2 (raw RX, claim 6076), N3 (ARP, claim
> 7293), N4 (IPv4/ICMP, claim 0148), N5 (UDP, claim 8552) and N6 (UDP
> syscall seam, claim 1384 — merged main `87fe7ae`) are ALL MERGED — the
> observed contract below is the baseline both cards build on. NEITHER
> card touches ADR 0007 (no syscalls — the seam stays frozen at slots
> 0–11); N7 is a RUNNER/ATTACHMENT card with a deliberate gate-shape
> change, N8 is a GUEST PROTOCOL card on the N5/N6 UDP layer. No
> libc/POSIX/heap anywhere. New branches `agent/buffy/m5-net-nat` (N7,
> slug `net-nat`) and `agent/buffy/m5-net-dhcp` (N8, slug `net-dhcp`);
> claim via branch + slug with `bash tools/status/claim-id.sh` (the
> numbers are TBD at claim time).**

## Why

The guest can already send and receive real Ethernet frames (N1/N2),
resolve peers and answer for its own static IP (N3), speak IPv4/ICMP
(N4), exchange UDP datagrams with the host through the file-handle
attachment (N5), and a user program can do all of the above through the
syscall seam (N6) — but the guest has only ever talked to the HOST on
the deterministic file-handle attachment. There is no path to anything
beyond the single VM, and the address is always typed by hand. N7/N8
close the milestone's last two honest gaps: **N7 proves real outbound
connectivity** by attaching `VZNATNetworkDeviceAttachment` (the one VZ
network attachment the roadmap reserved for exactly this rung — N1's
planning doc named it the "later card's outbound-connectivity option"),
and **N8 lets the guest obtain its address from a server instead of an
operator** — a DHCP client that also happens to be the honest way to
configure a guest on the NAT network. N8's second live phase rides N7's
attachment, so N7 lands first; both are independently claimable and both
keep the default VM byte-identical.

## The observed contract (the baseline — do NOT re-derive, do NOT regress)

Recorded in `docs/claims/1373-net-tx.md` … `docs/claims/1384-udp-syscall.md`,
`docs/hardware-contract.md` (net bullets, `[observed]` with saved logs),
`docs/march-m5.md`, and the driver comments in `kernel/src/virtio_net.zig`
/ `arp.zig` / `ipv4.zig` / `udp.zig` / `syscall.zig`. A fresh agent should
read those FIRST. The load-bearing facts for these cards:

1. **The guest IP stack is complete for these cards.** Static IP in
   `arp.own_ip` (THE one copy; zero = unset; `net ip <a.b.c.d>` sets
   it); ARP (4-slot BSS table, answer requests for our IP, learn
   replies); IPv4/ICMP (RFC 1071 checksums, echo request/reply
   byte-exact, fragments dropped counted — no reassembly); UDP
   (`kernel/src/udp.zig`: 4-slot listen table, 4×72-byte per-listener
   datagram rings, payload_max 64, FIXED src port 7000, the LOOPBACK
   path, counters received/sent/loopbacked/dropped_badsum/dropped_closed/
   dropped_len). `net_udp_send(target_ip, dst_port, payload, out_len) ->
   SendResult` is the transmit seam (`.no_peer` on an unresolved ARP —
   a peer send needs a MAC; own-IP sends loop back; `.not_ready` when
   the transport is down).
2. **The N2 RX drain filters own MAC + broadcast** and delivers into a
   bounded 4-slot frame FIFO (shell idle drain, polled — the used-ring
   IRQ is still unobserved). The device writes a 12-byte virtio_net_hdr
   into RX buffers and consumes one on every TX buffer; an RX buffer
   under 1530 bytes wedges the device (production 4096). Frames below
   the Ethernet 60-byte minimum travel unpadded (N3/N4/N5 observed —
   ARP 42 B, IPv4/ICMP 46 B, UDP 46 B). The net device does NOT reset at
   ExitBootServices (pre-rearm `st=0f`).
3. **The N6 syscall seam (ADR 0007):** slots 0–11 frozen (`ping`/`write`/
   `yield`/`exit`/`sleep`/`ipc_send`/`ipc_recv`/`procs`/`wait`/
   `udp_listen`/`udp_send`/`udp_recv`), 12–63 reserved → ENOSYS,
   `implemented_count = 12`. Errors EINVAL -1, EBADF -2, EFAULT -3,
   ENOSYS -4, ENOSPC -5. `uaccess.copy_in`/`copy_out` are the ONLY way
   bytes cross. The `syscalls` report prints rows 0–11.
4. **Runner surface (N1–N6):** `--net <capture-file>` attaches
   `VZVirtioNetworkDeviceConfiguration` with a
   `VZFileHandleNetworkDeviceAttachment` (a `socketpair(AF_UNIX,
   SOCK_DGRAM)`; VZ holds one end — every guest-TX frame arrives as a
   datagram the capture thread appends to the file byte-exactly; host→
   guest writes go into the runner's end, `fds[1]`); fixed host MAC
   `02:00:00:00:00:01`; plus the request-driven responders
   `--net-inject <file>` / `--net-arp-respond <host-ip>` /
   `--net-icmp-respond <host-ip>` / `--net-udp-respond
   <host-ip>:<host-port>` (the capture thread detects a guest frame and
   writes the deterministic answer back — never a sleep), all OFF by
   default; `config.networkDevices = []` without `--net` — every
   existing gate stays byte-identical.
5. **Gate shape / aggregates:** `tools/verify-live-net-{tx,rx,arp,icmp,
   udp,udp-syscall}.sh` are the templates — the script1/script2 (0.5 s
   settle) + 20 ms marker-poll patterns, marker greps with `|| true`
   under `set -euo pipefail`, evidence under `artifacts/live-net-*`,
   and the full `verify-vz` aggregate is **34 gates** (each new card
   makes it 35, then 36). The N5/N6 gates key their observation phase on
   the guest's own markers/counters, never on wall-clock assumptions.
6. **User-program pattern (M4/M5):** `user/src/*.zig` → DSK1 image →
   ESP (build.zig blocks + `image/make-image.sh`); `exec <file>` loads
   by name; entry contract argc in x0 / argv-block VA in x1; 7-slot
   pool (shell + worker + 4 user + idle). **NEITHER N7 NOR N8 adds a
   user program** — N8 is monitor-surface (the roadmap's DHCP is a
   monitor card; a DHCP-from-EL0 syscall seam is a FUTURE card, NOT
   here). The N6 seam regression (UDP.BIN) stays green.

## Card N7 — outbound connectivity: `VZNATNetworkDeviceAttachment`

### Why

Every N1–N6 gate proves the guest against the DETERMINISTIC file-handle
attachment — a socketpair to the runner. The milestone's promise is a
guest on a real network, and the roadmap + N1 planning doc both name the
NAT attachment as the outbound rung. NAT is also the honest prerequisite
for N8's second phase (a guest that leases its address from the host's
real network services). The guest DRIVER needs nothing new — the stack
(static IP + ARP + ICMP + UDP) is already complete; this card is the
attachment + the gate shape.

### Scope

1. **Runner: a new flag `--net-nat` (boolean; OFF by default).** In
   `host/vm-runner/Sources/VMRunner/main.swift`, attach
   `VZNATNetworkDeviceConfiguration` with a
   `VZNATNetworkDeviceAttachment` (macOS 27+; the `#if SPIKE` /
   availability pattern for API-floor concerns). Mutually exclusive with
   `--net <capture-file>` — one network device per guest for now
   (refuse both with a clear `fail(...)`, the existing flag-validation
   shape). Without the flag `config.networkDevices = []` — the default
   VM, and therefore the full 34-gate aggregate, stays byte-identical.
2. **MAC under NAT — claim-time observation, NOT an assumption.** The
   file-handle path sets `netConfig.macAddress` fixed; under NAT, record
   what MAC the guest's `VIRTIO_NET_F_MAC` read actually observes
   (locally administered, `net` report line). If NAT ignores the
   configured MAC, the gate must not assert `mac=02:00:00:00:00:01` —
   assert what is OBSERVED and pin it in the hardware contract
   (`[inferred]` → `[observed]` only with a saved `artifacts/` log).
3. **The NAT subnet/gateway — claim-time observation.** The VZ API does
   not expose the NAT prefix; the gate must empirically discover it on
   the first live run (commonly 192.168.64.0/24, gateway .1 — record
   the observed subnet in the hardware contract; do NOT hardcode before
   observing). The gate scripts may probe the host side (e.g., read the
   runner's printed NAT interface state if exposed) and must document
   the discovery step. The guest then `net ip <observed-subnet-addr>`,
   `net arp <gateway>` (the NAT attachment answers ARP for its gateway
   IP — observe), `net ping <gateway>`.
4. **Gate shape change — DELIBERATE and documented:** the byte-exact
   capture-file evidence pattern does NOT apply through NAT (the host
   translates the frames — that is the point of NAT; the runner never
   sees guest bytes). The N7 gate asserts **guest-observed counters**
   (`net` report: `pong=1` with the echoed seq, the rx/tx counters, the
   ARP table holding the gateway) instead of capture bytes. This is the
   card's one engineering surprise to record: the milestone's evidence
   ladder shifts from byte-exact captures (N1–N6) to guest-side
   counters (N7+) on the NAT path.
5. **Live gate `tools/verify-live-net-nat.sh` (new, class B):** ONE run
   on VZ with `--net-nat`: `net ip` to the observed subnet, `net arp
   <gateway>` (table shows the gateway MAC), `net ping <gateway>` →
   `pong=1` with seq 1 (the deterministic proof — the NAT gateway round
   trip needs NO internet), plus the full `net` report and a responsive
   shell. External-address pings (e.g., a public IP) are optional/manual
   runs, NOT part of the gate (no internet dependency in CI). The FULL
   34-gate `verify-vz` aggregate must stay green — proof the `--net-nat`
   mode left the default VM byte-identical. Evidence under
   `artifacts/live-net-nat-*`.
6. **Host tests / docs:** the flag parsing + mutual-exclusion failure
   path (`swift build --package-path host/vm-runner`); hardware-contract
   NAT observation (subnet, gateway, MAC-under-NAT, ARP/ICMP answers for
   the gateway) flipped `[observed]` with saved logs only; march-m5 N7
   row; status/gate-inventory (35-gate aggregate).

## Card N8 — DHCP: the guest obtains its address from a server

### Why

The address is still typed by hand (`net ip`). The roadmap's sketch
named DHCP as the rung after the static IP, and a guest on the N7 NAT
network realistically needs one. N8 is the bounded RFC 2131 client on
the N5/N6 UDP layer — a monitor card (like N3/N4/N5 were), NOT a syscall
card: no ADR 0007 change, no EL0 program, no sockets/fds/POSIX. The
honest second phase of its live gate runs against the HOST'S REAL NAT
services (the VZ NAT attachment), proving the client against a real
server, not just a crafted one.

### Scope

1. **`kernel/src/dhcp.zig` (NEW — pure RFC 2131 logic, the `arp.zig`/
   `udp.zig` pattern, host-testable):** the full four-message handshake
   from INIT — DISCOVER (broadcast, a transaction id from the claim-2665
   CSPRNG, or a deterministic counter for the fixtures) → parse OFFER
   (magic cookie `0x63825363`, option 53 = 2, server identifier 54,
   yiaddr) → REQUEST (option 50 = the offered IP, option 54 = the server
   id) → parse ACK (option 53 = 5) → BOUND: record the lease {ip, mask,
   gateway, server id, lease time}. **Honest bounds (documented, never
   assumed away):** no renewal/rebind/lease-expiry (the lease time is
   recorded, not enforced); no hostname/DNS options stored; no DHCPv6;
   no relay/giaddr; ONE client state machine — a fixed BSS struct + one
   fixed 256-byte packet buffer, no heap, no unbounded anything. The
   client's UDP packets use src 68 → dst 67 with a BROADCAST dst
   (255.255.255.255 / ff:ff:ff:ff:ff:ff — no ARP lookup; the N2 MAC
   filter accepts broadcast).
2. **The ONE protocol-seam change: a broadcast-dst send path.** The N5
   `net_udp_send` seam resolves a peer MAC via ARP; DHCP needs L2
   broadcast. Extend the send seam (or add `net_dhcp_send`) so a
   broadcast-dst datagram (dst IP 255.255.255.255) goes out with dst MAC
   ff:ff:ff:ff:ff:ff directly, no ARP — the ONLY change to the N5 layer,
   and it is a send-direction extension, not a semantics change (every
   existing send behavior stays). Host-test both directions.
3. **Monitor surface:** `net dhcp` SUBCOMMAND (registry stays 34 — the
   `net` command's subcommand shape from N3/N4/N5): runs the client
   through the handshake and prints the steps + the bound lease
   (`net: dhcp bound ip=… mask=… gw=… server=…`); counters (discover
   sent, offer recv, request sent, ack recv, nack, timeout) with a
   bounded retry (e.g., 3 DISCOVER attempts then an honest refuse); on
   BOUND it sets `arp.own_ip` (THE one copy — DHCP overwrites the static
   address honestly and the report shows the old → new); `net` gains a
   `dhcp=` report line (bound/unbound + lease). The static `net ip`
   stays as the fallback. Driven by the shell idle drain (the polled
   drain contract — no new interrupts).
4. **Runner: `--net-dhcp-respond <host-ip>` (the `--net-udp-respond`
   pattern; OFF by default, requires `--net`).** The capture thread
   detects the guest's DHCPDISCOVER (UDP 68→67, ethertype 0x0800, proto
   17, dst broadcast) and writes a crafted OFFER (then, on the guest's
   REQUEST, the ACK) with a FIXED, gate-assertable lease {ip, mask
   255.255.255.0, gateway, server id} — byte-exact fixtures for the
   DISCOVER/REQUEST shapes and the OFFER/ACK responses. This is the
   deterministic file-handle path for class-A-style gate coverage.
5. **Live gate `tools/verify-live-net-dhcp.sh` (new, class B), TWO
   phases:**
   - Phase 1 — **deterministic file-handle:** `--net` +
     `--net-dhcp-respond <host-ip>`: `net dhcp` → the DISCOVER is
     byte-exact in the capture, the crafted OFFER/ACK land, the guest
     prints `net: dhcp bound ip=<fixture-ip> …` and `net` shows the
     `dhcp=` line + the counters — the client's handshake proven against
     known bytes.
   - Phase 2 — **real NAT (rides N7's `--net-nat`):** `net dhcp` against
     the host's real services — the lease comes from a REAL DHCP server.
     **Claim-time observation:** whether the VZ NAT attachment serves
     DHCP (the common VZ NAT shape serves the 192.168.64.0/24 pool with
     a DHCP server — observe and record in the hardware contract; if it
     does NOT, phase 2 is honestly blocked with the observation
     recorded, NOT faked). On BOUND: `net arp <gateway>` + `net ping
     <gateway>` → `pong=1` — the honest end-to-end: the guest leases its
     own address and reaches beyond the VM.
   The FULL 35-gate `verify-vz` aggregate (N7 landed) must stay green;
   the N6 seam regression (UDP.BIN) re-runs green. Evidence under
   `artifacts/live-net-dhcp-*`.
6. **Host tests (class A):** DHCP packet build/parse fixtures (magic
   cookie, option 53/50/54/55/255, xid echo, yiaddr extraction), the
   state machine transitions (INIT → SELECTING → REQUESTING → BOUND;
   OFFER validation failures — bad cookie, wrong type, malformed; ACK
   vs NACK; timeout + bounded retry), the broadcast-send seam, the
   `net dhcp` output shapes + counters, and the report test
   re-derivation if `net`'s shape changes. The transcript fixture
   re-derives only if the `net` report line appears in it.

## Suggested split / sequence / agent ownership

- **N7 (claim `net-nat`, branch `agent/buffy/m5-net-nat`) — runner +
  gate only, NO guest code.** Owns `--net-nat` +
  `VZNATNetworkDeviceAttachment` in `host/vm-runner/Sources/VMRunner/
  main.swift`, the mutual-exclusion failure, `tools/verify-live-net-
  nat.sh`, the hardware-contract NAT observation, and the march-m5 N7
  row. Land FIRST — N8's phase 2 needs the attachment.
- **N8 (claim `net-dhcp`, branch `agent/buffy/m5-net-dhcp`) — guest
  protocol card.** Owns `kernel/src/dhcp.zig`, the broadcast-dst send
  seam, the `net dhcp` subcommand + `net`'s `dhcp=` line, the runner's
  `--net-dhcp-respond`, `tools/verify-live-net-dhcp.sh`, and the
  march-m5 N8 row. Claims on merged main after N7 (or ships phase 1
  first and phase 2 once N7 merges — sequence N7 → N8).
- Both cards: **NO ADR 0007 change, NO scheduler/process/heap changes,
  NO user programs, default runner config unchanged.** Cross-cutting
  docs (`status.md`, `gate-inventory.md`, `hardware-contract.md`) are
  updated per card at claim close-out, never during implementation.

## Do not

- Regress the N1–N6 observed contract (feature mask, MAC path, no-EBS
  reset, TX/RX 12-byte headers, 1530-byte RX minimum, MAC filter, the
  ARP/IPv4/ICMP/UDP seams + counters, the N6 syscall seam + `syscalls`
  rows 0–11, the 46-byte unpadded observation) — read the claims +
  hardware contract + driver comments first.
- Assume the NAT subnet/gateway/MAC or NAT-DHCP behavior from
  documentation — VZ exposes almost none of it; observe at claim time
  and record it. Never gate on a MAC/subnet that was not OBSERVED.
- Gate NAT evidence on byte-exact captures — the capture-file pattern
  does not apply through NAT; guest-observed counters are the honest
  evidence shape (documented in the gate).
- Add syscalls (ADR 0007 frozen — no DHCP-from-EL0, no new slots);
  add TCP (N9+, the roadmap's far-future rung), routing tables, DNS,
  sockets/fds/POSIX, or a libc.
- Make N8 a user-program/syscall card (the roadmap's DHCP is a monitor
  card; the client's state machine is bounded and monitor-driven).
- Add heap, allocation, or unbounded tables (one fixed 256-byte DHCP
  packet buffer + one client struct at most); touch the scheduler pool,
  the switching core, the lifecycle states, or the process registry.
- Change the default runner config (the new flags stay OFF by default —
  the 34-gate aggregate must stay green) or make an N8 responder
  require `--net-nat` (phase 2 may, the responder must not).
- Claim hardware behavior without a saved VZ log (`artifacts/`).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
