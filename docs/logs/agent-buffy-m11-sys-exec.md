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
- **Pre-existing M9 bug found + fixed (claim 1016's `sys_wait_event`):**
  the first live run of the extended gate showed all three GUI apps
  exiting 43 ~1 tick after `menu ready` — `desktop: wait err=-3`. The
  blocking path of `sys_wait_event` rewinds ELR to re-execute the svc on
  wake, but `handle_svc` writes the blocking result (0) into the saved
  frame's x0 AFTER `wait_event_current` parked the task — the re-executed
  svc saw x0=0, so the event copy_out targeted address 0 (EFAULT) and
  every blocking event loop died. The original M11 gate masked it (the
  session ended before the apps' first post-block wake) and KEYTEST.BIN
  masked it (its loop re-arms `x0=sp` each iteration). Fix: stash the
  frame's x0 in a new `wait_event_buf` task field at block time and patch
  it back into the saved frame in `wake_event_waiters`. Regression test
  drives the full block → push → wake → resume → re-execute round trip
  through `handle_svc`. After the fix the gate's apps STAY ALIVE.
- Class A: `zig test kernel/src/syscall.zig` + `kernel/src/exec.zig` +
  `user/src/lib/ui.zig` + `user/src/desktop.zig` green; `zig fmt --check`
  clean; `zig build` green. Coordination: indexes refreshed,
  `verify-coordination.sh` ok.
- **Class B: `bash tools/verify-live-desktop.sh` PASS on VZ** — NOTEPAD /
  TOP / DESKTOP exec'd and stay alive, the injected Enter makes DESKTOP
  launch CALC.BIN through slot 28 (`desktop: launch CALC.BIN pid=4`), the
  launched `calc: ready` follows, and the `syscalls` report shows
  `28 sys_exec calls=1` (evidence `artifacts/live-desktop-*`).
