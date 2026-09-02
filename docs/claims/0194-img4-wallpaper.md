# Claim 0194: Toolkit draw_image alpha blit & WND.BIN desktop wallpaper & window open crash fix

- **Owner:** antigravity (`agent/antigravity/img4-wallpaper`)
- **Prompt / plan:** `docs/claims/0194-img4-wallpaper.md`
- **Scope:** M33 raster graphics (IMG4) + issue #730 WM crash fix
- **Touches:** assets/mascot.png, assets/wallpaper.png, image/WALLPAPER.QOI, tools/lib/gate-run.sh, user/src/lib/ui.zig, user/src/wnd.zig, tools/verify-live-wallpaper.sh, tools/verify-live-wnd4-chrome.sh, docs/claims/0194-img4-wallpaper.md, docs/logs/agent-antigravity-img4-wallpaper.md
- **Depends on:** —
- **Heartbeat:** 2026-09-02
- **Status:** ✅ agent/antigravity/img4-wallpaper

## Notes

1. Issue #825 (IMG4):
   - Enhance userland UI toolkit (`user/src/lib/ui.zig`) with window backing buffer support and Porter-Duff source-over alpha blending (`draw_image`, `draw_image_scaled`) with clipping bounds.
   - Extend `WND.BIN` (`user/src/wnd.zig`) to probe `/host/WALLPAPER.QOI` and `/host/WALLPAPER.PNG` at startup, decode into background buffer, map scanout surface (`m33_surf_scan_tag | m33_map_shared`), and composite the desktop backdrop during presents while preserving dock, taskbar, and active windows.
   - New Class-B hardware gate `tools/verify-live-wallpaper.sh` verifying wallpaper pixels on scanout.

2. Issue #730:
   - Fix uninitialized `mirrors` state in `user/src/wnd.zig` and clean struct initialization in `wm_window_kind` on window open.
   - Fix metrics parsing guard in `tools/verify-live-wnd4-chrome.sh:122` defaulting empty `$SUBS` and `$POL`.
