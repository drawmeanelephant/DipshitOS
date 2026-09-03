# Claim: M37 DQ1 — God Menu completion (issue #836)

- **Owner:** t3code (`agent/t3code/dq1-godmenu`)
- **Prompt / plan:** `docs/march-m37-desktop-quality.md` (DQ1 row), issue #836
- **Scope:** DQ1 only — dynamic `/host/APPS.TXT` apps section, live active-app actions via the mailbox seam, real theme/exec effects, full win/tab entries. No tab chrome (DQ2), no tokens (DQ4), no snap (DQ5), no new syscalls.
- **Touches:** docs/claims/5514-dq1-godmenu-completion.md, docs/logs/agent-t3code-dq1-godmenu.md, docs/march-m37-desktop-quality.md, user/src/wnd.zig, user/src/lib/sexiburger.zig, host/vm-runner/Sources/VMRunner/main.swift, tools/verify-live-godmenu-summon.sh
- **Depends on:** Phase 1 (claim 7154) — landed
- **Heartbeat:** 2026-09-03
- **Status:** 🔄 agent/t3code/dq1-godmenu

## Notes

Completes the `WND.BIN` God Menu overlay that Phase 1 skeletonized with
hardcoded sections (`populate_god_menu` / `execute_god_menu_command`,
`user/src/wnd.zig:719-858` @ `719297b`). Slices, in order:

1. Dynamic apps: parse `/host/APPS.TXT` over the M34/HF4 file channel
   (bounded, static caps, fall back to the 4 hardcoded entries on
   missing/malformed manifest).
2. Live active-app actions: focused app's `wm_rpc_kind_register_action`
   registrations surfaced in Section 2 end-to-end (SEXITEST proof).
3. Real effects: `theme` light/dark switch (consume the M36 wallpaper +
   `ui.zig` theme hooks if present, else a WM-owned flag + repaint);
   audit `reboot`/`shutdown`/`about`/`notify`.
4. `win-N` for all window ids + tab entries with real titles.

Verified by host unit tests (populate/dispatch, empty-manifest + no-action
fallbacks) + Class-B live VZ (`Ctrl+Space` → filter → Enter executes;
`verify-live-sexiburger-actions.sh` re-runs green) + `verify-bss-budget.sh`
+ `verify-coordination.sh`.

## Findings (2026-09-03)

- **Parse-cap bug, caught live:** the first cut parsed into a
  `menu_apps_max` (16) buffer, so a 22-entry manifest lost 6 entries incl.
  dock ones past the cutoff (`apps=14` live). Fix: parse into 24
  (desktop's `manifest_max_apps`), select 16 dock-first
  (`select_god_menu_apps`, pure + unit-pinned with a 22-entry fixture).
  Live now reports `apps=16`.
- **Runner needed a `ctrl-space` token** (`hidChord` + `macChord`,
  additive) — no Class-B summon proof is possible without it.
- **New gate `tools/verify-live-godmenu-summon.sh`: PASS 2/2** —
  `apps=16` + `god-menu open` + `exec verb=calc` (CALC window `id=2`
  ready) + `god-menu close`, all Class-B headless.
- **`verify-live-sexiburger-actions.sh`: PASS 1/3 on near-final tree**
  (8/8), then flaky stalls/faults incl. once on stashed `origin/main`
  code — filed as issue #843 (script-phase delivery stalls, near-null
  EL0 aborts, one EL1h abort with `sp=0x0`; host was memory-pressured).
  Not DQ1's scope; DQ1's own gate is green.
- Unit: wnd 103/103, sexiburger 86/86. Build clean. BSS PASS
  (543,656 B headroom). Coordination clean.
