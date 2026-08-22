# Branch log: agent/buffy/m21-compositor

## 2026-08-22 — Buffy (claim 1079)

**Starting M21 compositor work (Lane E).** Pulling latest from main, reading
driving_award.zig (3,617 lines) and input.zig (903 lines) to understand the
existing compositor architecture.

Lane E owns `driving_award.zig` and `input.zig`. M21 cards: W1–W5 (tiling,
master-detail, minimize, workspace alt-tab, notification center). M27 cards:
G1–G7 (boot splash, about dialog, previews, sound, sysmon, tooltips).

Starting with W1–W3 as the foundational window management features, then W4–W5.
All zero new syscall slots — pure compositor geometry and paint.

M20 (font sizes) is a soft dependency — chrome uses existing 8×8 font.
Proceeding now; font dimensions can be adjusted when M20 lands.
