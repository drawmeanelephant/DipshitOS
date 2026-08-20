# Log — `agent/buffy/m15-c4-dock`

### 2026-08-20 — claim 9697

Claimed. C4 dock — 24 px left dock `Kind.dock` id 253, topmost `wallpaper < taskbar < dock < tray < user windows`, click launches via `sys_exec` slot 28 or raises, `image/apps.txt` `dock=true` flag per row, hit-test `x<24` vs wallpaper `x>=24`, workspaces-visibility locked. Pure compositor, no new ABI, stacks on C3.


### 2026-08-20 — claim 9697 done

Implemented. `driving_award.zig` `Kind.dock` + `dock_*` BSS (24 px bar) + `arm` dock window 253 (5 fixed total, `max_windows` 8→9) + `paint` dock bar (5 icons c/n/t/b/s) + `pointer_tick` dock click launch/raise + `image/apps.txt` `dock=true` (5 apps) + `desktop.zig:27` `AppEntry.dock` + `parse_manifest` 4-field. Fixed `arm`/`user_open`/`user_query`/`resources`/`syscall` win_count/q.z tests for new fixed count, `verify-unit-tests` PASS, `verify-bss-budget` PASS.
