# Claim: Milestone five, card N6 — UDP exposed to user programs behind a bounded syscall seam

- **Owner:** buffy (`agent/buffy/m5-udp-syscall`)
- **Prompt / plan:** `docs/m5-udp-syscall-prompt.md` (planning-first;
  card N6 of milestone five — the roadmap's "UDP datagrams behind a
  bounded syscall seam (an ADR 0007 amendment)" rung; N5 delivered UDP
  over the monitor `net` surface with ADR 0007 frozen, this card is the
  seam). N1 (claim 1373), N2 (claim 6076), N3 (claim 7293), N4 (claim
  0148) and N5 (claim 8552) are MERGED (main `2c9a406`) and their
  OBSERVED contract is the baseline this card builds on; the claim-time
  questions are the ones N1–N5 did NOT answer. The seam is the card's
  ONE ABI change (the ipc slots-5/6 precedent): THREE new frozen
  syscall rows. No libc/POSIX/heap anywhere.
- **Scope:** (1) ADR 0007 amendment — slots 9/10/11: `sys_udp_listen(port)`
  (bind the bounded kernel listen table; 0/duplicate/full → EINVAL),
  `sys_udp_send(ip, port, buf, len)` (ONE datagram to `ip:port` from
  the FIXED source port 7000; `ip` = the 4 octets in network byte order
  in the low 32 bits of x0; payload ≤ 64 copied through uaccess,
  truncated honestly; own-IP sends take the N5 LOOPBACK path, a peer
  send needs its MAC in the ARP table — unresolved/unready → EINVAL;
  EFAULT for a bad pointer; returns the payload length sent) and
  `sys_udp_recv(port, buf, max)` (the oldest datagram for the listener
  — the full 8-byte header + payload; 0 when empty; EINVAL when not
  listening; EFAULT leaves the datagram queued — peek → copy_out → pop,
  the claim-5965 contract; `max` clamps to 72, shorter truncates and
  consumes). `implemented_count` 9 → 12, `syscalls` rows 0–11. (2)
  `kernel/src/udp.zig` gains `peek` (the recv-EFAULT preservation).
  (3) the EL0 proof — NEW ESP image UDP.BIN (`user/src/udp.zig`, the
  peer.zig naked-asm pattern with pinned `pub const` markers):
  `sys_udp_listen(7000)` → `udp: listen ok`; LOOPBACK from EL0
  (`sys_udp_send` to own 10.0.0.1:7000 + `sys_udp_recv` → `udp: loop
  ping`); round trip (`sys_udp_send` to 10.0.0.2:9999 with a
  yield-retry on EINVAL while the ARP reply lands, poll `sys_udp_recv`
  until the host's `--net-udp-respond` answer arrives → `udp: got
  ping`); `sys_exit(17)`. (4) host tests (class A): the syscall
  handlers (listen ok/dup/full/0, send loopback/peer/no-peer/not-ready/
  port-0/EFAULT/truncation, recv empty/unbound/byte-exact/clamp/
  truncate/EFAULT-preserves), `udp.peek`, the report re-derivation
  (`implemented=12`, rows 0–11), the pinned UDP.BIN markers. (5) new
  class B gate `tools/verify-live-net-udp-syscall.sh` — ONE run on real
  VZ: `net ip 10.0.0.1` + `net arp 10.0.0.2` + `exec UDP.BIN` → the
  serial log shows `udp: listen ok` → `udp: loop ping` → `udp: got
  ping` then `procs UDP.BIN exited status=17`; the capture holds the
  ARP request + the program's 46-byte datagram (byte-exact
  concatenation fixture); phase 2 greps the `syscalls` rows 9/10/11 +
  the `net udp` counters (rx/tx/loop) — the seam's counters visible in
  the SAME monitor report surface; the FULL 34-gate `verify-vz`
  aggregate must stay green (NO runner change — N5's
  `--net-udp-respond` answers the program).
- **Depends on:** N1–N5 MERGED (claims 1373/6076/7293/0148/8552 — main
  `2c9a406`): the transport, the observed RX seam, the ARP seam
  (`arp.own_ip` + the table), the IPv4 validation + protocol dispatch,
  the N5 UDP layer (`udp.listen_port`/`pop`/`loopback`/
  `net_udp_send`/counters), the ADR 0007 ABI + uaccess + the
  claim-5965/6120 handler patterns, the M4 user-program pipeline
  (user/src + build.zig + make-image.sh + exec), and
  `tools/verify-live-net-udp.sh` as the gate template. Branched from
  MERGED MAIN (no open-PR dependency), carrying the N6 prompt commit.
- **Status:** ✅ DONE 2026-08-12 on `agent/buffy/m5-udp-syscall` (from
  the N6 prompt commit — PR #100's prompt doc, on merged main
  `2c9a406`; claim PR pending).

## Notes

**Why this card:** N5 proved UDP on the monitor surface — bind, receive
byte-exact, send to a resolved peer, loopback — but no user program can
touch any of it. This card exposes the SAME bounded kernel state to EL0
through the ADR 0007 seam, the established pattern: one card, one ABI
amendment, every byte across the claim-6120 uaccess window, kernel-owned
and bounded. The proof rides a new ESP image that binds, sends (loopback
AND to the host), and receives — the strongest end-to-end evidence that
a program can do networking without the monitor, and the first network
syscall in the frozen table.

**Observe, don't assume (claim-time questions):** (a) does the EL0
syscall path through `net_udp_send` behave identically to the monitor
path (same counters, same loopback, same `.no_peer` semantics)? — the
handlers call the N5 layer directly, but the live gate's counter greps
pin it; (b) the ARP-reply learning race when a program sends right
after `net arp <ip>` (the reply is drained by the shell idle loop) — the
gate resolves BEFORE exec and the program retries on EINVAL, so the
first-send race is observed, not assumed away; (c) no new device
behavior is expected (the seam is a syscall layer over the observed N5
contract — the device sees the same raw Ethernet frames) — record any
surprise with a saved VZ log as `[observed]`, never assumed.

## Close-out (2026-08-12)

**All claim-time questions answered; the gate PASS 4/4 on VZ.** The EL0
syscall path drives the SAME N5 counters (rx=2 tx=2 loop=1 drop=0 in
both the monitor and the seam reports), the ARP-resolve-before-exec +
yield-retry shape landed without a first-send refusal (the peer send
succeeded first try in every live run), and the device saw NO new
behavior (the 46-byte datagram travels unpadded, consistent with the
N3/N4/N5 observation). UDP.BIN's full transcript ran IN ORDER: `udp:
listen ok` → `udp: loop ping` → `udp: got ping` → `udp: recv err -1`
→ `udp: send err -1` → `procs UDP.BIN exited status=17` / `tasks
user-exec exited status=17` / `tasks user-exec reaped`; the capture
held the 42-byte ARP request + the 46-byte datagram byte-exact; the
observation phase showed `implemented=12` with rows 9/10/11 counted.

**Two honest gate-engineering lessons, recorded:**

1. **An early `--script-expect` makes a HEALTHY kernel look hung.** The
   first gate keys killed the VM at ~5 s — script2 (typed right after
   the early ready marker) was answered instantly, the expect
   (`net-udp-ok`) matched, and the runner stopped the VM before the
   ring (1 s ticks, 5 tasks) returned to UDP.BIN after its
   cooperative `sys_yield`. The tasks snapshot told the story:
   `switches=5` (one full rotation), every task `state=ready` — and
   `net udp: rx=2` showed the host's answer had ALREADY been received;
   the program simply never got another quantum before the VM died.
   The gate now keys its observation phase on the program's OWN
   `udp: got ping` marker and its exit on `tasks user-exec reaped`.
2. **An absent marker under `set -euo pipefail` was killing the gate
   BEFORE it could report the FAIL** — the bare
   `l_x=$(grep … | head -1 | cut …)` substitution exits the script
   when grep finds nothing (bash 3.2 + pipefail), silently, with no
   report file. The marker greps now carry `|| true`; an absent marker
   is an empty value and the phase assertion honestly fails.

**A schedule-truth this gate is the FIRST to prove live:** a user task
RESUMES after `sys_yield`. The boot payload yields as its LAST act
(before its exit), so no earlier live gate ever observed a user task
running again after a cooperative yield — the ring returning to UDP.BIN
between polls (`udp: e` → … → `udp: got ping` in the serial log) is the
first observation. The claim-8215/3594 sleep/exit seam was already
proven; the yield-resume path uses the identical frame machinery, but
it had never been observed from EL0 until this card's poll loop.

**Evidence:** `tools/verify-live-net-udp-syscall.sh` PASS 4/4 on VZ
(artifacts `live-net-udp-syscall-*`); full class A green (fmt, 31-module
unit suite incl. the syscall 9/10/11 + udp.peek + UDP.BIN-marker tests,
byte-identical transcript, build/image/inspect with UDP.BIN embedded,
swift build, context, coordination ×2, mmu-debt); the **34-gate
`verify-vz` aggregate re-ran green 34/34** (evidence
`artifacts/m5-udp-syscall-vz-sweep.log`). The next rung: outbound with
`VZNATNetworkDeviceAttachment`, or DHCP/TCP on the N6 seam.
