# Claim: a long-lived process among live peers (distinct programs)

- **Owner:** Buffy (`agent/buffy/m4-long-lived-process`)
- **Prompt / plan:** milestone-four follow-on 2 card (claim 0826 proved TWO
  live processes — but only as two copies of the SAME program, USER.BIN,
  both of which exit after a few ticks). Written plan first:
  [`docs/m4-long-lived-process-prompt.md`](../m4-long-lived-process-prompt.md).
- **Scope:** (1) a SECOND user program in the image (COUNTER.BIN from
  `user/src/counter.zig`, built + embedded by the same build/image
  pipeline, with DISTINCT EL0 markers so the serial log can tell the two
  programs apart); (2) a NEVER-EXITING program — COUNTER.BIN loops forever
  writing a counter marker each quantum (bounded spin, sys_write +
  sys_yield only, no sys_exit) — the strong liveness proof the two-copies
  gate lacks; (3) recycle + reap under a permanent occupant — while
  COUNTER.BIN runs, exec + exit USER.BIN (reaped, pages returned to the
  allocator — free-count recovery asserted), a THIRD exec lands in the
  freed slot, and with the counter still alive a subsequent exec is
  `pool_full` (the capacity gate — `has_free_slot` still works; no page/
  table leaks on the refused path); (4) observable live — a `procs` table
  showing COUNTER.BIN `state=running` across the whole session while
  USER.BIN transitions running → exited → reaped, and a live gate that
  execs the counter, execs + reaps the short program, re-execs, then
  observes `pool_full`; (5) docs/march-m4 reconciliation (row 3b) +
  claim + PR. Syscall ABI (ADR 0007) frozen; no libc/POSIX/heap; host
  tests first; class B on VZ.
- **Depends on:** claim 0826 (per-process roots + allocator-backed
  text/stack/EL1-stack pages, exec gate relaxed to capacity — PR #73, the
  branch this card branches off), claim 3848 (the process registry,
  `procs`), claims 6783/5804/6729/0635, the physical allocator
  (3972/5162), claims 2665/3693 (per-process stack ASLR).
- **Status:** ✅ done — Stage A (the second program + image pipeline + the
  reap page-return) and Stage B (the live long-lived gate + full
  shared-seam sweep) landed 2026-08-10; Stage C (docs reconciliation,
  this flip) complete.
- **PR:** [drawmeanelephant/DipshitOS#75](https://github.com/drawmeanelephant/DipshitOS/pull/75)
  — opened 2026-08-10, commit `3bac6b9` on
  `agent/buffy/m4-long-lived-process`.

## Notes

**Why it matters:** claim 0826 proved the machinery for two live user
address spaces — but both copies ran the SAME program and BOTH exited
after a few ticks. This card proves the machinery against DISTINCT
programs and a PERMANENT occupant: a second DSK1 image (COUNTER.BIN) that
never exits, staying responsive alongside a short-lived program that is
exec'd, reaped, and re-exec'd into its freed slot — with the pool's
capacity gate (`pool_full` when the counter + one other user program leave
no free slot) exercised live. No new syscall: the counter needs only
sys_write + sys_yield (ADR 0007 stays frozen).

**Key design facts (from the survey):**

- **A second DSK1 image costs little.** The image pipeline is already
  parameterized: `build.zig` adds one more freestanding executable
  (`user/src/counter.zig` → elf2bin → `COUNTER.BIN`), `make-image.sh`
  takes a fifth positional arg (optional, like USER.BIN), and
  `image/mkfat32.py` gains a third optional volume file (`COUNTER BIN`
  root entry, its own cluster chain). `exec <file>` already takes any
  FAT 8.3 name (`exec [<file>]` → `esp.lookup` + `fat.read_file`), so no
  monitor or kernel load-path change is needed — `exec COUNTER.BIN` just
  works once the file is embedded.
- **The never-exiting program needs NO new syscall.** The counter loop is
  naked asm under the fixed ABI: sys_write(fd 1, marker, len) →
  bounded nop spin → sys_yield → repeat. No sys_exit, no new slot.
- **Pool budget with a permanent occupant:** shell + idle + worker +
  counter + one user program = 5/5. The boot payload exits + is reaped
  before the script is forwarded (`--script-after "tasks user-el0 exited
  status=7"`), so the counter takes the first free slot; a second exec
  (USER.BIN) takes the last — the counter leaves exactly ONE spare slot;
  a THIRD exec while both are live is `pool_full` (the exec path checks
  `has_free_slot()` FIRST, before allocating pages/tables, so the refused
  path leaks nothing — host-tested with an exact free-count assertion).
- **A gap this card fixed:** claim 0826's docs said an exited process's
  pages are "freed at reap or recycle", but the lifecycle reap only freed
  the TASK slot — the exited process held its allocator pages until the
  registry recycled it, so a re-exec cycle under a permanent occupant
  would leak 5 pages per generation. The fix: `process.on_task_exit` now
  KEEPS the executor slot on the exited process, and the scheduler reap
  calls the new `process.release_pages_on_reap(task_id)` to return the
  text/stack/EL1-stack pages at the same reap that frees the slot — the
  exited descriptor (name, status, stack VA) stays in `procs` for the
  claim-3848 exit record (`task=reaped`).
- **The runner forwards the whole script in one burst** (claim 6684:
  `--script` is written to the serial attachment once after
  `--script-after`), so a scripted re-exec that must land AFTER the first
  USER.BIN exits and is reaped (~10 s with the 1 s tick) cannot be timed
  from a single burst. The live gate therefore uses a new second scripted
  phase in the runner (`--script2` + `--script2-after`): phase 1 drives
  `ls | exec COUNTER.BIN | exec USER.BIN | procs | pages | echo`, and
  phase 2 is forwarded once `tasks user-exec reaped` appears (the first
  USER.BIN's reap) — `exec USER.BIN` (re-exec lands in the freed slot) |
  `procs` | `exec USER.BIN` (pool_full) | `pages` | `echo rx-long-lived-ok`.
  Runner changes are class-A buildable and do not touch the guest.
- **Free-count recovery is observable two ways:** the host test pins the
  EXACT +5 page recovery across exit → reap → re-exec against the fixture
  allocator; the live gate prints `pages` in both phases and asserts the
  late free count is >= the early one (the recycled USER.BIN's 5 pages
  returned; the re-exec re-allocated 5, so the pool is restored — and a
  leak would make the late count lower).

## Verification

- **Class A:** fmt, unit tests (exec gains the counter exec-by-name +
  pool-gate-with-one-spare + free-count recovery tests; user counter
  module marker-shape test; process reap-page-return test), transcript
  byte-identical, build/image/inspect (image listing now asserts
  COUNTER.BIN), swift build, context, coordination ×2, mmu-debt — all
  green.
- **Class B — the live gate:** `tools/verify-live-long-lived.sh` **PASS
  1/1 on VZ** — the two-phase script (phase 1 `ls | exec COUNTER.BIN |
  exec USER.BIN | procs | pages | echo`; phase 2, forwarded by the new
  `--script2`/`--script2-after` runner phase after `tasks user-exec
  reaped`: `exec USER.BIN | procs | exec USER.BIN | pages | echo
  rx-long-lived-ok`). Observed in `artifacts/live-long-lived-serial-01.log`:
  both programs listed + loaded; the counter `state=running task=2`
  across BOTH procs reads with 21 `counter: alive` markers spanning the
  whole log (first before the first USER exit, still landing after the
  last — never exits, no `procs COUNTER.BIN exited`); USER#1 `state=
  exited task=reaped exit=43`; the re-exec LANDED in the freed slot
  (task=3 reused, a fresh ASLR stack VA); `exec: no free scheduler pool
  slot` with the counter + re-exec'd program both live; `pages`
  free=0xfd54 in BOTH phases (5 returned at reap, 5 re-allocated —
  leak-free recycle); the counter still `state=running` at the final
  procs; shell responsive; no `[EXC] parking:`.
- **Class B — shared-seam regressions:** the full live sweep
  (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/uaccess/
  userspace/entropy) all PASS 1/1 against the second-program image.
