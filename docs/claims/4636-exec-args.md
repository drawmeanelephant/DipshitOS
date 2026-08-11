# Claim: exec context block — arguments to EL0 (card 3e)

- **Owner:** Buffy (`agent/buffy/m4-exec-args`)
- **Prompt / plan:** milestone-four follow-on 3 card 3e (after claim 1014 /
  PR #77). Written plan first:
  [`docs/m4-exec-args-prompt.md`](../m4-exec-args-prompt.md).
- **Scope:** (1) `exec <file> [arg...]` packs a bounded argv block (8 args ×
  32 B) into the process's OWN text page, right after the loaded content —
  the text leaf is already EL0 read-only (W^X, AP=read-only), so the block
  is a read-only leaf with ZERO extra pages (the per-program 5-page budget
  and every existing exact-count gate stay untouched); (2) the text aperture
  extends over the block, so uaccess reads it (copy_in ok) and writes fault
  (copy_out → EFAULT — host-tested both directions); (3) entry-contract
  extension (NOT a syscall change, ADR 0007 frozen): `_start` receives
  `argc` in x0 and the block VA in x1 — `register_exec_user` writes them
  into the claim-9746 frame's x0/x1 slots (the seam where
  `build_initial_frame` zeroes the frame); (4) USER.BIN prints each arg via
  sys_write (`user: arg=<n>` per arg, plus its existing markers); (5) host
  tests: argv packing shape, per-arg 31-byte truncation, >8-arg refusal
  (`too_many_args`), block-inside-text-leaf read-only both directions,
  per-exec distinct argv; (6) new class-B gate `tools/verify-live-args.sh`:
  `exec USER.BIN alpha` + `exec USER.BIN beta` — the SAME binary prints
  `user: arg=alpha` / `user: arg=beta`, both programs live (two running
  rows), plus the full 12-gate shared-seam live sweep. Do NOT touch
  syscalls/ADR 0007 or grow the pool (two live programs = 5/5, no spare).
  No libc/POSIX/heap; host tests first; class B on VZ.
- **Depends on:** claim 1014 / PR #77 (card 3d — this branch stacks on the
  3d tree so the pool and report machinery are current). Independent of
  cards 3c/3d's mechanics.
- **Status:** ✅ done 2026-08-10 (PR #78, staged after PR #77 card 3d)

## Notes

**Why it matters:** a program's identity today is its image only — the same
binary cannot distinguish itself per exec, and EL0 has no way to receive
per-exec data. Args make the "distinct programs" proof stronger (the SAME
image, distinguished by its argv) and open per-invocation behavior.

**Key design facts (from the survey):**

- **The tokenizer already splits** (`shell.zig` tokenize →
  `monitor.exec(mon, argv[0..count])`; `max_tokens` = 17 = command + 16
  args), but `cmd_exec` uses only `args[0]` and `exec_file` ignores the
  extras. Card 3e packs a bounded block of 8 args × 32 B = 256 B.
- **The block lives in the process's OWN text page.** The per-program page
  budget is 5 (1 text + 2 user-stack + 2 EL1 exception-stack, claim 0826)
  and the kill/long-lived live gates assert EXACT page recovery (+5,
  free=0xfd54) — so 3e must not add a page. The text leaf is already EL0
  read-only + executable (W^X, `user_leaf` AP=read-only, PXN, UXN=0) and
  page-granular: the whole 4 KiB page is EL0-readable. The block is packed
  at `text_va + align8(content_len)`; the aperture passed to
  `rebuild_user_root`/`register_exec_user` extends over it (content +
  256 ≤ 4096 guard → honest `no_args_room` refusal). Because the block is
  inside the uaccess TEXT region, `copy_in` from it succeeds and `copy_out`
  to it is a permission fault — the frozen W^X/uaccess discipline holds and
  is host-tested both directions.
- **Truncation is documented + host-tested:** per-arg strings are truncated
  at 31 bytes + NUL (32-byte slot); MORE than 8 args is an honest REFUSAL
  (`too_many_args` — never silent loss). The no-args path (`exec USER.BIN`)
  is byte-identical to today: argc=0, argv_va=0, no block, unchanged text
  aperture — so every existing gate keeps its exact assertions.
- **The entry-contract seam:** `build_initial_frame` zeroes the whole
  claim-9746 frame; `register_exec_user` (exec only — the boot static
  payload registers through `register_user`, which stays untouched) writes
  `argc` into slot x0 and the block VA into slot x1 after `spawn` — the
  same pattern as `register_user` writing the timer-witness VA into slot
  x9. Not a syscall: ADR 0007's numbers and x8 convention are untouched.
- **USER.BIN stays backward-compatible:** the arg loop runs only when
  argc > 0, so no-arg execs print exactly the same markers as today (all
  existing marker-count gates stay green). With args it prints
  `user: arg=<n>` per arg BEFORE the existing hello/ping/yield/sleep/exit
  flow, then exits status 43 as usual.

## Verification

- **Class A:** fmt, unit tests (exec: pack shape, per-arg truncation,
  too-many-args refusal, no-room refusal, block read-only via uaccess both
  directions, per-exec distinct argv, frame x0/x1 at spawn), transcript
  byte-identical, build/image/inspect, swift build, context, coordination
  ×2, mmu-debt — all green.
- **Class B — the new gate:** `tools/verify-live-args.sh` PASS 1/1 on VZ —
  `exec USER.BIN alpha` + `exec USER.BIN beta` back to back: two
  `state=running` rows with distinct task ids + stack VAs, and the SAME
  binary prints `user: arg=alpha` AND `user: arg=beta` (distinct markers
  prove which invocation is which), both programs complete (status 43,
  exact FIFO counts), a third exec is `pool_full`. Evidence under
  `artifacts/live-args-*`.
- **Class B — shared-seam regressions:** the full live sweep
  (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/uaccess/
  userspace/entropy/long-lived/kill) all PASS 1/1, plus the new args gate.

## Stage C (2026-08-10)

- Docs reconciled: march-m4 row + Buffy summary, roadmap bullet, status
  paragraph, README follow-on 3 paragraph, gate-inventory (live-args row +
  machine record + verify-vz aggregate). Claim flipped. PR #78 opened.
- **Live-run bugs found and fixed by the gate (both recorded in the serial
  evidence):** (1) a PAYLOAD bug — the prefix write length was 11 for the
  10-char `user: arg=` string, so it swallowed the following `.byte 10`
  and printed `user: arg=` + newline + arg on separate lines (the kernel
  plumbing was correct — the args reached EL0 and were readable); fixed
  to `mov x2, #10`, re-run green. (2) a GATE bug — the first boot's exact-
  line grep (`grep -Fxc`) missed the marker when program A's prefix
  landed on the shell's trailing `dipshit> ` prompt line (the same
  line-merge the concurrent gate's markers tolerate); switched to
  substring match with an exact count of 1, re-run green.
