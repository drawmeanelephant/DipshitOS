# Claim: blocking syscalls — sleep/yield/wakeup in the tick scheduler (card 7)

- **Owner:** Buffy (`agent/buffy/m3-lifecycle`)
- **Prompt / plan:** milestone-three march card 7 ([`docs/march-m3.md`](../march-m3.md)),
  following the ESP exec card (claim 6783). Card text: **blocking syscalls —
  wire sleep/yield and wakeup behavior into the tick scheduler without
  busy-waiting or breaking shell responsiveness. Gate scheduler state
  transitions, timer-driven wakeups, return values, and live progress of
  other runnable tasks.**
- **Scope:** the blocking half of the syscall ABI + scheduler. A new frozen
  `sys_sleep(ticks)` row (slot 4, ADR 0007 amendment) blocks the calling
  task for `ticks` scheduler ticks and returns 0 on wake; the scheduler
  gains an explicit `blocked` task state with a per-task wakeup deadline,
  and each tick (IRQ context, console-free) advances a tick counter and
  moves expired sleepers back to `ready`. Cooperative `sys_yield` (slot 2)
  is unchanged. The ESP-loaded user program is extended to yield, sleep 2
  ticks (asserting the 0 return), write markers before/after, and exit
  with status 43 — proving other runnable tasks (worker advances, shell
  echo) keep progressing while the user task is blocked. A new live gate
  (`tools/verify-live-sleep.sh`) asserts the whole chain on VZ.
- **Depends on:** claims 6783 (exec + user program), 6729 (lifecycle —
  states/spawn/exit/reap, idle reaper), 5275/8215 (tick scheduler + EL0),
  3594 (syscall ABI — new row, no renumbering), 6120 (uaccess EFAULT),
  9187/9746 (timer IRQ + vector frame).
- **Status:** ✅ done 2026-08-10

## Notes

**Semantics:** `sys_sleep(n)` blocks the caller until the scheduler tick
counter has advanced `n` ticks past the call (`wakeup_tick = tick_count +
n`; `n == 0` is clamped to 1 — the minimum sleep is one tick, matching the
1 s timer period). A sleeping task is `blocked`, drops out of the
round-robin ring (`next_runnable` scans `ready` only, so it is never
selected), and the always-ready idle task keeps the ring alive. On each
tick, `wake_expired` (IRQ context, console-free — claim 9187) flips
expired sleepers back to `ready`; the ring picks them up on the next
round. The task's saved SVC frame is untouched while blocked, so the
syscall return (x0 = 0) lands when it resumes — the same resume path as
`sys_yield`. `sleep_current` fails (EINVAL) if the caller is the idle task
or the pool is not active; it rolls back if no successor exists.

**Why the shell stays responsive:** blocking is a state transition, not a
spin. During the user task's sleep the worker keeps receiving quanta
(advance reports continue) and the shell keeps echoing — both asserted by
the live gate. The EL0 task's own writes bracket the sleep
(`user: sleeping 2 ticks` before, `user: awake` after), the worker's
advance lines appear between them, and the exit/reap close the lifecycle.

**State hygiene:** `user_root_in_use` (the exec gate, claim 6783) now
counts `blocked` tasks too — a sleeping user program still owns the user
root, so `exec` refuses until it exits and is reaped.

## Verification

- **Class A:** `zig fmt --check` (including `user/src/*.zig`), unit tests
  (scheduler 47 total incl. new: block→tick→wake transitions, sleep-while-
  inactive refusal, ring-order root-gate fix; syscall 55 total incl.
  `sys_sleep` returns + EINVAL paths), byte-identical transcript gate,
  build + image + inspect (USER.BIN embedded, 234 content bytes),
  coordination indexes — all green.
- **Class B on VZ (all 1/1):** the new `bash tools/verify-live-sleep.sh`
  (yield, sleep 2 ticks, `user: awake` after worker advances interleave,
  exit `status=43` + reaped) plus regressions: exec (updated to expect
  status 43), lifecycle, addrspaces, uaccess, svc, userspace, tasks, timer,
  fs, exceptions, cvspike, transcript, reboot 2/2.
- **Evidence:** `artifacts/live-sleep-*` (gate log + serial logs),
  `artifacts/m3-sleep-live.txt`.

**Observed vs inferred:** the sleep/wake cycle is directly observed in
`vm-serial.log` on VZ — `user: sleeping 2 ticks`, worker advance lines
interleaved during the sleep (proving the shell/worker stay responsive
while the user task is blocked), `user: awake`, then exit + reap. The one
live-found bug (sleep never saving the caller's SVC frame, so the resumed
task ran garbage) was root-caused from the serial log and fixed in
`sleep_current` — it must capture the frame exactly like `yield_current`.
