# Claim: fix verify-live-args — console fresh-line prepend splits multi-write program lines

- **Owner:** buffy (`agent/buffy/fix-args-console-split`)
- **Prompt / plan:** user-reported pre-existing red gate: `verify-live-args`
  fails 0/1 on clean main (stash-proven during HF4, issue #738 work).
  `process_stdout` (claim 1714, bba817c, 2026-08-31 — the strace fresh-line
  fix) prepends a `\n` whenever the serial cursor is mid-line, and USER.BIN
  composes each argv line from THREE sys_write calls (prefix / arg /
  newline), so writes 2+ each get a prepended newline and the line splits
  (`user: arg=` + `alpha` on separate lines) — the `user: arg=alpha`
  needles miss.
- **Scope:** in `kernel/src/main.zig` only — track whether the current
  partial serial line is owned by process stdout (`stdout_owns_open_line`,
  cleared on any newline and on any non-stdout partial write from
  `uart_puts`), and gate `process_stdout`'s fresh-line prepend on
  `!stdout_owns_open_line`. Restores M4-era contiguity for a program's own
  multi-write lines while preserving the claim-1714 strace behavior (the
  FIRST foreign write after the shell's prompt still fresh-lines).
- **Touches:** `kernel/src/main.zig`, `docs/claims/5251-fix-args-console-split.md`,
  `docs/logs/agent-buffy-fix-args-console-split.md`
- **Depends on:** — (red gate is pre-existing; no milestone card)
- **Heartbeat:** 2026-09-01
- **Status:** ✅ done
