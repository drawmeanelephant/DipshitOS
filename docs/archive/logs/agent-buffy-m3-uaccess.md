# Log — `agent/buffy/m3-uaccess`

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-10** — *Buffy (`agent/buffy/m3-uaccess`)*: claim 6120
  uaccess-fault-safe-copy → implementing the milestone-three uaccess card
  (copy_in/copy_out + EFAULT contract + fault recovery window), migrating
  `sys_write` onto uaccess, adding the `uaccess` monitor diagnostic and the
  EL0-payload EFAULT exercise, then the new class-B live gate. · 🔄 in progress

- **2026-08-10** — *Buffy (`agent/buffy/m3-uaccess`)*: **claim 6120 done** →
  `kernel/src/uaccess.zig` (bounded copy_in/copy_out, EFAULT for
  out-of-region/overflow/unmapped/permission, masked fault-recovery window),
  `exceptions.zig` sync-path hook, `sys_write` migrated onto uaccess,
  `uaccess` monitor command (registry 23 → 24, mock fixture + transcript
  regenerated), EL0-payload EFAULT exercise (`uaccess: efault ok n=8`),
  ADR 0007 amendment, gate-inventory + justfile updated. **Root cause found
  on the first live run:** the optimizer sank `window_active = true` below
  the faulting user load (no reader inside the loop) → the handler parked
  instead of recovering; fixed with volatile window-state accesses + a
  compiler barrier, documented in the module. Class A green (fmt, 164+
  unit tests, byte-identical transcript, builds, coordination,
  test-coordination, mmu-debt). Class B green on VZ: new
  `verify-live-uaccess.sh` 1/1 (EL0 sees -3 and survives; monitor recovers
  a real data abort — `valid=1 fault=1 recovered=1`), `verify-live-svc`
  1/1 with `write=3`, regressions live-exceptions / live-userspace /
  live-timer / live-tasks / live-transcript / `zig build run` all green.
  Evidence: `artifacts/m3-uaccess-live.txt`, `artifacts/live-uaccess-*`,
  `artifacts/live-svc-*`. · ✅ done
