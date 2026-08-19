# Log — `agent/buffy/m16-c3-resources`

### 2026-08-19 — claim 0339

Claimed. Audited the fixed pools under concurrent app load: the scheduler
executor pool (`max_tasks = 7`, 4 user slots) is the hard cap — the exec
path refuses a fifth concurrent program (`pool_full`). Growing it to 8 user
slots (11 total) and the process registry to 16 for headroom.

## 2026-08-19 — claim 0339 done

The measured bottleneck was the scheduler executor pool (`max_tasks = 7`,
4 user slots — `pool_full` at the 5th exec). Grown `max_tasks` 7 → 11
(8 user slots) and `process.max_processes` 8 → 16. Added the `resources`
monitor command (registry 47 → 48) auditing tasks/procs/windows/tables +
the per-process ring bounds.

Live measurement (`verify-live-m16-resources.sh` PASS 1/1):
- before: `resources: tasks=3/11 procs=1/16 tables=62/256`
- after 8 concurrent programs (counter + 7 USER.BINs):
  `tasks=11/11 procs=9/16 tables=238/256` (the 256-page carve-out fits
  8 user roots with 18 pages headroom — no table growth needed)
- ninth exec `pool_full`; windows/events/mbox/fds/timers/tcp stay bounded.

Re-derived the M4-era gates that pinned the old 7/7 budget to the 11/11
budget: scale (8 programs), args (dropped the redundant pool_full ending),
ipc (ninth exec), long-lived (comments only). All PASS 1/1. The
exec/scheduler/monitor/shell tests + the canonical transcript were
re-derived too (transcript now `pool=4/11` + the `resources` help line).
