# Desktop quality pass (M37 proposal) — scoping sketch and gated card split

Status: **DRAFT 2026-09-03** · Umbrella: **issue #821** (no milestone) ·
Proposed: **GH milestone 24 / M37** · Phase 1 landed: **claim 7154** (`1d80f50`)
Derived from: M19 Sexiburger seam (#677, #701/#705 tab model #782), M32 WM
server (`user/src/wnd.zig`, `kernel/src/wnd_core.zig` drift guard), M34 host
file channel (`/host/APPS.TXT`), M36 raster engine (QOI/mascot/wallpaper).

> This document turns issue #821 — four workstreams stapled into one card —
> into a concrete, gated, milestone-shaped proposal. It is NOT a commitment
> to start — it is the seed. Phase 1 proved the split works: one ~400-line
> overlay PR, own gate slice, no collisions.

## The one-line pitch

Finish what M19 started and M32/M36 unlocked: **one global God Menu, real tab
chrome, one design-token look, snap previews** — five small cards, each with
its own unit + Class-B live gate, instead of one unreviewable mega-PR.

## Why this composes with everything

- **Phase 1 is the beachhead.** `WND.BIN` already summons `SexiburgerMenu`
  on `Ctrl+Space`, filters, executes, and draws the mascot (`populate_god_menu`,
  `toggle_god_menu`, `execute_god_menu_command` in `user/src/wnd.zig:719-858`).
  What remains is *completion*, not invention: dynamic app discovery, real
  active-app actions, real theme/exec effects.
- **The pure rules already exist.** `kernel/src/wnd_core.zig` carries
  `tab_bar_height`/`tab_item_rect` (:479-507), `snap_zone_for_point`/`snap_zone_bounds`
  (:215-242), and the 40-byte chrome descriptor + parity policy (:308-442).
  Cards DQ2/DQ5 wire these into pixels and previews — no new ABI unless a
  card proves it needs one (new `chrome_*` kind bits are the only candidate,
  and only DQ2 may propose them).
- **Zero new syscall slots by default.** Like M33/M35: EL0 + `sys_wmctl`
  (slot 65) + mailbox seam only. Any new slot-65 subcommand needs its card's
  justification section filled in.
- **One editor per file at a time** (`AGENTS.md`): DQ1 owns `wnd.zig` god-menu
  fns, DQ2/DQ3 own `wnd_core.zig` + WND blit/input halves in sequence (DQ3
  after DQ2), DQ4 owns `lib/ui.zig` + per-app call sites, DQ5 owns the
  drag/preview path. The card table pins this so parallel agents never collide.

## What Phase 1 left on the table (observed, not inferred)

Read at `user/src/wnd.zig:719-826` on `21bee43`:

1. Apps section is **4 hardcoded entries** (NOTEPAD/CALC/FILE/DEVCONS) —
   issue asks for dynamic `/host/APPS.TXT` discovery (M34/HF4 file channel).
2. Active-app section falls back to **placeholder Save/Find** when no
   `app_actions[]` are registered — the `wm_rpc_kind_register_action`
   mailbox seam exists but no live app drives it end-to-end through the menu.
3. `theme` verb prints a marker (`wnd: theme toggled`) — **no real
   light/dark switch**; `reboot`/`shutdown`/`about`/`notify` are wired, the
   rest are markers.
4. `win-N` single-char parse only handles ids 2–5, labels are `Window {d}
   (Active)` — no tab titles, no search-and-switch over tabs.
5. Tab chrome: **zero pixels** — `tab_item_rect` has no blit caller in
   `WND.BIN`; `EDIT.BIN` has its own in-app tab bar (`edit.zig:38,1995`)
   but windows have no WM-drawn strip, no hover/`×`, no click-switch,
   no drag-detach.
6. Snap: `snap_zone_*` pure rules exist; **no drag preview outline** on
   the desktop path (WMS5 snap-on-drop issues rects silently).

## The cards, in order

> **DQ1 close-out → DQ2 render → DQ3 interact → DQ4 tokens → DQ5 preview.**
> Render before interact (hit-test needs the layout); tokens and preview ride
> on top independently once DQ2 lands; DQ1 can land any time (owns only the
> god-menu fns).

| DQ# | Card | Depends on | Touches (exclusive) | Gate |
|----:|------|------------|---------------------|------|
| DQ1 | **God Menu completion** — dynamic `APPS.TXT` apps, live active-app actions via mailbox seam, real theme/exec effects, `win-N` for all ids + tab entries | — (Phase 1) | `user/src/wnd.zig` god-menu fns (`populate`/`execute`), `user/src/lib/sexiburger.zig` | unit (populate/dispatch) + Class-B: `Ctrl+Space` summon → filter → Enter executes (exec/focus/theme), SEXITEST action appears in Section 2 live |
| DQ2 | **Tab-bar chrome render** — WM-drawn strip via `tab_item_rect`: titles + truncation, active highlight, hover, `×`; optional new `chrome_*` kind bits if parity policy needs them | DQ1 (god-menu fns stable) or parallel with care | `kernel/src/wnd_core.zig` (layout/hit-test pure fns + tests), WND blit half of `user/src/wnd.zig` | unit (layout/truncation/hit-test) + Class-B screenshot/shape: attached tabs render strip, active tab highlighted |
| DQ3 | **Tab mouse interaction** — click switch via `activate_tab`/`sys_wmctl` cmd 20, `×` close, drag-to-detach → standalone window | DQ2 (needs the strip + hit-test) | WND input half of `user/src/wnd.zig` (pointer routing), `wnd_core` detach rule if needed | unit (hit dispatch) + Class-B headless pointer injection (claim-9367 pattern): click switches tab, `×` closes, drag detaches |
| DQ4 | **Design tokens & cohesion** — unify padding/borders/focus/hover-press in `lib/ui.zig`; window borders/shadows for z-contrast; cursor glyphs (I-beam/pointer/resize); roll out across NOTEPAD/CALC/EDIT/FILE/SYSMON/DEVCONS | DQ2 (chrome look must be settled first) | `user/src/lib/ui.zig`, per-app call sites (one app per commit) | unit (token values) + Class-B: light+dark screenshots, cursor states observable |
| DQ5 | **Snap guides** — semi-transparent half/full-screen preview outline when dragging near edges, using `snap_zone_*`; release commits (existing WMS5 path) | DQ2 (rect math settled) | WND drag path in `user/src/wnd.zig`, preview blit | unit (zone→preview rect) + Class-B pointer-drag: near-edge shows outline, release snaps |

Hard edges: DQ2 before DQ3 (can't click what isn't drawn + hit-tested).
DQ2 before DQ4/DQ5 (look and rect math must be pinned first). DQ1 independent
— land it first to close out Phase 1 and free `wnd.zig`.

## Out of scope

- New syscalls or slots (default no; DQ2's chrome bits are the only named
  candidate and must justify).
- Kernel WM policy growth (WMS8 direction holds — WM decides, kernel clamps).
- Full theme engine (DQ1/DQ4: light/dark tokens only, no per-app theming API).
- Touch gestures, multi-monitor, animation framework.

## Verification spine

- Per-card host unit tests in the touched file (`wnd_core`, `ui`,
  `sexiburger`, `wnd` god-menu fns).
- Per-card Class-B live VZ slice; the umbrella gate is #821's own plan:
  global `Ctrl+Space` summon + exec, mouse tab switch — split across
  DQ1 (keyboard/exec) and DQ3 (pointer).
- `verify-bss-budget.sh` + `verify-coordination.sh` per card (god-menu
  BSS, mascot pixels, and per-app growth all count).
