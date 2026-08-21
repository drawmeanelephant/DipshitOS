# Roadmap archive — Milestone eleven — desktop platform & first real GUI apps

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).

---

### Milestone eleven — desktop platform & first real GUI apps

> Combine windows, events, and storage into a recognizable graphical desktop
> with dedicated consumer applications and a desktop launcher.

- **A1 — Micro-widget toolkit (`user/src/lib/ui.zig`).** Reusable, lightweight
  GUI primitives: buttons (with hover/pressed states), text labels, single-line
  text entry, and list views. Extracted from actual app usage.
- **A2 — `CALC.BIN` (Calculator).** The classic GUI proof: clickable button
  grid, keyboard numeric entry, and 64-bit arithmetic display.
- **A3 — `NOTEPAD.BIN` (Graphical Text Editor).** Multi-line text editor opening,
  editing, and saving files on `/data/notes.txt`.
- **A4 — `TOP.BIN` (Graphical Task Manager).** Polls `sys_procs`, renders live
  CPU/memory bar graphs, and provides a clickable "Kill" button.
- **A5 — `DESKTOP.BIN` / Launcher.** **[Capstone Gate]** Top status bar with
  clock and system stats + clickable application menu to launch EL0 programs.
  Live gate: `verify-live-desktop.sh`.
