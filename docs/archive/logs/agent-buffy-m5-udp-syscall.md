# Log — agent/buffy/m5-udp-syscall

Branch: `agent/buffy/m5-udp-syscall` · Slug: `udp-syscall` · Claim: [1384](claims/1384-udp-syscall.md)

## 2026-08-11 — claim N6 (UDP behind a bounded syscall seam, ADR 0007)

- N5 (claim 8552) MERGED (main `2c9a406`); PR #99 merged, PR #100 (the
  N6 prompt doc) open; the N6 claim branch was created from merged main
  and carries the prompt commit (the two-PR pattern).
- Claim id 1384 via `bash tools/status/claim-id.sh
  agent/buffy/m5-udp-syscall udp-syscall`.
- Scope: ADR 0007 slots 9/10/11 (`sys_udp_listen` / `sys_udp_send` /
  `sys_udp_recv`), `udp.peek`, UDP.BIN (the EL0 proof image), the new
  class-B live gate, the 33→34 aggregate re-run.

## 2026-08-12 — close-out

- **Class A green:** fmt, the 31-module unit suite (syscall slots 9/10/11
  + udp.peek + the UDP.BIN marker pins), byte-identical transcript,
  build/image/inspect (UDP.BIN 605 bytes embedded), swift build,
  context, coordination ×2, mmu-debt.
- **Live gate `tools/verify-live-net-udp-syscall.sh` PASS 4/4 on VZ:**
  UDP.BIN's full transcript IN ORDER (listen → loop → got → recv-err →
  send-err → exited status=17 → reaped), the capture byte-exact (42-byte
  ARP request + the 46-byte datagram), and the observation phase on the
  SAME kernel state (syscalls rows 0–11 implemented=12 rows 9/10/11
  counted; net udp/net counters rx=2 tx=2 loop=1 drop=0).
- **The 34-gate `verify-vz` aggregate re-ran green 34/34**
  (artifacts/m5-udp-syscall-vz-sweep.log).
- **Gate-engineering lessons recorded (claim close-out):** (1) an early
  `--script-expect` killed the VM at ~5 s — script2 keyed on the early
  ready marker was answered instantly and the expect matched BEFORE the
  ring (1 s ticks, 5 tasks) returned to UDP.BIN after its cooperative
  yield; the tasks snapshot proved the kernel was healthy (`switches=5`,
  every task `state=ready`, the host answer already rx'd) — the gate now
  keys its observation phase on the program's OWN `udp: got ping` marker
  and its exit on `tasks user-exec reaped`; (2) an absent marker under
  `set -euo pipefail` killed the gate silently BEFORE it could report
  the FAIL (the bare grep substitution exits on no-match, bash 3.2) —
  the marker greps carry `|| true` now.
- **Schedule-truth first proved live by this gate:** a user task RESUMES
  after `sys_yield` — the boot payload yields as its LAST act before
  exit, so no earlier live gate observed a post-yield user resume; the
  ring returning to UDP.BIN between polls is the first observation.
- No new device behavior: the 46-byte datagram travels unpadded,
  consistent with the N3/N4/N5 observation (no hardware-contract entry).
