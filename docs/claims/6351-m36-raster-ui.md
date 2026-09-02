# Claim: M36 Raster Graphics Engine & UI Toolkit Integration for Issue #821

- **Owner:** antigravity (`agent/antigravity/raster-graphics-ui`)
- **Prompt / plan:** `docs/claims/6351-m36-raster-ui.md`
- **Scope:** Milestone 23 (M36: #822 IMG1, #823 IMG2, #824 IMG3, #825 IMG4 UI toolkit portion) & Issue #821 UI raster elements
- **Touches:** docs/claims/6351-m36-raster-ui.md, docs/logs/agent-antigravity-raster-graphics-ui.md, tests/fixtures/deflate/*, tests/fixtures/png/*, tests/fixtures/qoi/*, tests/fixtures/zlib/*, tools/png2qoi.py, user/src/lib/crc32.zig, user/src/lib/fixtures/*, user/src/lib/flate.zig, user/src/lib/image.zig, user/src/lib/png.zig, user/src/lib/qoi.zig, user/src/lib/sexiburger.zig, user/src/lib/ui.zig
- **Depends on:** —
- **Heartbeat:** 2026-09-02
- **Status:** ✅ agent/antigravity/raster-graphics-ui

## Notes

Delivers the core raster graphics engine for VirelaiOS:
1. Core `Image` abstraction, alpha blitting math, and freestanding zero-heap QOI decoder (`image.zig`, `qoi.zig`, `tools/png2qoi.py`, tests).
2. Freestanding bounded RFC 1951 DEFLATE inflator with RFC 1950 zlib wrapper support and Adler-32 verification (`flate.zig`, tests).
3. Conforming 8-bit PNG decoder supporting all 5 filter types and Truecolor RGB/RGBA/Grayscale (`png.zig`, `crc32.zig`, format dispatch in `image.zig`, tests).
4. UI toolkit image blitting and scaling primitives (`ui.draw_image`, `ui.draw_image_scaled`) in `user/src/lib/ui.zig` using `win_fill_batched`.
5. Enables raster UI elements (icons, mascot emblems) for Issue #821 (Sexiburger God Menu, tab chrome, and visual cohesion) while deferring standalone desktop viewer apps (`VIEW.BIN`).
