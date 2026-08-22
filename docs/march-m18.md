# Milestone eighteen march — terminal & shell depth (living tracker)

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts. This file holds M18's per-card detail and agent split, following
> the [`docs/march-arc2.md`](march-arc2.md) pattern.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

M17 desktop completeness and all Arc1–5 work are done. The desktop has a
full widget toolkit, 20+ apps, window management, context menus, workspaces,
notifications, clipboard, timers, compose sequences, and audio. The shell
(`shell.zig`) has a line editor, history (up/down), basic builtins, and
lives on the serial console.

M18 makes the terminal *comfortable* — the place you actually want to spend
time. Scrollback so you can see what happened, text selection so you can
copy things, command search so you can find past output, persistent history
so you don't lose commands on reboot, and colored output so you can tell
what's going on at a glance.

**No new kernel syscalls.** Every card is pure `shell.zig` or
`driving_award.zig` paint. The only kernel interaction is the existing
clipboard syscalls (slots 38/39) for T2.

## The cards, in order

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| T1 | **Scrollback.** Ring buffer in `shell.zig` that preserves the last 200 lines of terminal output. Shift+Up/Down or PageUp/PageDown scrolls the view. Visible cursor indicator showing current scroll position. | ⬜ | — | Pure `shell.zig` BSS ring (200 × 128 bytes = 25,600 bytes). No new syscall. The ring captures everything the shell prints, including command output, error messages, and monitor replies. |
| T2 | **Text selection & clipboard.** Click-drag to start a selection in the terminal. Shift+click extends the selection. Ctrl+C copies selected text to the M14 clipboard. Ctrl+V pastes clipboard contents at the prompt. Visual highlight (inverted colors) on the selected region. | ⬜ | — | Reuses M14 clipboard syscalls (slots 38/39). `shell.zig` tracks selection start/end coordinates. The highlight is painted by `driving_award.zig` during the composite pass. |
| T3 | **Command search (reverse-i-search).** Ctrl+R opens a search bar at the bottom of the terminal. Type to search backward through the scrollback buffer and history. Enter accepts the match and puts it at the prompt. Esc cancels. First match highlighted. | ⬜ | — | Pure `shell.zig` state machine. Scans the scrollback ring + history ring. The search bar is a small overlay painted by the compositor. |
| T4 | **Shell improvements.** Up/Down arrow cycles through command history (already works). Tab completion for built-in commands (`help`, `echo`, `exec`, `mem`, `tasks`, etc.). Persistent history: last 50 commands saved to FAT on every command entry, restored on boot. Ctrl+L clears the screen. | ⬜ | — | `shell.zig` history ring + FAT write on each command. `clear` builtin or Ctrl+L sends the terminal clear sequence. Tab completion scans the builtin table — no filesystem path completion yet (deferred to M19). |
| T5 | **Terminal colors.** ANSI-style colored prompt: green for success (last command exit 0), red for error (non-zero). `ls`-style output: directories in bold, files in normal weight. `color` command toggles color on/off. Color state persisted in SETTINGS.TXT. | ⬜ | — | `shell.zig` ANSI escape output + `driving_award.zig` paint support for color attributes. `settings.zig` color flag. Comptime color table. |

## Agent split

> **Constraint:** one editor per file at a time (AGENTS.md).
> T1–T4 all touch `shell.zig` — they should be done sequentially or by
> a single agent. T5 touches `shell.zig` + `driving_award.zig` and should
> follow T4.

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Shell core** | `shell.zig` for T1 (scrollback), T2 (selection), T3 (search), T4 (improvements). Sequential: T1 → T2 → T3 → T4. | None |
| **B — Colors** | `shell.zig` (color output) + `driving_award.zig` (color paint) + `settings.zig` (persist flag) for T5. | T4 (shell improvements land first) |

## Notes

1. **ABI budget:** Zero new syscall slots. T2 uses existing clipboard slots
   38/39. Everything else is pure userland.
2. **BSS budget:** T1 adds ~25.6 KiB for the scrollback ring. T2 adds
   ~200 bytes for selection state. T3 adds ~256 bytes for search state.
   Total M18 BSS delta: ~26 KiB.
3. **Gate shape:** Every card lands with a class-A host unit test AND a
   class-B `verify-live-*.sh` on VZ. T1's gate asserts scrollback lines
   survive after output exceeds one screen. T2's gate asserts copy/paste
   round-trip through the clipboard. T3's gate asserts search finds a
   known string. T4's gate asserts persistent history across reboot.
   T5's gate asserts color output in the serial log.
4. **Known limitation:** Text selection (T2) in the terminal is
   character-grid based (monospace 8×8). Selection across wrapped lines
   is deferred to M20 (font/rendering improvements).
5. **Scope exclusions:** No font size changes (M20). No Unicode rendering
   (M20). No new kernel syscalls. No filesystem path completion (M19).
