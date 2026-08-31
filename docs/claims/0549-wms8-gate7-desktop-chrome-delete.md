# Claim: WMS8 Gate 7 — desktop-chrome click decisions deleted

- **Owner:** buffy (`agent/buffy/wms8-gate7-dead-blocks`)
- **Prompt / plan:** `docs/march-m32-wm-migration.md` (WMS8 card, issue #628)
- **Scope:** M32 WMS8 Gate 7 — delete the kernel shim's dormant desktop-chrome click decision blocks
- **Touches:** kernel/src/driving_award.zig docs/claims/0549-wms8-gate7-desktop-chrome-delete.md docs/logs/agent-buffy-wms8-gate7-dead-blocks.md docs/march-m32-wm-migration.md
- **Depends on:** WMS6 Gates B and D (tray/notif and dock parity-proven with the WM registered)
- **Heartbeat:** 2026-08-30
- **Status:** ✅ done

## Notes

WMS8's delete rule: a drained policy block is deleted once its parity gate ran
green with the WM registered. WMS6 Gate B (tray/notif: `wnd: notif-open`,
`wm: notif=1`, kernel did not self-toggle) and Gate D (dock: `wnd: dock idx=0`,
`wm: dock=1`, NOTEPAD restored+focused) both passed on VZ, so the three
`!wm_owns_input`-gated click decision blocks in `pointer_tick` were dormant
whenever a WM is registered:

1. the dock icon click chain (restore-from-dock / open / focus+raise),
2. the tray-clock click → `notif_center_toggle()`,
3. the notification-center panel click handling (dismiss / clear-all).

Deletion only — no rewrite. The applied primitives
(`notif_center_toggle/set_open/dismiss/clear_all`, `restore_from_dock`,
`dock_icon_click`, `notif_center_hit_test`, `tray_rect`) stay: slot-65 cmds 6/7/9
and the `dui` monitor commands drive them, and the panel/blit rendering stays.
Close/minimize buttons, resize, modal blocking, focus-at, and app event
delivery stay (no full WM coverage / not drained).

## Result (2026-08-30)

Deleted the three dormant desktop-chrome click decision blocks from
`pointer_tick` in `kernel/src/driving_award.zig` (~76 lines, deletion only):
the dock icon-grid hit-test chain, the tray-rect click toggle, and the
notification-panel dismiss/clear-all handling. All were `!wm_owns_input`-gated
and their parity gates (WMS6 Gates B and D) were green, satisfying the WMS8
delete rule.

KEPT: applied primitives + panel/blit rendering; close/minimize buttons,
resize, modal blocking, focus-at, focus-follows-mouse, app event delivery.

Shim end-state degradation (intended): with no WM, dock/tray/panel clicks do
nothing.

Verified: `zig build` clean; `zig test kernel/src/driving_award.zig` 212/212;
`zig fmt --check` clean; `verify-coordination.sh` ok; `verify-bss-budget.sh`
PASS (kernel .bss 10848872 / 11534336 B).
