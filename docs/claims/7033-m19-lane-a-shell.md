# Claim: M19 Lane A — shell as programming environment (pipes → scripting)

- **Owner:** buffy (`agent/buffy/m19-lane-a-shell`)
- **Prompt / plan:** "you can work on lane a?" — the user is dispatching
  parallel agents per `docs/agent-concurrency-plan.md` (5-lane plan,
  PR #483). Lane A is the shell backbone: M19 (issues #290–#305,
  P1–P16), owning `kernel/src/shell.zig` + new `kernel/src/pipe.zig`.
- **Scope:** M19 P1–P16 sequentially, starting with P1 (pipe syscalls,
  slots 56/57) then P2 redirection, P3 env vars, P4 functions, P5
  scripts, P6 globbing, P7 jobs, P8 function args, P9 command
  substitution, P10 arithmetic, P11 conditionals, P12 loops, P13
  here-docs, P14 pipe-to/from-file, P15 `set -x` tracing, P16 temp
  files. Each card gets a live gate + host tests + evidence.
- **Depends on:** M18 done ✅ (merged to main as `4d11713`, PR #485).
  Lane A is the critical path — Lane C (M20 text) and Lane E (M21
  compositor) depend on it.
- **Status:** 🔄 in progress — P1 (pipes) ✅ done 2026-08-22; P2 (redirection) ✅ done 2026-08-23; P3 (env vars) ✅ done 2026-08-23

## Notes

Why: M19 turns the one-command-at-a-time shell into a tool — pipes so
commands talk to each other, redirection to files, env vars for session
state, functions and scripts for reuse. Two new syscall slots (56/57)
for pipe read/write; everything else is pure `shell.zig`.

P1 detail (issue #290): new `kernel/src/pipe.zig` with a 4 KiB BSS
buffer; `sys_pipe_read` (slot 56) copies pipe→user via uaccess,
`sys_pipe_write` (slot 57) copies user→pipe, ENOSPC when full. The
shell parses `|`, splits the line, runs cmd1 to completion (stdout →
pipe), then cmd2 (stdin ← pipe). Sequential model — no concurrent
execution, no heap. `echo hello | type` must print "hello".

Gate shape per the march file: `verify-live-pipe.sh` (P1),
`verify-live-redirect.sh` (P2), `verify-live-env.sh` (P3),
`verify-live-function.sh` (P4), `verify-live-script.sh` (P5), plus new
gates for P6–P16 as they land.

Verification: host unit tests per card (the `verify-unit-tests.sh`
pattern), class-B live gates on real VZ with evidence saved under
`artifacts/` and recorded here. The march file `docs/march-m19.md`
currently lists only P1–P5 — it lags the 16-issue plan and will be
updated as cards land.

## P1 — pipes (issue #290) — done 2026-08-22

- `kernel/src/pipe.zig` (new): 4 KiB BSS buffer, `write`/`available`/
  `capacity_left`/`append_slice`/`advance_write`/`unread_slice`/
  `advance_read`, plus two console adapters — `sink_console()` (writes
  land in the pipe; the LEFT command's stdout) and `source_console(inner)`
  (reads pull from the pipe, writes pass through to `inner`; the RIGHT
  command's stdin). Vtables built at runtime into BSS (ADR 0005).
- `kernel/src/syscall.zig`: slots 56 `sys_pipe_read(buf, max)` / 57
  `sys_pipe_write(buf, len)` through uaccess (copy-out from the unread
  region, copy-in into the append region — no staging); ENOSPC when full,
  EFAULT for bad buffers, EINVAL for over-capacity writes.
  `implemented_count` 56 → 58.
- `kernel/src/shell.zig`: `pipe_split` (first `|` outside double quotes,
  `multiple` refusal for chaining), `run_pipe` (reset pipe, left with
  sink console, right with source console, restore), and the `type`
  builtin (echo stdin to stdout). `monitor.zig` registers `type`
  (help/usage/completion) and `registry_count` 53 → 54.

### Verification

- Host (class A): pipe round-trip + overflow-drop + adapter tests (3);
  shell pipe tests (6: split rules, `echo hello | type` exact-once,
  `ls | type`, chaining refusal, bare `type`, right-command-ignores-
  stdin); syscall pipe slot test (dispatch, EFAULT/ENOSPC/EINVAL,
  consume-on-read). 558/558 shell, 370/370 syscall, all monitor modules,
  build + image, transcript byte-identical, coordination — green.
- Class B: `tools/verify-live-pipe.sh` — `echo pipe-left-marker | type`
  (exact-line pipe proof), `ls | type` (listing through the pipe),
  `echo a | echo b | echo c` (chaining refusal), `echo pipe-ok`
  (completion). **PASS 1/1** on real VZ; evidence
  `artifacts/live-pipe-*` (gate/report/serial logs).

## P2 — redirection (issue #291) — done 2026-08-23

- `kernel/src/redirect.zig` (new): 4 KiB BSS capture buffer with
  `reset_capture`/`captured`/`capture_write`, a `capture_console()`
  adapter (writes land in the buffer; the command's stdout during `>`
  / `>>`), a `feed_console(inner, data)` adapter (reads pull from
  pre-loaded `data`, writes pass through to `inner`; the command's
  stdin during `<`), and two file helpers — `write_captured_to_file`
  (writes buffer to ESP or FAT path) and `read_file_into` (reads a file
  into a caller buffer from ESP or FAT). Vtables built at runtime into
  BSS (ADR 0005).
- `kernel/src/shell.zig`: `redirect_split` (finds `>`, `>>`, or `<`
  outside double quotes, returns the operator kind + split left/right),
  `trim_start`/`trim_end` helpers (inline since Zig 0.16 removed
  `std.mem.trimLeft`/`trimRight`), `run_redirect_out` (captures command
  stdout → writes to file; `>>` appends with newline separator),
  `run_redirect_in` (pre-loads file → feeds as command stdin).
  Redirect handled in `shell_handle_expanded` before the pipe split.
  No new ABI — pure `shell.zig` argument parsing, reuses existing file
  syscalls (ESP/FAT).
- `tools/verify-unit-tests.sh`: added `redirect` to MODULES list.

### Verification

- Host (class A): 6 redirect module tests (capture, overflow, reset,
  feed), 6 shell redirect tests (split rules for >/>>/< inside/outside
  quotes, whitespace trimming, bad-input null). 628/628 shell tests
  pass (`zig test kernel/src/shell.zig`). `verify-unit-tests.sh` all
  modules green (22 redirect, all others). `zig build test-console`
  transcript byte-identical. `zig fmt --check` clean. `zig build` +
  `zig build image` green.
- Class B: live gate `verify-live-redirect.sh` pending.

## P3 — environment variables (issue #292) — done 2026-08-23

- `kernel/src/shell.zig`: `env_unset` (removes a variable, shifts table),
  `save_env` (persists env table to ENV.TXT via ESP window), `load_env`
  (restores from ESP window on boot — no disk_ready gate needed since
  esp.lookup works without a FAT mount). New builtins: `set` (like
  `export`), `unset`, `env` (lists all). `load_env` wired into
  `boot_and_park` after `load_history`.
- Existing M18 T12 infrastructure reused: `env_set`, `env_get`,
  `env_expand`, `EnvEntry` table (16 × 64 bytes).
- No new ABI — pure userland `shell.zig`.

### Verification

- Host (class A): 6 new tests (set/unset/env builtins, direct API,
  persistence round-trip, multi-$VAR expansion, unmatched-$VAR, bounds).
  634/634 shell tests pass. `verify-unit-tests.sh` all modules green.
  `zig build test-console` transcript byte-identical. `zig fmt --check`
  clean. `zig build` + `zig build image` green.
- Class B: live gate `verify-live-env.sh` pending.
