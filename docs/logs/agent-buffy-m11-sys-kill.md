# Log — `sys_kill`: ADR 0007 slot 29, EL0 process termination

## Context

- **Goal:** Give EL0 programs the ability to terminate another process —
  TOP.BIN's Kill button becomes real — reusing the claim-7786 EL1h kill
  seam, and prove it with a live gate.
- **Claim:** [`docs/claims/7604-sys-kill-el0-termination.md`](../claims/7604-sys-kill-el0-termination.md)

## Entries

### 2026-08-15: Claimed and implemented (claim 7604)

- Claimed under `agent/buffy/m11-sys-kill` (deterministic ID 7604), on top
  of the claim-6359 sys_exec branch (slot 29 follows slot 28).
- Kernel — `kernel/src/syscall.zig`:
  - Slot 29 `sys_kill(target_pid) -> i64` registered in the runtime
    dispatch table; `implemented_count` 29 → 30; report rows 0–29.
  - `handle_kill` requires a process caller, validates the target
    (range / free / exited / no-executor) through `process.info`, and
    arms the kill through `scheduler.request_kill` (the claim-7786 seam —
    pure TCB write, safe from SVC context). 0 on success; EINVAL for every
    refusal (the sys_wait precedent for numeric targets).
- ADR 0007 amendment: slot 29 row + amendment section; slot note that the
  M12 TCP plan (issue #148) now runs at 30–33 with kill at 29.
- Toolkit — `user/src/lib/ui.zig`: `sys_kill_num` + `kill_process(pid)`
  wrapper (syscall1).
- App — `user/src/top.zig`:
  - `ProcessTable.refresh_from_system` auto-selects the first RUNNING
    process when nothing is selected (the Kill button's default target).
  - `kill_selected(row)` calls `ui.kill_process(pid)`, prints
    `top: kill pid=<n>` (or the negative error), and refreshes the table
    so the exited row (status 137) appears.
  - The Kill button and the `k`/`K` keys route through it (the
    "Future kill syscall" no-op is gone).
- Live gate — `tools/verify-live-sys-kill.sh`: exec COUNTER.BIN + TOP.BIN
  (TOP opened last → focused), type `k` after `top: ready` (the I3 string
  seam), TOP auto-selected the running COUNTER (pid 1) and kills it;
  script2 after `top: kill pid=1` dumps procs + syscalls. Assertions:
  `top: kill pid=1`, NO `counter: alive` after the kill,
  `tasks user-exec exited status=137` + `procs COUNTER.BIN exited
  status=137` (the real lifecycle), and `29 sys_kill calls=1`.
- Class A: `zig test kernel/src/syscall.zig` (slot 29 arm/refusals/round
  trip) + `user/src/top.zig` (auto-select + kill routing) green; `zig fmt
  --check` clean. Coordination: indexes refreshed,
  `verify-coordination.sh` ok.
- Class B: `bash tools/verify-live-sys-kill.sh` PASS on VZ (evidence
  `artifacts/live-sys-kill-*`); the desktop gate's suite still green.
