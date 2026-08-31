# Prompt: Arc2 — finish system tray + Arc4/Arc5 follow-ons

Copy-paste this prompt to start the next session.

---

You are working in virelaios at `/Users/tbuddy/dev/t3/virelaios` on `main` after Arc2 W1+W2 landed.

**Current position (2026-08-21, main 19f3d66 + 2 direct commits):**
- **Arc1 widget depth** — done 2026-08-21 (ScrollView 0819, Checkbox/Toggle 2418, ProgressBar/Dialog/HScrollBar 6437/0835/1872) — `main` 3d7f59b.
- **Arc2 W1 drag-to-resize #224** — ✅ done 2026-08-21 — `kernel/src/events.zig:35` kind 10 `WIN_RESIZE`, `kernel/src/syscall.zig:78` slot 47 `sys_win_resize` (48 total), `kernel/src/driving_award.zig:760` 6×6 hit + clamp 128×64..512×384 — merged 44ca7d2/17e7951 — `docs/claims/3589-drag-resize.md` ✅.
- **Arc2 W2 context menus #228** — ✅ done 2026-08-21 — `events.zig:36` kinds 11 `MOUSE_RIGHT_DOWN` + 13 `MOUSE_RIGHT_UP` (12 skipped for SCROLL), `user/src/lib/ui.zig:71` ContextMenu widget + 3 host tests (32/32 ui, 132/132 driving_award), `driving_award.zig:1159` left/right split — landed directly on `main` (no PR, branch confusion resolved) — `docs/claims/1757-context-menu.md` ✅.
- **Arc2 W3 system tray #226** — 🔄 `agent/buffy/arc2-tray` (claim 1264) — compositor-only, no ABI — `Kind.taskbar` id 255 20px @ y=700 right 80px: HH:MM (tick/60%86400), theme D/L/A (accent), clipboard filled/empty rect — `Kind.clock` id 1 deprecated (no duplicate). WIP commit `6795a5d` exists on old branch but conflicts with W1's `driving_award` changes (`arm`/`composite`/`drain`). Needs rebase onto current `main`.

**Next lane — land W3 (GH #226):**
- Re-verify `syscall.zig` still `implemented_count=48` (slot 48 next free) and `events.zig` next free is now 14 (10,11,13 consumed; 12 is SCROLL for #236). W3 needs no new slot/kind.
- Branch from current `main`: `git checkout main && git checkout -b agent/buffy/arc2-tray-next`.
- Implement in `kernel/src/driving_award.zig` only: `tray_w=80`, `tray_x=fb_width-80`, `tray_h=20`, `tray_y=700`, BSS `tray_tick/tray_has_tick/tray_last_theme/tray_last_clip_len` ~32B, helpers `tray_rect()`/`format_hhmm()`/`theme_letter()`/`tray_clipboard_filled()`, `arm()` creates 4 windows (terminal, wallpaper, taskbar, dock) not 5, `paint(.taskbar)` draws HH:MM + D/L/A + clipboard, `composite()`/`drain()` mark taskbar dirty on tick/theme/clip change without timer, keep `Kind.clock` enum for compat but no window.
- Tests: `tray_rect`, `format_hhmm`, `theme_letter`, `clipboard_filled`, tick/dirty, framebuffer — update win_count 5→4 etc. `verify-bss-budget` should stay ~9788088/11534336 (+32B), `verify-coordination` PASS, `zig fmt` PASS.
- See groomed issue: `gh issue view 226 --json body`, ADR 0013 D1/D2 for reservations, `docs/march-arc2.md:19` for W3 row, `docs/claims/1264-system-tray.md` for scope.

**After W3, Arc4 (rich interactions) is parallelizable — all deferred past M17, all need ABI per ADR 0013:**
- #236 mouse wheel — kind 12 `MOUSE_SCROLL`, HID wheel parse, ScrollView/HScrollBar consume.
- #237 drag-and-drop — slot 48 `sys_drag_start`, kinds 14/15/16 `DRAG_ENTER/LEAVE/DROP`.
- #238 lower-to-back — slot 50 `sys_win_lower_back` (slot 49 is raise).
- #239 animations — no ABI, uses `sys_timer_set` slot 40.
- #240 notifications — slot 51 `sys_notify`.
- #241 workspaces — slot 52 `sys_win_move_to_workspace`.
- Each is file-disjoint except `events.zig`/`syscall.zig` reservations — claim with `bash tools/status/claim-id.sh` before start, keep one editor per file (branch isolation), merge in kind/slot order 12→14→15→16.

**Arc5 (system polish) follows:** #242 unsaved, #243 tombstones, #244 graceful shutdown, #245 compose, #246 rlimits, #247 settings migration — see `gh issue list --limit 20` and ADR 0013 D3 budgets.

**Verification for any card:** `zig test kernel/src/driving_award.zig`, `zig test user/src/lib/ui.zig`, `bash tools/verify-bss-budget.sh`, `bash tools/verify-coordination.sh`, `zig fmt --check`.

**Coordination:** claim before start (`docs/claims/TEMPLATE.md` → `docs/claims/NNNN-slug.md`), log in `docs/logs/<branch>.md`, `bash tools/status/refresh-indexes.sh`, never hand-edit `docs/claims/README.md`.

**Reference:** `docs/march-arc2.md` is living tracker, `docs/status.md` is canonical milestone facts, `docs/decisions/0013-post-m14-abi-amendment.md` is slot/kind reservation.
