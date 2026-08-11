# Claim: process observability — sys_procs introspection syscall (card 4a)

- **Owner:** Buffy (`agent/buffy/m4-procs-syscall`)
- **Prompt / plan:** milestone-four follow-on 4, card 4a (the first card of
  the 4a/4b/4c set — the proposal doc
  [`docs/m4-followon4-prompt.md`](../m4-followon4-prompt.md), split per
  card: [`docs/m4-procs-syscall-prompt.md`](../m4-procs-syscall-prompt.md)).
  Written plan first; stacked on merged main d792c85 (PR #80, card 3g).
- **Scope:** (1) the card's ONE ABI change — ADR 0007 slot 7, following the
  `sys_sleep` slot-4 and ipc slots-5/6 precedents: `sys_procs(buf, max)`
  copies a bounded snapshot of the process table (id, name, state, exit
  status where set) OUT into the caller's region through uaccess (a
  read-only view — no write path), with a documented truncation result
  (`max` floors to whole 40-byte rows); `implemented_count` 7 → 8,
  `syscalls` rows 0–7 (updated ADR doc + `syscall.zig` table + `syscalls`
  command output; every existing syscall number 0–6 stays frozen);
  (2) the row marshaling (u64 pid, u64 state code, u64 exit_status,
  name[16] NUL-padded; free rows skipped; fixed BSS scratch — no
  allocation) host-tested for shape, truncation, EFAULT, and live-registry
  reflection; (3) PEER.BIN gains a phase-1 `sys_procs` read (one call per
  quantum until it sees its peer, then the existing recv-loop) printing
  `peer: sees <pid> <name> <state>` per row — a process-level view of the
  process table REACHABLE FROM EL0; (4) new class-B gate
  `tools/verify-live-procs-syscall.sh`: exec PEER.BIN + COUNTER.BIN — the
  peer's `peer: sees ... COUNTER.BIN running` row proves the counter is
  visible FROM EL0 (distinct from the monitor's own `procs` read), both
  programs stay running, and the ipc flow still echoes. Do NOT grow the
  pool (`max_tasks` stays 7), touch the switching core / lifecycle states,
  or add pipes/fds/signals/heap. No libc/POSIX; host tests first; class B
  on VZ.
- **Depends on:** merged main d792c85 (PR #80 — card 3g, the 7-slot pool
  capstone). Card 4a is the first card of the follow-on 4 set; 4b and 4c
  stack on it in order (4a → 4b → 4c).
- **Status:** ✅ done 2026-08-11 (claim flipped after class-A green + the new live gate + the full shared-seam sweep)

## Notes

**Why it matters:** the process registry exists (claim 3848) and the
monitor can print it — but only the EL1h monitor can. An EL0 program has
no way to learn who else is alive; the strongest remaining "real OS" proof
is a process-level view reachable from EL0 — a program that can report its
peers by name/state. `sys_procs` is the read-only introspection half of
that proof (card 4c's `sys_wait` is the reactive half — it builds on this
card's snapshot where sensible).

**Key design facts:**

- **The ABI amendment follows the precedents exactly**: one new row in the
  runtime-built dispatch table, the ADR 0007 D2 table, and the `syscalls`
  report (rows 0–7, implemented 8). Slots 8–63 stay reserved. The x8/
  x0–x5/x0-result convention is untouched; errors only reuse the frozen
  codes (`EFAULT` for a bad buf).
- **Fixed-width rows, honest truncation:** every row is 40 bytes
  (pid/state/exit_status/name[16]) so `max` bytes truncates to whole rows
  — the same "bounded + documented truncation" contract as the ipc recv
  path. The snapshot is marshaled into a fixed BSS scratch
  (`max_processes` × 40 = 320 B) — no allocation — then copy_out'd. Free
  descriptors are skipped; created/running/exited rows are included (the
  boot payload's exited row is visible too).
- **The EL0 proof rides PEER.BIN** (the pool is 7/7 — no fourth image):
  PEER.BIN calls `sys_procs` once per quantum until it sees a running
  peer (the counter is exec'd AFTER the peer, so the first snapshot may
  only show the peer itself — the loop is deterministic, the counter's
  row appears on the next round), prints `peer: sees <pid> <name>
  <state>` per row, then enters its existing recv-loop unchanged. The
  gate asserts the counter's row is visible from EL0, distinct from the
  monitor's `procs` read.

## Verification

- **Class A:** fmt, unit tests (the new `syscall.zig` procs tests — row
  shape, truncation, EFAULT, live-registry reflection, slot-7 frame
  marshaling — plus the updated `syscalls` report), transcript
  byte-identical (the `syscalls` fixture row/implemented count changes),
  build/image/inspect (the PEER.BIN listing self-verify is unchanged),
  swift build, context, coordination ×2, mmu-debt — all green.
- **Class B — the new gate:** `tools/verify-live-procs-syscall.sh` PASS
  1/1 on VZ — `exec PEER.BIN` + `exec COUNTER.BIN 1`: the peer's
  `peer: sees <pid> <name> <state>` lines include the counter's
  `COUNTER.BIN running` row read FROM EL0 (distinct from the monitor's
  own `procs` read), both processes still `state=running` at the final
  `procs` and neither ever exits, the ipc flow still echoes (`peer: got
  ping` lines land — the peer entered its recv-loop after the snapshot),
  shell responsive. Evidence under `artifacts/live-procs-syscall-*`.
- **Class B — shared-seam regressions:** the full 12-gate live sweep
  (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/uaccess/
  userspace/entropy/long-lived) all PASS 1/1, plus the args/kill/ipc/
  scale gates.
