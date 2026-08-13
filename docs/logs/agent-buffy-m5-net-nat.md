# Log — agent/buffy/m5-net-nat

Branch: `agent/buffy/m5-net-nat` · Slug: `net-nat` · Claim: [4678](claims/4678-net-nat.md)

## 2026-08-12 — claim N7 (outbound connectivity: `VZNATNetworkDeviceAttachment`)

- N6 (claim 1384) MERGED (main `87fe7ae`); the N7/N8 planning prompt is
  PR #102 (`agent/buffy/m5-net-outbound-prompt`); the N7 claim branch
  carries the prompt commit (the two-PR pattern).
- Claim id 4678 via `bash tools/status/claim-id.sh
  agent/buffy/m5-net-nat net-nat`.
- Scope: `--net-nat` + `VZNATNetworkDeviceAttachment` (mutually
  exclusive with `--net`), the claim-time NAT observations (MAC under
  NAT, subnet/gateway, ARP/ICMP answers for the gateway), the new
  class-B live gate `tools/verify-live-net-nat.sh` (guest-observed
  counters — the capture-file shape does not apply through NAT), the
  34→35 aggregate re-run, and the hardware-contract/march-m5/status/
  gate-inventory updates.

## 2026-08-12 — close-out

- **Runner:** `--net-nat` (boolean, OFF by default) attaches
  `VZVirtioNetworkDeviceConfiguration` with `VZNATNetworkDeviceAttachment`
  (macOS 11+ — no `#if` needed on the macOS 27 floor); mutually
  exclusive with `--net` (clear `fail(...)`, exit 1, tested); without
  the flag `config.networkDevices = []`.
- **Class A green:** fmt, the unit suite, byte-identical transcript,
  build/image/inspect, swift build (incl. the mutual-exclusion fail
  path), context, coordination ×2, mmu-debt.
- **Live gate `tools/verify-live-net-nat.sh` PASS on VZ — ONE run, 11/11
  assertions**: `net ip 192.168.64.5` (the OBSERVED NAT subnet) + `net
  arp 192.168.64.1` + `net ping 192.168.64.1`; phase 2 (0.5 s settle)
  re-checks the ARP table (the gateway MAC learned: `net arp:
  192.168.64.1 is at …`) and reads the full `net` report — the
  assertions: ip-set, the 42-byte ARP request, the 46-byte ping,
  `pong=1` `seq=1` (the deterministic gateway round trip, no internet),
  the learned gateway, the MAC-under-NAT line (`mac=02:00:00:00:00:01
  source=feature`), `arp=req=1,repl=0,learn=1,drop=1,fail=0`, transport
  `status=0x0f`, the shell echo, and the runner's `net-nat: ENABLED`
  line.
- **The 35-gate `verify-vz` aggregate re-ran green 35/35**
  (artifacts/m5-net-nat-vz-sweep.log).
- **Claim-time observations pinned in the hardware contract
  `[observed]`** (saved logs under artifacts/live-net-nat-explore/):
  (1) the NAT attachment HONORS the configured locally-administered MAC;
  (2) the observed subnet/gateway is 192.168.64.0/24/.1 (VZ exposes no
  prefix API); (3) the gateway answers ARP for its IP and ICMP echo
  (pong=1 seq=1); (4) the NAT router MAC VARIES PER BOOT
  (ae:07:75:20:da:64 vs the host bridge0 interface's 36:27:ce:a2:21:40)
  — gates assert the learned-line prefix, never a hardcoded MAC; (5)
  the router sends IPv6 multicast at boot (dst 33:33:00:00…,
  router-advertisement-shaped) — the N2 MAC filter drops it
  (filtered=3, arp drop=1); (6) off-subnet addresses are NOT
  proxy-ARP'd — a guest `net arp 8.8.8.8` is unanswered and `net ping
  8.8.8.8` honestly refuses (no routing rung; outbound proof stays at
  the gateway, external-address runs optional/manual).
- **Docs:** hardware-contract NAT section `[observed]`, march-m5 N7 row
  + agent-split bullet, status.md milestone-five row + gate table
  (35-gate), gate-inventory live-net-nat row + aggregate list, claim
  close-out.
