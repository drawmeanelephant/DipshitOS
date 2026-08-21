# Milestone five, card N6 — UDP exposed to user programs behind a bounded syscall seam (ADR 0007 amendment)

> **PLANNING-FIRST — card N6 of milestone five, the roadmap's "UDP
> datagrams behind a bounded syscall seam (an ADR 0007 amendment)" rung
> (docs/roadmap.md — the N5 card delivered UDP over the monitor `net`
> surface with ADR 0007 frozen; THIS card is the seam). N1 (transport +
> TX, claim 1373), N2 (raw RX, claim 6076), N3 (ARP, claim 7293), N4
> (IPv4/ICMP, claim 0148) and N5 (UDP, claim 8552 — merged main
> `2c9a406`) are ALL MERGED — the observed contract below is the
> baseline this card builds on. The seam is the ONE ABI change of the
> card (the ipc slots-5/6 precedent): THREE new frozen syscall rows.
> No libc/POSIX/heap anywhere. New branch `agent/buffy/m5-udp-syscall`;
> claim via branch + slug `udp-syscall` with
> `bash tools/status/claim-id.sh` (the number is TBD at claim time).**

## Why

N5 proved UDP on the monitor `net` surface: the guest binds a port,
receives datagrams byte-exact, sends to a resolved peer (or loops back
to itself), and the counters tell the whole story. But a USER PROGRAM
cannot touch any of it — the N5 surface is the EL1h monitor's. This card
exposes the SAME bounded UDP state to EL0 through the ADR 0007 syscall
seam, the established pattern: one card, one ABI amendment, every byte
crossing the claim-6120 uaccess window, kernel-owned and bounded. The
proof rides a new ESP image (UDP.BIN) that binds, sends (loopback AND to
the host), and receives — the strongest possible end-to-end evidence
that a program can do networking without the monitor.

## The observed contract (the baseline — do NOT re-derive, do NOT regress)

Recorded in `docs/claims/1373-net-tx.md` … `docs/claims/8552-udp.md`,
`docs/hardware-contract.md` (net bullets, `[observed]` with saved logs),
`docs/march-m5.md`, and the driver comments in `kernel/src/virtio_net.zig`
/ `arp.zig` / `ipv4.zig` / `udp.zig`. A fresh agent should read those
FIRST. The load-bearing facts for the seam:

1. **The N5 UDP module (`kernel/src/udp.zig`) is the layer the seam
   wraps.** Public surface: `listen_port(port) -> bool` (refuse
   full/duplicate), `close_port(port) -> bool`, `deliver(dst_port,
   datagram)`, `pop(port) -> ?Datagram` (the 4-slot ring, drop-oldest),
   `loopback(own_ip, dst_port, payload)`, `build_frame(...)` (the full
   Ethernet+IPv4+UDP frame builder), counters (`received`, `sent`,
   `loopbacked`, `dropped_badsum`, `dropped_closed`, `dropped_len`).
   The 4-slot listen table + 4×72-byte per-listener datagram rings are
   pure BSS. A datagram = the 8-byte header (src port, dst port, length,
   checksum) + payload; `datagram_max` = 72, `payload_max` = 64.
2. **`virtio_net.net_udp_send(target_ip: [4]u8, dst_port: u16, payload,
   out_len) -> SendResult`** is the transmit seam (N5): own-IP sends
   take the LOOPBACK path (`udp.loopback`, no device round trip, counts
   `sent` + `loopbacked`); a peer send needs `arp.lookup(target_ip)`
   (`.no_peer` when unresolved — `net arp <ip>` resolves it first) and
   a live transport (`.not_ready`); success counts `udp.sent`. Sends
   always use the FIXED source port 7000 (`udp.default_src_port`) and
   the payload is truncated honestly at `payload_max`.
3. **The syscall ABI (ADR 0007, `docs/decisions/0007-syscall-abi.md`):**
   x8 = number, x0–x5 = args, x0 = result, `svc #0`. Slots 0–8 are
   frozen (`ping`/`write`/`yield`/`exit`/`sleep`/`ipc_send`/`ipc_recv`/
   `procs`/`wait`), 9–63 reserved → ENOSYS. Errors: EINVAL -1, EBADF -2,
   EFAULT -3 (the claim-6120 uaccess contract), ENOSYS -4, ENOSPC -5.
   `implemented_count = 9`; the `syscalls` report prints rows 0–8.
   `uaccess.copy_in`/`copy_out` (claim 6120) are the ONLY way bytes
   cross the boundary. The claim-5965 ipc handlers are the template:
   copy_in through a fixed BSS staging buffer, error precedence
   documented, recv = peek → copy_out → drop (an EFAULT never loses a
   message). `scheduler.current_id()` + `process.find_by_task` resolve
   the caller when identity matters (sys_ipc_recv EINVALs an EL1h task).
4. **The M4 user-program pattern** (claims 4613/5965/4636/9946):
   `user/src/*.zig` → DSK1 image → ESP (build.zig blocks + the
   parameterized `image/make-image.sh` embedding); `exec <file>`
   loads by name; the entry contract puts argc in x0 / argv-block VA in
   x1 (card 3e); the payload is naked-asm `_start` with the
   fixed-register syscall convention (peer.zig's `mov x8, #N; svc #0`
   + sys_write of pinned `pub const` markers is the template); a
   never-exiting program occupies its pool slot (7-slot pool: shell +
   worker + 4 user + idle). The `syscalls` report + the `net udp`
   counters are the monitor-visible surface the live gate greps.
5. **Runner surface (N5):** `--net` / `--net-inject` /
   `--net-arp-respond <host-ip>` / `--net-icmp-respond <host-ip>` /
   `--net-udp-respond <host-ip>:<host-port>` (the capture thread
   answers the guest's UDP datagrams byte-exact). The script1/script2
   (0.5 s settle) gate pattern + the 20 ms marker poll are the template.
6. **Gate shape / aggregates:** `tools/verify-live-net-udp.sh` (4
   phases, byte-exact captures) is the template; the `verify-vz`
   aggregate is 33 gates — N6 makes it 34. `tools/verify-live-sleep.sh`
   asserts the `syscalls` report shape (`implemented=9` → re-derive to
   `implemented=12`).

## Scope

1. **ADR 0007 amendment — THREE new frozen slots** (the card's ONE ABI
   change, the ipc slots-5/6 precedent; every existing number 0–8 stays
   frozen):
   - **Slot 9 — `sys_udp_listen(port) -> i64`:** bind the bounded kernel
     listen table to `port` (1–65535; 0 → EINVAL). Duplicate or full
     table → EINVAL (the `listen_port` bool, honestly mapped). Returns 0
     on success. No uaccess.
   - **Slot 10 — `sys_udp_send(ip, port, buf, len) -> i64`:** send ONE
     UDP datagram to `ip:port` from the FIXED source port 7000. `ip` is
     the 4 octets in NETWORK byte order in the low 32 bits of x0 (e.g.
     10.0.0.2 = `0x0a000002` — the kernel extracts bytes
     `(ip>>24)&0xff, (ip>>16)&0xff, (ip>>8)&0xff, ip&0xff`, never a
     bitcast: AArch64 is little-endian). `len` bytes (≤ 64, truncated
     honestly at `payload_max`) are copied from `buf` through uaccess
     into a fixed BSS staging buffer, then `net_udp_send` runs the N5
     path: own-IP → loopback, peer → ARP lookup (`.no_peer` →
     EINVAL — resolve first via `net arp <ip>`), transport unready →
     EINVAL. Port 0 → EINVAL. Bad `buf` → EFAULT. Returns the payload
     length sent (the sys_write / sys_ipc_send positive-result shape).
   - **Slot 11 — `sys_udp_recv(port, buf, max) -> i64`:** copy the
     oldest datagram for the listener on `port` OUT through uaccess
     (the full 8-byte header + payload — the caller parses the header
     for the src port; the src IP is not kept, honest bound). Returns
     the copied length; 0 when the ring is empty; EINVAL when not
     listening on `port`; EFAULT leaves the datagram QUEUED (peek →
     copy_out → pop — add `udp.peek` so the claim-5965 "an EFAULT never
     loses a message" contract holds). `max` clamps to `datagram_max`
     (72); shorter copies truncate and CONSUME (documented, the ipc
     recv shape).
   - `implemented_count` 9 → 12; the `syscalls` report prints rows
     0–11; the counters and names are deterministic (the report test +
     `tools/verify-live-sleep.sh`'s `implemented=12` assertion re-derive
     together).
   - **Honest bounds (documented in the ADR, never assumed away):** the
     listen table is KERNEL-GLOBAL — any EL0 task may bind or receive on
     any port (no per-process port ownership; the N5 table is shared
     with the monitor; a later card can add ownership). The syscall
     layer does NOT resolve ARP (`.no_peer` is an honest EINVAL — the
     gate resolves first and the EL0 program retries); no blocking, no
     sockets, no fds, no POSIX — this is the ADR-0007 numbered seam.
2. **The EL0 proof — a NEW ESP image UDP.BIN (`user/src/udp.zig`),** the
   peer.zig pattern (naked asm, `pub const` markers pinned by host
   tests). Deterministic flow, hardcoded gate addresses (10.0.0.1 =
   own, 10.0.0.2 = host, ports 7000/9999, payload bytes "ping") exposed
   as `pub const`s:
   - `sys_udp_listen(7000)` → prints `udp: listen ok` (or the error).
   - LOOPBACK from EL0: `sys_udp_send(own 10.0.0.1, 7000, "ping", 4)`
     then `sys_udp_recv(7000, buf, 72)` → prints `udp: loop ping`
     (the 4-byte payload at datagram offset 8 — the header is parsed by
     the program, proving the datagram shape from EL0).
   - Round trip: `sys_udp_send(10.0.0.2, 9999, "ping", 4)` — retry on
     EINVAL with a cooperative yield (the ARP reply may still be in
     flight; the shell idle loop drains RX between quanta) — then poll
     `sys_udp_recv(7000, buf, 72)` until the host's echoed answer lands
     (yield between polls) → prints `udp: got ping`.
   - `sys_exit(17)` (the UDP protocol number — a distinct status for the
     gate's `procs UDP.BIN exited status=17` assertion).
   - The payload parse of the 12-byte datagram (skip the 8-byte header,
     print bytes 8..12 as text) is the EL0-side proof that the recv
     returns the full datagram shape.
3. **Kernel wiring:** `syscall.zig` (slots 9/10/11, table rows,
   `implemented_count`, report) + `udp.zig` (`peek`) — the handlers live
   in syscall.zig and call the N5 layer (NO protocol logic in the
   handlers; `net_udp_send` already exists). No monitor/shell changes
   beyond the `syscalls` report (the `net udp` monitor surface is
   untouched — the seam shares the SAME kernel state). No runner change
   (N5's `--net-udp-respond` answers the program's sends).
4. **Host tests (class A):** syscall tests — listen (ok / duplicate /
   full / port 0), send (loopback delivers into the ring, peer send
   counts + TX, `.no_peer`/unready → EINVAL, port 0 → EINVAL, EFAULT
   for a bad buf, truncation at 64), recv (empty → 0, unbound → EINVAL,
   byte-exact copy, clamp + truncate, EFAULT preserves the datagram —
   peek → copy_out → pop) — plus the report test re-derivation
   (`implemented=12`, rows 0–11) and an `udp.peek` unit test. The
   UDP.BIN marker strings + payload are `pub const`s pinned by a host
   test (the peer.zig pattern). The transcript fixture re-derives if the
   `syscalls` line appears in it.
5. **Live gate `tools/verify-live-net-udp-syscall.sh` (new, class B):**
   ONE run on real VZ, the script1/script2 settle pattern:
   - Phase 1 — **EL0 loopback:** `net ip 10.0.0.1` + `net arp 10.0.0.2`
     (resolve first — the program's peer send needs the MAC) + `exec
     UDP.BIN`. The serial log shows `udp: listen ok` → `udp: loop ping`
     → `udp: got ping` in order, then `procs UDP.BIN exited status=17`
     (the reap report). The host capture holds the ARP request (42
     bytes) + the program's datagram (46 bytes: src 10.0.0.1:7000 →
     10.0.0.2:9999, payload "ping") — the byte-exact concatenation
     fixture (the N5 phase-3 shape). The host's `--net-udp-respond
     10.0.0.2:9999` answer lands in the program's listener ring
     (proven by `udp: got ping` — the payload matches).
   - Phase 2 — **scope check from EL0:** after the program exits, the
     monitor greps `syscalls` (rows 9/10/11 counted) and the `net udp`
     counters (rx=1, tx=1, loop=1 — the loopback counted, the round
     trip counted) — the seam's counters are visible in the SAME report
     surface the monitor uses.
   The FULL 34-gate `verify-vz` aggregate must stay green (no runner
   config change — the N5 flags already exist). Evidence under
   `artifacts/live-net-udp-syscall-*`.

## Sequence

1. Claim first (this prompt + `docs/claims/<id>-udp-syscall.md` +
   `docs/logs/agent-buffy-m5-udp-syscall.md` +
   `bash tools/status/refresh-indexes.sh`). N1–N5 are MERGED (main
   `2c9a406`) — the N6 claim branches from merged main, carrying the N6
   prompt commit (the two-PR pattern: prompt PR first, then the claim
   PR; either merge order self-cleans).
2. Class A first: fmt, unit tests, transcript byte-identical, build/
   image/inspect, swift build, context, coordination ×2, mmu-debt.
3. Class B on VZ: the new `verify-live-net-udp-syscall.sh` + the FULL
   34-gate aggregate, evidence under `artifacts/`.
4. Docs reconciliation: ADR 0007 (the slots-9/10/11 amendment), march-m5
   (N6 row + flip; agent-split N6 line), roadmap (the "later, sketched
   only" UDP bullet flips to the N6 row), status (milestone-five row +
   gate table), gate-inventory (new live-net-udp-syscall row + the
   33→34 aggregate update), README, architecture, claim flip, log
   append, PR per the repo template (real observed evidence only).

## Do not

- Regress the N1–N5 observed contract (feature mask, MAC path, no-EBS
  reset, TX/RX 12-byte header, 1530-byte RX minimum, MAC filter, the ARP
  seam, the IPv4 validation + ICMP path, the UDP listen/loopback
  semantics + counters) — read the claims + hardware contract + driver
  comments first.
- Add protocol logic to the syscall handlers (the N5 layer owns UDP;
  `net_udp_send` + `udp.*` already exist — the handlers marshal args,
  copy bytes through uaccess, and call through).
- Resolve ARP in the syscall path (no blocking, no internal ARP
  state machine — `.no_peer` is an honest EINVAL, the gate resolves
  first, the program retries). No sockets, fds, POSIX, or a libc.
- Touch existing syscall numbers, the uaccess contract, the scheduler
  pool, the switching core, the lifecycle states, the process registry,
  or the mailbox.
- Make UDP.BIN read its addresses from argv (hardcode the deterministic
  gate addresses as pinned `pub const`s — one gate, one shape).
- Change the default runner config (no new flags — N5's `--net-udp-
  respond` answers the program; every existing gate stays byte-
  identical).
- Add heap, allocation, or unbounded tables (the seam adds one fixed
  BSS staging buffer at most — reuse `sys_write`'s cap or add a
  `payload_max`-sized one).
- Claim hardware behavior without a saved VZ log (`artifacts/`).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
