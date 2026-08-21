# Claim: Milestone 14 Card S4 — security/isolation hardening (ownership audit, uaccess sweep, resource limits)

- **Owner:** buffy (`freebuff/hey-bestie-the-chat-got-lost-so-we-re-so-back-can--53baf792-c2f8-470d-a9f1-6344aa90847a`)
- **Prompt / plan:** `docs/march-m14.md` (Issue #178; wishlist 19)
- **Scope:** Milestone 14, Card S4 — hardening the EL0 surface alongside the M14 services
- **Depends on:** M14 S1/S2/S3 (merged, PRs #182/#183); the claim-6120 uaccess window
- **Status:** ✅ done (class A + class B, 2026-08-18)

## Notes

Three workstreams, plus a hostile-consumer proof:

- **Process-ownership audit** — every resource an EL0 process can name
  (windows, file handles, event queues, app timers, clipboard, TCP
  connection, mailbox targets, process pids, UDP ports). Expected: windows
  owner-checked (`win_owned_by_caller`); files/events/timers per-process by
  construction; clipboard/UDP/mailbox/process-control documented-global by
  design. **Suspected gap: the TCP connection's `owner_pid` is set on
  `sys_tcp_connect` but never enforced on send/recv/close** — a second
  process can drive another process's connection. Fix + EACCES refusal.
- **uaccess validation sweep** — every pointer/length-taking handler must go
  through `uaccess.copy_in`/`copy_out` with bounds/NULL/unmapped/over-long
  handling; no handler dereferences a raw user pointer.
- **Resource limits** — each bounded pool (processes, windows, handles,
  timers, events, mailbox, clipboard, UDP listen table, TCP connection)
  refuses over-allocation with a clean error; a hostile process cannot
  exhaust a pool.

Proof: a hostile EL0 program (HARDEN.BIN) attacks a victim process's
window from EL0 (fill/present/close/move/query), observes clean EINVAL
refusals, survives, and reports `hardening: refused`. Class-B gate
`tools/verify-live-hardening.sh`. Class-A tests pin the TCP-ownership fix.

## Result (2026-08-18)

- Audit confirmed the expected posture (windows per-process via
  `win_owned_by_caller`; files/events/timers per-process by construction;
  clipboard/UDP/mailbox/process-control documented-global) and found the
  ONE suspected gap: TCP — `tcp.owner_pid` was set on connect but never
  enforced. `handle_tcp_send`/`handle_tcp_recv`/`handle_tcp_close` and the
  connect-reuse path now refuse EACCES for a non-owner; the connection
  clears its owner on close. Class-A test 341 pins it.
- uaccess sweep: every pointer-taking handler routes through
  `uaccess.copy_in`/`copy_out` (ownership checks run BEFORE user buffers
  are touched); no handler dereferences a raw user pointer.
- Resource limits: every bounded pool refuses over-allocation with a clean
  error (ENOSPC/EINVAL), audited; no hostile-exhaustion path found.
- Hostile-consumer proof, live on VZ: `bash tools/verify-live-hardening.sh`
  **PASS 1/1** — VICTIM.BIN owns window 2 and yield-loops forever;
  HARDEN.BIN (separate process) attacks fill/present/close/move/query and
  is refused EINVAL every time, reports `hardening: refused` +
  `hardening: survived`, exits status 44; the victim never exits.
- Class-A suite fully green (45 modules, 463 tests) at `1f6bfbb` + this
  change; docs (march-m14/roadmap/status) updated; indexes refreshed.
