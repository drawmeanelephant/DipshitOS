# Log — Micro-widget toolkit & runtime

## Context

- **Goal:** Implement the zero-heap micro-widget toolkit and runtime library in `user/src/lib/ui.zig` and `user/src/lib/font8x8.zig` for Milestone 11 applications.
- **Claim:** [`docs/claims/8155-a1-micro-widget-toolkit.md`](../claims/8155-a1-micro-widget-toolkit.md)

## Entries

### 2026-08-15: Initialized and completed Card A1 implementation (claim 8155)

- Created `user/src/lib/font8x8.zig` with the 8×8 monochrome bitmap font table and FNV-1a fingerprint test.
- Implemented `user/src/lib/ui.zig` containing:
  - System call wrappers (windows, events, processes, storage)
  - Color palette tokens conforming to ADR 0008 and ADR 0011
  - `Rect` geometry and hit-testing helpers
  - Text and primitive rasterizers (`draw_char`, `draw_text`, `draw_rect`, `draw_rect_outline`)
  - `Button`, `Label`, `TextInput`, and `ListView` micro-widgets
- Added Class A host unit tests covering geometry, button click detection, text entry/backspace, and list view selection; all unit tests pass green.
- Flipped claim 8155 to ✅ done and updated `docs/march-m11.md`.
