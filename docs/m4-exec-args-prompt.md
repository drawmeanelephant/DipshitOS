# Milestone-four follow-on 3, card 3e — exec context block: arguments to EL0

Planning-first prompt doc for DipshitOS, split from the master
`docs/m4-args-ipc-scale-prompt.md` (cards 3e + 3f + 3g). This card runs
AFTER claim 1014 / PR #77 (card 3d); the syscall ABI (ADR 0007) stays
frozen — card 3e is an ENTRY-CONTRACT extension, not a syscall change. No
libc/POSIX/heap anywhere. The full 12-gate shared-seam live sweep runs
after this card.

- **Branch:** `agent/buffy/m4-exec-args` (claim 4636 from branch + slug
  `exec-args` via `bash tools/status/claim-id.sh`)
- **Why:** a program's identity today is its image only — the same binary
  cannot distinguish itself per exec, and EL0 has no way to receive
  per-exec data. Args make the "distinct programs" proof stronger (the
  SAME image, distinguished by its argv) and open per-invocation behavior.

## Scope

1. `exec <file> [arg...]` — the tokenizer already splits (`shell.zig`:
   `tokenize` → `monitor.exec(mon, argv[0..count])`; the cap is 17 tokens
   = command + 16 args). `cmd_exec`/`exec_file` today ignore everything
   past the filename; card 3e packs a bounded argv block (8 args × 32 B)
   into the process's OWN text page, right after the loaded content — the
   text leaf is already EL0 read-only (W^X), so the block is a READ-ONLY
   leaf with ZERO extra pages (the per-program 5-page budget and every
   existing exact-count gate stay untouched).
2. The text aperture extends over the block, so uaccess reads it
   (copy_in ok) and writes fault (copy_out → EFAULT) — the frozen
   W^X/uaccess discipline, host-tested both directions.
3. Entry-contract extension (documented in the claim, NOT a syscall
   change): `_start` receives `argc` in x0 and the block VA in x1. Today
   `build_initial_frame` zeroes the whole claim-9746 frame — x0/x1 are 0
   at `_start`. The exec path (`register_exec_user`, the same pattern as
   `register_user` writing the timer-witness VA into slot x9) writes
   argc/argv-VA into the x0/x1 frame slots. The boot static payload
   (`register_user`) is untouched.
4. USER.BIN prints each arg via sys_write (`user: arg=<n>` per arg, before
   its existing markers); truncation host-tested (per-arg 31-byte cap;
   more than 8 args → honest refusal `too_many_args`, never silent loss).
5. Host tests: argv packing shape + per-arg truncation + too-many-args
   refusal; the args range present / read-only (uaccess both directions) /
   absent from the EL0 write aperture; per-exec distinct argv; frame x0/x1
   at spawn.
6. Live gate `tools/verify-live-args.sh`: `exec USER.BIN alpha` and
   `exec USER.BIN beta` back to back — the SAME binary prints
   `user: arg=alpha` / `user: arg=beta` markers, both programs live (two
   running rows, distinct task ids + stack VAs), both complete (status 43,
   exact FIFO counts), a third exec is `pool_full`.

## Do not

- Add syscalls or touch ADR 0007's syscall numbers; grow the pool (two
  live programs = 5/5, no spare — document it); add a page per program
  (the 5-page budget and the kill/long-lived exact-count assertions stay);
  break the frozen W^X / uaccess discipline; touch the scheduler switching
  core or the lifecycle states.

## Shared process

1. Claim first: deterministic claim doc + branch log +
   `bash tools/status/refresh-indexes.sh`; planning-first prompt doc.
2. Class A first: `zig fmt --check`, unit tests, transcript
   byte-identical (`zig build test-console` + `verify-transcript.sh`),
   build/image/inspect, swift build, context, coordination ×2, mmu-debt.
3. Class B on VZ: the new live gate + the FULL 12-gate shared-seam live
   sweep, evidence saved under `artifacts/`.
4. Docs reconciliation: march-m4 row + lane, roadmap, status,
   gate-inventory, README, claim flip, log append, PR per the repo
   template (real observed evidence only).
