# Claim: milestone nine, card E5 — event syscall seam

- **Owner:** buffy (`agent/buffy/m9-events`)
- **Prompt / plan:** `docs/march-m9.md`
- **Scope:** Milestone 9 card E5: implementing non-blocking `sys_poll_event` (slot 21) and blocking `sys_wait_event` (slot 22) across the uaccess boundary in `kernel/src/syscall.zig`, with event-driven scheduler sleep/wake (`scheduler.wait_event_current` / `scheduler.wake_event_waiters`).
- **Depends on:** E1 (claim 7670)
- **Status:** ✅ done (2026-08-15)

## Notes

Implements event syscalls (slots 21 & 22) with 23 implemented syscall slots:
- `sys_poll_event`: non-blocking poll of the caller's event queue.
- `sys_wait_event`: blocking wait with restartable SVC frame PC rewind (`pc.elr - 4`).
- Scheduler wakeup hook `events.on_event_pushed` connected to `scheduler.wake_event_waiters`.
- Class A unit tests covering non-blocking poll, blocking wait, error results (EFAULT, EINVAL), and scheduler event wakeup.

## Verified

- Class A unit tests in `kernel/src/syscall.zig` and `kernel/src/scheduler.zig`.
