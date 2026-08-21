# Roadmap archive — Milestone four: entropy/CSPRNG, general FS, processes & follow-ons

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).
>
> These bullets lived under `docs/roadmap.md`'s "Later milestones (sketches only,
> not commitments)" section; they are milestone-four work (claims 2665/3678/3848/
> 0826/4613/7786/1014/4636/5965/5795/5799/3179/9946), closed by tag
> `m4-processes`. Per-card tracker: [`docs/march-m4.md`](../march-m4.md).

---

- A guest-side filesystem — **the ESP FAT32 driver landed 2026-08-09
  (claim 6420):** `kernel/src/fat.zig` (GPT + FAT32 mount/list/read/write
  with injected sector I/O) over `kernel/src/virtio_blk.zig` (the
  runner's disk as a modern virtio-blk transport, DID 0x1042 on VZ,
  re-armed post-exit after VZ resets the device at ExitBootServices).
  `ls`/`cat`/`write` serve the live ESP volume; files persist on the
  disk itself. **A general (non-ESP) filesystem is DONE 2026-08-10
  (claim 3678, milestone four card 2)** — the driver now mounts ANY FAT32
  volume at ANY disk offset (`fat.mount_partition`), walks arbitrary
  directory cluster chains with `/`-path resolution (the image's
  EFI/BOOT tree is reachable: `ls [<dir>]`, `cat <file|path>`), and the
  disk image carries a second 36 MiB DATA FAT32 partition (Linux-FS type
  GUID) mounted by the new `mount <esp|data>` command with a re-
  snapshotted, honestly-labeled window. Live gate
  `tools/verify-live-gfs.sh` PASS 1/1 — the DATA volume is mounted by
  GUID, listed, read, written, and the file persists across a reboot on
  the disk itself.
- ~~**Entropy/CSPRNG (sketch).**~~ **DONE 2026-08-10 (claim 2665, milestone
  four card 1)** — the kernel has a REAL randomness source: a modern
  virtio-pci entropy driver (`kernel/src/virtio_entropy.zig`, DID 0x1044)
  with the claim-6420 post-MMU re-arm lesson (**observed: VZ resets the
  device at ExitBootServices — `entropy: pre-rearm st=00`**), a
  freestanding ChaCha20 CSPRNG (`kernel/src/csprng.zig`, RFC 7539,
  KAT-pinned in `zig test`) seeded from a 64-byte boot-time device read
  (`entropy: seeded n=64`), the `random [n]` monitor command (registry
  27→28), and a real ASLR consumer (the exec path randomizes the loaded
  EL0 program's user stack VA per boot). Live gate
  `tools/verify-live-entropy.sh` PASS 2/2 — two boots produce different
  `random` sequences and stack placements; see
  `docs/hardware-contract.md` (entropy bullet now `[observed]`).
- **A process abstraction is DONE 2026-08-10 (claim 3848, milestone four
  card 3)** — a bounded process registry (`kernel/src/process.zig`) where
  each Process owns the loaded image, the address space, the lifecycle
  state, and the exit status (which now survives the executor task's
  reap); exec and the boot-time static EL0 payload register as real
  processes, `exit_current` feeds the registry, the `procs` monitor
  command (registry 29→30) prints the table, and the new class-B gate
  `tools/verify-live-procs.sh` PASS 1/1 shows the exec'd program running
  as a process with the boot payload's exited status kept past the reap.
- **Concurrent processes is DONE 2026-08-10 (claim 0826, milestone four
  follow-on)** — the exec gate (`scheduler.user_root_in_use`, one user
  program at a time) is gone: every process owns its own TTBR0 user root
  and allocator-backed text/user-stack/EL1-exception-stack pages, the
  syscall/uaccess regions arm per task at SVC entry, and exec gates on
  capacity (pool slot, table carve-out, registry) instead. Two programs
  now load and run CONCURRENTLY — the class-B gate
  `tools/verify-live-concurrent.sh` PASS 1/1 on VZ shows a `procs` table
  with TWO `state=running` USER.BIN rows (distinct task ids + stack VAs)
  and both programs' markers interleaving; the full shared-seam live
  sweep (exec/procs/addrspaces/tasks/userspace/svc/uaccess/lifecycle/
  sleep/entropy) is green against the relaxed gate.
- **A long-lived process among live peers is DONE 2026-08-10 (claim 4613,
  milestone-four follow-on 2)** — claim 0826's two processes were copies
  of the SAME program that both exited; this card adds a SECOND DSK1
  image (COUNTER.BIN from `user/src/counter.zig`, embedded by the same
  build/image pipeline) that NEVER exits (sys_write + sys_yield only, no
  sys_exit) with DISTINCT `counter: alive` markers, and returns an exited
  program's allocator pages at the same reap that frees its executor slot
  (the exited descriptor stays in `procs`). The class-B gate
  `tools/verify-live-long-lived.sh` PASS 1/1 on VZ — the counter stays
  `state=running` across the whole session while USER.BIN exits, is
  reaped, and is re-exec'd into the freed slot (the runner's new
  `--script2`/`--script2-after` second phase forwards the re-exec after
  the first reap), the `pages` free count recovers, and a further exec
  with both live reports `pool_full` — the capacity gate with one spare
  slot; the full shared-seam live sweep is green against the second
  program.
- **Kill — the kernel owns process lifetime — is DONE 2026-08-10 (claim
  7786, milestone-four follow-on 3, card 3c)** — claim 4613 proved a
  process can REFUSE to exit (COUNTER.BIN loops forever) but nothing
  could END it; the new `kill <pid|name>` monitor command (registry
  30→31) arms the target's TCB (`scheduler.request_kill`) and the ring
  converts its NEXT selection into the existing exit path with the
  reserved status 137 (no syscall, ADR 0007 frozen; the switching core
  is untouched). The killed process flows through the REAL lifecycle —
  exit → zombie → idle-reap → page return (`procs` shows
  `state=exited task=reaped exit=137`) — and the class-B gate
  `tools/verify-live-kill.sh` PASS 1/1 on VZ: NO `counter: alive` marker
  lands after the `kill:` line (only one task runs at a time, so the
  killed task never executes again), the `pages` free count recovers by
  EXACTLY 5 at the reap, and a phase-3 re-exec lands in the freed slot
  (the runner gains the `--script3`/`--script3-after` third phase); the
  full 12-gate shared-seam live sweep is green.
- **Per-process exit reports — exact counts — is DONE 2026-08-10 (claim
  1014, milestone-four follow-on 3, card 3d)** — the exit/reap report
  machinery was a single first-wins-while-undrained flag (documented
  debt from claims 0826/4613), so N exits in one idle-loop window
  collapsed to ONE report line and the concurrent/long-lived gates had to
  assert ≥1. The three single-slot report flags become bounded 4-slot
  name+status FIFOs (pushed from exception context — pure BSS writes —
  and drained IN ORDER by the shell idle loop and the monitor, no
  double-print; drop-oldest overflow, documented + host-tested; ADR 0007,
  the switching core, and the lifecycle states untouched — reporting
  machinery only). The concurrent + long-lived gates tighten to EXACT
  counts and both PASS 1/1 on VZ: two exits in one window print exactly
  two `tasks user-exec exited status=43` / two `procs USER.BIN exited
  status=43` / two `tasks user-exec reaped` lines, in order, with the
  boot payload's `tasks user-el0 exited status=7` staying its own
  distinct line; the full 12-gate shared-seam live sweep is green.
- **Exec context block — arguments to EL0 — is DONE 2026-08-10 (claim
  4636, milestone-four follow-on 3, card 3e)** — the tokenizer already
  split `exec <file> [arg...]` but `monitor.exec` ignored the extras, so
  a program's identity was its image only and the SAME binary could not
  distinguish itself per exec. Card 3e packs a bounded argv block (8
  args × 32 B, NUL-terminated, per-arg 31-byte truncation; >8 args is an
  honest refusal) into the process's OWN text page right after the
  loaded content — the text leaf is already EL0 read-only (W^X, AP=
  read-only), so the block is a READ-ONLY leaf with ZERO extra pages
  (the per-program 5-page budget and every exact-count page gate stay
  untouched) — and extends the ENTRY contract (NOT a syscall; ADR 0007
  frozen): `_start` receives `argc` in x0 and the block VA in x1 via the
  claim-9746 frame slots. The text aperture extends over the block, so
  uaccess copy_in reads it and copy_out faults (host-tested both
  directions). The class-B gate `tools/verify-live-args.sh` PASS 1/1 on
  VZ — `exec USER.BIN alpha` + `exec USER.BIN beta`: the SAME binary
  loads twice, the procs snapshot shows two `state=running` rows with
  distinct task ids + stack VAs, the DISTINCT markers (`user:
  arg=alpha` / `user: arg=beta`) prove which invocation is which, both
  programs complete (status 43 — EXACT FIFO counts), and a third exec is
  `pool_full` (5/5, no spare); the full 12-gate shared-seam live sweep
  is green.
- **IPC — distinct processes exchange data (claim 5965, milestone-four
  follow-on 3, card 3f)** — coexistence is proven (claims 0826/4613) but
  two live processes cannot COMMUNICATE; the strongest proof of "real
  processes" is end-to-end data flow between them. The card lands the
  FIRST inter-process data path: a bounded per-process kernel mailbox
  (4 × 64 B BSS ring per process id, no allocation —
  `kernel/src/mailbox.zig`) behind TWO new syscalls (the card's ONE ABI
  change, following the `sys_sleep` slot-4 precedent): `sys_ipc_send`
  (slot 5) copies the caller's bytes through uaccess into the TARGET's
  ring (full → `ENOSPC` -5), `sys_ipc_recv` (slot 6) copies the caller's
  OWN ring out (empty → 0; peek → copy_out → drop, so an EFAULT never
  loses a message) — cross-process isolation (a process reaches only its
  own mailbox via recv and a live target's via send), the ring reset on
  process create/recycle. `mbox [<pid>]` monitor command (registry
  31→32) dumps per-process pending/sent/recv + the queued bytes.
  COUNTER.BIN gains a periodic send (`ipc: ping <d>` every 3 iterations,
  target pid parsed from its argv — card 3e's entry contract) and a
  THIRD image PEER.BIN (`user/src/peer.zig` through the parameterized
  build pipeline) recv-loops forever and echoes `peer: got ping <d>` —
  TWO never-exiting programs exchanging bytes, byte-exact in the serial
  log. Pool math at 5 slots: counter + peer + shell + worker + idle =
  5/5, NO spare (a third exec is `pool_full`; the 3g capstone raises the
  budget). The class-B gate `tools/verify-live-ipc.sh` PASS 1/1 on VZ:
  `exec PEER.BIN` + `exec COUNTER.BIN 1` back to back, the counter's
  `ipc: ping N` sends and the peer's `peer: got ping N` echoes
  interleaved across the whole log (every send echoed byte-for-byte),
  `mbox` shows the peer's ring drained (pending ≤ 1, sent − recv ==
  pending) and the counter's ring empty, both processes still
  `state=running` at the final `procs` and neither ever exits, a third
  exec is `exec: no free scheduler pool slot`, and the shell stays
  responsive; the full 12-gate shared-seam live sweep + the args + kill
  gates are green.
- **[Claim 5795, milestone-four follow-on 3, card 3g — the pool-scale
  capstone]** — every prior card documented the 5-slot budget (3b/3c/3f:
  "5/5, NO spare"; 3a/3e: one spare). This card DELIBERATELY raises the
  scheduler pool `max_tasks` 5 → 7 (`idle_id` stays `max_tasks - 1`) and
  re-derives the gates: shell + worker + FOUR EL0t user slots + idle
  (the 4th user slot is the "spare" while only three are live). A BUDGET
  change only — ADR 0007, the switching core, the lifecycle states, and
  the ring mechanics untouched; the pool is a BSS array (no allocation).
  The page-table carve-out survey (kernel root + 4 user roots,
  `addrspaces: tables=NN/256`) keeps the roots well inside the 256-page
  budget (observed 150/256). Every capacity assertion re-derives: the
  exec/scheduler host tests (`pool_full` at the new budget, exact
  free-counts on the refused path), the transcript fixture (`tasks:
  pool=4/5` → `pool=4/7`), and the live gates (args/ipc's `pool_full`
  moves to the FIFTH exec at 7/7; long-lived's ending becomes the
  one-spare scenario — counter + two users + spare — with the page
  counts differing by exactly the second program's 5 pages). The new
  class-B gate `tools/verify-live-scale.sh` PASS 1/1 on VZ: `exec
  COUNTER.BIN` + `exec USER.BIN` ×3 back to back — FOUR `state=running`
  user rows with distinct task ids + stack VAs, the programs' markers
  interleaving with the worker's advances across the whole log, a FIFTH
  exec `pool_full` (7/7 — shell + worker + 4 users + idle),
  `addrspaces: tables=150/256`, the counter still running at the final
  procs; the full shared-seam sweep re-derived against the 7-slot pool:
  12-gate sweep + args + kill + ipc all PASS 1/1.
- **[Claim 5799, milestone-four follow-on 4, card 4a — process
  observability]** — the process registry exists (claim 3848) but only
  the EL1h monitor can read it; this card gives EL0 a READ-ONLY view:
  `sys_procs(buf, max)` = slot 7 (ADR 0007 amendment — the card's ONE
  ABI change, `implemented_count` 7 → 8, `syscalls` rows 0–7) copies a
  bounded snapshot of the process table (one fixed 40-byte row per
  non-free descriptor: u64 pid, u64 state code, u64 exit status,
  name[16] NUL-padded) out into the caller's region through uaccess,
  `max` truncating to whole rows (a documented truncation result like
  the ipc recv path), marshaled into a fixed BSS scratch — no
  allocation. PEER.BIN (reused — the pool stays 7/7) polls `sys_procs`
  once per quantum until it sees a running peer, then prints
  `peer: sees <pid> <name> <state>` per row (including the exited boot
  payload's row) and falls into its existing recv loop. The new class-B
  gate `tools/verify-live-procs-syscall.sh` PASS 1/1 on VZ: the peer's
  `peer: sees 2 COUNTER.BIN running` row proves the counter is visible
  FROM EL0 — distinct from the monitor's `procs` read — the IPC flow
  still echoes, both processes never exit; the full 12-gate shared-seam
  sweep + the args/kill/ipc/scale gates all PASS 1/1.
- **[Claim 3179, milestone-four follow-on 4, card 4b — IPC depth]** —
  the card-3f mailbox is 4 × 64 B per process, so a bursty flow (more
  than 4 sends before the peer drains) would refuse with ENOSPC. This
  card raises `mailbox.max_messages` 4 → 8 (the per-process ring grows
  256 → 512 B of fixed BSS) as a DATA-PATH CONSTANT — NOT a syscall
  number (ADR 0007 documents the choice; the follow-on-4 set's ABI
  amendments are ONLY slots 7/8, on cards 4a/4c). The truncation
  contract is unchanged: a message > 64 B still truncates at the slot
  bound, a full ring still refuses with the same `ENOSPC` -5 (now at the
  9th send), the same empty → 0 recv, the same drain invariant
  `sent − recv == pending ≤ capacity`, the same cross-process isolation.
  COUNTER.BIN's send cadence becomes a BURST: every 6th iteration it
  sends 6 messages back-to-back in ONE quantum, then 5 quiet iterations
  (the peer drains 1 per round — the ring peaks at 6 of the 8 slots and
  drains to 0 before the next burst: NO ENOSPC, deterministically); each
  send checks its return and prints a distinct `ipc: enospc` marker on
  failure. The re-derived class-B gate `tools/verify-live-ipc.sh` PASS
  1/1 on VZ: the counter's 6-message bursts (`ipc: ping N` … `ipc: ping
  N+5` back-to-back) interleave with the peer's byte-exact echoes, ZERO
  `ipc: enospc` lines, the log's peak (sends − echoes) = 6 (> 4
  messages queued at once, never over the re-derived 8-slot bound), the
  `mbox` snapshot shows the peer's ring drained at the new capacity
  (pending ≤ 8, sent − recv == pending) and the counter's empty, both
  never exit, a fifth exec is `pool_full` at 7/7; the full 12-gate
  shared-seam sweep + the args/kill/scale/procs-syscall gates all PASS
  1/1.
- **[Claim 9946, milestone-four follow-on 4, card 4c — exit-status
  propagation]** — the process table is observable FROM EL0 (4a) and
  the mailbox flows deeper (4b), but a process still cannot WAIT on a
  peer: the exit status of another process is visible only through the
  EL1h monitor. This card lands `sys_wait(target)` = slot 8 (ADR 0007
  amendment — the follow-on-4 set's explicit slots 7/8 change,
  `implemented_count` 8 → 9, `syscalls` rows 0–8): the caller blocks
  until the target process exits and returns its status — bounded,
  kernel-owned, NOT POSIX wait (no zombies, no fds). A running target
  parks the caller through the claim-0635 sleep seam
  (`scheduler.wait_current` — the SVC frame stays on the caller's
  kernel stack), and the exit path's `wake_waiters` flips the task back
  to `ready` while patching the observed status into the saved frame's
  x0, so the syscall return lands when the ring resumes it; an
  already-exited target returns its stored status immediately; EINVAL
  for a non-process caller, a free/out-of-range target, a `created`
  (loaded, not yet running) target, or a self-wait (the refused
  deadlock). The block is event-driven — the tick clock never wakes a
  waiter. A THIRD program STATUS43.BIN (`user/src/status43.zig`, a
  fourth ESP image through the same build pipeline) prints its alive
  marker, sleeps 6 scheduler ticks (a deterministic window), then exits
  43; COUNTER.BIN exec'd with the wait target in its argv (slot 8)
  prints `ipc: waiting pid=<n>`, blocks, and prints `ipc: saw pid=<n>
  status=<s>` on wake — the EL0-side proof of the propagation. The new
  class-B gate `tools/verify-live-wait.sh` PASS 1/1 on VZ: the
  phase-2 `tasks` snapshot shows TWO `state=blocked` user-exec rows
  (the sleeping STATUS43 + the waiting counter) while `procs` still
  shows STATUS43 `state=running` — the target ALIVE while the waiter is
  blocked — then `ipc: saw pid=1 status=43` agreeing with the kernel's
  `tasks user-exec exited status=43` / `procs STATUS43.BIN exited
  status=43` records; the full 12-gate shared-seam sweep + the
  args/kill/ipc/scale/procs-syscall gates all PASS 1/1.
