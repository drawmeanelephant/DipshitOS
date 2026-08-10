# Claim: load and exec a real user program from the ESP (card 6)

- **Owner:** Buffy (`agent/buffy/m3-lifecycle`)
- **Prompt / plan:** milestone-three march card 6 ([`docs/march-m3.md`](../march-m3.md)).
  Card text: **load and exec a real user program from the ESP — read through
  the existing FAT32 storage path and enter the loaded program at EL0.**
- **Scope:** the milestone-three ESP-exec half of userspace. A separate user
  program (`user/src/main.zig`, freestanding AArch64, naked-asm EL0 payload
  on the fixed syscall ABI) is built into a flat `USER.BIN` (the proven
  elf2bin DSK1 format) and embedded on the ESP by the image builder. The
  kernel gains an `exec [<file>]` monitor command that reads the file
  through the claim-6420 FAT path into a fixed BSS buffer, validates the
  DSK1 header, rebuilds the EL0 task's TTBR0 user root around the loaded
  pages (reusing claim 5804's `build_user_root`), and spawns an EL0t task
  that runs the loaded program — proving loading + exec, not a new general
  filesystem or process abstraction.
- **Depends on:** claims 6420 (FAT32 storage driver), 5804 (per-task user
  address spaces + `build_user_root`), 6729 (task lifecycle — the freed
  user slot + bounded spawn), 3594/6120 (syscall ABI + uaccess), 8215
  (EL0/SVC boundary).
- **Status:** ✅ done 2026-08-10

## Notes

**Why the loaded program replaces (not joins) the static payload:** the
claim-8215 static EL0 payload is boot-registered and owns the user root
while alive. Exec is gated on that task being gone (exited to a zombie and
reaped — the lifecycle's closed loop), so at most ONE user program runs
under the user root at a time. This is milestone-three scope: no process
abstraction, no multi-program address spaces.

**User-root strategy — rebuild, don't mutate:** `exec` reuses
`mmu.build_user_root` to synthesize a fresh user root (identity-tree clone
+ the loaded text page at `userspace.text_va` + the static user stack at
`userspace.stack_va`), then D-cache-cleans the table carve-out and the
program buffer before the scheduler's next TTBR0 switch. Each exec consumes
a fresh clone from the fixed 256-table carve-out, so repeated exec cycles
are bounded by the pool and reported honestly (`table_exhausted`). The
syscall/uaccess apertures stay the claim-8215 static regions — the loaded
program maps within them (≤ 1 page at `text_va`, the 8 KiB user stack), so
`sys_write` bounds hold unchanged.

**The gate proves the full chain on VZ:** `USER.BIN` is on the ESP (a real
file), `exec USER.BIN` reads it through the virtio-blk FAT path, the loaded
program writes marker lines through `sys_write` (direct to the serial log),
round-trips `sys_ping`, and exits with a distinct status; `tasks` +
exit/reap lines close the lifecycle. All of it is asserted in
`vm-serial.log`.

## Verification

- **Class A:** `zig fmt --check` (including `user/src/*.zig`), unit tests
  (exec module 4 tests: DSK1 header rejection, honest no-disk, the ok
  load+spawn path with the header stripped, and the one-program-at-a-time
  gate; monitor 148 total), byte-identical transcript gate (help listing +
  fixture updated with the `exec` command), build + image + inspect
  (USER.BIN embedded on the ESP, 155 bytes), coordination indexes — all
  green.
- **Class B on VZ (all 1/1):** the new `bash tools/verify-live-exec.sh`
  (USER.BIN listed, `exec: loaded` reply with the loaded head bytes, both
  sys_write markers, `tasks user-exec exited status=42` + `reaped`, shell
  echo, runner rc=0) plus regressions on the shared seams: lifecycle,
  addrspaces, uaccess, svc, userspace, tasks, timer.
- **Evidence:** `artifacts/live-exec-*` (gate log + serial logs),
  `artifacts/m3-exec-live.txt`.

**Observed vs inferred:** the loaded program's execution, sys_write
markers, ping round-trips, exit and reap are directly observed in
`vm-serial.log` on VZ. The two fixes (`.eh_frame` discard; in-place DSK1
header strip) were each root-caused from live fault data: the first fault
ran the CFI bytes (`elr` inside `.eh_frame_hdr` at the entry), the second
fetched the literal "DSK1" magic and faulted on its zero padding
(`elr=0x400004`, `ec=0x00`, `head=0x44534b31...`).
