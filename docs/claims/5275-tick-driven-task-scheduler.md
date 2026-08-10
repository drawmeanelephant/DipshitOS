# Claim: tick-driven task scheduler (milestone-three first tasks card)

- **Owner:** buffy (`agent/buffy/macos27-custom-virtio-spike`)
- **Prompt / plan:** mission — the first milestone-three card: a tick-driven
  round-robin scheduler between two kernel tasks on the claim-9187 timer
  IRQ, a `tasks` monitor command, host tests, and a class-B live gate.
- **Scope:** kernel tasks only — preemptive at the tick, minimal context
  save/restore (one stack per task), no userspace, no MMU changes.
- **Depends on:** claim 9187 (a real 1 s CNTP PPI enters the claim-9746 EL1
  IRQ vector on VZ), claim 9746 (the vector stubs + IRQ dispatcher hook).
- **Status:** ✅ done

## Notes

The smallest honest scheduler: `kernel/src/scheduler.zig` — two fixed
kernel tasks (the shell/main task + a demo worker on its own static BSS
stack), round-robin on every timer tick. The context switch is tiny
because the claim-9746 IRQ stubs already push/pop the full caller-saved
register file as a 160-byte vector frame on the interrupted task's stack;
the scheduler only saves/restores three words per task (the vector-frame
pointer, ELR_EL1, SPSR_EL1) through `exceptions.resume_frame` (staged at
IRQ entry) and the stub's new `mov sp, x0` + register restore + `eret`,
which lands in the next task exactly as if IT had been interrupted.

New `dipshit> tasks` command reports enabled/current/switches plus
per-task saves/resumes/advances. The worker bumps its advance counter each
loop iteration and asks the shell idle loop to report it (main-context
console discipline, claim 9187 — nothing prints from IRQ context). Host
tests cover frame construction, round-robin alternation/round-trip,
counters, and the report machinery. Timer heartbeat/report lines now
snapshot their counters at the event (not print time) so the strict
`ticks=5 irq=5 poll=0` live-timer gate stays exact under preemption.

Class B gate `tools/verify-live-tasks.sh`: boots VZ, scripts `tasks` +
`echo rx-tasks-ok`, and requires the worker's report line (`tasks worker
advances=N`, N>=1 — only possible after a full worker quantum AND a shell
idle loop, i.e. >= 2 real context switches) plus a responsive shell.
Evidence: `artifacts/live-tasks-*`. Regressions re-run live: live-timer,
live-exceptions, live-transcript, live-reboot, live-fs all green.
