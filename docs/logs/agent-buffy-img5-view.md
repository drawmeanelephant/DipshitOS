# Log: agent/buffy/img5-view

- **2026-09-02** — *buffy (agent/buffy/img5-view)*: Claimed IMG5 (issue #826,
  M36) — VIEW.BIN image viewer with pan & zoom. Dependencies IMG1 (image.zig)
  and IMG4 (draw_image) landed in PR #827 on main; worktree reattached to
  fresh origin/main (98a5478). Plan: new `user/src/view.zig`, `zig build view`
  step, APPS.TXT row, live gate `tools/verify-live-image-viewer.sh`. No
  kernel changes planned.
