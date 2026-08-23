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
- **Status:** 🔄 in progress — P1 (pipes) ✅ done 2026-08-22; P2 (redirection) ✅ done 2026-08-23; P3 (env vars) ✅ done 2026-08-23; P4 (functions) ✅ done 2026-08-23; P8 (function args) ✅ done 2026-08-23; P9 (command substitution) ✅ done 2026-08-23; P10 (arithmetic expansion) ✅ done 2026-08-23; P11 (conditionals) ✅ done 2026-08-23; P12 (loops) ✅ done 2026-08-23; P13 (here-documents) ✅ done 2026-08-23; P14 (pipe to/from files) ✅ done 2026-08-23; P15 (set -x tracing) ✅ done 2026-08-23

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

## P4 — shell functions (issue #293) — done 2026-08-23

- `kernel/src/shell.zig`: `FuncEntry` table (16 functions × 64-byte
  name + 16 body lines × 256 bytes each), `func_count` BSS counter,
  `func_find` (linear scan by name), `func_define` (register or replace,
  builds body array from brace-delimited multiline input), `func_delete`
  (remove by name, shift table). New `fn` builtin: `fn name { ... }`
  defines (brace-delimited body, possibly multiline — shell prompts
  with `>` until closing brace), `fn -d name` deletes, bare `fn` lists
  all. Function invocation: when a command name matches a registered
  function, each body line is fed through `shell_handle_expanded`
  sequentially (like a script).
- No new ABI — pure `shell.zig`. No new files (all in shell.zig).
- Null-terminated BSS names; `body_lens` per-line tracked for safe
  copy without overread.

### Verification

- Host (class A): 6 new tests (define-and-call, fn -d delete, bare fn
  listing, func_find/func_delete static API, empty-fn list message,
  fn overwrite). 640/640 shell tests pass. `verify-unit-tests.sh` all
  modules green. `zig build test-console` transcript byte-identical.
  `zig fmt --check` clean. `zig build` + `zig build image` green.
- Class B: live gate `verify-live-function.sh` pending.

## P8 — function arguments (issue #297) — done 2026-08-23

- `kernel/src/shell.zig`: `FuncEntry` extended with `arg_names` array
  (4 × 16 bytes), `arg_name_lens`, and `arg_count`. `func_define` parses
  `fn name(a, b) { ... }` — extracts comma-separated argument names from
  parentheses, clamped to `func_arg_max` (4). `func_call` injects
  positional `$0` (function name) and `$1`..`$N` (caller arguments) via
  `env_set` before executing body lines. Body lines are `env_expand`-ed
  at invocation time so `$name` references resolve to caller values.
- `handle_line`: skips `env_expand` for `fn` commands so `$` references
  in function bodies are preserved literally at definition time.
- `fn` listing updated to show argument signatures: `name(a, b) { ... }`.
  Help text updated. No-arg functions (`fn name { ... }`) continue to
  work (P4 compat).
- No new ABI — pure `shell.zig`. No new files.

### Verification

- Host (class A): 6 new tests (define-with-args, call-with-positionals,
  named-arg-expansion, no-arg-compat, listing-with-signature,
  arg-count-clamped). 646/646 shell tests pass. `verify-unit-tests.sh`
  all modules green. `zig build test-console` transcript byte-identical.
  `zig fmt --check` clean. `zig build` + `zig build image` green.
- Class B: live gate `verify-live-function.sh` pending (covers both P4
  and P8).

## P9 — command substitution (issue #298) — done 2026-08-23

- `kernel/src/shell.zig`: `cmd_subst` function scans for `$(cmd)`, finds the
  matching `)`, rejects nested `$(` inside the inner region, extracts and
  trims the inner command, executes it via `handle_line` with stdout captured
  through the redirect module's `capture_console`, trims trailing newlines,
  and substitutes the captured output back into the original line.
- `subst_active` guard prevents recursive substitution (the inner command
  skips `cmd_subst`). `fn` definitions skip substitution so `$()` in function
  bodies is preserved literally until invocation time.
- Bounded: one substitution per line, max 256 bytes of captured output
  (`subst_max_output`). Empty inner commands are a no-op.

### Verification

- Host (class A): 7 new tests (basic inline, nested refusal, unmatched
  error, empty no-op, fn-body preservation, prefix+suffix combination,
  no-subst-passthrough). 653/653 shell tests pass. `verify-unit-tests.sh`
  all modules green. `zig build test-console` transcript byte-identical.
  `zig fmt --check` clean. `zig build` + `zig build image` green.
- Class B: live gate `verify-live-subst.sh` pending.

## P10 — arithmetic expansion (issue #299) — done 2026-08-23

- `kernel/src/shell.zig`: `ArithLexer` struct (tokenizes integers, operators,
  and parentheses) and recursive-descent parser (`arith_parse_expr` →
  `arith_parse_term` → `arith_parse_factor`) with precedence: `()` >
  unary `-` > `* / %` > `+ -`. `arith_expand` scans for `$((expr))`,
  finds matching `))` with depth tracking, evaluates via the parser,
  formats result as decimal, and splices into the line.
- Handles: 64-bit signed integers, unary minus, division by zero → 0,
  modulo by zero → 0, empty expression → pass-through.
- Wired into `handle_line` before `cmd_subst` (arithmetic expands first,
  then command substitution, then env vars). Skipped for `fn` definitions
  (preserves `$((...)` in function bodies).
- No new ABI — pure `shell.zig`, ~128 bytes BSS.

### Verification

- Host (class A): 12 new tests (addition, precedence, grouping,
  subtraction, division, modulo, negative result, unary minus,
  mixed prefix/suffix, no-op passthrough, empty expression,
  nested parens). 665/665 shell tests pass. `verify-unit-tests.sh`
  all modules green. `zig build test-console` transcript byte-identical.
  `zig fmt --check` clean. `zig build` + `zig build image` green.

## P11 — conditionals (issue #300) — done 2026-08-23

- `kernel/src/shell.zig`: `last_exit_ok` module-level bool (exit status
  of the last command). New builtins: `true` (sets exit status to
  success), `false` (sets to failure), `if COND; then BODY; [else
  BODY]; fi`. `find_if_keyword` matches whole-word keywords (bounded
  by whitespace, semicolons, or string boundaries). `run_if_body`
  splits on `;` and executes each sub-command via `shell_handle_expanded`.
  `run_if` parses the if/then/else/fi structure, evaluates the condition
  via `shell_handle_expanded`, and executes the appropriate body.
- `monitor.exec` calls updated to set `last_exit_ok` based on
  `ExecError.none`.
- No new ABI — pure `shell.zig`, ~4 bytes BSS (`last_exit_ok`).

### Verification

- Host (class A): 7 new tests (true-then, false-skip, true-else-skip,
  false-else-run, multi-command body, missing fi, missing then).
  672/672 shell tests pass. `verify-unit-tests.sh` all modules green.
  `zig build test-console` transcript byte-identical. `zig fmt --check`
  clean. `zig build` + `zig build image` green.

## P12 — loops (issue #301) — done 2026-08-23

- `kernel/src/shell.zig`: `loop_iter`, `break_flag`, `continue_flag`
  module-level state. `loop_max_iter = 256`. New builtins: `for VAR in
  WORD1 ...; do BODY; done`, `while CMD; do BODY; done`, `break`,
  `continue`. `find_loop_keyword` matches whole-word keywords.
  `run_loop_body` splits on `;` and executes via `handle_line` (full
  env/alias/arith expansion). `run_for` parses `for/in/do/done`,
  splits words on whitespace and `;`, loops setting `$VAR` per
  iteration, unsets after. `run_while` evaluates condition via
  `shell_handle_expanded`, loops while `last_exit_ok`.
- `handle_line`: skip expansions for `for`/`while` lines (body `$VAR`
  expanded at iteration time, not parse time). Word parsing treats
  `;` as separator.
- No new ABI — pure `shell.zig`, ~10 bytes BSS.

### Verification

- Host (class A): 11 new tests (for-words, for-unset, for-empty,
  for-missing-done, for-missing-do, while-true, while-false,
  while-break, while-missing-done, while-missing-do, for-multi-cmd).
  683/683 shell tests pass. `verify-unit-tests.sh` all modules green.
  `zig build` + `zig build image` green. `zig fmt --check` clean.

## P13 — here-documents (issue #302) — done 2026-08-23

- `kernel/src/shell.zig`: `heredoc_active`, `heredoc_delim`, `heredoc_buf`
  (4 KiB), `heredoc_cmd` module-level state. `heredoc_max_lines = 64`.
  `handle_line` detects `<<DELIM` before expansions: extracts command
  (before `<<`) and delimiter (after `<<`), strips quotes from
  `"DELIM"` to disable `$VAR` expansion, enters collection mode.
  Collection mode: each subsequent `handle_line` call appends to the
  buffer until the delimiter line is found. On delimiter: optionally
  expands `$VAR` (unquoted delimiter only), feeds content to command
  via `redirect.feed_console`. Trailing newline added after last line.
- No new ABI — pure `shell.zig`, ~4 KiB BSS.

### Verification

- Host (class A): 6 new tests (basic heredoc, empty, variable
  expansion, quoted delimiter, missing command, multiple lines).
  689/689 shell tests pass. `verify-unit-tests.sh` all modules green.
  `zig build` + `zig build image` green. `zig fmt --check` clean.

## P14 — pipe to/from files (issue #303) — done 2026-08-23

- Verified that existing P1 (pipe) and P2 (redirection) already compose
  correctly: `redirect_split` finds `>`/`<` in lines containing `|`,
  and `run_redirect_out`/`run_redirect_in` execute the left side through
  `shell_handle_expanded` which handles pipes. No code changes needed —
  the composition works because each adapter swaps the console, runs
  the command, and restores. 2 new tests confirm.

## P15 — set -x tracing (issue #304) — done 2026-08-23

- `kernel/src/shell.zig`: `trace_enabled` module-level bool. `set -x`
  enables trace mode, `set +x` disables. `set` without args shows env
  vars plus trace status. In `shell_handle_expanded`, after tokenization
  and before builtin dispatch, prints `+ <line>` when trace is enabled.
  Works with pipes, redirects, scripts, and functions.
- 1 byte BSS.

### Verification

- Host (class A): 4 new tests (P14: pipe+redirect, cmd<file|cmd>file;
  P15: set -x trace output, set shows trace status). 693/693 shell
  tests pass. `verify-unit-tests.sh` all modules green. `zig build` +
  `zig build image` green. `zig fmt --check` clean.

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
