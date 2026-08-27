# Claim: M27 UI consistency polish (G9/G10/G14/G20/G21/G22/G23)

- **Owner:** buffy (`agent/buffy/input-poll-563`)
- **Prompt / plan:** `docs/parallel-dispatch-plan.md` Stream D
- **Scope:** M27 G9 (consistent menus), G10 (consistent dialogs), G14 (button states), G20 (theme consistency), G21 (font consistency), G22 (empty states), G23 (error states)
- **Touches:** `user/src/lib/ui.zig`, `kernel/src/settings.zig`
- **Depends on:** — (nothing)
- **Heartbeat:** 2026-08-27
- **Status:** ⬜ unclaimed

## Scope detail

This stream builds the **UI toolkit foundation** that Phase 2 streams
(compositor polish, first-boot wizard) depend on. All work is in `ui.zig`
and `settings.zig` — no compositor touch.

### G9 — Consistent menu structure

Standardize `ui.menu_build()` across all apps. Define a canonical menu
ordering:
```
File  |  Edit  |  View  |  Help
```
With consistent shortcut labels (Ctrl+S save, Ctrl+O open, Ctrl+Q quit,
Ctrl+Z undo, Ctrl+F find, Ctrl+H help). Apps that currently have
ad-hoc menus switch to the canonical builder.

**Scope:** `ui.zig` `menu_build()` + update callers in NOTEPAD, CALC,
FILE.BIN, EDIT.BIN to use the canonical form.

### G10 — Consistent dialog style

New `ui.DialogResult` enum and `ui.show_dialog()`:
```zig
pub const DialogResult = enum { button_0, button_1, button_2 };

pub fn show_dialog(
    ctx: *DrawContext,
    title: []const u8,
    body: []const u8,
    buttons: []const []const u8,  // max 3
) DialogResult { ... }
```

Replaces ad-hoc dialog code in:
- EDIT.BIN close confirmation (E16)
- FILE.BIN delete confirmation (F18)
- FILE.BIN directory create prompt (F3)
- Any future G15 dangerous-action confirmations

**Scope:** `ui.zig` dialog builder + migrate existing callers.

### G14 — Button states

New `ui.ButtonState` enum:
```zig
pub const ButtonState = enum { normal, hovered, pressed, disabled };
```

All buttons in the toolkit render with the correct visual state based on:
- Pointer position (hovered = cursor inside hit rect)
- Pointer button state (pressed = left button down inside hit rect)
- Focus state (keyboard navigation)

**Scope:** `ui.zig` button rendering + state tracking.

### G20 — Theme consistency

`settings.zig` owns `theme_id` (u8: 0=dark, 1=light, 2=amber).
New:
```zig
pub const ThemeColors = struct {
    bg: u32,
    fg: u32,
    accent: u32,
    border: u32,
    title_bg: u32,
    title_fg: u32,
    error: u32,
    success: u32,
};

pub fn get_theme_colors() ThemeColors { ... }
```

Apps call `settings.get_theme_colors()` instead of hardcoding `0x000000`,
`0xFFFFFF`, etc. Theme ID persisted to SETTINGS.TXT.

**Scope:** `settings.zig` theme API + migrate callers in `ui.zig` and
`driving_award.zig` (the paint calls only — no compositor logic change).

### G21 — Font consistency

`settings.zig` owns `font_size` (u8: 0=8x8, 1=16x16, 2=24x24).
New:
```zig
pub fn get_font_size() u8 { ... }
pub fn set_font_size(size: u8) void { ... }
```

Apps call `settings.get_font_size()` instead of hardcoding size 0.
Font size persisted to SETTINGS.TXT.

**Scope:** `settings.zig` font API + migrate callers.

### G22 — Polished empty states

New `ui.draw_empty_state()`:
```zig
pub fn draw_empty_state(
    ctx: *DrawContext,
    message: []const u8,
    icon_char: u8,  // e.g. '>' for directory, '.' for file
) void { ... }
```

Renders centered text + icon character in muted color. Adopted in:
- FILE.BIN empty directory listing
- EDIT.BIN new empty buffer
- NOTEPAD search with no results

**Scope:** `ui.zig` empty state renderer + adopt in 3 apps.

### G23 — Polished error states

New `ui.format_error()`:
```zig
pub fn format_error(
    buf: []u8,
    code: i32,
    context: []const u8,
) []const u8 { ... }
```

Maps error codes to human-readable strings:
- `-1` → "Unknown error"
- `-2` → "File not found"
- `-3` → "Permission denied"
- `-4` → "No space left"
- `-5` → "Invalid argument"
- `-6` → "I/O error"
- `-9` → "Already exists"

Adopted in:
- FILE.BIN file operation errors
- EDIT.BIN save failures

**Scope:** `ui.zig` error formatter + adopt in 2 apps.

## Verification

### Host (class A)
- `zig test user/src/lib/ui.zig` — dialog builder, button state, empty
  state, error formatter unit tests
- `zig test kernel/src/settings.zig` — theme/font persistence round-trip
- `zig build` + `zig build image` green
- `zig fmt --check` clean
- `zig build test-console` transcript byte-identical

### Class B (live VZ)
No separate live gate needed for toolkit primitives — these are adopted by
apps that already have their own live gates (NOTEPAD, CALC, FILE.BIN,
EDIT.BIN). The consistency is verified by those apps' existing gates
continuing to pass after the migration.

## Gate shape

Class-A only: host unit tests proving the new `ui.zig` functions work
correctly, plus existing class-B app gates continuing to pass (regression).
