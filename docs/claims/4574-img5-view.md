# Claim: IMG5 — VIEW.BIN image viewer app with pan & zoom

- **Owner:** buffy (`agent/buffy/img5-view`)
- **Prompt / plan:** Freebuff session, issue #826 (M36 IMG5)
- **Scope:** M36 Raster Graphics — the VIEW.BIN userland image viewer: argv file
  path, `image.decode()` load, aspect-ratio window (clamped to the user
  back-buffer bounds), zoom (keys `+`/`-`/`0`, scroll wheel) and pan (arrow
  keys, click-drag when zoomed), title bar with filename/dims/format/zoom,
  `zig build view` step, APPS.TXT row, live gate
  `tools/verify-live-image-viewer.sh`.
- **Touches:** user/src/view.zig, build.zig, image/apps.txt, tools/verify-live-image-viewer.sh, docs/claims/4574-img5-view.md, docs/logs/agent-buffy-img5-view.md
- **Depends on:** IMG1 `user/src/lib/image.zig` + IMG4 `ui.draw_image` (both landed in PR #827 on main)
- **Heartbeat:** 2026-09-02
- **Status:** 🔄 in progress (`agent/buffy/img5-view`)

## Notes

Per issue #826: exec `VIEW.BIN <path>` (e.g. `/host/PHOTO.QOI`); no-args opens
an empty state. Decode via `image.decode()` (QOI + PNG), render through the
IMG4 toolkit blits (`draw_image` / `draw_image_clipped` / `draw_image_scaled`
with nearest-neighbor scale). Window sized to the image aspect ratio clamped
to `user_buf_w=512` × `user_buf_h=424`. Verification: class-A `zig build view`
+ host unit tests, then the class-B VZ live gate asserting viewer markers and
a clean window. Kernel changes are explicitly out of scope — sys_exec takes no
args, so the live gate drives the shell's `exec VIEW.BIN <path>` path
(max 9 args, already supported).
