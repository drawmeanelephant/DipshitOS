# Log — `sys_exec`: the EL0 exec seam (ADR 0007 slot 28)

## Context

- **Goal:** Give EL0 programs the ability to load a `.BIN` from the ESP
  into a fresh process slot — so DESKTOP.BIN's launcher actually launches —
  and extend the live desktop gate to prove it end to end.
- **Claim:** [`docs/claims/6359-sys-exec-userland-launcher.md`](../claims/6359-sys-exec-userland-launcher.md)

## Entries

### 2026-08-15: Claimed and implemented (claim 6359)

- Claimed under `agent/buffy/m11-sys-exec` (deterministic ID 6359), branched
  from main at the #155 merge (`cdb88d5`).
- Kernel — `kernel/src/syscall.zig`:
  - Slot 28 `sys_exec(path_ptr, path_len) -> i64` registered in the runtime
    dispatch table; `implemented_count` 28 → 29; report prints rows 0–28.
  - `handle_exec` marshals the path through uaccess (the `sys_file_open`
    pattern), requires a process caller, calls `exec.exec_file`, and maps
    `ExecResult` → ADR 0007 error codes (EINVAL / EFAULT / ENOENT / ENOSPC).
  - Returns the new process's pid on success via `exec.last_exec_pid()`.
- Kernel — `kernel/src/exec.zig`: `last_pid` module state + `last_exec_pid()`
  getter set at the loader's success point (a later exec overwrites it, as
  documented); no `exec_file` signature churn.
- ADR 0007 amendment: slot 28 row + amendment section; issue #148's TCP
  slot plan moved to 29–32.
- Toolkit — `user/src/lib/ui.zig`: `sys_exec_num` + `exec_program(name)`
  wrapper (syscall2).
- App — `user/src/desktop.zig`: quick-launch buttons now launch their target
  (was select-only); Enter (HID 0x28 / `\n`) on the selected list item
  launches it; `launch()` prints `desktop: launch <NAME> pid=<n>` (or the
  negative error) for the live gate.
- Live gate — `tools/verify-live-desktop.sh`: the session now execs NOTEPAD /
  TOP / DESKTOP from the monitor, types Enter after `desktop: menu ready`
  (the I3 chord seam), DESKTOP launches CALC.BIN through slot 28 (4th
  concurrent GUI app), and script2 runs after `calc: ready`. Assertions:
  all four `ready` markers, `desktop: launch CALC.BIN`, and
  `28 sys_exec calls=1` in the `syscalls` report.
- Class A: `zig test kernel/src/syscall.zig` + `kernel/src/exec.zig` +
  `user/src/lib/ui.zig` + `user/src/desktop.zig` green; `zig fmt --check`
  clean; `zig build` green. Coordination: indexes refreshed,
  `verify-coordination.sh` ok.
