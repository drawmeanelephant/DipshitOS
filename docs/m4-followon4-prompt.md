# Milestone-four follow-on 4, cards 4a + 4b + 4c — process observability, IPC depth, exit-status propagation

> **PROPOSAL — NOT YET A REPO PLAN.** The follow-on-3 set (cards 3c–3g,
> claims 7786/1014/4636/5965/5795, PRs #77–#80) is the last written
> block; nothing in the repo plans past card 3g. This doc is a
> planning-first PROPOSAL for the next set, grounded in the current
> code state (7 syscall slots implemented of the frozen 64; 32-command
> monitor registry; 7-slot pool; 4 × 64 B per-process mailbox rings;
> kill + exit-report FIFOs). Treat every branch/claim/PR number below
> as a suggestion to verify with `bash tools/status/claim-id.sh` at
> claim time, and the whole set as open to rewrite.

Planning-first prompt doc for DipshitOS, the NEXT SET after follow-on 3.
ADR 0007 stays frozen EXCEPT this set's explicit slots 7/8 amendment
(following the `sys_sleep` slot-4 and ipc slots-5/6 precedents). No
libc/POSIX/heap anywhere. Each card is its own branch/claim/PR; the full
12-gate shared-seam live sweep runs after every card.

## Suggested sequence

- Card 4a first (process observability) then 4b (IPC depth) then 4c
  (exit-status propagation). 4a gives EL0 its first read-only view of
  the process table and rides the existing `process.info`/`procs`
  plumbing; 4c's blocked-wait builds on 4b's send/recv machinery where
  sensible and needs the 4a snapshot to make "waiting for <pid>" testable
  by name. 4b is independent of 4a.
- Merge order: 4a → 4b → 4c (each stacked on merged main).

---

## Card 4a — process observability: a `sys_procs` introspection syscall (proposed claim)

- **Branch:** `agent/buffy/m4-procs-syscall` (claim via branch + slug
  `procs-syscall` and `bash tools/status/claim-id.sh`)
- **Why:** today only the EL1h monitor (`procs` command) can read the
  process table; an EL0 program cannot tell who else is alive. The
  strongest remaining "real OS" proof is a process-level view reachable
  from EL0 — a program that can report its peers by name/state.

**Scope:**

1. **ADR 0007 amendment** (this card's one ABI change): `sys_procs(buf,
   max)` = slot 7 — copy_out a bounded snapshot of the process table
   (id, name, state, exit status where set) into the CALLER's region
   through uaccess (a read-only view; no write path). `implemented_count`
   7 → 8; `syscalls` rows 0–7. Update the ADR doc + `syscall.zig`
   table + `syscalls` command output.
2. The snapshot is bounded (the table is `process.max_processes` = 8
   rows; each row fixed-width so `max` bytes truncates honestly — a
   documented truncation result, like the ipc recv path). No allocation:
   the reply is formatted into a fixed BSS scratch then copy_out.
3. Host tests: row shape + fixed-width marshaling; truncation at `max`;
   EFAULT for a bad `buf`; the snapshot reflects live registry state
   (running/exited rows); the frame/syscall marshaling for slot 7.
4. Live gate `tools/verify-live-procs-syscall.sh`: extend PEER.BIN (or a
   new fourth image if the pool budget allows at 7/7 — otherwise reuse
   PEER.BIN) to call `sys_procs` once and print a
   `peer: sees <name>=<state>` line per live peer; the gate asserts the
   counter's `COUNTER.BIN=running` row is visible FROM EL0, distinct
   from the monitor's own `procs` read.

## Card 4b — IPC depth: bigger or more messages (proposed claim)

- **Branch:** `agent/buffy/m4-ipc-depth` (claim via branch + slug
  `ipc-depth`)
- **Why:** the card-3f mailbox is 4 × 64 B per process — a message
  longer than 64 B truncates and only four outstanding messages fit. The
  data-flow proof is real but narrow; depth makes the IPC path useful
  for multi-line payloads and bursty flows, still bounded.

**Scope:**

1. Choose ONE, document it in ADR 0007 (the ABI stays frozen — this is a
   data-path constant, not a syscall number):
   - **Option A — variable-length messages:** raise `message_max` 64 →
     256 B (ring stays 4 slots, pure BSS, still bounded; a longer
     message still truncates honestly). Smallest change; the counter can
     send multi-line payloads.
   - **Option B — more messages:** raise `max_messages` 4 → 8 (256 → 512
     B per process ring, still fixed BSS). The counter can send 8
     pings before the peer drains.
   (Either way: same ENOSPC full-ring result, same empty result, same
   drain invariant `sent − recv == pending ≤ capacity`, same
   cross-process isolation — host-test all of it.)
2. Re-derive every host test that pins the 64 B / 4-slot constants
   (mailbox ring wrap/full/empty/reset, the ipc syscall truncation
   tests, the `mbox` command output shape).
3. Live gate: extend `tools/verify-live-ipc.sh`'s flow — the counter
   sends a >64 B (or >4-message burst) payload and the peer echoes it
   byte-exact; the `mbox` drain invariant holds at the new capacity.

## Card 4c — exit-status propagation: a bounded `sys_wait`-style block (proposed claim)

- **Branch:** `agent/buffy/m4-wait-exit` (claim via branch + slug
  `wait-exit`)
- **Why:** a process can EXIT with a status (3d), be KILLED (3c), and be
  observed by the monitor — but no other PROCESS can wait for that
  outcome. The kernel already owns lifetime; this lets one process block
  until another's exit and receive its status. NOT POSIX `wait` — no
  zombies, no fds, no process-tree semantics: a bounded, kernel-owned
  "block until target pid exits, then return its status".

**Scope:**

1. **ADR 0007 amendment** (this card's one ABI change): `sys_wait(pid)` =
   slot 8 — block the CALLER until `pid` exits (or is already exited),
   then return its snapshotted status (the registry already keeps it
   past the reap). `implemented_count` 8 → 9; `syscalls` rows 0–8.
   Follow the `sys_sleep` slot-4 block/resume precedent (blocked task
   drops out of the ring, wake on the target's exit) — do NOT touch the
   switching core or the lifecycle states.
2. Refusals, documented + host-tested: a nonexistent pid; waiting on the
   shell/idle (the console must survive); self-wait; the bounded-pool
   interaction (a blocked waiter still occupies its pool slot — document
   the pool math at 7/7).
3. Host tests: the block → target exit → status return path; already-
   exited target returns immediately; the refusals; the frame/syscall
   marshaling for slot 8; the report FIFOs still print exactly once.
4. Live gate `tools/verify-live-wait.sh`: exec COUNTER.BIN + a short
   program that exits status 43; COUNTER.BIN blocks on it via
   `sys_wait` and prints `counter: saw exit <status>` after the exit
   line — end-to-end exit-status propagation between live processes at
   the 7-slot pool.

---

## Shared process (every card)

1. Claim first: deterministic claim doc + branch log +
   `bash tools/status/refresh-indexes.sh`; planning-first prompt doc
   (split this file per card when claiming).
2. Class A first: `zig fmt --check`, unit tests, transcript
   byte-identical (`zig build test-console` + `verify-transcript.sh`),
   build/image/inspect, swift build, context, coordination ×2, mmu-debt.
3. Class B on VZ: the card's new live gate + the FULL 12-gate shared-seam
   live sweep (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/
   uaccess/userspace/entropy/long-lived) plus the args/kill/ipc/scale
   gates, evidence saved under `artifacts/`.
4. Docs reconciliation: march-m4 rows + lane, roadmap, status,
   gate-inventory, README, claim flip, log append, PR per the repo
   template (real observed evidence only).

## Do not (any card)

- Grow the pool (7/7 stays — card 3g is the capstone; do NOT change
  `max_tasks`); touch the scheduler switching core or the process
  lifecycle states.
- Add POSIX pipes/fds/signals/`waitpid` semantics; unbounded mailboxes
  or tables; heap allocation anywhere.
- The ABI amendment is ONLY this set's slots 7/8 — every existing
  syscall number (0–6) stays frozen.
- Claim hardware behavior without a saved VZ log (`artifacts/`).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
