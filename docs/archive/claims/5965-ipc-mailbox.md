# Claim: IPC — distinct processes exchange data (card 3f)

- **Owner:** Buffy (`agent/buffy/m4-ipc`)
- **Prompt / plan:** milestone-four follow-on 3 card 3f (after claim 4636 /
  PR #78, card 3e). Written plan first:
  [`docs/m4-ipc-prompt.md`](../m4-ipc-prompt.md).
- **Scope:** (1) the card's ONE ABI change — ADR 0007 slots 5/6, following
  the `sys_sleep` slot-4 precedent: `sys_ipc_send(target, buf, len)` and
  `sys_ipc_recv(buf, max)` (updated ADR doc + `syscall.zig` table +
  `syscalls` command output; every other syscall number stays frozen);
  (2) a bounded per-process kernel mailbox (4 × 64 B ring, BSS — no
  allocation) where send copy_in's from the caller's region into the
  TARGET's ring (full → documented ENOSPC-style result), recv copy_out's
  the caller's OWN ring (empty → 0), and a process can only reach its own
  mailbox (recv) and the target's (send) — cross-process isolation,
  uaccess-bounded both directions (host-tested); (3) `mbox [<pid>]`
  monitor command (registry 31→32) dumping per-process pending/sent/recv
  + the pending messages; (4) COUNTER.BIN gains a periodic send (`ipc:
  ping n` every few quanta, target pid parsed from argv — card 3e's
  entry contract) and a THIRD image PEER.BIN (`user/src/peer.zig` →
  PEER.BIN through the now-parameterized build pipeline —
  `build.zig`/`make-image.sh`/`mkfat32.py` embed the third program,
  self-verified in the listing) that recv-loops and echoes `peer: got
  ping n` forever — TWO never-exiting programs communicating; pool math
  at 5 slots: counter + peer + shell + worker + idle = 5/5, NO spare
  (documented; a third exec is `pool_full` — the 3b capacity proof
  reused under IPC); (5) host tests: send/recv round-trip, full/empty
  results, cross-process isolation, truncation, and the frame/syscall
  marshaling for slots 5/6; (6) new class-B gate
  `tools/verify-live-ipc.sh`: exec COUNTER.BIN + PEER.BIN — the peer's
  `peer: got ping n` echoes land interleaved with the counter's `ipc:
  ping n` sends across the whole log (end-to-end data flow between two
  live processes), both still running at the final `procs`, `mbox`
  shows the rings drained (the peer's pending ≤ 1 — the single in-flight
  message — and its recv count tracks its sent count; nobody sends to
  the counter, so its pending is exactly 0), and a third exec is
  `pool_full`. Do NOT grow the pool (`max_tasks` stays 5 — the 3g
  capstone raises it), add pipes/fds/signals, unbounded mailboxes, or
  touch the switching core / lifecycle states. No libc/POSIX/heap; host
  tests first; class B on VZ.
- **Depends on:** claim 4636 / PR #78 (card 3e — this branch stacks on
  the 3e tree so argv/entry-contract, the pooled exec path, and the
  report FIFOs are current). Independent of cards 3c/3d's mechanics.
- **Status:** ✅ done 2026-08-10 (PR #79, staged after PR #78 card 3e)

## Notes

**Why it matters:** coexistence is proven (claims 0826/4613 — two live
processes, distinct images), but two live processes cannot COMMUNICATE.
The strongest remaining proof of "real processes" is end-to-end data flow
between them — not just simultaneous markers: the counter SENDS bytes, the
peer RECEIVES the same bytes and echoes them into the serial log.

**Key design facts (from the survey):**

- **The ABI amendment follows the `sys_sleep` slot-4 precedent exactly**:
  one new row per slot in the runtime-built dispatch table, the ADR 0007
  D2/D3 tables, and the `syscalls` report (rows 0–6 now). Error codes
  only GROW: `ENOSPC` = -5 is added; nothing existing moves. Slots 7–63
  stay reserved. The x8/x0–x5/x0-result convention is untouched.
- **The mailbox is a fixed BSS ring per process id** (`max_processes` × 4
  slots × 64 B ≈ 2 KiB — no allocation, no pointers in const tables).
  `kernel/src/mailbox.zig` is a pure storage module (no libc/POSIX/heap);
  `send`/`peek`/`drop` are the only mutators. The syscall layer owns the
  POLICY: target validation against the process registry, uaccess
  copy-in/copy-out through the frozen `EFAULT` contract, and the
  documented truncation rules (a send longer than 64 B is truncated to
  64; a recv with `max` > 64 clamps to 64; a recv whose `max` is shorter
  than the oldest message copies that many bytes and consumes the
  message). Send to a free/exited target is `EINVAL`; a full ring is
  `ENOSPC`; a bad user pointer is `EFAULT` — checked before any mailbox
  state changes (the recv path peeks → copy_out → drop, so an EFAULT
  leaves the message queued).
- **Isolation story:** a process reaches its OWN mailbox via recv and a
  TARGET's via send; the ring is keyed by process id, every byte crosses
  the uaccess window (kernel-mediated), and the ring is reset whenever a
  process id is created/recycled (`mailbox.reset(pid)` right after
  `process.create` on both the exec path and the boot-payload
  registration; `mailbox.init()` alongside `process.init()` in
  `scheduler.init`). Host tests drive send/recv both directions and pin
  the EINVAL rejections (free target, exited target, out-of-range id).
- **The payloads ride the card-3e entry contract, not new syscalls for
  plumbing**: `exec COUNTER.BIN <peer-pid>` — the counter parses its
  target pid from argv[0] (naked-asm decimal parse, 2 digits), and with
  argc == 0 it is byte-identical to the claim-4613 counter (the
  long-lived/kill gates' exact marker counts stay green). The counter
  formats `ping <d>\n` (d cycles 1..9) on its OWN stack, writes the
  console marker `ipc: ping <d>` (the "send" announcement), and sends
  the same 7 bytes via sys_ipc_send every 3rd iteration — slower than
  the peer drains, so the ring never accumulates. PEER.BIN recv-loops:
  recv (empty → spin + yield; got → `peer: got ` + the received bytes)
  forever — a second permanent occupant, no sys_exit anywhere.
- **Pool math at 5 slots:** shell + worker + idle + COUNTER + PEER = 5/5,
  NO spare — a third exec is `pool_full` (the 3b capacity proof reused
  under IPC; the 3g capstone raises the budget). The peer + counter are
  BOTH never-exiting, so this is the strongest simultaneous-marker +
  data-flow proof yet.
- **The `mbox` snapshot is honest about the one in-flight message**: the
  counter sends 1 message per ~3 of its quanta and the peer drains every
  quantum, so at any instant at most ONE message can be in flight
  (send → drain window ≤ one round-robin round). The gate therefore
  asserts the peer's `pending ≤ 1` (never accumulating — the bounded
  ring is DRAINED, not filling), its `recv` count tracks the echo count,
  and the counter's own ring is `pending=0` deterministically (nobody
  sends to it). The `peer: got ping n` echoes vs `ipc: ping n` sends
  across the whole log are the end-to-end byte-flow proof.

## Verification

- **Class A:** fmt, unit tests (mailbox ring wrap/full/empty/reset; the
  syscall round-trip, full→ENOSPC, empty→0, isolation rejections,
  truncation both directions, slot-5/6 marshaling; mbox command output;
  exec host tests: PEER.BIN + COUNTER.BIN by name, both running, third
  exec `pool_full`, 5/5 no spare), transcript byte-identical (fixture +
  mock test gain the `mbox` help row), build/image/inspect (listing
  self-verifies PEER.BIN), swift build, context, coordination ×2,
  mmu-debt — all green.
- **Class B — the new gate:** `tools/verify-live-ipc.sh` PASS 1/1 on VZ —
  `exec PEER.BIN` + `exec COUNTER.BIN 1` back to back: two
  `state=running` rows with distinct task ids + stack VAs, the counter's
  `ipc: ping <d>` sends and the peer's `peer: got ping <d>` echoes
  interleaved across the whole log (echoes track sends, byte-for-byte),
  `mbox` shows the peer's ring drained (pending ≤ 1, recv tracking) and
  the counter's ring empty, both processes still running at the final
  `procs`, a third exec is `pool_full` (5/5, no spare), shell
  responsive. Evidence under `artifacts/live-ipc-*`.
- **Class B — shared-seam regressions:** the full 12-gate live sweep
  (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/uaccess/
  userspace/entropy/long-lived) all PASS 1/1, plus the new ipc gate and
  the existing args/kill gates.

## Stage C (2026-08-10)

- Docs reconciled: march-m4 row + Buffy summary, roadmap bullet, status
  paragraph, README follow-on 3 paragraph, gate-inventory (live-ipc row +
  machine record + verify-vz aggregate, and the verify-vz aggregate
  regains the live-args recipe the 3e card left out of justfile), claim
  flipped. PR #79 opened.
