# Claim: M18 T16 — basic scripting mode (`sh`)

- **Owner:** buffy (`agent/buffy/m18-t16-scripting`)
- **Prompt / plan:** issue #419 (M18 T16, milestone `docs/march-m18.md`)
- **Scope:** M18 card T16 — `sh <script>` executes a plain-text file of
  shell commands line by line through `handle_line()`; bounded to 64 lines
  × 256 chars (16 KiB BSS staging); `#` comments, empty lines skipped,
  no abort-on-error, `exit` stops early, scripts cannot call scripts;
  registered `sh` monitor command; host tests + class-B live gate
- **Depends on:** M18 T12–T15 (shell builtins, `.dipshitrc`, prompt) —
  already merged (`4265ea3`)
- **Status:** ✅ done 2026-08-22

## Notes

Implements issue #419 T16: basic scripting mode.

### Design

- **Execution path:** `sh` is intercepted as a shell builtin in
  `shell_handle_expanded` (the `export`/`alias`/`prompt` pattern) and runs
  `run_script(mon, name)`, which loads the file into a 16 KiB BSS staging
  buffer and feeds each non-empty, non-comment line through `handle_line()`
  — so env expansion, aliases, and builtins apply inside scripts.
- **File seam:** mirrors `cat` — bare names read the ESP window
  (`esp.lookup`/`content_of`, honest "content not loaded" refusal above the
  window cap), `/`-paths read the FAT volume directly (`fat.file_size` +
  `fat.read_file`, size-checked against the staging bound).
- **Flags:** `script_active` (nesting guard — refuses `sh` inside a
  script with `sh: scripts cannot call scripts`) and `script_stop` (set by
  the `exit` intercept). Both live at module scope beside `env_table`,
  because the execution path (`handle_line`) is module-level; the Shell
  struct's monitor is threaded, not the struct itself.
- **Bounds:** staging 64 × 256 = 16384 bytes; >64 executable lines refused;
  a line >256 chars refused and skipped (the editor refuses the same
  bound). Failures never abort the script (no abort-on-error); `set -x`
  printing is M19.
- **`exit`:** only intercepted while `script_active`; at the interactive
  prompt it still falls through to the registry's unknown-command shape.
- **Registry:** `sh` registered in the monitor registry (help/usage/tab
  completion, `registry_count` 51 → 52). Direct `monitor.exec` of `sh`
  (host tests only — the shell always intercepts first) gets an honest
  refusal from `cmd_sh`.
- **BSS budget:** 16 KiB staging + ~32 B flags, within ADR 0013 D3.1
  headroom; staging is BSS, not stack (16 KiB kernel stack, ADR 0004 D5).

### Tests

- Host (class A): two-echo script executes both lines with no prompt
  between; comments/blank lines skipped; `exit` stops early; nesting
  refused; missing file honest error; >256-byte line refused and skipped;
  >64 lines refused; bare `exit` stays unknown-command.
- Class B: `tools/verify-live-scripting.sh` — `write` a script on the ESP,
  `sh` it, verify output on real VZ; nesting refusal; missing-file error.

### Files changed

- **Modified:** `kernel/src/shell.zig`, `kernel/src/monitor.zig`,
  `tests/transcript-console.txt`
- **New:** `tools/verify-live-scripting.sh`
- **Coordination:** `docs/claims/0469-m18-t16-scripting.md`,
  `docs/logs/agent-buffy-m18-t16-scripting.md`

### Boot regression found & fixed (pre-existing — NOT caused by T16)

While bringing up the class-B gate, every M18 kernel (main HEAD, T1–T15)
**hung on VZ before the shell banner** — the serial log stopped at
`aslr: boot user stack=...`. Bisected on real hardware:

- `438b57f` (pre-M18): boots, shell prompt appears ✅
- `804fdc0` (M18 T1, scrollback): hangs at the aslr seam ❌
- main HEAD: hangs identically ❌

**Root cause:** M18 T1 introduced `const scrollback_vtable` — a const
function-pointer table. The flat loader applies no relocations and the
kernel runs at a runtime-chosen load base, so a const vtable holds wrong
absolute addresses; the first banner write through the wrapped console
faulted silently (claim 0015 root cause, ADR 0005 — the same reason
`MachineControl`'s vtable, the monitor registry, and the syscall table
are built at runtime into BSS).

**Fix (in `kernel/src/shell.zig`):** build the scrollback vtable at
runtime into BSS (`ensure_scrollback_vtable`, the established pattern),
used by `Shell.boot()`. With the fix, main HEAD boots to the prompt and
the T16 walk passes end to end.

Evidence under `artifacts/`: `live-scripting-run-prem18.txt` (boots),
`live-scripting-run-t1.txt` / `live-scripting-run-main.txt` (hang),
`live-scripting-run-fixed.txt` (boots + T16 walk), `live-scripting-gate.txt`,
`live-scripting-serial-01.log`.

### Verification

- `zig test kernel/src/shell.zig` — 544/544 pass (8 new T16 tests)
- `bash tools/verify-unit-tests.sh` — all modules pass
- `bash tools/verify-transcript.sh` — transcript byte-identical (help lists `sh`)
- `zig build` / `zig build image` / `bash tools/verify-bss-budget.sh` — PASS (9.85 MiB / 11.0 MiB)
- `bash tools/verify-coordination.sh` — ok
- `bash tools/verify-live-scripting.sh` — **class-B VZ gate PASS 1/1**
  (boots real VM: `write` script on ESP → `sh SCRIPT.TXT` outputs marker;
  `sh: scripts cannot call scripts` for nesting and inner script never
  runs; `sh MISSING.TXT` honest not-found; completion marker)
