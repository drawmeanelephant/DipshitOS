# Agent concurrency plan — M19–M27

> **Purpose:** enable 3–5 agents to work simultaneously on VirelaiOS's
> forward roadmap (M19–M27) without file-level collisions. This document
> is the coordination surface for parallel agent dispatch.
>
> **Canonical status:** [`docs/status.md`](status.md) remains the source of
> truth for what's done. This file governs *how* agents split the work.
>
> **Last updated:** 2026-08-22. M18 (T1–T15) landed on `main`; T16
> (scripting) in progress on `agent/buffy/m18-t16-scripting`.

---

## 0. Current state

| Milestone | GitHub issues | Open | Status |
|-----------|--------------|------|--------|
| M18 — Terminal & shell depth | T1–T16 | 1 (T16) | ✅ T1–T15 landed on `main`; T16 in progress |
| M19 — Shell as programming env | P1–P16 | 16 | ⬜ not started |
| M20 — Text rendering & Unicode | U1–U15 | 15 | ⬜ not started |
| M21 — Window management depth | W1–W16 | 16 | ⬜ not started |
| M22 — Developer tools | D1–D16 | 16 | ⬜ not started |
| M23 — The text editor | E1–E25 | 25 | ⬜ not started |
| M24 — CALC grows up | K1–K16 | 16 | ⬜ not started |
| M25 — File manager depth | F1–F18 | 18 | ⬜ not started |
| M26 — Network experience | N1–N16 | 16 | ⬜ not started |
| M27 — Desktop polish & completeness | G1–G30 | 30 | ⬜ not started |
| **Total** | | **169** | |

---

## 1. The concurrency constraint

Milestone march files (`docs/march-m*.md`) define per-milestone card
groups. But milestones overlap — two agents working on different
milestones will collide if they edit the same file. The three bottleneck
files are:

| File | Lines | Why it's contested |
|------|-------|--------------------|
| `kernel/src/driving_award.zig` | 3,617 | Window manager — every visual milestone touches it |
| `kernel/src/shell.zig` | 2,155 | Shell — every terminal/programming milestone touches it |
| `kernel/src/text.zig` | 468 | Text renderer — every font/Unicode milestone touches it |

**Rule: one agent per file at a time.** This plan assigns each contested
file to exactly one lane. New files (edit.zig, ping.zig, elf.zig, etc.)
have no collision risk and are assigned to the lane that creates them.

---

## 2. The five lanes

### Lane A — Shell backbone

| | |
|---|---|
| **Files owned** | `kernel/src/shell.zig`, new `kernel/src/pipe.zig` |
| **Issues** | [#290](https://github.com/user/repo/issues/290) P1–[#305](https://github.com/user/repo/issues/305) P16 |
| **Milestone** | M19 (16 issues) |
| **ABI slots** | 56/57 (pipe read/write) |
| **BSS delta** | ~34 KiB (scrollback ring, selection, search, pipe, env, functions) |
| **Depends on** | M18 done ✅ |
| **Gate scripts** | `verify-live-pipe.sh`, `verify-live-redirect.sh`, `verify-live-env.sh`, `verify-live-function.sh`, `verify-live-script.sh` |

The critical-path lane. P1 (pipe syscalls) is the kernel-side work;
P2–P16 are pure `shell.zig` features. Sequential within the lane — P1
feeds P2 feeds P3, etc.

**External callers:** M25-F4 adds a `du` builtin to `shell.zig`. M26-N5
adds connection management commands. Both are small additions that fit
after M19 completes.

### Lane B — CALC (independent)

| | |
|---|---|
| **Files owned** | `user/src/calc.zig` |
| **Issues** | [#365](https://github.com/user/repo/issues/365) K1–[#380](https://github.com/user/repo/issues/380) K16 |
| **Milestone** | M24 (16 issues) |
| **ABI slots** | 0 |
| **BSS delta** | ~768 bytes (negligible) |
| **Depends on** | M17 (DropDown widget). Already done. |
| **Gate scripts** | `verify-live-calc-prog.sh`, `verify-live-calc-memory.sh`, `verify-live-calc-units.sh`, `verify-live-calc-constants.sh`, `verify-live-calc-history.sh` |

Completely independent. Touches nothing in the kernel or toolkit. Can start
and finish without coordinating with any other lane. K1 and K2 touch
disjoint state within calc.zig and can be parallelized internally.

### Lane C — Text rendering

| | |
|---|---|
| **Files owned** | `kernel/src/text.zig` |
| **Issues** | [#306](https://github.com/user/repo/issues/306) U1–[#320](https://github.com/user/repo/issues/320) U15 |
| **Milestone** | M20 (15 issues) |
| **ABI slots** | 58 (`sys_font_size`) |
| **BSS delta** | ~63 KiB (16×16 + 24×24 glyph tables — largest single BSS add) |
| **Depends on** | M18 done ✅ |
| **Gate scripts** | `verify-live-font-sizes.sh`, `verify-live-unicode.sh`, `verify-live-tabs.sh` |

Small file (468 lines) but foundational — every visual milestone downstream
(U4 chrome, M21 tiling, M27 previews) needs font sizes and Unicode working.
Fast lane to unblock the compositor.

### Lane D — New userland apps

| | |
|---|---|
| **Files owned** | New files only: `user/src/edit.zig`, `user/src/ping.zig`, `user/src/netstat.zig`, `user/src/sysmon.zig`, `user/src/about.zig`, `user/src/disas.zig`, `user/src/asm.zig`, `kernel/src/elf.zig`, `kernel/src/symbol.zig` |
| **Issues** | M22: [#324](https://github.com/user/repo/issues/324) D1–[#339](https://github.com/user/repo/issues/339) D16 · M23: [#340](https://github.com/user/repo/issues/340) E1–[#364](https://github.com/user/repo/issues/364) E25 · M25: [#381](https://github.com/user/repo/issues/381) F1–[#398](https://github.com/user/repo/issues/398) F18 · M26: [#399](https://github.com/user/repo/issues/399) N1–[#403](https://github.com/user/repo/issues/403) N5 |
| **Milestones** | M22 (16), M23 (25), M25 (18), M26 partial (5) |
| **ABI slots** | 59/60 (ELF load + strace) — kernel-side in this lane |
| **BSS delta** | ~18 KiB kernel + ~200 KiB userland (editor buffers dominate) |
| **Depends on** | M20-U1 for editor gutter rendering. New-file apps (ping, netstat) have minimal deps. |
| **Gate scripts** | `verify-live-elf.sh`, `verify-live-asm.sh`, `verify-live-editor-*.sh`, `verify-live-ping.sh`, `verify-live-netstat.sh` |

Zero collision with any other lane — all new files. Generates the most
new code per milestone. The editor (M23, 25 issues) is the heavyweight.
Lane D has the most issues (64 total) and should be split internally:

| Sub-lane | Issues | Work |
|----------|--------|------|
| D-Tools | D1–D16 | M22: assembler, disassembler, ELF, symbols, strace, dev utilities |
| D-Editor | E1–E25 | M23: EDIT.BIN core, undo, tabs, syntax, console, sidebar, themes |
| D-Files | F1–F18 | M25: bulk ops, properties, mkdir, trash, favorites, split panes |
| D-NetApps | N1–N5 | M26: PING.BIN, NETSTAT.BIN, fetch display, TOP network, connection mgr |

### Lane E — Compositor

| | |
|---|---|
| **Files owned** | `kernel/src/driving_award.zig`, `kernel/src/input.zig` |
| **Issues** | M21: [#321](https://github.com/user/repo/issues/321) W1–[#432](https://github.com/user/repo/issues/432) W16 · M27 partial: [#444](https://github.com/user/repo/issues/444) G1–[#450](https://github.com/user/repo/issues/450) G7 |
| **Milestones** | M21 (16), M27 partial (7) |
| **ABI slots** | 0 |
| **BSS delta** | ~14 KiB (tile state, minimized flags, notification ring, preview buffer, tooltip state) |
| **Depends on** | M20-U1 (font sizes affect chrome dimensions). |
| **Gate scripts** | `verify-live-tile.sh`, `verify-live-minimize.sh`, `verify-live-notif-center.sh`, `verify-live-boot-splash.sh`, `verify-live-about.sh`, `verify-live-tooltip.sh` |

One agent owns driving_award.zig for all compositor work. No other agent
touches this file. M27 remainder (G8–G30, 23 issues) is mostly polish
that can be dispatched to any lane after the core compositor is stable.

---

## 3. File ownership matrix

| File | Lane A | Lane B | Lane C | Lane D | Lane E |
|------|--------|--------|--------|--------|--------|
| `kernel/src/shell.zig` | **OWN** | — | — | — | — |
| `kernel/src/pipe.zig` (new) | **OWN** | — | — | — | — |
| `user/src/calc.zig` | — | **OWN** | — | — | — |
| `kernel/src/text.zig` | — | — | **OWN** | — | — |
| `user/src/edit.zig` (new) | — | — | — | **OWN** | — |
| `user/src/ping.zig` (new) | — | — | — | **OWN** | — |
| `user/src/netstat.zig` (new) | — | — | — | **OWN** | — |
| `user/src/sysmon.zig` (new) | — | — | — | **OWN** | — |
| `user/src/about.zig` (new) | — | — | — | **OWN** | — |
| `user/src/asm.zig` (new) | — | — | — | **OWN** | — |
| `user/src/disas.zig` (new) | — | — | — | **OWN** | — |
| `kernel/src/elf.zig` (new) | — | — | — | **OWN** | — |
| `kernel/src/symbol.zig` (new) | — | — | — | **OWN** | — |
| `kernel/src/driving_award.zig` | — | — | — | — | **OWN** |
| `kernel/src/input.zig` | — | — | — | — | **OWN** |
| `kernel/src/syscall.zig` | — | — | — | — | — |
| `kernel/src/main.zig` | — | — | — | — | — |
| `kernel/src/scheduler.zig` | — | — | — | — | — |
| `kernel/src/monitor.zig` | — | — | — | — | — |
| `user/src/desktop.zig` | — | — | — | — | — |
| `user/src/notepad.zig` | — | — | — | — | — |
| `user/src/file_browser.zig` | — | — | — | — | — |
| `user/src/top.zig` | — | — | — | — | — |
| `user/src/settings_panel.zig` | — | — | — | — | — |

### Shared files (touch with coordination)

| File | Who adds to it | When |
|------|----------------|------|
| `kernel/src/shell.zig` | Lane D (M25 F4 `du` builtin, M26 N5 connection cmds) | After Lane A finishes M19 |
| `kernel/src/driving_award.zig` | Lane D (M27 G3 about dialog paint) | After Lane E owns it, small merge |
| `kernel/src/syscall.zig` | Lane D (M22 D1 slot 59, D5 slot 60) | New slots are append-only additions |
| `kernel/src/main.zig` | Lane E (M27 G1 splash timing) | Small change, coordinate |
| `kernel/src/input.zig` | Lane A (M18 T2 click-drag) or Lane E (M21 W4 alt-`) | Depends on who gets there first |
| `user/src/desktop.zig` | Lane E (M21 W3 dock restore for minimized) | Small addition |
| `user/src/file_browser.zig` | Lane D (M25 F1–F18) | Primary owner in Lane D |
| `user/src/top.zig` | Lane D (M26 N4 network bandwidth tab) | Small addition |

---

## 4. Dependency graph

```
         ┌──────────────────────────────────────────────┐
         │  Lane B (CALC M24) — independent, any time   │
         └──────────────────────────────────────────────┘

Lane A (shell.zig)                 Lane D (new files)
  M19 P1→P2→...→P16                  M22 D1→D16 (dev tools)
       │                              M23 E1→E25 (editor)
       ├──shared──→ M25 F4 (du)       M25 F1→F18 (file mgr)
       ├──shared──→ M26 N5 (net)      M26 N1→N5 (net apps)
       │                                    │
       ▼                                    │
  Lane C (text.zig)                        │
  M20 U1→U15                               │
       │                                    │
       ├──→ Lane E (driving_award.zig)      │
       │    M21 W1→W16 (window mgmt)        │
       │         │                          │
       │         ▼                          │
       │    M27 G1→G7 (compositor polish)   │
       │                                    │
       └───────→ M26 N1/N2 ────────────────┘
                  (new apps, minimal deps)
```

**Critical path:** Lane A (M19) → Lane C (M20) → Lane E (M21→M27).
Lane B and early Lane D can run fully in parallel from day one.

---

## 5. Execution timeline

### Phase 1 — Immediate start (no dependencies)

| Lane | Agent | Issues | Work |
|------|-------|--------|------|
| **A** | Agent 1 | P1–P16 | M19: pipe syscalls, redirection, env vars, functions, scripts, all shell features |
| **B** | Agent 2 | K1–K16 | M24: CALC programmer mode, memory, units, constants, trig, stats, CLI mode |
| **D-Tools** | Agent 3 | D1–D16 | M22: ELF loader, assembler, disassembler, symbols, strace, dev utilities |

### Phase 2 — After M19 lands (Lane A done)

| Lane | Agent | Issues | Work |
|------|-------|--------|------|
| **C** | Agent 4 | U1–U15 | M20: font sizes, Unicode glyphs, grapheme clusters, window chrome, monospace |
| **D-NetApps** | Agent 3 | N1–N5 | M26: PING.BIN, NETSTAT.BIN, fetch display, TOP network, connection mgr |

### Phase 3 — After M20 lands (Lane C done)

| Lane | Agent | Issues | Work |
|------|-------|--------|------|
| **E** | Agent 5 | W1–W16 + G1–G7 | M21: tiling, minimize, alt-tab, notifications + M27: splash, about, previews, tooltips |
| **D-Editor** | Agent 3 | E1–E25 | M23: EDIT.BIN base, undo, goto, tabs, syntax, console, sidebar, themes |

### Phase 4 — After M21 lands

| Lane | Agent | Issues | Work |
|------|-------|--------|------|
| **D-Files** | Agent 3 | F1–F18 | M25: bulk ops, properties, mkdir, trash, favorites, split panes |
| **E (remaining)** | Agent 5 | G8–G30 | M27 polish: buttons, focus, drag, clipboard, menus, shortcuts, errors, perf, dogfood |

### Phase 5 — Integration gates

All lanes converge. Run full gate sweep:
```bash
for script in tools/verify-live-*.sh; do bash "$script"; done
```

Update `docs/status.md` with completed card evidence. Run coordination
verification: `bash tools/verify-coordination.sh`.

---

## 6. Issue-to-lane quick reference

Copy-pasteable for agent dispatch. Each line is one issue that maps to
a specific lane and phase.

```
# Lane A — Shell (Phase 1)
#290 P1: Pipe syscalls (slots 56/57)
#291 P2: Output/input redirection
#292 P3: Command chaining (;, &&, ||)
#293 P4: Exit status propagation
#294 P5: Quoting & escaping
#295 P6: Globbing (wildcard expansion)
#296 P7: Foreground/background jobs (&)
#297 P8: Shell functions with arguments
#298 P9: Command substitution
#299 P10: Arithmetic expansion
#300 P11: Conditional execution (if/then/else)
#301 P12: Loop constructs (for/while)
#302 P13: Here-documents
#303 P14: Pipe to/from files
#304 P15: Shell debugging/tracing (set -x)
#305 P16: Temporary files

# Lane B — CALC (Phase 1, independent)
#365 K1: Programmer mode (hex/oct/dec, bitwise)
#366 K2: Memory store (4 slots)
#367 K3: Unit conversion
#368 K4: Mathematical constants
#369 K5: History persistence (FAT)
#370 K6: Scientific notation display
#371 K7: Trigonometric functions
#372 K8: Logarithmic & exponential functions
#373 K9: Expression editor
#374 K10: Copy result/expression
#375 K11: CLI CALC mode
#376 K12: Formatting controls
#377 K13: Date/time arithmetic
#378 K14: Random number generation
#379 K15: Saved expressions & definitions
#380 K16: Statistics mode

# Lane C — Text (Phase 2, after M19)
#306 U1: Multiple font sizes (8x8, 16x16, 24x24)
#307 U2: Unicode glyph table — Latin-1 Supplement
#308 U3: Unicode glyph table — Latin Extended-A
#309 U4: Character width calculation (wcwidth)
#310 U5: Grapheme cluster support
#311 U6: Zero-width & combining character handling
#312 U7: Basic emoji support
#313 U8: Text search in apps (Ctrl+F)
#314 U9: Improved window chrome
#315 U10: Monospace rendering (tab stops, fixed width)
#316 U11: Missing glyph fallback
#317 U12: Text measurement API
#318 U13: Glyph rendering cache
#319 U14: Unicode torture test document
#320 U15: Line breaking & word wrapping

# Lane D-Tools — Dev tools (Phase 1)
#324 D1: ELF loader (AArch64 ELF32/ELF64)
#325 D2: Tiny AArch64 assembler
#326 D3: Symbol table for crash reports
#327 D4: Disassembler
#328 D5: System call tracer (strace)
#329 D6: Process viewer (ps)
#330 D7: Environment viewer (printenv)
#331 D8: Filesystem inspection (stat, find)
#332 D9: System information dashboard (sysinfo)
#333 D10: Resource monitor
#334 D11: Crash report viewer
#335 D12: System log viewer (dmesg)
#336 D13: Command timing (time)
#337 D14: Developer console
#338 D15: File permissions viewer
#339 D16: Package/tool inventory

# Lane D-Editor — Text editor (Phase 3, after M20)
#340 E1: EDIT.BIN — base text editor
#341 E2: Undo/redo (50 operations)
#342 E3: Goto line (Ctrl+G)
#343 E4: Multi-file tabs
#344 E5: Syntax coloring (Zig keywords)
#345 E6: Console integration (Ctrl+backtick)
#346 E7: Search & replace (Ctrl+F/H)
#347 E8: Autoindent
#348 E9: Bracket matching
#349 E10: Word wrap in editor
#350 E11: Line numbers (toggle)
#351 E12: Multiple cursors (basic)
#352 E13: Rectangular selection (Alt+drag)
#353 E14: Command palette (Ctrl+Shift+P)
#354 E15: Recent files list
#355 E16: Unsaved changes handling
#356 E17: Crash recovery
#357 E18: Configurable keybindings
#358 E19: Editor themes
#359 E20: Indentation controls
#360 E21: Bookmarks (Ctrl+B)
#361 E22: Delete line (Ctrl+Shift+D)
#362 E23: Jump to definition (basic)
#363 E24: File tree sidebar
#364 E25: Minibuffer & status bar

# Lane D-Files — File manager (Phase 4, after M21)
#381 F1: Bulk selection & batch operations
#382 F2: File properties panel
#383 F3: Create directory
#384 F4: Disk usage (du)
#385 F5: Recent files (persistent ring)
#386 F6: Trash & restore
#387 F7: Batch rename
#388 F8: Split panes
#389 F9: Favorites/bookmarks
#390 F10: File search
#391 F11: Sorting options
#392 F12: Hidden files toggle
#393 F13: File associations & open with
#394 F14: Terminal here
#395 F15: Editor here
#396 F16: Path copy
#397 F17: Overwrite & conflict resolution
#398 F18: Transactional delete UX

# Lane D-NetApps — Network apps (Phase 2, after M19)
#399 N1: PING.BIN (ICMP echo)
#400 N2: NETSTAT.BIN (connection dashboard)
#401 N3: HTTP fetch display (terminal mode)
#402 N4: Network bandwidth tab in TOP.BIN
#403 N5: Shell connection manager

# Lane E — Compositor (Phase 3, after M20)
#321 W1: Tiling mode (Ctrl+T)
#322 W2: Master-detail layout (Ctrl+M)
#323 W3: Window minimize (Ctrl+N)
#420 W4: Workspace-aware alt-tab
#421 W5: Notification center
#422 W6: Maximize / restore
#423 W7: Fullscreen mode (F11)
#424 W8: Always-on-top (Ctrl+Shift+T)
#425 W9: Focus rings & visual focus indicator
#426 W10: Keyboard window movement (Alt+arrows)
#427 W11: Window persistence across sessions
#428 W12: Window title updates
#429 W13: Close confirmation dialog
#430 W14: Orphan window cleanup
#431 W15: Modal windows
#432 W16: Transient window behavior

# Lane E — M27 compositor polish (Phase 3-4)
#444 G1: Boot splash screen
#445 G2: First-boot wizard
#446 G3: About dialog (Ctrl+Shift+A)
#447 G4: Window previews in alt-tab
#448 G5: Sound design (action feedback)
#449 G6: System monitor dashboard (sysmon)
#450 G7: Tooltip system

# Lane D/E — M27 remaining polish (Phase 4, dispatch freely)
#451 G8: Consistent keyboard shortcuts
#452 G9: Consistent menu structure
#453 G10: Consistent dialog style
#454 G11: Clipboard consistency everywhere
#455 G12: Drag/drop consistency
#456 G13: Focus behavior polish
#457 G14: Button states (hover/pressed/disabled)
#458 G15: Confirmation dialogs for dangerous actions
#459 G16: Settings persistence & reset
#460 G17: Startup behavior
#461 G18: Shutdown/restart polish
#462 G19: Crash recovery for apps
#463 G20: Theme consistency
#464 G21: Font consistency
#465 G22: Polished empty states
#466 G23: Polished error states
#467 G24: Performance pass
#468 G25: Memory leak audit
#469 G26: Keyboard-only navigation pass
#470 G27: Screenshot capability
#471 G28: Help system
#472 G29: Keyboard shortcut reference
#473 G30: Dogfood development session
```

---

## 7. Collision-avoidance rules

### Rule 1: Own your file

Each lane has a primary file owner. No other lane edits that file while
the owner is actively working on it. If you need a small addition to an
owned file, wait for the owner's current card to complete, or coordinate
via the integration branch.

### Rule 2: Claim before you start

Per AGENTS.md: non-trivial work gets a claim file under `docs/claims/`
and a log entry in `docs/logs/<branch>.md` before code is written.
This prevents two agents from claiming the same issue.

### Rule 3: New files are free

Creating new files (`edit.zig`, `ping.zig`, `elf.zig`, etc.) has zero
collision risk. Lane D is the new-file lane and can create as many files
as needed without coordinating.

### Rule 4: Shared files are append-only

When a lane needs to add to another lane's file (e.g., M25 F4 adding
`du` to `shell.zig`), the addition should be:
- A single, self-contained commit
- Placed at a clearly marked insertion point (comment: `// M25 du builtin`)
- Tested independently against the existing file state

### Rule 5: Merge through integration branches

If two lanes need the same file simultaneously (should be rare with this
split), the second lane works on an `agent/<name>/<milestone>` branch and
merges through `main` after the first lane's PR lands.

### Rule 6: Update on blockers

If you're blocked (dependency not ready, test failing), append a log entry
to `docs/logs/<branch>.md` so the next agent doesn't repeat the attempt.

---

## 8. ABI budget tracking

| After milestone | Slots used | Remaining | Lane |
|-----------------|------------|-----------|------|
| Current (M18) | 56 | 8 | — |
| M19 (pipes) | 58 | 6 | A |
| M20 (font size) | 59 | 5 | C |
| M22 (ELF + strace) | 61 | 3 | D |
| **Final** | **61** | **3** | — |

Three slots remain after all milestones. Future work must be predominantly
userland. This budget is a hard constraint — no lane may consume a slot
without documenting it in the march file and updating this table.

---

## 9. BSS budget tracking

| Component | BSS | Lane |
|-----------|-----|------|
| M19 (pipe + env + functions + script) | ~7.6 KiB | A |
| M20 (font tables) | ~63 KiB | C |
| M22 (kernel: ELF + symbols + strace) | ~3.4 KiB | D |
| M23 (editor: base + undo + tabs) | ~188 KiB | D |
| M24 (CALC) | ~768 B | B |
| M25 (file manager) | ~368 B | D |
| M26 (network apps) | ~1 KiB | D |
| M21+M27 (compositor polish) | ~14 KiB | E |
| **Total M19–M27 delta** | **~278 KiB** | |

The editor (M23) at ~188 KiB is the largest single consumer. If the process
BSS limit is tight, reduce E4 tabs from 4 to 2 (drops to ~72 KiB).

---

## 10. Maintenance tracks (continuous refactoring)

### 10a. Driving Award decomposition

`kernel/src/driving_award.zig` is 3,617 lines and growing with every
visual milestone. It has accumulated M6→M17 without a refactoring pass.
The functional zones are already self-contained:

| Zone | Approx lines | Target file |
|------|---------------|-------------|
| Notifications (push/dismiss/advance/render) | ~65 | `notifications.zig` |
| Snap zones (detect/apply/restore) | ~100 | `snap.zig` |
| Alt-tab overlay (activate/cycle/commit/dismiss) | ~100 | `alttab.zig` |
| Pointer routing + drag-and-drop | ~350 | `pointer.zig` |
| Composite loop + drain | ~370 | `composite.zig` |
| Theme color accessors | ~80 | `theme.zig` |
| Tray position + helpers | ~50 | tray stays (too small to extract) |
| Window registry + focus + dirty + user ops | ~1200 | stays in `driving_award.zig` (core) |

**Rule for Lane E:** every time you add a card that touches one of these
zones (e.g., M21-W5 notification center → notifications), extract the
core logic into its own file first, then build the new feature on top.
Don't let driving_award.zig grow past ~4,000 lines without an extraction.

### 10b. Gate script harness

There are 80 `verify-live-*.sh` scripts totaling 16,000 lines. The
largest (TCP retransmission) is 22K. They all follow the same pattern.

**Recommended refactoring:** extract a shared `tools/lib/gate-harness.sh`
that provides:

```bash
# Launch a VM, wait for a prompt, run commands, check output
gate_launch [flags...]
gate_expect <pattern> [timeout]
gate_assert_counter <label> <expected>
gate_assert_contains <text>
gate_finish
```

Each gate script becomes ~30-80 lines of assertions instead of 200+
lines of boilerplate. Priority: do this before M19 gates land. Any lane
can pick it up during downtime — zero collision risk (tools/ directory).

---

## 11. Known risks

1. **driving_award.zig growth.** At 3,617 lines, adding M21's 16 issues
   + M27 polish could push it past 5,000 lines. Extract submodules as
   you go (Section 10a).

2. **Editor BSS budget.** M23 E4 (4-tab editor) at ~188 KiB is the
   largest single-process BSS in the system. Monitor against the process
   limit and reduce to 2 tabs if needed.

3. **keyboard events=0 (issue #179).** The synthesized keyboard seam
   reports `events=0`. Any live gate that depends on keyboard input in
   the framebuffer (not serial) may be blocked. Track in `docs/status.md`.

4. **Pointer focus class-C only (issue #151, claim 4769).** Live proof
   for U4 pointer class-C-only. Not blocking but noted.

5. **Lane D issue count.** Lane D has 64 issues (D1–D16 + E1–E25 +
   F1–F18 + N1–N5). This is more than any other lane. Consider
   splitting D-Editor and D-Files into separate agents if throughput
   is a bottleneck.

6. **Integration conflicts.** Despite the lane split, small shared-file
   additions (du builtin, about dialog paint, syscall slots) require
   merge coordination. Keep commits atomic and self-contained.

---

## 12. How to dispatch an agent

When spinning up a new agent session:

1. **Identify the lane.** Which files does the work touch? That determines
   the lane.
2. **Check the timeline.** Is the lane's dependency met? (e.g., Lane C
   can't start until Lane A finishes M19.)
3. **Claim the work.** Create `docs/claims/<NNNN>-<slug>.md` and append to
   `docs/logs/<branch>.md`.
4. **Give the agent the march file.** Point it at `docs/march-m<N>.md`
   for card detail and gate scripts.
5. **Give the agent the issue list.** The issues for that lane are in
   Section 6 of this document.
6. **Give the agent the architecture.** Point it at `docs/architecture.md`
   and `docs/decisions/0007-syscall-abi.md` if it needs ABI context.
7. **Verify on completion.** Run `bash tools/verify-coordination.sh` and
   the lane's gate scripts.
