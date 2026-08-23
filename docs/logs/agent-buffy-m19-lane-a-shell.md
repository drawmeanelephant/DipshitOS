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
