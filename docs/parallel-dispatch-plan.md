# Parallel dispatch plan — M18–M27 remaining work

> **Created:** 2026-08-27  
> **Purpose:** Enable 4+ agents to work concurrently with zero file conflicts.  
> **Status:** ACTIVE — streams A–D are safe to start immediately.

## Background

M18–M27 are the "experience layer." Through 2026-08-26, most cards are done.
What remains is scattered across independent work units that can be parallelized
if we respect the **one editor per file at a time** coordination rule.

## What's left (as of 2026-08-27)

| Work | Status | Primary files |
|------|--------|---------------|
| M18 T16 Scripting mode | 🔄 on `agent/buffy/m18-t16-scripting` | `kernel/src/shell.zig` |
| M19 P5 Script execution (`sh file.BIN`) | ⬜ | `kernel/src/shell.zig` (needs T16 first) |
| M25 F6–F10, F12–F18 file manager cards | 🔶 code done, live gates pending | `user/src/file_browser.zig` |
| M26 N13 Network-aware app preflight | ⬜ | `user/src/fetch.zig`, `user/src/ping.zig` |
| M26 N14 Offline state handling | 🔶 partial | `user/src/fetch.zig`, `user/src/ping.zig` |
| M27 G2 First-boot wizard | ⬜ | `user/src/settings_panel.zig` |
| M27 G8–G29 Consistency polish | mostly ⬜ | `user/src/lib/ui.zig`, `kernel/src/settings.zig`, `kernel/src/driving_award.zig`, `kernel/src/monitor.zig` |
| M27 G17/G18 Startup/shutdown polish | ⬜ blocked | `kernel/src/settings.zig`, `kernel/src/monitor.zig` |

## The bottleneck file

`kernel/src/driving_award.zig` is touched by **both** the G1–G7 compositor work
(claim 4402, in progress) **and** the G8/G12/G13/G26/G27/G29 consistency polish.
These cannot run concurrently. The plan splits them into Phase 1 (no compositor)
and Phase 2 (compositor-owned).

## Parallel streams

### Phase 1 — Four independent streams (start immediately)

```
Stream A: Shell Script Mode    [shell.zig only]
Stream B: File Manager Gates   [file_browser.zig + new gate scripts]
Stream C: Network Offline      [fetch.zig, ping.zig + new gate scripts]
Stream D: UI Consistency       [ui.zig, settings.zig]
```

**No file overlap between any pair.** All four can start today.

### Phase 2 — After Phase 1 lands

```
Stream E: Compositor Final     [driving_award.zig, monitor.zig, input.zig]
Stream F: First-Boot Wizard    [settings_panel.zig]
```

Stream E needs Stream D's `ui.zig` helpers (`show_dialog`, `format_error`).
Stream F needs Stream D's theme seam from G20.

---

## Stream A — Shell Script Mode

**Claim:** 9206 (`docs/claims/9206-m18-t16-m19-p5-script-mode.md`)  
**Branch:** `agent/buffy/m18-t16-scripting` (T16 already in flight) or new agent branch  
**Files:**
- `kernel/src/shell.zig` (sole editor)
- `tools/verify-live-script.sh` (new gate)

**Scope:**
1. **M18 T16** (in progress): Complete the basic scripting mode — `sh script.BIN` reads a
   file of shell commands from FAT and executes line-by-line. Bounded: 64 lines.
   `exit` stops early. Each line is a full shell command (pipes, redirections,
   env vars all work). No loops/conditionals in script mode — straight-line.
2. **M19 P5** (after T16): Build the full script execution path. The P5 card adds:
   - `fn` definitions and `if`/`for`/`while` work inside scripts (they're just
     lines fed through `handle_line`)
   - `exit` builtin stops script execution early
   - Error handling: print line number + error, continue or abort

**Gate:** `tools/verify-live-script.sh`
- Create a small `.BIN` script file on the ESP (via `write` command)
- `sh script.BIN` executes all lines
- Script with `exit` mid-way stops early
- Pipes/redirections work inside scripts
- Script with error prints line number

**ABI:** Zero new slots. Pure BSS shell state.

**Depends on:** Nothing — fully independent of B/C/D.

---

## Stream B — File Manager Live Gates

**Claim:** 2713 (`docs/claims/2713-m25-file-manager-live-gates.md`)  
**Branch:** New agent branch  
**Files:**
- `user/src/file_browser.zig` (read-only except for serial marker fixes)
- `tools/verify-live-filemanager-trash.sh` (new)
- `tools/verify-live-filemanager-split.sh` (new)
- `tools/verify-live-filemanager-rename.sh` (new)
- `tools/verify-live-filemanager-favorites.sh` (new)
- `tools/verify-live-filemanager-search.sh` (new)

**Scope:**
Write class-B VZ live gates proving these existing-but-ungated cards work on
real hardware. The code is already in `file_browser.zig` and passes host unit
tests (79/79 suite). This stream writes the gate scripts and flips march rows.

| Card | Gate script | What it proves |
|------|-------------|----------------|
| F6 Trash & restore | `verify-live-filemanager-trash.sh` | Delete moves to `.trash/`, `u` restores |
| F7 Batch rename | `verify-live-filemanager-rename.sh` | Ctrl+Shift+R prefix rename |
| F8 Split panes | `verify-live-filemanager-split.sh` | Ctrl+\ dual view, Tab switches |
| F9 Favorites | `verify-live-filemanager-favorites.sh` | Ctrl+D bookmark, Ctrl+B list |
| F10 File search | `verify-live-filemanager-search.sh` | Live filter bar |
| F12 Hidden files | `verify-live-filemanager-hidden.sh` | Ctrl+H toggle |
| F13 Associations | (covered by existing open-with gate) | |
| F14 Terminal here | (covered by existing terminal-here gate) | |
| F15 Editor here | (covered by existing editor-here gate) | |
| F16 Path copy | (covered by existing clipboard gate) | |
| F17 Overwrite check | (covered by existing mkdir gate) | |
| F18 Delete UX | (covered by existing bulk-delete gate) | |

**Gate pattern:** Each gate drives the card through the `--cvc-input` virtio
queue (HID keyboard events), asserts serial markers, and optionally checks
the scanout via `--cvc-snap`. Follow the `verify-live-filemanager-bulk.sh`
pattern exactly.

**ABI:** Zero new slots. All userland.

**Depends on:** Nothing — fully independent.

---

## Stream C — Network Offline Handling

**Claim:** 8460 (`docs/claims/8460-m26-network-offline-handling.md`)  
**Branch:** New agent branch  
**Files:**
- `user/src/fetch.zig`
- `user/src/ping.zig`
- `tools/verify-live-n13-offline.sh` (new)

**Scope:**

**N13 — Network-aware app status:**
Add a pre-flight check to `fetch` and `ping` that reads the kernel's network
state (IP set? link up? DHCP bound?) before attempting connection. If offline,
print a clear message and exit immediately instead of hanging on a connect
timeout. The kernel already exposes this via `net` monitor commands — the
userland apps need to query it.

Implementation approach: new `net_check_status()` helper in a shared
`user/src/lib/netstatus.zig` that reads a small kernel struct via an existing
syscall seam (or the `net` command output). Both `fetch.zig` and `ping.zig`
call it before their connect loop.

**N14 — Offline state handling:**
The bounded M5 connect/send error paths already prevent hangs. N14 makes the
*messages* user-friendly:
- `ping: offline — no network link detected`
- `fetch: offline — no IP address assigned (try: net dhcp)`
- `ping: host unreachable — no route to 10.0.0.2`
- `fetch: DNS resolution failed for example.com`

**Gate:** `tools/verify-live-n13-offline.sh`
- Boot with `--net` (DHCP active) — both apps work normally
- Boot with `--net-offline` (or equivalent no-network flag) — both apps
  print the offline message and exit 1 within 1 second (no 30s timeout)

**ABI:** Zero new slots. Pure userland.

**Depends on:** Nothing — fully independent.

---

## Stream D — UI Consistency Polish

**Claim:** 9180 (`docs/claims/9180-m27-ui-consistency-polish.md`)  
**Branch:** New agent branch  
**Files:**
- `user/src/lib/ui.zig`
- `kernel/src/settings.zig`

**Scope:**

**G9 — Consistent menu structure:** Standardize `menu_build()` across all apps.
Define a canonical menu ordering (File, Edit, View, Help) with consistent
shortcut labels. No app-specific deviations.

**G10 — Consistent dialog style:** New `ui.show_dialog(title, body, buttons)`
that every app uses for confirmations, errors, and prompts. Replaces the
ad-hoc per-app dialog code. Returns a button index.

**G14 — Button states:** `ui.ButtonState` enum (normal, hovered, pressed,
disabled). All buttons render with the correct visual state based on pointer
and focus position.

**G20 — Theme consistency:** `settings.zig` owns `theme_id`. New
`settings.get_theme_colors()` returns the active palette. Apps call this
instead of hardcoding colors. Theme ID persisted to SETTINGS.TXT.

**G21 — Font consistency:** `settings.zig` owns `font_size`. New
`settings.get_font_size()` returns the current size. Apps call this instead
of hardcoding. Font size persisted to SETTINGS.TXT.

**G22 — Polished empty states:** New `ui.draw_empty_state(ctx, message,
icon_char)` — centered text + icon for empty file lists, empty editor
buffers, empty search results. Three named surfaces:
- FILE.BIN empty directory
- EDIT.BIN new empty buffer
- NOTEPAD search no results

**G23 — Polished error states:** New `ui.format_error(buf, code, context)`
— human-readable error strings with context. Adopted in FILE.BIN (file
operation errors) and EDIT.BIN (save failures).

**Gate:** Host unit tests for `ui.zig` dialog builder, button state machine,
error/empty state formatting. `zig test user/src/lib/ui.zig` and
`zig test kernel/src/settings.zig`.

**ABI:** Zero new slots. Pure UI toolkit + settings persistence.

**Depends on:** Nothing — fully independent of A/B/C.

---

## Phase 2 streams (after Phase 1)

### Stream E — Compositor + Desktop Final

**Depends on:** Stream D (needs `show_dialog`, `format_error` from `ui.zig`).
Also depends on claim 4402 (G1–G7) completing its sweep of `driving_award.zig`.

**Scope:** G17 (startup behavior), G18 (shutdown polish), G27 (screenshot),
G28 (help system), G29 (keyboard shortcut reference), G8 (shortcut table),
G12 (drag/drop cursor), G13 (focus behavior), G26 (keyboard navigation).

**Files:** `kernel/src/driving_award.zig`, `kernel/src/monitor.zig`,
`kernel/src/input.zig`.

### Stream F — First-Boot Wizard

**Depends on:** Stream D (needs theme seam from G20).

**Scope:** M27 G2 — first-boot wizard in the settings panel: language
selection, theme picker, timezone setup. Shows on first boot, writes
SETTINGS.TXT, hides on subsequent boots.

**Files:** `user/src/settings_panel.zig` (sole editor).

---

## ABI budget

| Slot | Consumer | Status |
|------|----------|--------|
| 56/57 | M19 P1 pipes | ✅ consumed |
| 58 | M20 U1 font size | ✅ consumed |
| 59–60 | M22 reserved | ✅ consumed |
| 61 | M21 W12 win title | ✅ consumed |
| 62 | M26 N2 net stats | ✅ consumed |
| 63 | (unused) | Available |

**Streams A–D consume zero new slots.** All work is pure userland or BSS state.

---

## How to dispatch

1. **Agent picks a stream** (A, B, C, or D).
2. **Creates a worktree** via `just new-agent <name> <slug>`.
3. **Claims the work** by copying the claim file and flipping status to
   `🔄 <branch>`.
4. **Works the stream**, committing with evidence under `artifacts/`.
5. **Opens a PR** against `main` when done.
6. After merge, Phase 2 streams (E, F) can start.

Multiple agents can spin up right now — all four Phase 1 streams touch
completely disjoint files.
