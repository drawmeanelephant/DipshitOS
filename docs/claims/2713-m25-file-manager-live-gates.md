# Claim: M25 file manager live gates (F6–F18)

- **Owner:** TBD (`<branch>`)
- **Prompt / plan:** `docs/parallel-dispatch-plan.md` Stream B
- **Scope:** Class-B VZ live gates for M25 file manager cards F6–F10, F12–F18. Code already exists and passes host unit tests (79/79 suite); this stream writes live gates and flips march rows to ✅.
- **Touches:** `tools/verify-live-filemanager-trash.sh` (new), `tools/verify-live-filemanager-rename.sh` (new), `tools/verify-live-filemanager-split.sh` (new), `tools/verify-live-filemanager-favorites.sh` (new), `tools/verify-live-filemanager-search.sh` (new), `tools/verify-live-filemanager-hidden.sh` (new), `docs/march-m25.md`, `user/src/file_browser.zig` (serial marker additions only if needed)
- **Depends on:** — (nothing; all code is on main)
- **Heartbeat:** 2026-08-27
- **Status:** ⬜ unclaimed

## Scope detail

The following cards have code on main that passes host unit tests but has no
live VZ evidence. Each gate script follows the established
`verify-live-filemanager-bulk.sh` pattern: `gate-run.sh` boot → scripted
`--cvc-input` HID events → serial marker assertions → clean exit.

| Card | Gate script | What it proves | Serial markers expected |
|------|-------------|----------------|------------------------|
| F6 Trash & restore | `verify-live-filemanager-trash.sh` | Del moves to `.trash/`, `u` restores | `file: trash ok`, `file: restore ok` |
| F7 Batch rename | `verify-live-filemanager-rename.sh` | Ctrl+Shift+R prefix rename on selection | `file: rename ok`, `file: renamed N files` |
| F8 Split panes | `verify-live-filemanager-split.sh` | Ctrl+\ dual view, Tab switches active pane | `file: split on`, `file: pane-switch` |
| F9 Favorites | `verify-live-filemanager-favorites.sh` | Ctrl+D bookmark, Ctrl+B list, click to jump | `file: bookmark ok`, `file: jump-bookmark` |
| F10 File search | `verify-live-filemanager-search.sh` | Live filter bar narrows listing | `file: filter 'TXT' shown=N total=M` |
| F12 Hidden files | `verify-live-filemanager-hidden.sh` | Ctrl+H toggles dotfile visibility | `file: hidden on/off` |
| F14 Terminal here | (verify existing marker if present) | `file: terminal here` | |
| F15 Editor here | (verify existing marker if present) | `file: editor here` | |
| F16 Path copy | (verify clipboard marker) | `clip: set` | |

### Gate engineering notes

- Use the `--cvc-input` virtio queue for all keyboard events (HID chords)
- Use `--screen` + `--cvc-snap` for pixel assertions where needed
- Each gate is self-contained: creates test fixtures, exercises the card,
  asserts markers, cleans up
- Follow `tools/lib/gate-run.sh` for the boot harness
- One gate script per card group (trash+restore together, rename alone, etc.)

## Verification

### Host (class A)
- No new host tests needed (code already passes 79/79)
- Gate script syntax check: `bash -n tools/verify-live-filemanager-*.sh`

### Class B (live VZ)
- Each gate script runs against real VZ hardware
- Gate output saved under `artifacts/` per the evidence policy
- `docs/march-m25.md` rows flipped to ✅ with gate evidence

## Gate shape

Class-B `tools/verify-live-filemanager-<card>.sh` — one per card group,
driving FILE.BIN through the custom-virtio input queue, asserting serial
markers and optionally pixel scanouts.
