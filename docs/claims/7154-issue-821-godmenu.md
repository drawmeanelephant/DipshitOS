# Claim: Global Sexiburger God Menu in WND.BIN (Issue #821 Phase 1)

- **Owner:** antigravity (`agent/antigravity/desktop-quality-821`)
- **Prompt / plan:** `docs/claims/7154-issue-821-godmenu.md`
- **Scope:** Issue #821 Phase 1 (Global Sexiburger God Menu in WND.BIN, Ctrl+Space chord, dynamic 6-section population, and raster mascot emblem)
- **Touches:** docs/claims/7154-issue-821-godmenu.md, docs/logs/agent-antigravity-desktop-quality-821.md, user/src/lib/sexiburger.zig, user/src/wnd.zig
- **Depends on:** —
- **Heartbeat:** 2026-09-02
- **Status:** ✅ agent/antigravity/desktop-quality-821

## Notes

Delivers Phase 1 of Issue #821 (Desktop & Interface Quality Pass):
1. Binds global `Ctrl+Space` chord in `WND.BIN` to summon `SexiburgerMenu` as a centered floating command palette overlay.
2. Dynamically populates the 6 invariant sections (System, active app IPC actions, open windows & tabs, APPS.TXT applications, quick tools, theme/mascot).
3. Renders the Sexipus mascot emblem using our new raster graphics engine.
4. Executes actions on Enter (window focus/raise, app exec, theme toggle, system actions) and dismisses cleanly.
