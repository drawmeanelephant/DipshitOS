# Claim: Micro-widget toolkit & runtime (`user/src/lib/ui.zig`)

- **Owner:** buffy (`agent/buffy/m11-a1-ui-toolkit`)
- **Prompt / plan:** `docs/march-m11.md` card A1
- **Scope:** `user/src/lib/ui.zig`, `user/src/lib/font8x8.zig`, `docs/claims/8155-a1-micro-widget-toolkit.md`, `docs/logs/agent-buffy-m11-a1-ui-toolkit.md`
- **Depends on:** `docs/claims/0664-a0-architecture-ui-contract.md`
- **Status:** ✅ done

## Notes

Implements **Card A1 (Micro-Widget Toolkit & Runtime)**:
1. `user/src/lib/font8x8.zig`: Monochrome 8×8 bitmap font table for userland text rendering.
2. `user/src/lib/ui.zig`: Lightweight zero-heap GUI library providing `Rect`, `Button` (idle/hover/pressed states), `Label`, `TextInput` (with cursor and buffer management), `ListView` (with selectable rows), drawing and text rasterization helpers, and `App` event loop runtime.
3. Class A host unit test suite covering geometry arithmetic, hit-testing, widget state transitions, and text editing operations.
