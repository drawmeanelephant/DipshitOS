# Milestone-four follow-on 3, cards 3e + 3f + 3g — exec args, IPC, pool scale

Planning-first prompt doc for DipshitOS, the NEXT SET of follow-on 3
cards (after claim 1014 / PR #77). The syscall ABI (ADR 0007) stays
frozen EXCEPT card 3f's explicit amendment (slots 5/6, following the
`sys_sleep` slot-4 precedent). No libc/POSIX/heap anywhere. Each card is
its own branch/claim/PR; the full 12-gate shared-seam live sweep runs
after every card.

## Suggested sequence

- Card 3e first (args) then 3f (IPC) — both extend the EL0 data path:
  the entry contract, then the ABI amendment; 3f's PEER.BIN rides 3e's
  pipeline parameterization. 3e and 3f are independent of 3c/3d.
- Card 3g LAST — the capstone. It deliberately raises the pool budget and
  re-derives the capacity gate; the others' budgets must be stable first,
  and the full sweep re-runs after the pool change.

---

## Card 3e — exec context block: arguments to EL0 (claim 4636)

- **Branch:** `agent/buffy/m4-exec-args` (claim 4636 from branch + slug
  `exec-args` via `bash tools/status/claim-id.sh`)
- **Why:** a program's identity today is its image only — the same binary
  cannot distinguish itself per exec, and EL0 has no way to receive
  per-exec data. Args make the "distinct programs" proof stronger (the
  SAME image, distinguished by its argv) and open per-invocation behavior.

**Scope:**

1. `exec <file> [arg...]` — the tokenizer already splits (`shell.zig`:
   `tokenize` → `monitor.exec(mon, argv[0..count])`; the limit is 18
   tokens = command + 17 args). `monitor.exec` today ignores everything
   past the filename; card 3e packs a bounded argv block (suggest 8 args
   × 32 B) into a process-owned page.
2. The loader maps the argv block into the user root as a READ-ONLY leaf
   (W^X discipline preserved): EL0 can read it; a write faults via the
   existing uaccess contract (host-test both directions).
3. Entry contract extension (documented in the claim, NOT a syscall
   change): `_start` receives argc in x0 and the block VA in x1. Today
   `build_initial_frame` (`kernel/src/scheduler.zig:428`) zeroes the whole
   frame — x0/x1 are 0 at `_start`. The frame is the claim-9746 vector
   layout (32 slots: x0..x17, x30, pad, x19..x28+x29); write argc/argv-VA
   into the x0/x1 slots. `register_exec_user` takes `(entry_va, root,
   content_len, stack_va, kstack_size, kstack)` — thread the block VA
   through (or extend the signature) to a `spawn`-level frame build.
4. USER.BIN prints each arg via sys_write (`user: arg=<n>`);
   truncation/overflow host-tested (too many args → documented truncation
   or refusal, honestly reported).
5. Host tests: argv packing shape + truncation; the args leaf present /
   read-only / absent from the EL0 write aperture; per-exec distinct argv.
6. Live gate `tools/verify-live-args.sh`: `exec USER.BIN alpha` and
   `exec USER.BIN beta` back to back — the SAME binary prints
   `arg=alpha` / `arg=beta` markers, both programs live (two running
   rows), distinct markers prove which invocation is which.

**Do not:** add syscalls or touch ADR 0007's syscall numbers; grow the
pool (two live programs fit the 5-slot budget with no spare — document
it); break the frozen W^X / uaccess discipline.

---

## Card 3f — IPC: distinct processes exchange data (claim 5965)

- **Branch:** `agent/buffy/m4-ipc` (claim 5965 from branch + slug
  `ipc-mailbox`)
- **Why:** coexistence is proven (3a/3b), but two live processes cannot
  COMMUNICATE — the strongest remaining proof of "real processes" is
  end-to-end data flow between them, not just simultaneous markers.

**Scope:**

1. **ADR 0007 amendment** (the card's one ABI change, following the
   `sys_sleep` slot-4 precedent): `sys_ipc_send(target, buf, len)` = slot
   5 and `sys_ipc_recv(buf, max)` = slot 6.
2. Bounded per-process kernel mailbox (suggest 4 × 64 B ring, BSS — no
   allocation). Send does uaccess copy_in from the caller's region; full
   mailbox → documented ENOSPC-style result. Recv copies out; empty →
   documented empty result. A process can only reach ITS mailbox (recv)
   and the target's (send) — cross-process isolation, uaccess-bounded
   (host-test).
3. `mbox [<pid>]` monitor command (registry 31→32) dumps pending
   messages.
4. Extend COUNTER.BIN with a periodic send (`ipc: ping n` every few
   quanta); add a third image PEER.BIN (`user/src/peer.zig` → PEER.BIN
   through the now-parameterized pipeline — `build.zig`/`make-image.sh`/
   `mkfat32.py` embed a third program, self-verifying in the listing)
   that recv-loops and echoes `peer: got n` forever — TWO never-exiting
   programs communicating. Pool math at 5 slots: counter + peer + shell +
   worker + idle = 5/5, NO spare (document; a third exec is `pool_full` —
   reuse the 3b capacity proof under IPC).
5. Host tests: send/recv round-trip; mailbox full/empty results;
   cross-process isolation (a process can only reach its own mailbox +
   the target's ring, uaccess-bounded); truncation.
6. Live gate `tools/verify-live-ipc.sh`: exec COUNTER.BIN + PEER.BIN; the
   peer's `peer: got n` markers land interleaved with the counter's sends
   across the whole log (end-to-end data flow between two live
   processes), both still running at the final `procs`, `mbox` shows the
   ring drained, a third exec is `pool_full`.

**Do not:** grow the pool; add POSIX-style pipes/fds/signals; unbounded
mailboxes; touch the switching core. (The ABI amendment is the ONLY
syscall change in this card set — everything else keeps ADR 0007 frozen.)

---

## Card 3g — pool scale: a third live user process (claim 5795)

- **Branch:** `agent/buffy/m4-pool-scale` (claim 5795 from branch + slug
  `pool-scale-seven`)
- **Why:** every prior card documents the 5-slot budget with one spare or
  none. This card DELIBERATELY raises the budget and re-derives the gate
  — the machinery's scale proof, and the capstone that unblocks future
  cards needing 3+ live user programs.

**Scope:**

1. Grow `max_tasks` 5 → 7 (`kernel/src/scheduler.zig:73`; `idle_id` stays
   `max_tasks - 1`) — shell + worker + 3 user programs + one spare +
   idle. Re-derive the idle/spare budget.
2. Audit the page-table carve-out: the `tables=NN/256` budget
   (`mmu.build_user_root`) must hold the kernel root + 3 user roots —
   count it in the survey and assert it in the addrspaces gate.
3. Re-derive every pool-capacity host test: `pool_full` at the new
   budget; `has_free_slot` still first-checked; the refused path still
   leak-free with an exact free-count assertion.
4. New live gate `tools/verify-live-scale.sh`: exec COUNTER.BIN +
   USER.BIN + USER.BIN (three live user programs); `procs` shows THREE
   `state=running` rows with distinct task ids + stack VAs; all three
   markers interleave with the worker's advances; a fourth exec →
   `pool_full`. The 3b long-lived gate's one-spare scenario re-derives at
   the new budget (counter + two users + spare).

**Do not:** grow the pool for any OTHER card (3c/3d/3e/3f document their
own budgets); touch ADR 0007; unbounded anything.

---

## Shared process (every card)

1. Claim first: deterministic claim doc + branch log +
   `bash tools/status/refresh-indexes.sh`; planning-first prompt doc
   (split this file per card when claiming).
2. Class A first: `zig fmt --check`, unit tests, transcript
   byte-identical (`zig build test-console` + `verify-transcript.sh`),
   build/image/inspect, swift build, context, coordination ×2, mmu-debt.
3. Class B on VZ: the card's new live gate + the FULL 12-gate
   shared-seam live sweep (exec/procs/concurrent/tasks/lifecycle/
   addrspaces/sleep/svc/uaccess/userspace/entropy/long-lived), evidence
   saved under `artifacts/`.
4. Docs reconciliation: march-m4 row + lane, roadmap, status,
   gate-inventory, README, claim flip, log append, PR per the repo
   template (real observed evidence only).

## Do not (any card)

- Touch ADR 0007's syscall numbers except card 3f's explicit slots 5/6
  amendment; the scheduler switching core; the process lifecycle states.
- Add libc/POSIX/heap allocation anywhere; grow anything unbounded.
- Claim hardware behavior without a saved VZ log (`artifacts/`).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
