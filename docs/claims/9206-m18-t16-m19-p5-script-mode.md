# Claim: M18 T16 + M19 P5 — shell script mode

- **Owner:** TBD (`<branch>`)
- **Prompt / plan:** `docs/parallel-dispatch-plan.md` Stream A
- **Scope:** M18 T16 (basic scripting: `sh script.BIN` reads FAT file, executes line-by-line, `exit` stops early, 64 lines max) + M19 P5 (full script execution: pipes/redirections/functions work inside scripts, error handling with line numbers)
- **Touches:** `kernel/src/shell.zig`, `tools/verify-live-script.sh` (new)
- **Depends on:** — (nothing; M18 T16 is partially in flight on `agent/buffy/m18-t16-scripting`, coordinate handoff if needed)
- **Heartbeat:** 2026-08-27
- **Status:** ⬜ unclaimed

## Scope detail

### M18 T16 — Basic scripting (in progress on another branch)

T16 is partially implemented on `agent/buffy/m18-t16-scripting`. This claim
picks up that work if it's still in flight, or starts fresh if it landed.

Core requirements:
- `sh script.BIN` reads a FAT file and executes each line as a shell command
- Bounded: 64 lines maximum, honest refusal beyond
- `exit` builtin stops script execution early
- Pipes, redirections, env vars, and globbing all work inside script lines
- No loops/conditionals inside scripts — straight-line execution only
- Error handling: print line number + error message, continue to next line

Implementation:
- New `script_active`, `script_file`, `script_line_count` BSS state in `shell.zig`
- `cmd_sh` builtin reads file via FAT, splits on newlines, feeds each line
  through `shell_handle_expanded`
- Line counter increments per line, 64-line limit enforced
- `exit` in script context clears `script_active` and returns to prompt

### M19 P5 — Full script execution

Builds on T16 to support the full shell language inside scripts:
- `fn` definitions work inside scripts (body lines stored, invoked later)
- `if`/`for`/`while` work inside scripts (they're just lines through `handle_line`)
- `$(cmd)` and `$((expr))` expand inside script lines
- `exit` stops the script (not the shell)
- Error handling: on error, print `script.BIN:N: error: <message>` and continue

## Verification

### Host (class A)
- Unit tests in `shell.zig` for script parsing, line counting, exit behavior
- Transcript test: `test-console` fixture updated with script examples

### Class B (live VZ)
- `tools/verify-live-script.sh`:
  1. Create a test script on ESP: `write test.BIN "echo script-line-1\necho script-line-2\necho script-line-3"`
  2. `sh test.BIN` — all three lines execute, output appears in order
  3. Create a script with `exit`: `write exit-test.BIN "echo before\necho mid\nexit\necho after"`
  4. `sh exit-test.BIN` — prints "before" and "mid", NOT "after"
  5. Create a script exceeding 64 lines — honest refusal
  6. Script with pipe: `write pipe-test.BIN "echo hello | type"` — prints "hello"
  7. Script with redirect: `write redir-test.BIN "echo data > out.BIN"` — file created

## Gate shape

Class-B `tools/verify-live-script.sh` — script execution, early exit, line
limit, pipe/redirect inside scripts, all observed through VZ serial gate.
