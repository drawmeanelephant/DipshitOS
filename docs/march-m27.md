# Milestone twenty-seven march — desktop polish & completeness (living tracker)

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts. This file holds M27's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

The desktop is feature-complete: windowing, widgets, apps, networking,
audio, clipboard, timers, tiling, workspaces, notifications, and developer
tools. But it doesn't *feel* finished. No boot splash, no about dialog,
no window previews in alt-tab, no sound feedback, no system monitor, and
no tooltips. M27 is the "make it feel right" milestone — not new
capabilities, but polish that turns a collection of features into an OS.

**Zero new syscall slots.** All cards are pure compositor paint, app
development, or audio reuse.

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| G1 | **Boot experience.** Boot splash screen: "DipshitOS" logo (8×8 text art) + version string + "loading…" indicator. Displayed for 2 seconds during kernel init (before shell appears). First-boot wizard: SETTINGS.BIN detects no theme saved → launches a 3-step wizard (select theme: dark/light/amber, select font size, confirm). Persists to SETTINGS.TXT. | ⬜ | — | `kernel/src/main.zig` splash paint (before shell init). `user/src/settings_panel.zig` first-boot wizard. The splash is painted to the framebuffer during the 2-second init delay. The wizard is a `ui.zig` multi-step flow. |
| G2 | **About dialog.** Ctrl+Shift+A opens a centered dialog showing: "DipshitOS", version string, kernel build date, "AArch64 on Apple Virtualization.framework", credits ("built with Zig"), license ("MIT" or whatever). Close button. Uses M17 Dialog widget. | ⬜ | — | `kernel/src/driving_award.zig` + new `user/src/about.zig` (tiny app). The dialog is a `Kind.window` with the about text. The version string comes from a comptime constant in `main.zig`. |
| G3 | **Window previews in alt-tab.** Alt+Tab shows a live mini-preview of each window (current: just icons/labels). Each preview is the window's framebuffer content scaled down to 64×48. The overlay shows 4 windows across with preview + name. | ⬜ | — | `kernel/src/driving_award.zig` composite preview. New BSS: `preview_buffer` (64 × 48 × 4 = 12,288 bytes) for the scaled preview. The scaling is nearest-neighbor (every Nth pixel). The overlay is a special paint mode during the alt-tab hold. |
| G4 | **Sound design.** Audio feedback for common actions: notification ping (short 440Hz beep, 50ms), error beep (880Hz, 100ms), window open (descending tone), window close (ascending tone), copy/paste (click). Uses M15 audio syscalls (sys_audio_play). | ⬜ | — | `kernel/src/driving_award.zig` + `user/src/chime.zig` (extend). PCM waveform generation: sine wave at specified frequency/duration. Comptime waveform tables (440Hz, 880Hz, sweep). The compositor calls the audio play syscall on window events. |
| G5 | **System monitor dashboard.** `sysmon` — a full-screen dashboard showing: CPU usage (from scheduler tick count), memory usage (from `mem` command), disk usage (from FAT), network I/O (from net counters), running processes (from `sys_procs`), uptime. Auto-refresh at 1 Hz. | ⬜ | — | New userland app `user/src/sysmon.zig`. Uses existing syscalls: `sys_procs` (slot 7), window syscalls (slots 12–20). Reads kernel globals for CPU/memory/net stats via monitor commands. Full-window layout with labeled sections. |
| G6 | **Tooltip system.** Hover over UI elements for 1 second → tooltip appears with description text. Bounded: 32-char string per tooltip. Tooltips appear below the cursor, offset by 4px. Disappear on mouse move. | ⬜ | — | `kernel/src/driving_award.zig` tooltip timer + paint. New BSS: `tooltip_timer`, `tooltip_x/y`, `tooltip_text[32]`, `tooltip_visible`. The compositor checks hover duration during pointer_tick. Tooltip is a small `Kind.window` painted above all windows. |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Compositor polish** | `kernel/src/driving_award.zig` for G1 (splash), G3 (previews), G6 (tooltips). `kernel/src/main.zig` for splash timing. | M20 done (font sizes for splash/preview). |
| **B — Apps & dialog** | `user/src/about.zig` (new) + `kernel/src/driving_award.zig` for G2 (about). `user/src/settings_panel.zig` for G1 wizard. | M17 done (Dialog widget for about). |
| **C — Audio & monitor** | `kernel/src/driving_award.zig` + `user/src/chime.zig` for G4 (sounds). `user/src/sysmon.zig` (new) for G5 (dashboard). | M15 done (audio syscalls). M18 done (scrollback for sysmon output). |

## Notes

1. **ABI budget:** Zero new syscall slots.
2. **BSS budget:** Preview buffer ~12 KiB. Tooltip state ~48 bytes.
   Sound waveform tables ~1 KiB (comptime, not BSS). Sysmon dashboard
   ~256 bytes. Total M27 BSS delta: ~12.4 KiB.
3. **Gate shape:** G1: `verify-live-boot-splash.sh` — splash text observed
   in framebuffer. G2: `verify-live-about.sh` — about dialog opens. G3:
   `verify-live-alttab-preview.sh` — preview thumbnails visible. G4:
   `verify-live-sound.sh` — audio feedback observed via serial. G5:
   `verify-live-sysmon.sh` — dashboard output. G6:
   `verify-live-tooltip.sh` — tooltip appears on hover.
4. **Splash timing:** The splash is painted during the kernel's 2-second
   init delay (before the shell prompt appears). This is a cosmetic overlay —
   the kernel is still initializing underneath. The splash disappears when
   the shell prompt is ready.
5. **Scope exclusions:** No accessibility (screen reader, high contrast
   beyond theme). No localization (English only). No remote desktop. No
   system tray extensions. No lock screen. This is polish, not a platform
   rewrite.
