# Claim: Milestone five, card N7 — outbound connectivity: `VZNATNetworkDeviceAttachment`

- **Owner:** buffy (`agent/buffy/m5-net-nat`)
- **Prompt / plan:** `docs/m5-net-outbound-prompt.md` (planning-first;
  card N7 of milestone five — the roadmap's reserved "outbound with
  `VZNATNetworkDeviceAttachment`" rung). N1 (claim 1373), N2 (claim
  6076), N3 (claim 7293), N4 (claim 0148), N5 (claim 8552) and N6
  (claim 1384) are MERGED (main `87fe7ae`); the N7/N8 planning prompt
  is the open PR #102 (`agent/buffy/m5-net-outbound-prompt`). This
  card is RUNNER + GATE ONLY — **NO guest code**: the guest's stack
  (static IP + ARP + ICMP + UDP) is already complete and untouched.
- **Scope:** (1) a new runner flag `--net-nat` (boolean, OFF by
  default) in `host/vm-runner/Sources/VMRunner/main.swift` that
  attaches `VZVirtioNetworkDeviceConfiguration` with a
  `VZNATNetworkDeviceAttachment` (macOS 27+; mutually exclusive with
  `--net <capture-file>` — one network device per guest, refuse both
  with the existing `fail(...)` validation shape; without the flag
  `config.networkDevices = []` — the default VM and the full 34-gate
  aggregate stay byte-identical). (2) claim-time observations, never
  assumptions: what MAC the guest's `VIRTIO_NET_F_MAC` read observes
  under NAT (locally administered), the NAT subnet/gateway (commonly
  192.168.64.0/24, gateway .1 — VZ exposes no prefix API, so it is
  observed on the first live run), and whether the NAT attachment
  answers ARP for its gateway IP. (3) the new class-B live gate
  `tools/verify-live-net-nat.sh` — the DELIBERATE gate-shape change:
  the byte-exact capture-file evidence does NOT apply through NAT (the
  host translates frames — that is the point), so the gate asserts
  **guest-observed counters** (`net` report: `pong=1` with the echoed
  seq, rx/tx counters, the ARP table holding the gateway) instead of
  capture bytes. ONE run on VZ with `--net-nat`: `net ip <observed
  subnet addr>`, `net arp <gateway>` (table shows the gateway MAC),
  `net ping <gateway>` → `pong=1` seq 1 — the deterministic proof, no
  internet dependency. (4) the FULL 34-gate `verify-vz` aggregate must
  stay green (proof the `--net-nat` mode left the default VM
  byte-identical). (5) docs: the NAT observations (subnet, gateway,
  MAC-under-NAT, ARP/ICMP answers for the gateway) pinned in
  `docs/hardware-contract.md` flipped `[observed]` with saved
  `artifacts/` logs only, the march-m5 N7 row, and the status /
  gate-inventory updates (35-gate aggregate).
- **Depends on:** N1–N6 MERGED (main `87fe7ae`): the guest IP stack is
  the baseline the gate drives (no guest change). The N7 gate scripts
  ride the N3/N4/N5 `net ip` / `net arp` / `net ping` monitor surface
  and the claim-7293/0148 responder patterns where applicable — but the
  NAT gate deliberately has NO responder: the NAT attachment itself is
  the peer. Branched from the N7/N8 prompt commit (PR #102's doc, on
  merged main `87fe7ae`), the established two-PR pattern.
- **Status:** ✅ DONE 2026-08-12 on `agent/buffy/m5-net-nat` (from the N7/N8 prompt commit `0fcd96b` — PR #102's doc, on merged main `87fe7ae`; claim PR pending)

## Notes

**Why this card:** every N1–N6 gate proves the guest against the
DETERMINISTIC file-handle attachment — a socketpair to the runner. The
milestone's promise is a guest on a real network; the roadmap + N1
planning doc both name the NAT attachment as the outbound rung, and NAT
is the honest prerequisite for N8's second live phase (a guest that
leases its address from the host's real network services). The guest
DRIVER needs nothing new — the stack is already complete; this card is
the attachment + the gate shape.

**Observe, don't assume (claim-time questions):** (a) what MAC does the
guest observe under NAT when `macAddress` is set on the device config —
does the NAT attachment honor a fixed locally-administered MAC, or
assign its own (then the gate must not assert
`mac=02:00:00:00:00:01`, it asserts what is OBSERVED and pins it in
the hardware contract)? (b) what is the actual NAT subnet/gateway —
VZ exposes no prefix API, so the first live run discovers it (commonly
192.168.64.0/24, gateway .1) and records it; (c) does the NAT
attachment answer ARP for its gateway IP (the guest's `net arp
<gateway>` must learn the gateway MAC)? (d) does the gateway answer
ICMP echo (`net ping <gateway>` → `pong=1`)? Each is answered with a
saved VZ log, never assumed.

## Close-out (2026-08-12)

**All claim-time questions answered; the gate PASS on VZ (ONE run, 11/11
assertions).** (a) **MAC under NAT:** the NAT attachment HONORS the
configured locally-administered MAC — the guest reports `net:
mac=02:00:00:00:00:01 source=feature` (identical to the file-handle
path), so the gate CAN assert the fixed MAC. (b) **Subnet/gateway:** VZ
exposes no NAT prefix API; observed on the first live run —
192.168.64.0/24, gateway 192.168.64.1 (the guest statically addressed
192.168.64.5). (c) **The NAT gateway ANSWERS ARP for its gateway IP**
(the guest learns the gateway MAC — `net arp: 192.168.64.1 is at …`,
`learn=1`). (d) **The gateway ANSWERS ICMP echo** (`net ping
192.168.64.1` → `pong=1` `seq=1`) — the deterministic proof, NO
internet dependency.

**Three further observations, pinned in the hardware contract:**

1. **The NAT router MAC VARIES PER BOOT and is NOT the host bridge
   interface MAC** (observed `ae:07:75:20:da:64` vs the host bridge0
   interface's `36:27:ce:a2:21:40`) — the gate asserts the learned-line
   prefix, never a hardcoded MAC (exactly the prompt's "assert what is
   OBSERVED" rule).
2. **The NAT router SENDS IPv6 multicast to the guest at boot**
   (router-advertisement-shaped frames — the guest's first rx-obs shows
   dst `33:33:00:00…`); the N2 MAC filter (own + broadcast only) drops
   them (`filtered=3`) and the ARP-layer drop counter moves once
   (`drop=1`) — recorded, not a regression.
3. **The NAT attachment does NOT proxy-ARP off-subnet addresses:** a
   guest `net arp 8.8.8.8` broadcast goes unanswered (`learn=0`) and
   `net ping 8.8.8.8` honestly refuses (`peer not in ARP table`) — the
   guest has no routing rung (out of scope), so outbound proof stays at
   the gateway round trip. External-address pings remain optional /
   manual (recorded honestly, never gated).

**Evidence:** `tools/verify-live-net-nat.sh` PASS on VZ — ONE run, 11/11
assertions (ip-set, the 42-byte ARP request line, the 46-byte ping-sent
line, `icmp=req=1,repl=0,pong=1,drop=0,fail=0,seq=1`, the learned
gateway MAC, the MAC-under-NAT line, `arp=req=1,repl=0,learn=1,drop=1,
fail=0`, transport `status=0x0f`, the shell echo, the runner's
`net-nat: ENABLED` line); evidence under `artifacts/live-net-nat-*`
(runner output, serial log, host-bridge capture, gate + report) and
`artifacts/live-net-nat-explore/` (the exploratory boot + the
off-subnet 8.8.8.8 refusal). Full class A green (fmt, unit suite,
byte-identical transcript, build/image/inspect, swift build incl. the
`--net-nat`/`--net` mutual-exclusion fail path — exit 1 with the clear
`fail(...)` message, context, coordination ×2, mmu-debt); the
**35-gate `verify-vz` aggregate re-ran green 35/35** (evidence
`artifacts/m5-net-nat-vz-sweep.log`) — proof the `--net-nat` mode left
the default VM byte-identical. The next rung: card N8 (DHCP on the N6
seam / the N7 attachment).
