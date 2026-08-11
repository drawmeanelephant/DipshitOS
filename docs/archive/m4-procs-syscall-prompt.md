# Milestone-four follow-on 4, card 4a — process observability: a `sys_procs` introspection syscall

> **PLANNING-FIRST — this is the per-card split of
> [`docs/m4-followon4-prompt.md`](m4-followon4-prompt.md) (the proposal for
> the whole 4a/4b/4c set). ADR 0007 stays frozen EXCEPT this card's slot 7
> (following the `sys_sleep` slot-4 and ipc slots-5/6 precedents). No
> libc/POSIX/heap anywhere. New branch `agent/buffy/m4-procs-syscall` on
> merged main (current tip d792c85), claim 5799 (deterministic).

## Why

Today only the EL1h monitor (`procs` command) can read the process table; an
EL0 program cannot tell who else is alive. The strongest remaining "real OS"
proof is a process-level view reachable from EL0 — a program that can report
its peers by name/state.

## Scope

1. **ADR 0007 amendment** (this card's one ABI change): `sys_procs(buf,
   max)` = slot 7 — copy_out a bounded snapshot of the process table
   (id, name, state, exit status where set) into the CALLER's region
   through uaccess (a read-only view; no write path). `implemented_count`
   7 → 8; `syscalls` rows 0–7. Update the ADR doc + `syscall.zig` table +
   `syscalls` command output.
2. **Row shape (fixed-width, host-tested):** each row is 40 bytes —
   `u64 pid` (LE) at 0, `u64 state code` at 8 (1=created, 2=running,
   3=exited — the `process.State` enum), `u64 exit_status` at 16 (0
   unless exited), `name[16]` NUL-padded at 24 (the `process.name_max`
   bound). Free descriptors are skipped. The snapshot is marshaled into a
   fixed BSS scratch (`max_processes` × 40 = 320 B, no allocation) then
   copy_out'd: `max` bytes truncates to WHOLE rows
   (`floor(max / 40)`), a documented truncation result like the ipc recv
   path. Returns the row count written.
3. **Errors:** `EFAULT` (-3) for a bad `buf` (the claim-6120 contract —
   the copy is validated before any state is touched; nothing is
   consumed, there is no peek/drop ordering to preserve); `EINVAL` for a
   `max` that is not a whole-row multiple? **No** — partial rows are
   simply not copied (honest truncation, never a partial row). `max == 0`
   → 0 rows.
4. **Host tests:** row shape + fixed-width marshaling; truncation at
   `max` (floor to whole rows, partial rows dropped); EFAULT for a bad
   `buf`; the snapshot reflects live registry state (running/exited rows,
   free rows skipped); the frame/syscall marshaling for slot 7 (x8=7,
   x0=buf, x1=max, x0=rows); the `syscalls` report shape (implemented=8,
   row 7).
5. **Live gate `tools/verify-live-procs-syscall.sh`:** reuse PEER.BIN
   (the pool is 7/7 — no new image). PEER.BIN gains a phase-1 loop: call
   `sys_procs` once per quantum and scan the returned rows until it sees
   its peer; print `peer: sees <pid> <name> <state>` per row, then enter
   the existing recv-loop. The gate asserts the counter's
   `COUNTER.BIN running` row is visible FROM EL0 (distinct from the
   monitor's own `procs` read), both programs still run, and the ipc
   flow still echoes.

## Sequence

1. Claim first (this prompt + `docs/claims/5799-procs-syscall.md` +
   `docs/logs/agent-buffy-m4-procs-syscall.md` + `refresh-indexes.sh`).
2. Class A first: fmt, unit tests, transcript byte-identical
   (`zig build test-console` + `verify-transcript.sh` — the `syscalls`
   fixture row changes), build/image/inspect, swift build, context,
   coordination ×2, mmu-debt.
3. Class B on VZ: the new gate + the FULL 12-gate shared-seam live sweep
   (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/uaccess/
   userspace/entropy/long-lived) plus the args/kill/ipc/scale gates,
   evidence saved under `artifacts/`.
4. Docs reconciliation: march-m4 row + lane, roadmap, status,
   gate-inventory, README, claim flip, log append, PR per the repo
   template (real observed evidence only).

## Do not

- Grow the pool (`max_tasks` stays 7); touch the switching core or the
  lifecycle states.
- Add POSIX pipes/fds/signals; unbounded mailboxes or tables; heap.
- Touch existing syscall numbers 0–6 (slot 7 is THIS card's only ABI
  change).
- Claim hardware behavior without a saved VZ log (`artifacts/`).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
