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

## 2026-08-23 — claim 7033: P2 redirection done (issue #291)

P2 (I/O redirection: `>`, `>>`, `<`) landed. Host-tested; live gate pending.

- New `kernel/src/redirect.zig`: 4 KiB BSS capture buffer, two console
  adapters (`capture_console` for `>`/`>>` — captures command stdout;
  `feed_console` for `<` — pre-loaded file feeds command stdin), two
  file helpers (`write_captured_to_file` writes buffer via ESP or FAT,
  `read_file_into` reads file into caller buffer from ESP or FAT).
  Vtables built at runtime into BSS (ADR 0005).
- `shell.zig`: `redirect_split` (finds `>`, `>>`, `<` outside double
  quotes, returns operator kind + left/right split), inline
  `trim_start`/`trim_end` helpers (Zig 0.16 removed
  `std.mem.trimLeft`/`trimRight`), `run_redirect_out` (captures stdout
  → writes to file; `>>` reads existing + appends with newline),
  `run_redirect_in` (pre-loads file → feeds as stdin). Redirect handled
  in `shell_handle_expanded` before pipe split; no ABI impact.
- `tools/verify-unit-tests.sh`: added `redirect` to MODULES list.
- Host tests: 6 redirect module tests (capture, overflow, reset, feed),
  6 shell redirect tests (split rules for >/>>/<, whitespace trimming,
  bad-input null). 628/628 shell tests pass. `verify-unit-tests.sh` all
  modules green. `zig build test-console` transcript byte-identical.
  `zig fmt --check` clean. `zig build` + `zig build image` green.
- Zig 0.16 API note: the unused `@import("tokenizer.zig")` in
  `redirect_split` was replaced with inline trim helpers since
  `std.mem.trimRight`/`trimLeft` were removed in 0.16.

## 2026-08-23 — claim 7033: P3 env vars done (issue #292)

P3 (environment variables: set, unset, env, persistence) landed. Host-tested.

- `shell.zig`: `env_unset` removes a variable and shifts the table;
  `save_env` persists to ENV.TXT through the ESP window; `load_env`
  restores on boot (no disk_ready gate — the esp.lookup path works
  without a FAT mount, which also makes it host-testable). New builtins:
  `set` (like `export`), `unset`, `env`. Reuses existing M18 T12
  infrastructure (env_set/env_get/env_expand, 16-entry BSS table).
- Host tests: 6 new (set/unset/env builtins, direct API, persistence
  round-trip, multi-$VAR expansion, unmatched-$VAR, bounds). 634/634
  shell tests pass. All verify gates green.

## 2026-08-23 — claim 7033: P4 shell functions done (issue #293)

P4 (shell functions: `fn name { ... }`, `fn -d name`, bare `fn`) landed.
Host-tested; live gate pending.

- `shell.zig`: `FuncEntry` table (16 functions × 64-byte name + 16 body
  lines × 256 bytes each), `func_count` BSS counter, `func_find` (linear
  scan by name), `func_define` (register or replace, parses brace-delimited
  body with multiline support — shell prompts `>` until closing brace),
  `func_delete` (remove by name, shift table). New `fn` builtin:
  `fn name { ... }` defines, `fn -d name` deletes, bare `fn` lists all.
  Function invocation: when a command name matches a registered function,
  each body line is fed through `shell_handle_expanded` sequentially.
  No new ABI — no syscalls, no new files.
- Host tests: 6 new (define-and-call, fn -d delete, bare fn listing,
  func_find/func_delete static API, empty-fn list message, fn overwrite).
  640/640 shell tests pass. All verify gates green (`verify-unit-tests.sh`,
  `test-console` transcript byte-identical, `zig fmt --check`, build +
  image clean).

## 2026-08-23 — claim 7033: P8 function args done (issue #297)

P8 (function arguments: `fn name(a, b) { ... }`, `$0`–`$N` positionals)
landed. Host-tested; live gate pending.

- `shell.zig`: `FuncEntry` extended with `arg_names[4][16]`, `arg_name_lens`,
  `arg_count`. `func_define` parses `fn name(a, b) { ... }` — extracts
  comma-separated argument names from parentheses, clamped to 4.
  `func_call` sets `$0` (function name) + `$1`..`$N` (caller args) via
  `env_set`, and named args (`$name` = caller value). Body lines expanded
  at invocation time (`env_expand` in func_call, not at definition).
- `handle_line` skips `env_expand` for `fn` commands so `$name` in
  function bodies stays literal until invoked.
- `fn` listing updated to show arg signatures: `name(a, b) { ... }`.
  No-arg `fn name { ... }` still works (P4 compat).
- Host tests: 6 new (arg define, positional $0–$N, named $VAR, no-arg
  compat, listing signature, clamp 4). 646/646 shell tests pass.
  All verify gates green.


## 2026-08-23 — claim 7033: P9 command substitution done (issue #298)

P9 (command substitution: `$(cmd)` inlines captured stdout) landed.
Host-tested; live gate pending.

- `shell.zig`: new `cmd_subst` function — scans for `$()`, finds matching
  `)`, rejects nested `$(` via a `$`+`(` check inside the inner region,
  trims whitespace, executes the inner command via `handle_line` with stdout
  captured through `redirect.capture_console()`, trims trailing newlines, and
  substitutes the captured output back into the line. `subst_active` guard
  prevents recursive substitution. `fn` definitions skip substitution so
  `$()` in bodies stays literal.
- Bounded: one substitution per line, max 256 bytes captured output.
  Empty inner commands return the raw line unchanged.
- Host tests: 7 new (basic inline, nested refusal, unmatched error,
  empty no-op, fn-body preservation, prefix+suffix, no-subst-passthrough).
  653/653 shell tests pass. All verify gates green.

## 2026-08-23 — claim 7033: P10 arithmetic expansion done (issue #299)

P10 (arithmetic expansion: `$((expr))` evaluates 64-bit signed integer
expressions) landed. Host-tested.

- `shell.zig`: `ArithLexer` tokenizes integers, operators (`+ - * / %`),
  and parentheses. Recursive-descent parser with precedence: `()` >
  unary `-` > `* / %` > `+ -`. Division/modulo by zero → 0.
  `arith_expand` scans for `$((expr))`, finds matching `))` with depth
  tracking, evaluates, formats as decimal, splices into line.
  Wired into `handle_line` before `cmd_subst`. Skipped for `fn` defs.
- Host tests: 12 new (addition, precedence, grouping, subtraction,
  division, modulo, negative, unary minus, mixed prefix/suffix,
  no-op, empty expression, nested parens). 665/665 shell tests pass.
  All verify gates green.
