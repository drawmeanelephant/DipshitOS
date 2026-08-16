# Claim: `sys_kill` — ADR 0007 slot 29, EL0 process termination (TOP.BIN's Kill button becomes real)

- **Owner:** buffy (`agent/buffy/m11-sys-kill`)
- **Prompt / plan:** Phase B sibling of the post-M11 apps review: slot 29 `sys_kill` so TOP.BIN's Kill button terminates a process from EL0, extending the live desktop/TOP gate to prove it.
- **Scope:** `kernel/src/syscall.zig`, `docs/decisions/0007-syscall-abi.md`, `user/src/lib/ui.zig`, `user/src/top.zig`, `tools/verify-live-sys-kill.sh`, `docs/claims/7604-sys-kill-el0-termination.md`, `docs/logs/agent-buffy-m11-sys-kill.md`
- **Depends on:** `docs/claims/7786-...` (the claim-7786 EL1h kill), `docs/claims/6359-sys-exec-userland-launcher.md` (slot 28 — this is slot 29)
- **Status:** ✅ done

## Notes

M11's A4 tracker claim called TOP.BIN a "click-to-kill process termination"
tool — but the Kill button only logged `top: kill requested` under a
"Future kill syscall" comment (the kernel had the EL1h `kill` path, claim
7786, but no EL0 seam). This card closes the gap with ADR 0007 slot 29:

**`sys_kill(target_pid) -> i64`** — arm the target process's executor for
termination from EL0, reusing the claim-7786 seam (`scheduler.request_kill`:
a pure TCB write; the ring converts the target's NEXT selection into the
existing exit path with the reserved status 137, flowing through the real
exit → zombie → idle-reap → page-return lifecycle). Returns 0 once armed;
`EINVAL` for a non-process caller (an EL1h task), an out-of-range / free /
exited / no-executor target, or a scheduler-owned refusal (shell, idle).
Self-kill is allowed (the monitor's `kill` is equally general); a blocked
target keeps the EL1h kill's documented bound — the arm applies at the
target's next selection, so a permanently blocked target stays until woken.

`implemented_count` 29 → 30; the `syscalls` report prints rows 0–29.

TOP.BIN's Kill button and the `k`/`K` keys now call a shared
`kill_selected` path through the new toolkit wrapper `ui.kill_process(pid)`,
printing `top: kill pid=<n>` (or the negative error), and the process table
auto-selects the first RUNNING process when nothing is selected yet — so
the launcher has a sane default target. A new class-B gate
`tools/verify-live-sys-kill.sh` execs COUNTER.BIN + TOP.BIN, types `k` after
`top: ready` (TOP has focus — it opened last), and asserts `top: kill
pid=1`, NO `counter: alive` after the kill, `tasks user-exec exited
status=137` / `procs COUNTER.BIN exited status=137`, and
`29 sys_kill calls=1` in the syscalls report — the EL0 kill, proven live.

Class A: `zig test kernel/src/syscall.zig` (slot 29 dispatch: caller /
range / free / exited refusals, the arm → next-selection-137 round trip
through the ring, the exited-target refusal after the kill lands) and
`zig test user/src/top.zig` (auto-select + kill routing) — all green;
`zig fmt` clean.
