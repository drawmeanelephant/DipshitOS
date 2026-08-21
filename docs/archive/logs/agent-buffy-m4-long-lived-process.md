# Log — milestone-four follow-on 2: a long-lived process among live peers

- **Branch:** `agent/buffy/m4-long-lived-process`
- **Claim:** [`docs/claims/4613-long-lived-process.md`](../claims/4613-long-lived-process.md)
- **Prompt / plan:** [`docs/m4-long-lived-process-prompt.md`](../m4-long-lived-process-prompt.md)
- **Started:** 2026-08-10

## Progress

- **Claimed** (2026-08-10): claimed the milestone-four follow-on 2 card (a
  long-lived process among live peers — distinct programs) on
  `agent/buffy/m4-long-lived-process` with claim 4613 (deterministic ID
  from branch+slug), branched off `agent/buffy/m4-concurrent-processes`
  (claim 0826 / PR #73 — per the card, to be rebased onto `origin/main`
  once PR #73 merges). Written plan first
  (`docs/m4-long-lived-process-prompt.md`).

- **Implemented — Stage A (the second program + the reap page-return)**
  (2026-08-10): `user/src/counter.zig` — the never-exiting COUNTER.BIN
  (naked asm, frozen sys_write + sys_yield only, NO sys_exit; a `pub
  const marker` pins the exact `counter: alive\n` bytes and the sys_write
  length in host tests); `build.zig` adds the `counter` executable
  (elf2bin → COUNTER.BIN, installed, passed to both `image` and
  `bad-handoff`), `make-image.sh` takes a fifth optional arg + its
  self-verify now asserts KERNEL/USER/COUNTER in the listing, and
  `image/mkfat32.py` embeds the third volume file (`COUNTER BIN` root
  entry + cluster chain). Kernel change: the missing half of claim 0826's
  "freed at reap/recycle" contract — `process.on_task_exit` keeps the
  executor slot on the exited process, new
  `process.release_pages_on_reap(task_id)` frees its owned pages (text/
  user-stack/EL1-stack) at the same scheduler reap that frees the slot
  (the exited descriptor + status stay in `procs`, `task=reaped`),
  `scheduler.reap` calls it, and `cmd_procs` prints `reaped` for exited
  rows regardless of the kept binding. Host tests: counter marker-shape
  (2), process reap-page-return (34 total incl. the new one), exec
  COUNTER.BIN-by-name with both programs live (124 total incl. two new:
  exec-by-name + permanent-occupant recycle — one spare slot → third exec
  `pool_full` with the free count unchanged → exit + reap → +5 page
  recovery → re-exec lands → `pool_full` again, leak-free).

- **Verification — Stage A** (2026-08-10): class A all green —
  `zig fmt --check` clean; `verify-unit-tests.sh` (every present module
  passed; exec 124/124, process 34/34, scheduler 82/82, monitor 182/182);
  `zig build test-console` (206/206 + transcript byte-identical);
  `zig build` (COUNTER.BIN 83 bytes, marker verified in the blob),
  `zig build image` (embed + self-verify assert COUNTER.BIN),
  `zig build inspect`; `swift build`; `zig build context`;
  `verify-coordination.sh` (indexes in sync); `test-coordination.sh`
  (15/15); `verify-mmu-debt.sh` PASS.

- **Implemented — Stage B (the live long-lived gate)** (2026-08-10): the
  runner gains a SECOND scripted phase — `--script2 <file>` +
  `--script2-after <text>` (the primary `--script` is forwarded in ONE
  burst, claim 6684, so the re-exec that must land AFTER the first
  USER.BIN exits + is reaped (~10 s with the 1 s tick) cannot be in the
  same burst; `forwardScriptOnce` now serves both phases). New class-B
  gate `tools/verify-live-long-lived.sh`: phase 1 `ls | exec COUNTER.BIN
  | exec USER.BIN | procs | pages | echo rx-long-lived-phase1` (after
  the boot payload's exit), phase 2 `exec USER.BIN | procs | exec
  USER.BIN | pages | echo rx-long-lived-ok` (forwarded after the first
  `tasks user-exec reaped`). Registered in `docs/gate-inventory.md`
  (`live-long-lived`, B/gate, + the verify-vz aggregate row),
  `justfile verify-vz`, and README.

- **Verification — Stage B** (2026-08-10): `bash tools/verify-live-long-lived.sh`
  **PASS 1/1 on VZ** — evidence `artifacts/live-long-lived-serial-01.log`:
  `exec: loaded COUNTER.BIN size=0x3b stack=0x…26550000` and `exec:
  loaded USER.BIN size=0xea stack=0x…6d080000`; the phase-1 `procs`
  shows `id=1 name=COUNTER.BIN state=running task=2` + `id=2
  name=USER.BIN state=running task=3` (two live processes, DISTINCT
  programs, distinct tasks); 21 `counter: alive` markers span the whole
  log (first at line 77 before the first USER exit at line 89, last at
  line 159 after the last USER exit line 120 — the counter outlived BOTH
  USER.BIN runs and never exits); phase 2 re-exec landed in the freed
  slot (`exec: loaded USER.BIN … stack=0x…6f620000`, task=3 reused,
  `procs: id=3 name=USER.BIN state=running` next to `id=2 name=USER.BIN
  state=exited task=reaped exit=43`); `exec: no free scheduler pool
  slot` (pool_full with the counter + re-exec'd program both live);
  `pages: free=0xfd54` in BOTH phases (the recycled USER.BIN's 5 pages
  returned, the re-exec re-allocated 5 — leak-free); counter still
  `state=running` at the final procs; shell responsive; no exception
  park. Shared-seam live regressions all PASS 1/1 against the second
  program: exec, procs, concurrent, tasks, lifecycle, addrspaces, sleep,
  svc, uaccess, userspace, entropy.

- **Implemented — Stage C (docs reconciliation + claim flip)** (2026-08-10):
  `docs/march-m4.md` gains row 3b (long-lived process among live peers,
  ✅ done, claim 4613 + prompt link, stage-by-stage notes incl. the
  one-burst/`--script2` phase design and the free-count-recovery
  evidence) and the best-agent split row covers card 3b; `docs/roadmap.md`
  gains a "A long-lived process among live peers is DONE" bullet next to
  the concurrent-processes bullet; `docs/status.md`'s milestone-four row
  + tracker mention updated (cards 1 + 2 + 3 + 3a + 3b); README +
  `docs/gate-inventory.md` (`live-long-lived` gate) updated during Stage
  B. Claim 4613 flipped ✅ done (Stage A + B + C complete; PR pending).
  Indexes refreshed; coordination + test-coordination checks green.

- **PR** (2026-08-10): branch pushed, PR opened
  ([#75](https://github.com/drawmeanelephant/DipshitOS/pull/75), commit
  `3bac6b9`) — body per the repo template (summary + AGENTS compliance
  checklist + observed class A/B evidence + commands).
