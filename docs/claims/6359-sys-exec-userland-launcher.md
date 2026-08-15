# Claim: `sys_exec` — the EL0 exec seam (ADR 0007 slot 28), the DESKTOP launcher becomes real

- **Owner:** buffy (`agent/buffy/m11-sys-exec`)
- **Prompt / plan:** Phase B of the post-M11 apps review — the first kernel seam: expose the ESP exec loader to EL0 so DESKTOP.BIN can actually launch apps, and extend the live desktop gate to prove it.
- **Scope:** `kernel/src/syscall.zig`, `kernel/src/exec.zig`, `docs/decisions/0007-syscall-abi.md`, `user/src/lib/ui.zig`, `user/src/desktop.zig`, `tools/verify-live-desktop.sh`, `docs/claims/6359-sys-exec-userland-launcher.md`, `docs/logs/agent-buffy-m11-sys-exec.md`
- **Depends on:** `docs/claims/2427-a5-desktop-launcher.md`, `docs/decisions/0011-desktop-platform-and-gui-apps.md`
- **Status:** ✅ done

## Notes

M11's A5 tracker claim said DESKTOP.BIN is a "clickable application menu to
launch EL0 programs" — but the code only *selected* apps and printed
`desktop: select X`; there was no EL0 exec path (`exec` was an EL1h monitor
command only). This card closes that gap with ADR 0007 slot 28:

**`sys_exec(path_ptr, path_len) -> i64`** — copy the `.BIN` name through the
claim-6120 uaccess window, then run the existing EL1h loader
(`exec.exec_file`) to load the program from the ESP into a fresh process
slot and spawn it at EL0. Returns the new process's pid on success (surfaced
via a new `exec.last_exec_pid()` getter set by the loader — no signature
churn across the ~30 `exec_file` call sites); negative error codes otherwise:

- `EINVAL` (-1): caller is not a process (an EL1h task), `path_len == 0` or
  `> esp.name_max`, or the loader refused the image (`no_disk`,
  `bad_magic`, `bad_entry`, `too_large`, `no_args_room`).
- `EFAULT` (-3): bad user path pointer (uaccess).
- `ENOENT` (-6): the named file is absent from the ESP volume.
- `ENOSPC` (-5): capacity refused — scheduler pool full, page allocator
  exhausted, page-table carve-out full, or process registry full.

`implemented_count` 28 → 29; the `syscalls` report prints rows 0–28.

**Slot-allocation note:** M12's TCP seam (issue #148) planned slots 28–31;
this card takes slot 28 for `sys_exec`, so the TCP plan moves to slots 29–32
(the issue body is updated to match).

DESKTOP.BIN's quick-launch buttons now exec their target, and Enter on the
selected list item launches it; a new toolkit wrapper `ui.exec_program(name)`
carries the call. The live gate restructures the desktop session: NOTEPAD /
TOP / DESKTOP are exec'd by the monitor, the runner types Enter after
`desktop: menu ready`, DESKTOP launches CALC.BIN through slot 28 (the fourth
concurrent GUI app), and the gate asserts `desktop: launch CALC.BIN`,
`calc: ready`, and `syscalls` showing `28 sys_exec calls=1`.

Class A: `zig test kernel/src/syscall.zig` (dispatch/marshalling/error
mapping for slot 28), `zig test kernel/src/exec.zig` (pid getter), and
`zig test user/src/lib/ui.zig` / `user/src/desktop.zig` — all green;
`zig fmt` clean. Class B: `tools/verify-live-desktop.sh` extended as above.
