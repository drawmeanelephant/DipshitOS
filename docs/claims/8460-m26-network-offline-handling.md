# Claim: M26 N13 + N14 — network-aware apps & offline handling

- **Owner:** buffy (`agent/buffy/input-poll-563`)
- **Prompt / plan:** `docs/parallel-dispatch-plan.md` Stream C
- **Scope:** M26 N13 (network-aware preflight in fetch/ping) + N14 (user-friendly offline error messages)
- **Touches:** `user/src/fetch.zig`, `user/src/ping.zig`, `user/src/lib/netstatus.zig` (new), `tools/verify-live-n13-offline.sh` (new)
- **Depends on:** — (nothing)
- **Heartbeat:** 2026-08-27
- **Status:** ⬜ unclaimed

## Scope detail

### N13 — Network-aware app status

Currently `fetch` and `ping` attempt connection and wait for a bounded
timeout even when the network is clearly down (no link, no IP, no DHCP).
N13 adds a pre-flight check that reads the kernel's network state and
exits early with a clear message.

**Implementation:**
1. New `user/src/lib/netstatus.zig` — reads the kernel's network globals
   via an existing syscall seam (the `net` command's internal data, or a
   new compact query). Returns a struct:
   ```zig
   const NetStatus = struct {
       link_up: bool,
       ip_set: bool,
       ip: [4]u8,
       dhcp_state: enum { idle, discover, request, bound, expired },
   };
   ```
2. `fetch.zig` and `ping.zig` call `netstatus.check()` before their
   connect loop. If `link_up == false` or `ip_set == false`, print the
   offline message and exit 1 immediately.

**Fallback approach** (if no clean syscall seam exists): parse the `net`
monitor command output from a `type` pipe. This is fragile but honest.

### N14 — Offline state handling

Make error messages user-friendly across both apps:

| Condition | Current behavior | N14 behavior |
|-----------|-----------------|--------------|
| No link | 30s connect timeout | `ping: offline — no network link detected` (exit 1) |
| No IP | 30s connect timeout | `fetch: offline — no IP address assigned (try: net dhcp)` (exit 1) |
| No route | 30s ARP timeout | `ping: host unreachable — no route to 10.0.0.2` (exit 1) |
| DNS fail | 30s UDP timeout | `fetch: DNS resolution failed for example.com` (exit 1) |
| Connect refused | Immediate RST | `fetch: connection refused by 10.0.0.2:80` (exit 1) |

These are message-only changes on top of the existing bounded error paths.
The M5 TCP/UDP connect/send error returns already provide the error codes;
N14 maps them to human-readable strings.

## Verification

### Host (class A)
- Unit tests for `netstatus.zig` struct parsing
- Unit tests for error message formatting in `fetch.zig` and `ping.zig`

### Class B (live VZ)
- `tools/verify-live-n13-offline.sh`:
  1. Boot with `--net` (DHCP active) — `ping 10.0.0.1` works normally
  2. Boot without network — `ping 10.0.0.1` prints offline message and exits
     within 1 second (no 30s hang)
  3. Boot without network — `fetch http://example.com` prints offline message
     and exits within 1 second

## Gate shape

Class-B `tools/verify-live-n13-offline.sh` — boot without network, assert
offline messages appear promptly (no timeout hang), observed through VZ
serial gate.
