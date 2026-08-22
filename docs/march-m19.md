# Milestone nineteen march — shell as programming environment (living tracker)

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts. This file holds M19's per-card detail and agent split, following
> the established march-file pattern.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

M18 gives us a comfortable terminal (scrollback, selection, search, history,
colors). But the shell is still a one-command-at-a-time echo chamber. M19
turns it into a *tool* — pipes so commands can talk to each other,
redirection so output goes to files, environment variables so state persists
within a session, functions so users can build reusable commands, and scripts
so complex workflows can be saved and replayed.

**Two new syscall slots** for pipes (56/57). Everything else is pure userland.

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| P1 | **Pipes.** `cmd1 \| cmd2` — stdout of cmd1 feeds stdin of cmd2. Bounded: one pipe at a time, max 4 KiB buffer. `echo hello \| type` prints "hello". `ls \| type` lists directory contents through the pipe. The pipe is set up before cmd1 runs, cmd1 writes to it, cmd2 reads from it after cmd1 exits. | ⬜ | — | Kernel: slot 56 `sys_pipe_read(buf, max)`, slot 57 `sys_pipe_write(buf, len)`. BSS pipe buffer (4 KiB). The shell parses `\|`, sets up the pipe, forks both commands' I/O. Single-pipe only (no chaining `a \| b \| c`). |
| P2 | **Redirection.** `cmd > file` writes stdout to a file (create or overwrite). `cmd < file` reads stdin from a file. `cmd >> file` appends stdout to a file. Reuses existing file syscalls (slots 23–27). No new ABI. | ⬜ | — | Pure `shell.zig` argument parsing. Before exec, the shell opens the target file and redirects the child's stdout/stdin file descriptors. Uses existing `sys_file_open`/`sys_file_write`/`sys_file_read`. |
| P3 | **Environment variables.** `set VAR=val` defines a variable. `$VAR` expansion in any command. Bounded: 16 variables × 64 characters. `unset VAR` removes. `env` shows all. Persisted to FAT (survives reboot). | ⬜ | — | `shell.zig` BSS array (16 × 64 = 1,024 bytes). FAT write on `set`/`unset`. Boot restore from FAT. `$` expansion in command-line parsing before exec. |
| P4 | **Shell functions.** `fn name() { cmd1; cmd2 }` — user-defined multi-command sequences. `name` executes them. Bounded: 8 functions × 4 commands each. `fn -l` lists defined functions. `fn -d name` deletes. | ⬜ | — | `shell.zig` BSS table (8 × (32 name + 4 × 64 command) = ~2,304 bytes). Functions are stored as parsed command strings, executed sequentially. No return values, no arguments. |
| P5 | **Script mode.** `sh script.BIN` — reads a file of shell commands from FAT and executes them line-by-line. Bounded: 64 lines max. Each line is a full shell command (supports pipes, redirection, env vars). `exit` stops early. | ⬜ | — | `shell.zig` script state (line counter, file handle). Reads from FAT via existing file syscalls. Feeds each line through the normal shell parser. No loops, no conditionals — straight-line execution only. |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Kernel pipe** | `kernel/src/syscall.zig` (slots 56/57), `kernel/src/shell.zig` (pipe setup), `kernel/src/pipe.zig` (new file, BSS buffer + read/write). | M18 done. |
| **B — Shell features** | `kernel/src/shell.zig` for P2 (redirection), P3 (env vars), P4 (functions), P5 (scripts). Sequential: P2 → P3 → P4 → P5. | P1 (pipe lands first, shell.zig changes merge). |

## Notes

1. **ABI budget:** 2 new syscall slots (56/57) for pipe read/write.
   Cumulative: 58/64 after M19.
2. **BSS budget:** Pipe buffer 4 KiB + env array 1 KiB + function table
   ~2.3 KiB + script state ~256 bytes. Total M19 BSS delta: ~7.6 KiB.
3. **Gate shape:** P1: `verify-live-pipe.sh` — `echo hello | type` round-trip.
   P2: `verify-live-redirect.sh` — write to file, read back.
   P3: `verify-live-env.sh` — set/expand/unset/persist.
   P4: `verify-live-function.sh` — define/call/list/delete.
   P5: `verify-live-script.sh` — script execution with pipe + redirect.
4. **Pipe semantics:** The pipe buffer is filled by cmd1 until it exits or
   the buffer is full, then cmd2 reads from it. This is a simplified model
   — no streaming between concurrent processes. Both commands run
   sequentially (cmd1 completes, then cmd2 runs with the buffered output).
   This matches the bounded, no-heap philosophy.
5. **Scope exclusions:** No command substitution (`cmd $(cmd2)`). No
   conditionals (`if/else`). No loops (`for/while`). No subshells. These
   are programming-language features, not shell features.
