# Claim: Syscall ABI and dispatch table

- **Owner:** Codex (`agent/codex/m3-syscall-abi`)
- **Prompt / plan:** `docs/m3-syscall-abi-prompt.md`
- **Scope:** milestone-three syscall ABI: runtime-built 64-slot dispatch table,
  x8/x0-x5 register marshalling, ping/write/yield/exit, minimal scheduler hooks,
  monitor reporting, ADR 0007, portable tests/transcript, and a live VZ SVC gate.
  No uaccess, per-task address spaces, process abstraction, ELF loading,
  allocation, libc, or POSIX.
- **Depends on:** PR #60 / claim 8215 (EL0 task and SVC boundary), merged as
  `65ad6af` on `main`.
- **Status:** ✅ done

## Notes

The required pre-implementation review found a prompt-transcription defect in
`6b1b8cd`: merged PR #60, claim 8215, its branch log, `userspace.zig`, and its
live evidence all define x8 as the operation selector and x0 as
argument/result, while that later docs-only commit says both number and result
are x0. That wording is internally impossible for slot-0
`ping(value) -> value`. This card preserves the landed and VZ-proven x8/x0
boundary and will correct the prompt while freezing it in ADR 0007.

The implementation layers only the numbered table and marshalling on the
landed `set_svc_dispatcher` / `is_svc64_from_el0` route. Yield and exit add the
smallest scheduler hooks needed for cooperative switching and a non-returning
terminated user task; later milestone work remains out of scope. Verification
is class A first, then the new live SVC gate plus the required VZ regressions,
with command output saved under `artifacts/m3-syscall-abi-*`.

Completed with ADR 0007, a runtime-built 64-slot table, x8/x0–x5/x0
marshalling, fixed slots 0–3, reserved slots 4–63, bounded `sys_write`, minimal
yield/exit scheduler hooks, deterministic `syscalls` counters, and the live SVC
gate. `sys_write` accepts only the two kernel-known EL0 apertures and the real
low-4-GiB identity blanket; privileged and MMIO ranges are rejected with
EINVAL while EFAULT remains reserved for uaccess.

Review caught and corrected three false-positive evidence defects before
publication: the EL0 literal now ends with a real LF; the live gate uses the
runner's one-shot `--script-after` path instead of a replaying FIFO and matches
exact complete lines; and EL0 waits for a timer-only witness before cooperative
yield so claim 8215's preemption proof remains real. The corrected VZ run is
1/1 with a 3,987-byte serial log, exact counters (`ping=2`, `write=1`,
`yield=1`, `exit=1`), timer IRQ ordered between write and exit, and one
post-exit echo. The corrected `live-userspace`, `live-timer`, and `live-tasks`
regressions each pass 1/1. Affected format/unit/build checks and the Swift
runner build pass.

The host has no `just` executable, so `just verify-vz` itself was not observed.
Its explicit command list was run manually before final review; the earlier
live-SVC portion is superseded by the corrected gate above. Final acceptance
uses the corrected affected-gate reruns, not the earlier FIFO artifact.
