# Claim: M16 C3 — the resource model, measured (grow the exhausted pool)

- **Owner:** buffy (`agent/buffy/m16-c3-resources`)
- **Prompt / plan:** `docs/march-m16.md` (card C3, issue #192)
- **Scope:** milestone sixteen card C3 — audit the fixed pools under real
  concurrent app load, grow only the pool the demo apps exhaust, record the
  before/after measurement as evidence.
- **Depends on:** C1 (`agent/buffy/m16-c1-image-format`) + C2
  (`agent/buffy/m16-c2-guards`) — rides on their address-space shape.
- **Status:** ✅ done — live gate PASS 1/1 (2026-08-19)

## Notes

The measured bottleneck is the **scheduler executor pool** — `max_tasks = 7`
(shell + worker + idle + FOUR EL0t user slots), so the exec path refuses a
**fifth** concurrent user program with `pool_full` (proven by every M4-era
gate). The demo apps (launcher, file browser, chat, sound apps, desktop)
compete for those four slots.

This card:
1. Grows `scheduler.max_tasks` 7 → 11 (shell + worker + idle + **EIGHT**
   EL0t user slots) — the pool the apps actually exhaust.
2. Grows `process.max_processes` 8 → 16 — the registry saturates at exactly
   the new 8-program concurrency (8/8 with the boot payload's exited slot
   recycled), so "8+ apps on the desktop" (desktop + 8 apps) needs headroom.
3. Audits the other pools (windows 8, mailbox rings 8, event queues 16,
   file handles 8, app timers 8, TCP single-client) — measured and left
   bounded (no demo app exhausts them).
4. Adds a `resources` monitor command that pins every pool's bound + live
   occupancy, and a `verify-live-m16-resources.sh` gate proving 8 concurrent
   programs with the before/after accounting.

Re-derives the M4-era gates that pinned the old 7/7 budget (scale/args/ipc/
long-lived + the exec/scheduler/monitor/shell unit tests + the canonical
transcript) to the new 11-slot budget. Verified class-A (fmt, unit tests,
byte-identical transcript, build/image/inspect, coordination) and class-B
(live VZ gate).
