# Milestone-four follow-on 2 — a long-lived process among live peers (distinct programs)

Planning-first prompt doc for DipshitOS, the follow-on to claim 0826 /
PR #73 (concurrent processes: two live user address spaces).

- **Branch:** `agent/buffy/m4-long-lived-process` (claim 4613, deterministic
  ID from branch + slug via `bash tools/status/claim-id.sh`)
- **Date:** 2026-08-10
- **Depends on:** claim 0826 (per-process roots + allocator-backed
  text/stack/EL1-stack pages, exec gate relaxed to capacity), claim 3848
  (process registry, `procs`), claims 6783/5804/6729/0635, the physical
  allocator (3972/5162), claims 2665/3693 (per-process stack ASLR). The
  syscall ABI (ADR 0007) is frozen and untouched.

## The card

Claim 0826 proved TWO live processes — but only as two copies of the SAME
program (USER.BIN), both of which exit after a few ticks. This card proves
the machinery against DISTINCT programs and a permanent occupant:

1. **A second user program in the image.** Today the ESP carries one user
   program (USER.BIN from `user/src/main.zig`). Add a second DSK1 flat
   image (`user/src/counter.zig` → `COUNTER.BIN`) built and embedded by
   the same build/image pipeline, with its own distinct EL0 markers (the
   serial log can tell the two programs apart — the claim-0826 gate's
   markers are identical strings today).
2. **A never-exiting program.** COUNTER.BIN loops forever writing a counter
   marker each quantum (a bounded spin, no sys_exit). This is the strong
   liveness proof the two-copies gate lacks: the shell, the worker, AND a
   second concurrently-exec'd program all stay responsive while a process
   occupies its pool slot and address space permanently.
3. **Recycle and reap under a permanent occupant.** While COUNTER.BIN
   runs, exec + exit a short program (USER.BIN) — its process is reaped,
   its pages return to the allocator (free-count recovery asserted), and a
   THIRD exec lands in the freed slot; with the counter still alive a
   subsequent exec is `pool_full` (the capacity gate with one slot left —
   `has_free_slot` still works, and the refused path leaks nothing).
4. **Observable live.** A `procs` table showing COUNTER.BIN
   `state=running` across the whole session while USER.BIN transitions
   running → exited → reaped, and a live gate that execs the counter,
   execs + reaps the short program, re-execs, then observes `pool_full`.
5. **Docs + claim + PR** (march-m4 follow-on note / row 3b, roadmap
   bullet, status, gate-inventory, README, log, claim flip).

Keep the syscall ABI (ADR 0007) frozen (the counter needs only sys_write +
sys_yield), no libc/POSIX/heap, host tests first, class B on VZ.

## Survey (what the code actually looks like today)

- **The image pipeline embeds ONE user program.** `build.zig` builds
  `user/src/main.zig` → elf2bin → `USER.BIN`, installed to
  `zig-out/bin/` and passed as the fourth arg to `image/make-image.sh`
  (`[EFI_BIN] [IMAGE] [KERNEL_BIN] [USER_BIN]`), which hands it to
  `image/mkfat32.py` (`IMAGE EFI_FILE [KERNEL_FILE] [USER_FILE]`). The
  FAT32 builder writes a `USER    BIN` root entry + its own cluster chain.
  **A second DSK1 image costs one more freestanding executable, one more
  optional arg through both scripts, and one more root entry + chain.**
- **`exec <file>` already takes any file name.** The monitor command is
  `exec [<file>]` (default `USER.BIN`); `exec.zig` does `esp.lookup(name)`
  + `fat.read_file(name, &program)` — an 8.3 FAT name, so `exec
  COUNTER.BIN` works once the file is embedded. No monitor or kernel
  load-path change needed.
- **The scheduler pool budget with a permanent occupant.** `max_tasks =
  5`: shell (0) + worker (1) + user (2) + spare (3) + idle (4). The boot
  payload exits + is reaped before the live gate's script is forwarded
  (`--script-after "tasks user-el0 exited status=7"`), so the counter
  takes the first free slot and USER.BIN takes the last — shell + idle +
  worker + counter + user = 5/5. A third concurrent exec is `pool_full`:
  `exec_file` checks `scheduler.has_free_slot()` FIRST, before allocating
  pages or tables, so the refused path never leaks (host-tested with an
  exact free-count assertion). The pool is NOT grown; the one-spare budget
  is the deliverable and is documented.
- **The allocator free-count path across a concurrent exit+reap.** Each
  exec allocates 5 pages (1 text + 2 user stack + 2 EL1 exception stack);
  `process.reap` frees them via `alloc.free_pages`. The live log proves
  the return two ways: the `pages` command's `free=` count (printed in
  both phases of the gate — the late count must be >= the early count,
  since the recycled USER.BIN's pages returned and the re-exec
  re-allocated) and the lifecycle lines (`tasks user-exec exited
  status=43` / `tasks user-exec reaped`). The host test pins the exact
  +5 recovery.
- **A never-exiting program needs NO new syscall.** The counter is naked
  asm under the fixed ABI: sys_write(fd 1, marker, len) → bounded nop
  spin → sys_yield → repeat. The saved register file survives SVC (the
  claim-9746 frame), so a register counter can persist across quanta, but
  no numeric printer is needed — one distinct fixed marker string per
  iteration distinguishes the programs in the log.
- **The runner forwards the whole script in ONE burst** (claim 6684:
  `--script` is written to the serial attachment once, after
  `--script-after`), so a scripted re-exec that must land AFTER the first
  USER.BIN exits (~10 s with the 1 s tick) cannot be timed from a single
  burst. The live gate therefore adds a SECOND scripted phase to the
  runner (`--script2 <file>` + `--script2-after <text>`, forwarded once
  after the second marker appears — the first USER.BIN's reap line). This
  is a class-A-buildable host-side change; the guest kernel is untouched.

## Design

### `user/src/counter.zig` — the never-exiting program (new)

- A second freestanding AArch64 flat image in the same shape as
  `user/src/main.zig` (naked `_start`, fixed register ABI only): write
  the distinct marker `counter: alive\n` via sys_write (fd 1, slot 1),
  run a bounded nop spin (~200k iterations), yield (sys_yield, slot 2),
  and loop forever. **No sys_exit.**
- The marker bytes are exposed as a `pub const marker: []const u8` so a
  host test pins the exact shape (and the sys_write length used in the
  asm) — the live gate's grep target cannot drift from the payload.
- The module exports `_start` and compiles under `zig test` (the same
  compile-check test as `user/src/main.zig`).

### `build.zig` / `image/make-image.sh` / `image/mkfat32.py` — the second image

- `build.zig`: a second freestanding executable (`user/src/counter.zig`,
  same kernel_target + `user/linker.ld`), elf2bin → `COUNTER.BIN`,
  installed (`zig-out/bin/COUNTER.BIN`), and passed to BOTH `zig build
  image` and `zig build bad-handoff` as the fifth arg.
- `make-image.sh`: fifth positional arg `COUNTER_BIN` (optional, same
  pattern as USER.BIN — skipped when absent, DSK1-magic-checked when
  present); the self-verify step now greps the `--list` output for
  `COUNTER.BIN` (plus the existing files) so the embed is asserted.
- `mkfat32.py`: `build_fat32_image` gains `counter_bytes=None` — a third
  optional volume file with its own cluster chain (`COUNTER BIN` root
  entry, `COUNTER.BIN` data clusters, ordered after USER.BIN);
  `build_image` and `main` pass it through (DSK1-magic-warned like the
  others). `--list`/`--cat-file` need no change.

### `kernel/src/exec.zig` — host tests pin the new behavior

The kernel load path is UNCHANGED (exec-by-name already works). The new
host tests:

- **exec COUNTER.BIN by name**: write a DSK1 image whose content is the
  counter marker into the fixture FAT, `exec_file("COUNTER.BIN")` → `ok`,
  the process is named `COUNTER.BIN` with its own root/stack/pages, and
  the task is registered.
- **pool-gate-with-one-spare + recycle + free-count recovery**: arm the
  fixture allocator, retire the boot payload, `exec COUNTER.BIN` (takes a
  slot), `exec USER.BIN` (takes the last free slot); a THIRD exec →
  `pool_full` with the free-count UNCHANGED (nothing allocated on the
  refused path); then drive USER.BIN's exit + reap (the scheduler
  lifecycle), assert the free count recovered by exactly the freed 5
  pages, re-exec USER.BIN (the third exec LANDS in the freed slot), and
  assert a subsequent exec is `pool_full` again while the counter stays
  running — the exact recycle-under-a-permanent-occupant sequence the
  live gate observes.

### `host/vm-runner` — second scripted phase

- New options `--script2 <file>` and `--script2-after <text>`: forward
  `script2` once (0.5 s settle, same machinery as `--script`) after the
  `script2-after` marker appears in the serial log. No-op unless both are
  given; class-A-buildable (the CI swift build compiles it).

### `tools/verify-live-long-lived.sh` — the live gate (new)

Phase 1 script (forwarded after the boot payload exits):
`ls | exec COUNTER.BIN | exec USER.BIN | procs | pages | echo
rx-long-lived-phase1`

Phase 2 script (forwarded after `tasks user-exec reaped` — the first
USER.BIN's reap):
`exec USER.BIN | procs | exec USER.BIN | pages | echo rx-long-lived-ok`

Asserted in `vm-serial.log`:

1. `ls` lists BOTH `USER.BIN` and `COUNTER.BIN`; both execs load
   (`exec: loaded COUNTER.BIN size=` and `exec: loaded USER.BIN size=`).
2. The counter's `counter: alive` markers appear across the WHOLE log:
   the first marker is before the first USER.BIN exit line and markers
   are STILL landing after the last one (count >= 3); the counter never
   exits — no `procs COUNTER.BIN exited` line anywhere.
3. A `procs` snapshot shows COUNTER.BIN `state=running` AND USER.BIN
   `state=running` (distinct task ids + stack VAs).
4. USER.BIN's lifecycle: `tasks user-exec exited status=43`,
   `procs USER.BIN exited status=43`, `tasks user-exec reaped` all
   present; a USER.BIN process row leaves `running` (`state=exited
   task=reaped`).
5. The re-exec lands: `exec: loaded USER.BIN size=` appears TWICE (phase
   1 + the phase-2 re-exec into the freed slot).
6. The third exec (phase 2, while counter + user are both live) reports
   `exec: no free scheduler pool slot` (pool_full) at least once.
7. `pages: armed=1 total=` in BOTH phases; the phase-2 `free=` is >= the
   phase-1 `free=` (the recycled USER.BIN's 5 pages returned; the re-exec
   re-allocated 5 — a leak would make the late count lower).
8. The counter is STILL `state=running` at the FINAL procs read; the
   shell stays responsive (`echo rx-long-lived-ok`); no `[EXC] parking:`.

The runner runs WITHOUT `--script-expect` (the 1 s tick + the reap-then-
re-exec handoff need the full window; the runner exits 0 on timeout when
no expect is configured — the assertions above are the gate). Evidence
saved under `artifacts/live-long-lived-*`.

## Definition of done

Stage A (this landing): `user/src/counter.zig` + the build/image pipeline
embed COUNTER.BIN (build + image + inspect all green, and `make-image.sh`
asserts the embed); host tests pin the counter's marker shape, exec-by-
name of both programs, and the pool-gate-with-one-spare + free-count
recovery behavior; class A green (fmt, unit tests, transcript
byte-identical, build/image/inspect, swift build, context, coordination
×2, mmu-debt).

Stage B: `tools/verify-live-long-lived.sh` with the two-phase script
above; registered in gate-inventory + `just verify-vz`; PASS on VZ with
the saved serial evidence; shared-seam regressions green
(exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/uaccess/
userspace/entropy).

Stage C: docs reconciliation (march-m4 row 3b, roadmap bullet, status,
README, gate-inventory), log append, claim flip, PR (template filled in,
real observed evidence only).

## Do not

- Touch the syscall ABI (ADR 0007) or the scheduler switching core (the
  counter uses only the frozen slots 1 + 2; the frame/ELR/SPSR/TTBR0
  switch is untouched).
- Grow the pool or carve-out to fit the demo — document the one-spare
  budget instead; the capacity gate is the deliverable.
- Add libc/POSIX/heap allocation anywhere.
- Hand-edit generated indexes (`refresh-indexes.sh` only).
- Claim hardware behavior without a saved VZ log (`artifacts/`).

## Process

1. Claim first (done): claim 4613 in
   `docs/claims/4613-long-lived-process.md`, log in
   `docs/logs/agent-buffy-m4-long-lived-process.md`, `refresh-indexes.sh`.
2. Write this plan (done), then implement: Stage A — the second program +
   build/image pipeline + host tests (class A green); Stage B — the
   two-phase runner + live gate + regressions (class B on VZ); Stage C —
   docs reconciliation, claim flip, PR.
3. Class A: `zig fmt --check`, unit tests, transcript, build/image/inspect,
   swift build, context, coordination ×2, mmu-debt.
4. Class B: `tools/verify-live-long-lived.sh` + shared-seam regressions.
   Evidence under `artifacts/live-long-lived-*`.
5. Reconcile docs, append the log, flip the claim to ✅, refresh indexes,
   open the PR.
