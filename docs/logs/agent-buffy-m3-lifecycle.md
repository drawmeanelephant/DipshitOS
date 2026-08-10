# Log — user task lifecycle (claim 6729)

- **Branch:** `agent/buffy/m3-lifecycle`
- **Claim:** [`docs/claims/6729-task-lifecycle.md`](../claims/6729-task-lifecycle.md)
- **Started:** 2026-08-10

## Progress

- **Survey** (2026-08-10): read the tick scheduler, exception vectors +
  IRQ chain, syscall exit semantics, EL0 payload, monitor `tasks`
  command, shell loop, and the live-tasks/live-addrspaces gates. The
  scheduler already had `exit_current`/terminated states from claim 5804;
  card 5's real work is the explicit lifecycle (spawn/reap/idle), the
  runtime `spawn` command, and the state reporting.

- **Lifecycle implemented** (2026-08-10): `State` enum (free/ready/running/
  zombie), `spawn` (first free slot, bounded), `reap`, the scheduler-owned
  idle task at the last slot (bounded-nop park + one-zombie-per-iteration
  reaper), `spawn_demo` + the monitor `spawn` command, per-row `state=` +
  pool/zombie header in `tasks`, per-task report slots, exit/reap reports
  from the shell loop. Unit tests updated (44/44); transcript fixture
  regenerated; new gate `tools/verify-live-lifecycle.sh` + justfile +
  gate-inventory entries; `verify-live-tasks.sh` hardened for the bigger
  ring.

- **Live gate regression — VM error (state=3) after the user's first
  quantum** (2026-08-10): every gate (lifecycle AND addrspaces, no spawn)
  died right after the EL0 payload's `uaccess: efault ok n=8` line with
  `switches=0`, no `[EXC]`, VM state=3 (.error). Bisected: with the idle
  task registered → VM error with no guest exception; with idle unregistered
  → the guest caught `[EXC] esr=0x96000021` (sync external abort, DFSC=0x21)
  at `far=0x872` in the shell task (sp=0x7e40a2c0), PC inside
  `shell.boot_and_park`'s report-printing path, `x19 = &mon.console ≈ 0x872`.

- **Root cause — callee-saved registers were never part of the task
  context** (2026-08-10): the claim-9746 vector frame saves x0..x17 + x30
  only. On a context switch the resumed task keeps the *preempting* task's
  live x19..x28 — the shell's `mon` (held live in x19 across the loop) was
  overwritten by the worker's loop counter (≈0x872), so the shell's next
  console write dereferenced 0x872. The old code layout dodged this latent
  claim-5275 bug; the idle task's extra ring slot shifted the codegen into
  it (and into a VM-level error instead of a guest abort depending on
  timing). Fixed by extending the frame to 32 slots: the stubs push
  x19..x28 + x29 first (6 pairs at the frame top), the inline restore
  became a 3-instruction setup + `b exc_restore_tail`, and a shared tail
  pops the full frame + `eret`. Stubs stay 28 instructions (112 bytes) in
  their 128-byte slots. The frame helpers gained x19..x29 read/write; the
  syscall ABI slots are untouched.

- **Two follow-on fixes from the green-again gates** (2026-08-10):
  1. The addrspaces gate's `user-own-root` assertion failed after the fix:
     claim 6729's idle task reaps the exited user promptly, so the
     `task user-el0 ttbr0=` row is legitimately gone by the time the gate's
     post-exit script runs (claim 5804's zombies were never reaped, so the
     row survived there). `cmd_addrspaces` now also prints
     `addrspaces: user root=` directly from `mmu.user_root_phys()`, and the
     gate compares that against the kernel root.
  2. `demo-adv` never appeared in the lifecycle gate: the single shared
     `report_pending` flag was permanently held by the worker's
     every-64-iterations requests, starving the demo's every-16-iterations
     reports. Reports became per-task arrays.

- **Verification** (2026-08-10): class A green (fmt, unit tests, transcript,
  build/image, coordination). Class B all 1/1 on VZ: lifecycle (the new
  gate), addrspaces (with the `user root=` assertion), uaccess, svc,
  userspace, tasks, timer, exceptions, transcript, fs, reboot.

- **Docs reconciled** (2026-08-10): claim 6729 + this log; march-m3 row 5 →
  done; status milestone-three row + roadmap item 12; gate inventory;
  README command count 24→26 + milestone blurb; indexes refreshed;
  `verify-coordination.sh` green.

## Claim 6783 — load and exec a real user program from the ESP (march-m3 card 6)

- **Started:** 2026-08-10

- **Survey** (2026-08-10): read the ESP/FAT/virtio-blk storage path (claim
  6420), the claim-5804 user-root builder (`mmu.build_user_root` +
  `clone_into_user_root`), the scheduler lifecycle (claim 6729 — bounded
  spawn, exit→zombie, idle reaper), the syscall/uaccess write path
  (sys_write's writer is the uart — EL0 writes land directly in the serial
  log), the monitor command pattern, the image builder (mkfat32.py +
  make-image.sh) and elf2bin.py's DSK1 flat format. The static EL0 payload
  (userspace.entry) is the only EL0 code today; card 6 replaces it at
  runtime with a program loaded from the ESP.

- **Design** (2026-08-10): a separate `user/` program built via elf2bin
  into `USER.BIN` and embedded on the ESP; a kernel `exec [<file>]` monitor
  command that reads the file through `fat.read_file` into a fixed BSS
  buffer, validates the DSK1 header, rebuilds the user root around the
  loaded page with `mmu.build_user_root`, and spawns the program as an EL0t
  task; gated on the static user task being gone (one user program at a
  time — the lifecycle's closed loop). A new class-B live gate asserts the
  loaded program's `sys_write` marker lines + exit in vm-serial.log.

- **Implementation** (2026-08-10): `user/src/main.zig` + `user/linker.ld`
  (naked-asm EL0 payload: sys_write markers, two sequenced pings, sys_exit
  status 42); `zig build user` → USER.BIN via elf2bin; `mkfat32.py` +
  `make-image.sh` embed USER.BIN at the volume root; `kernel/src/exec.zig`
  (DSK1 header validation, in-place header strip, `mmu.build_user_root`
  post-install + `mmu.clean_table_storage`, bounded one-program-at-a-time
  gate via `scheduler.user_root_in_use`); scheduler `register_exec_user` +
  `user_stack_phys`; monitor `exec` command (registry 26→27); class-B gate
  `tools/verify-live-exec.sh`; unit tests + transcript fixture + CI fmt +
  justfile + gate-inventory entries.

- **Live fixes found by the gate (2026-08-10):**
  1. The user ELF's orphan `.eh_frame_hdr`/`.eh_frame` sections landed at
     VMA 0, so the flat image's entry pointed at CFI bytes — the EL0 task
     faulted immediately (`ec=0x00` at the entry). Fixed by discarding
     `.eh_frame*` in the user linker script.
  2. `build_user_root` masks the text phys to page granularity, so mapping
     `program+24` mapped the DSK1 HEADER page — the task fetched "DSK1" and
     faulted on its zero pad (`elr=0x400004`, `head=0x44534b31...`). Fixed
     by stripping the 24-byte header in place before mapping.

- **Verification** (2026-08-10): class A green (fmt incl. user/src, unit
  tests, transcript byte-identical, build/image/inspect with USER.BIN on
  the ESP, coordination). Class B all 1/1 on VZ: the new live-exec gate +
  lifecycle, addrspaces, uaccess, svc, userspace, tasks, timer regressions.

- **Docs reconciled** (2026-08-10): claim 6783 + this log; march-m3 row 6 →
  done + lane D text; status milestone-three row, gate table `live-exec`
  row, tracker item 13, command count 26→27; README milestone-three blurb;
  gate inventory; indexes refreshed; `verify-coordination.sh` green.
