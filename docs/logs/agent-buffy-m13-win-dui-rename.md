# Log — `m13-win-dui-rename`: the `win` → `dui` monitor command rename (claim 2223)

## 2026-08-16 — branch opened

- Issue #159 (march-m13 housekeeping): rename Driving Award's EL1h command
  `win` → `dui` (same subcommands; report-prefix shape preserved).
- Branch based on `origin/main` (`30dc9a9`, B4 merged as PR #171).

## 2026-08-16 — branch work

- `kernel/src/monitor.zig`: `.name = "dui"` + help/usage text, dispatch,
  sub-verb completion, `cmd_dui`, eight `lookup("dui")` sites, all report
  strings (`dui: windows=`, `dui[…]`, `dui focus:`/`raise:`/`move:`/
  `close:`/`list:`/`hit:`, `dui: cycle focused=`, `dui: window manager not
  armed`), the `complete("dui z")` test, and doc comments. 409/409 tests.
- `kernel/src/shell.zig`: `dui: cycle focused=` / `dui: pointer focus=`
  idle-loop reports + the pinned help-catalog transcript. 450/450 tests.
- `kernel/src/driving_award.zig`: title-bar label `dui`. 122/122 tests.
- Seven gates re-derived; four script-only gates re-ran PASS on VZ
  (`win-syscall`, `win-close`, `win-move`, `win-hig`), all asserting `dui:`
  output. `verify-live-win` passes every `dui:` assertion; its
  keyboard-typed `uname` leg is down in this session (the synthesized
  `--input-string` path — `verify-live-input` fails identically, independent
  of the rename).
- Docs: `gate-inventory.md`, `roadmap.md`, `status.md`, ADR 0008 command
  table, ADR 0007 `dui close` prose, `hardware-contract.md`, `march-m13.md`
  housekeeping row.
