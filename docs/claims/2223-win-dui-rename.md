# Claim: `win` → `dui` monitor command rename

- **Owner:** buffy (`agent/buffy/m13-win-dui-rename`)
- **Prompt / plan:** `docs/march-m13.md` housekeeping
- **Scope:** Issue #159 — rename Driving Award's EL1h monitor command `win` to `dui`
- **Depends on:** Milestone 13 B1–B4 (merged)
- **Status:** 🔄 in progress

## Notes

The monitor command that drives the Driving Award window manager was `win` —
short, ambiguous with the `win[...]` report rows / window syscalls, and it
didn't say what it manages. This card renames it to `dui` (Driving Award's
UI), keeping every subcommand (`focus`, `raise`, `move`, `close`, `list`,
`hit`, `cycle`) and the report-prefix shape byte-for-byte otherwise.

Scope (monitor command + report rename only — ADR 0007 `sys_win_*` syscall
names are untouched):

- `kernel/src/monitor.zig`: command table entry, dispatch, sub-verb
  completion, the eight `lookup("dui")` usage sites, `cmd_dui`, and the
  report strings (`dui: windows=…`, `dui[…]` rows, `dui focus:`, `dui
  raise:`, `dui move:`, `dui close:`, `dui list:`, `dui hit:`, `dui: cycle
  focused=`, `dui: window manager not armed`).
- `kernel/src/shell.zig`: the `dui: cycle focused=` / `dui: pointer focus=`
  idle-loop reports, and the pinned help-catalog transcript.
- `kernel/src/driving_award.zig`: the on-screen user title bar label
  `win<id>` → `dui<id>`.
- Seven live gates re-derived (`verify-live-win`,
  `verify-live-win-syscall`, `verify-live-win-close`, `verify-live-win-move`,
  `verify-live-win-hig`, `verify-live-pointer-cg`,
  `verify-pointer-manual`) — script commands + `dui:`/`dui[…]` assertions.
- Docs: `gate-inventory.md`, `roadmap.md`, `status.md`, ADR 0008 command
  table, ADR 0007 `dui close` prose, `hardware-contract.md`.

WIN.BIN/WINLOOP.BIN/WINCLOSE.BIN/WINMOVE.BIN and their `win: fill ok` /
`win: present ok` / `win: open id=2` / `win: close ok` markers are the
user-window app, not the command — left untouched.

- Class-A: monitor 409/409, driving_award 122/122, shell 450/450.
- Class-B: `verify-live-win-syscall`, `verify-live-win-close`,
  `verify-live-win-move`, `verify-live-win-hig` all PASS on VZ asserting
  `dui:` output. `verify-live-win` passes every `dui:` assertion; its
  keyboard-typed `uname` leg fails in this session because the synthesized
  `--input-string` path is down (confirmed by the unrelated
  `verify-live-input` gate failing identically), not by the rename.
