# Log — fix verify-live-args console fresh-line split

Branch: `agent/buffy/fix-args-console-split` · Worktree: `../virelaios-buffy`
Claim: [5251](../claims/5251-fix-args-console-split.md)

### 2026-09-01 — root cause pinned, fix implemented
The args gate has been red on main since 2026-08-31: claim 1714
(`bba817c`, the strace fresh-line fix) made `process_stdout` prepend `\n`
whenever the serial cursor is mid-line, and USER.BIN composes each argv
line from three separate sys_write calls. Writes 2 and 3 each see the
cursor mid-line (their own prefix left it there) and get a prepended
newline — the serial shows `user: arg=` + `alpha` on separate lines and
the gate's `user: arg=alpha` substring needles miss. Observed byte-level:
`virelai> \nuser: arg=\nalpha\n\nuser: hello from the ESP\n…` — exactly
the prepend-per-syscall signature.

Fix (kernel/src/main.zig only): new `stdout_owns_open_line` flag —
cleared by any `\n`/`\r` in `uart_putc` and by any non-newline-terminated
write from `uart_puts` (the shell's prompt owns the open line), set by
`process_stdout` after its own write. The claim-1714 prepend now fires
only when FOREIGN output left the cursor mid-line, so a program composing
one line across several syscalls stays contiguous. This restores the
pre-M22 behavior for the argv preamble (contiguous per program — the
observed scheduler never preempts between the back-to-back syscalls) while
keeping the strace marker on its own line (first foreign write still
prepends).

Verification pending: `verify-live-args` re-green on VZ + `verify-live-
strace` regression PASS (the claim-1714 gate).

### 2026-09-01 — live verification + landing notes
- **verify-live-args: PASS 1/1 on real VZ** — the argv lines are
  contiguous again (`user: arg=alpha` / `beta` / `gamma` / `delta` on
  their own lines; the first write fresh-lines off the prompt, writes 2+3
  continue the program's open line). The gate had been red since claim
  1714 (2026-08-31) landed the un-gated prepend.
- **verify-live-strace: PASS 1/1** — the claim-1714 fresh-line behavior is
  preserved (the first foreign write after the prompt still prepends; the
  `elf: hello from HELLO.ELF` exact-line needle holds).
- **verify-live-concurrent: PASS 1/1** (sibling USER.BIN gate).
- **Two more stale gates found and re-greened (SAME M25 root cause, not
  the console change):** `verify-live-long-lived` and `verify-live-kill`
  asserted the per-user page count as 9 ("1 text + 4 user-stack + 4
  EL1-stack") from the pre-M25 16 KiB task stacks; `scheduler
  .task_stack_size` doubled to 32 KiB on 2026-08-25 (claim 0434/2539), so
  a user costs 17 pages (1 + 8 + 8). The gates' exact-count needles were
  stale (live diff observed = 17 EXACTLY — the accounting is correct; a
  leak would exceed it). Updated both gates' constants + doc comments to
  17 and re-ran: **long-lived PASS 1/1, kill PASS 1/1** on VZ.
- Class A: fmt, build, verify-unit-tests (24 modules), coordination all
  green. The fix is `kernel/src/main.zig` only (a BSS bool + the
  `process_stdout`/`uart_puts` gates) — no wire, no BSS growth beyond 1
  byte, no behavior change for default single-write program lines.
