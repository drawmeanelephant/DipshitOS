# Log — `agent/buffy/m19-lane-a-shell`

### 2026-08-22 — claim 7033

Claimed Lane A (M19, issues #290–#305). Working in the main checkout on
this branch because the file tools cannot reach gitignored worktree paths
(`.freebuff/` returns BLOCKED to read/edit tools); the isolation still
holds — the other lanes work in their own worktrees on their own
branches. Started with P1 (pipe syscalls, slots 56/57).

## 2026-08-22 — claim 7033: P1 pipes done (issue #290)

P1 (pipe syscalls, slots 56/57) landed and passed on VZ.

- New `kernel/src/pipe.zig`: 4 KiB BSS buffer + `write`/read APIs + two
  console adapters (`sink_console` for the left command's stdout,
  `source_console` for the right command's stdin), vtables built at
  runtime (ADR 0005).
- `syscall.zig`: slots 56 `sys_pipe_read` / 57 `sys_pipe_write` via
  uaccess (no staging — copy out of the unread region / into the append
  region); ENOSPC when full, EFAULT for bad buffers, EINVAL for
  over-capacity. `implemented_count` 56 → 58.
- `shell.zig`: `pipe_split` (first `|` outside quotes; `multiple` refusal
  for chaining), `run_pipe` (sequential: left with sink console, right
  with source console), and the `type` builtin. `monitor.zig` registers
  `type`; `registry_count` 53 → 54.
- Host tests: 3 pipe + 6 shell pipe + 1 syscall pipe slot test.
  558/558 shell, 370/370 syscall, all monitor modules, build + image,
  transcript byte-identical, coordination — green.
- Class B: `verify-live-pipe.sh` PASS 1/1 on VZ — the serial log's
  exact-line `pipe-left-marker` (line 45) is the honest pipe proof (the
  typed line is `echo pipe-left-marker | type`, not an exact match), the
  `ls | type` listing travels the pipe (lines 49–51), and chaining is
  refused (line 88). Evidence `artifacts/live-pipe-*`.
- Doc note: the transcript fixture is mixed CRLF/LF and the emitted
  transcript must match byte-for-byte; a str_replace that normalized the
  fixture's line endings broke the gate — fixed by copying the emitted
  transcript over the fixture (git diff shows only the one `type` line).
