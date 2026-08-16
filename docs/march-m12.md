# Milestone twelve march — userland network applications (living tracker)

## Where we are

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds only
> milestone-twelve's per-card detail and collision-free agent split, following
> the [`march-m11.md`](march-m11.md) pattern.
> A card's row flips to ✅ only with real observed class-B evidence, never
> code-complete alone.

Milestone eleven delivered a complete graphical desktop: the ADR 0011 UI
contract, the zero-heap micro-widget toolkit, four consumer GUI apps, and —
through the post-ship `sys_exec` seam — a desktop launcher that really
launches. The kernel's network stack (virtio-net → ARP → IPv4/ICMP → UDP →
DHCP → TCP, milestones five) is currently reachable only from the EL1h
monitor (`net …` commands).

Milestone twelve connects **userland applications** to that network: a clean
TCP syscall seam (the UDP-syscall pattern from card N6), bounded DNS, and
the capstone EL0 network apps.

The cards, in order:

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| N12 | **Userland TCP syscall seam (ADR 0007 slots 30–33).** `sys_tcp_connect`, `sys_tcp_send`, `sys_tcp_recv`, `sys_tcp_close` — the EL0 TCP path, mirroring the card-N6 UDP seam. | 🔄 in progress (issue #148) | — | Slots moved to 30–33: 28 = `sys_exec` (claim 6359), 29 = `sys_kill` (claim 7604). |
| N13 | **Bounded DNS client.** RFC 1035 UDP query client on port 53 to resolve domain names. | ⬜ | — | Runs on the N12/N5 UDP layers; no new ABI expected. |
| N14 | **`FETCH.BIN` & `CHAT.BIN`.** **[Capstone Gate]** An EL0 HTTP/1.0 client fetching web text over NAT, and a peer-to-peer graphical chat app. Live gate: `verify-live-fetch.sh`. | ⬜ | — | Uses ADR 0011 widgets + N12/N13. |

## Notes

- The M12 plan lives in issue #148 (filed with the M11 closeout, 2026-08-15;
  updated 2026-08-16 when `sys_exec`/`sys_kill` claimed slots 28/29).
- M11's `verify-live-desktop.sh` gate proves DESKTOP.BIN launches CALC.BIN
  through slot 28 `sys_exec` — the launcher half of the app/network story.
