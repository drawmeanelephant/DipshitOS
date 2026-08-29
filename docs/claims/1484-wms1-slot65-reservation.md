# Claim: WMS1 — accept ADR 0015 + freeze slot 65 `sys_wmctl` & kind 18 `COMPOSITE_TICK`

- **Owner:** buffy (`agent/buffy/docs-pass`)
- **Prompt / plan:** implement GitHub milestone-16 card WMS1 (issue #621): flip
  ADR 0015 to ACCEPTED and freeze the ABI reservations it makes — slot 65
  `sys_wmctl` (subcommand encoding) in ADR 0007, event kind 18
  `COMPOSITE_TICK` (+ routing-restriction note) in ADR 0009, and the reserved
  `COMPOSITE_TICK` constant in `kernel/src/events.zig`. Docs + one kernel
  constant; the encoded blocks come verbatim from the planning claim 2852.
- **Touches:** docs/decisions/0007-syscall-abi.md, docs/decisions/0009-application-events.md, docs/decisions/0015-window-server-render-seam.md, kernel/src/events.zig, docs/march-m32-wm-migration.md, docs/status.md, docs/logs/agent-buffy-docs-pass.md
- **Depends on:** planning claim 2852 (the folded WMS1 acceptance blocks); N/A
  otherwise (first card in the milestone)
- **Heartbeat:** 2026-08-28
- **Status:** ✅ done 2026-08-28 (all checks green: verify-coordination, `zig
  fmt --check` canonical scope, `zig build`, `verify-unit-tests.sh`; slot 65
  not in `dispatch_table`, kind 18 not delivered — no behavior change)

## Notes

Frozen decisions (from planning claim 2852's addendum): non-WM calls to
`sys_wmctl` return `EACCES` (-7) — **not** the draft's `EPERM`, which does not
exist in the kernel `ErrorCode` enum (`kernel/src/syscall.zig:285`, top at
-10 `ENOMEM`). Seat-taken on a second `REGISTER` → `EACCES` (EL1h
force-unregister escapes it); `REGISTER` with no GPU → `ENXIO` (-9);
`COMPOSITE_TICK` rides the scheduler tick seam. `slot_count` is already 128, so
the ADR 0007 amendment writes the honest "reserved 66–127" tail.

**Verified when:** ADR 0015 reads ACCEPTED; ADR 0007 carries the slot-65 row,
the three-subcommand encoding table (REGISTER=1 / SET_WINDOW=2 /
REQUEST_PRESENT=3), and the error contract; ADR 0009 D2 carries the kind-18 row
+ routing note; `events.zig` defines `COMPOSITE_TICK = 18`; the WMS1 march row
flips ✅; the self-check (verify-coordination, `zig fmt --check`, `zig build`,
rg greps) is green. WMS1 is docs + a reserved constant only — no handler
registered, no behavior change (slot 65 still returns `-ENOSYS` via the
`handler orelse` at `syscall.zig:444`).