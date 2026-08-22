# Active claims (one file per claim)

**Why this exists:** claims used to live in a single table inside
`docs/status.md`. Every agent edited that table to claim work, so parallel
agents collided on the same file (PR #8/#10, then PR #12/#13). Claims are
now **one file per claim**: claiming work means creating a new file, never
editing a shared table.

**The rule is unchanged and still binding** (AGENTS.md): claim **before**
you start. Non-trivial work gets a claim file (and a log entry in
`docs/logs/<branch>.md`) *before* code is written. Unclaimed work is fair
game; claimed work is not.

## Claim numbers (deterministic, collision-resistant)

Claims used to be numbered sequentially ("next NNNN"). That collided when
two agents claimed concurrently: claim 0013 was claimed by serial-discovery
at 10:27 and by status-reverify at 15:18 on the same day, and the loser had
to be manually renumbered to 0014 (commit `be811cb`).

Numbers are now derived from the claim itself, so concurrent claimers pick
different IDs without editing any shared file:

```sh
bash tools/status/claim-id.sh "<branch>" "<slug>"
```

The ID is `0024 + (cksum("<branch>:<slug>") % 9976)` — deterministic,
reproducible on any machine, and always in `[0024, 9999]`. Claims
`0001–0023` are grandfathered sequential numbers; `0024+` is enforced by
`verify-coordination.sh`, which recomputes the ID from each claim file
(owner branch + filename slug) and fails on a mismatch, so a hand-picked
"next" number cannot slip through. If the extremely rare hash collision
happens (same ID from different branch/slug pairs), the duplicate-number
check fails the gate — change the slug and the ID changes.

## How to claim

1. Pick a kebab-case slug for the work and derive the number:
   `bash tools/status/claim-id.sh "<branch>" "<slug>"` → `NNNN`. Copy
   [`TEMPLATE.md`](TEMPLATE.md) to `docs/claims/<NNNN>-<slug>.md`.
2. Fill in Owner (agent id + branch), Prompt / plan, Scope, Depends on.
3. Set Status to `🔄 <branch>` **before** starting work.
4. Run `bash tools/status/refresh-indexes.sh` to regenerate the
   [Active claims index](#active-claims-index) below. The table is
   **generated from the claim files** — never hand-edit it (two agents
   hand-appending to the same table is exactly how parallel claims
   collide on merge).
5. On completion or blockers: flip Status in **your claim file** to `✅`
   (with evidence) or `⛔` (note why), append to `docs/logs/<branch>.md`,
   and re-run the refresh script so the index shows it.

Never edit another agent's claim file. Corrections are new entries in your
own branch's log that reference the old one.

## Active claims index

**This table is the canonical index** (status included) and it is
**generated** from the claim files by `bash tools/status/refresh-indexes.sh`
— do not hand-edit it. `docs/status.md` points here. The coordination
gate (`bash tools/verify-coordination.sh`, `just verify-coordination`, and
CI) fails if the table drifts from the claim files.

<!-- CLAIMS_INDEX:START -->
| Claim | Owner (branch) | Status |
|-------|----------------|--------|
| [0162-logs-cleanup](0162-logs-cleanup.md) | opencode (`t3code/fix-issue-267-git-current`) | ✅ done 2026-08-21 |
| [0163-m18-t5-colors](0163-m18-t5-colors.md) | buffy (`agent/buffy/m18-t5-colors`) | ✅ done 2026-08-22 |
| [0265-top-sort-filter](0265-top-sort-filter.md) | buffy (`agent/buffy/m15-c8-top-sort`) | ✅ done 2026-08-21 — `user/src/top.zig` sortable columns + filtering (`SortColumn pid/name/state/exit`, `compare_procs`, `name_contains` case-insensitive, stable insertion sort on `display_indices`, `filter_input TextInput 260,6,110,20` with label `Filter:`, header hit-test 52..68 click_column toggle ↑/↓, `rebuild_display` filtered+sorted, `handle_mouse_events` header+filter+row (display), `handle_keyboard_event` filter-focused priority + filtered Up/Down, `handle_timer`/`kill_selected` rebuild, `draw` header indicator accent + filtered rows). Host tests 23/23 PASS (8 new: compare, contains, sortable, filter, sort+filter, auto-refresh preserve, header click, row click), `TOP AppState 1352 <4KiB`, `zig build` PASS `TOP.BIN 10526` (+2355B), `verify-bss-budget` PASS `9788088/11534336` headroom `1746248`, `zig fmt --check` PASS. |
| [0469-m18-t16-scripting](0469-m18-t16-scripting.md) | buffy (`agent/buffy/m18-t16-scripting`) | ✅ done 2026-08-22 |
| [0819-scrollview](0819-scrollview.md) | Muse Spark (`agent/buffy/arc1-scrollview`) | 🔄 `agent/buffy/arc1-scrollview` |
| [0835-hscrollbar](0835-hscrollbar.md) | Muse Spark (`agent/buffy/arc1-progressbar`) | ✅ done 2026-08-21 — `user/src/lib/ui.zig` HScrollBar + 4 host tests, `zig test` 29/29, `verify-bss-budget` 9788088/11534336, `verify-coordination` PASS |
| [1264-system-tray](1264-system-tray.md) | Muse Spark (`agent/buffy/arc2-tray`) | ✅ done 2026-08-21 — `kernel/src/driving_award.zig` tray (Kind.taskbar id 255 20px @ y=700 right 80px: HH:MM via `format_hhmm` from tick, theme D/L/A `theme_letter` in `tray_theme_accent`, clipboard filled/empty rect via `tray_clipboard_filled`) + `Kind.clock` id 1 migration (no duplicate window, `arm` 4 windows, `drain`/`composite` tick without timer); `kernel/src/syscall.zig` z/count tests updated (4 base, z=4); host tests 140/140 PASS, `verify-bss-budget` PASS 9788088/11534336, `verify-coordination` PASS — branch `agent/buffy/arc2-tray` (commit 4521ff1) |
| [1601-prune-claims-269](1601-prune-claims-269.md) | t3code (`t3code/prune-claims-269`) | ✅ done 2026-08-21 — moved 178 claim files M3–M16 (incl. early M1.5/M2 diagnostics) from `docs/claims/` (209 files, ~1.2M) to `docs/archive/claims/` (178 files, 1.0M); active `docs/claims/` now 31 files, 176K (README 16K + claims ~160K, `du -sh` 176K) with 6 🔄 audit/M17 + 13 M17 desktop (Arc1/Arc2/C2–C9) + 8 hygiene + 4 planning; updated `docs/claims/README.md` (98 lines, 16K, + Archived section) and `docs/archive/README.md` (claims/ paragraph) and `docs/march-m3/m6/m13.md` links (15 refs) to `archive/claims/`; `bash tools/status/refresh-indexes.sh` and `bash tools/verify-coordination.sh` both PASS |
| [1757-context-menu](1757-context-menu.md) | Muse Spark (`agent/buffy/arc2-context-menu`) | ✅ done 2026-08-21 — right-click live on host: `events.zig` kinds 11 `MOUSE_RIGHT_DOWN` + 13 `MOUSE_RIGHT_UP` (ADR 0013 D2, kind 12 skipped for SCROLL), `user/src/lib/ui.zig` ContextMenu (show/dismiss/bounds/hit-test + 3 host tests) + FILE/NOTEPAD/TOP integration, `kernel/src/driving_award.zig` right-button routing (left/right split, WIN_RESIZE/DRAG gated left-only, `verify-bss-budget` PASS 9788088/11534336, `zig test` ui 32/32, driving_award 132/132, `zig fmt` PASS) |
| [1872-dialog](1872-dialog.md) | Muse Spark (`agent/buffy/arc1-progressbar`) | ✅ done 2026-08-21 — `user/src/lib/ui.zig` Dialog + 3 host tests, `zig test` 29/29, `verify-bss-budget` 9788088/11534336, `verify-coordination` PASS |
| [2203-trim-hardware-contract](2203-trim-hardware-contract.md) | ox-alpha (`agent/ox-alpha/hygiene-trim-hardware-contract`) | ✅ done (`agent/ox-alpha/hygiene-trim-hardware-contract`) |
| [2336-file-inline-preview](2336-file-inline-preview.md) | buffy (`agent/buffy/m15-c7-file-preview`) | ✅ done 2026-08-21 — `user/src/file_browser.zig` inline preview (selection auto-loads `preview_content[512]` first 15 lines, `is_binary_content` ≥80% printable sniff → `(binary)` placeholder for non-TXT/binary, `preview_is_binary` flag) + breadcrumb bar (`breadcrumb_rect 60,6,440,12` muted, `format_breadcrumbs`/`breadcrumb_hit_test`/`truncate_to_segment`, `current_path[64]` session-only, `enter_directory`/`navigate_to_segment`/`breadcrumb_click`, `build_path` helper, `refresh_preview` on select/click/keyboard, `draw_details` preview below metadata) + `HScroll` deferred (preview wraps at `preview_cols 30`, no extra widget). Host tests 25/25 PASS (6 new: binary sniff, breadcrumbs hit-test, build_path, current_path nav, preview auto-load, breadcrumb_click), `zig build` PASS `FILE.BIN 10882` (+24B), `verify-bss-budget` PASS `9788088/11534336` (1746248 B headroom), `zig fmt --check` PASS. |
| [2418-checkbox-toggle](2418-checkbox-toggle.md) | Muse Spark (`agent/buffy/arc1-checkbox-toggle`) | 🔄 `agent/buffy/arc1-checkbox-toggle` |
| [2616-dhcp-lifecycle-autonomous](2616-dhcp-lifecycle-autonomous.md) | buffy (`agent/buffy/audit-followup-3-dhcp-autonomy`) | 🔄 agent/buffy/audit-followup-3-dhcp-autonomy |
| [2762-window-snap-zones](2762-window-snap-zones.md) | buffy (`agent/buffy/m15-c3-snap-zones`) | ✅ done 2026-08-20 — `driving_award.zig:178` snap BSS (`last_rect`/`is_snapped`/`zone` ≈80 B) + `snap_zone_for_point`/`snap_window`/`snap_restore` + `pointer_tick` drag-out restore + `draw_chrome` preview, host tests `snap_zone`/`snap_window`/`preview` PASS, `verify-bss-budget` PASS `9787576/11534336` |
| [2860-trim-roadmap-completed-milestones](2860-trim-roadmap-completed-milestones.md) | t3code (`t3code/fetch-issue-264-details`) | ✅ done 2026-08-21 |
| [2873-alt-tab-cycling-ui](2873-alt-tab-cycling-ui.md) | buffy (`agent/buffy/m15-c2-alt-tab`) | ✅ done 2026-08-20 — `driving_award.zig:168` overlay BSS (32 B) + `input.zig:86` Alt+Shift latch + `shell.zig:191` hold-Alt commit, host tests PASS 125/125 `driving_award`, class-A `verify-bss-budget` PASS `9787576/11534336`, `zig fmt` + `zig build` + `test-console` PASS |
| [3589-drag-resize](3589-drag-resize.md) | Muse Spark (`agent/buffy/arc2-resize`) | ✅ done 2026-08-21 — drag-to-resize live on host (merge 44ca7d2): `driving_award` 6×6 hit + clamped resize + WIN_RESIZE kind 10 + `sys_win_resize` slot 47 (implemented_count 47→48), 4 host tests, `verify-bss-budget` PASS 9788088/11534336, `verify-coordination` PASS — branch `agent/buffy/arc2-resize` merged to `main` (commit 17e7951) |
| [3679-m18-t4-history](3679-m18-t4-history.md) | buffy (`agent/buffy/m18-t4-history`) | ✅ done 2026-08-22 |
| [4429-archive-m5-m6-prompts](4429-archive-m5-m6-prompts.md) | buffy (`agent/buffy/hygiene-archive-m5-m6-prompts`) | ✅ done |
| [4516-archive-ragshit-test-artifacts](4516-archive-ragshit-test-artifacts.md) | oxalpha (`t3code/handle-issue-268-git-current`) | ✅ done |
| [5093-scroll-keys-chords](5093-scroll-keys-chords.md) | buffy (`agent/buffy/m18-t16-scripting`) | ✅ done 2026-08-22 |
| [5227-notepad-wrap-find](5227-notepad-wrap-find.md) | buffy (`agent/buffy/m15-c5c6-notepad`) | ✅ done 2026-08-20 — `user/src/notepad.zig` soft-wrap (`TextLayout` last_space, gutter, `Line X of Y`) + `find_next`/`replace`/`replace_all` (case_sensitive=false) + `AppState` find bar (`find_active`/`find_buf`/`replace_buf`) + `draw` highlight + `handle_keyboard_event` Ctrl+F/H, host tests `soft-wrap`/`find` PASS, `verify-bss-budget` PASS `9788088/11534336` |
| [5301-m24-calc-decompose-k1-k5](5301-m24-calc-decompose-k1-k5.md) | buffy (`agent/buffy/m24-calc-features`) | ✅ done 2026-08-22 — PR #482 |
| [5512-archive-march-m4-m5-trackers](5512-archive-march-m4-m5-trackers.md) | oxalpha (`agent/oxalpha/archive-march-m4-m5`) | ✅ done |
| [5828-trim-gate-inventory](5828-trim-gate-inventory.md) | ox-alpha (`t3code/issue-265-fix`) | ✅ done (2026-08-21) |
| [6204-audit-2026-maintenance](6204-audit-2026-maintenance.md) | maintenance (`agent/maintenance/audit-2026-issues`) | 🔄 agent/maintenance/audit-2026-issues |
| [6215-adr-0013-post-m14-abi-amendment](6215-adr-0013-post-m14-abi-amendment.md) | buffy (`freebuff/can-you-review-issues-223-247-and-try-to-provide-h-f6c8d8a0-9349-4ada-9bca-1705150f0bde`) | ✅ done 2026-08-20 (as **proposed** ADR; the status flips to **accepted** when M14 closes and the first post-M14 claim cites it) — `docs/decisions/0013-post-m14-abi-amendment.md` exists (~18 KiB, ~290 lines), with D1 slot reservation (47–54), D2 event-kind reservation (10–17 with kind-12/13/16 collision resolutions called out by name), D3 BSS budgets + D3.1 observed measurement, D4 ABI contract under reservation, D5 slot-allocation table after M14 + post-M14, D6 event-kind table, D7 layering rule, D8 modifier matrix, and an Open-issues section for the implementing claims. |
| [6437-progressbar](6437-progressbar.md) | Muse Spark (`agent/buffy/arc1-progressbar`) | ✅ done 2026-08-21 — `user/src/lib/ui.zig` ProgressBar + 5 host tests, `zig test` 22/22, `verify-bss-budget` 9788088/11534336, `verify-coordination` PASS |
| [6560-ci-class-a-bss-budget-gate](6560-ci-class-a-bss-budget-gate.md) | buffy (`freebuff/can-you-review-issues-223-247-and-try-to-provide-h-f6c8d8a0-9349-4ada-9bca-1705150f0bde`) | ✅ done 2026-08-20 — gate exists and runs clean on current main (`measured=6,119,552 B`, `budget=7,340,032 B`, `remaining=1,220,480 B`, `status=PASS`); smoke-tested by `BSS_BUDGET_BYTES=6000000 bash tools/verify-bss-budget.sh` which produces the expected FAIL with the documented guidance; wired into `just verify-portable` (runs as part of CI); wired into `.github/workflows/ci.yml` so every PR runs the gate on `macos-latest`; `docs/gate-inventory.md` lists the gate as `bss-budget` class A; resolves GitHub issue #248. |
| [7127-audit-followup-gates-docs](7127-audit-followup-gates-docs.md) | buffy (`agent/buffy/audit-followup-1-gates-docs`) | 🔄 agent/buffy/audit-followup-1-gates-docs |
| [7302-xhci-depth-pointer-reports](7302-xhci-depth-pointer-reports.md) | buffy (`agent/buffy/audit-followup-2-input-depth`) | 🔄 agent/buffy/audit-followup-2-input-depth |
| [7656-plan-milestone-15-desktop-completeness](7656-plan-milestone-15-desktop-completeness.md) | buffy (`freebuff/can-you-review-issues-223-247-and-try-to-provide-h-f6c8d8a0-9349-4ada-9bca-1705150f0bde`) | ✅ done 2026-08-20 — `docs/m17-desktop-completeness.md` exists, 127 lines, 10 cards (C1–C10) with status legend, evidence column, dependency notes, best-agent split, notes section, and three open questions for the user. |
| [7675-m18-t2-selection](7675-m18-t2-selection.md) | buffy (`agent/buffy/m18-t2-selection`) | ✅ done 2026-08-22 |
| [8879-m18-t3-search](8879-m18-t3-search.md) | buffy (`agent/buffy/m18-t3-search`) | ✅ done 2026-08-22 |
| [9090-status-compress](9090-status-compress.md) | muse-spark (`agent/buffy/status-compress`) | ✅ done |
| [9091-calc-history](9091-calc-history.md) | buffy (`agent/buffy/m15-c9-calc-history`) | ✅ done 2026-08-21 — `user/src/calc.zig` history + keyboard (`history_max 10` ring `HistoryEntry [32]u8+result`, `history_area 8,8,239,60` 6 visible @10px with `^`/`v` scroll, `display_rect 8,72,239,28` below history, buttons y+64 shift, `push_history_entry`/`record_history_from_engine`/`history_up`/`history_down`/`get_history_entry`, `draw` history + indicator, `handle_mouse_events` evaluate records `pending/a/b → history`, `handle_keyboard_event` complete surface digits `0-9`, ops `+-*/%`, `.` no-op, `Enter` `0x28`/`=` evaluate+record, `Backspace` `0x08`/`0x2a`, `Esc` `0x29`/`0x1b` clear, `Up` `0x52`/`Down` `0x51` cycle, `m` MR, `c` clear, BODMAS documented). Host tests 22/22 PASS (3 new: ring wrap/scroll, Up/Down cycle+keys, AppState 1744 <4KiB), `zig build` PASS `CALC.BIN 8153` (+2324B), `verify-bss-budget` PASS `9788088/11534336`. |
| [9697-dock](9697-dock.md) | buffy (`agent/buffy/m15-c4-dock`) | ✅ done 2026-08-20 — `driving_award.zig:107` `Kind.dock` + `dock_*` BSS + `arm` window 253 + `paint` dock bar + `pointer_tick` dock launch/raise + `image/apps.txt` `dock=true` (5 apps) + `desktop.zig:27` `dock` parse, host tests `arm` 5→`count` + `hit_test` + `user_open` + `syscall` `win_query` + `monitor` `resources` update, `verify-bss-budget` PASS `9788k/11534k` |
| [9815-m22-dev-tools-lane](9815-m22-dev-tools-lane.md) | ox-alpha (`lane-d/m22-dev-tools`) | 🔄 in progress |
| [9867-m18-t1-scrollback](9867-m18-t1-scrollback.md) | buffy (`agent/buffy/m18-t1-scrollback`) | ✅ done 2026-08-22 |
<!-- CLAIMS_INDEX:END -->

## Archived claims (M3–M16, 178 files)

Completed-milestone claims (M3–M16) are historical records that no agent
needs during active development. They were moved to
[`docs/archive/claims/`](../archive/claims/) by issue #269 (claim 1601) —
`1.1M → ~160K` active (31 files + this index). The archive is **not**
indexed here and is **out of scope** for `tools/verify-coordination.sh`
(deterministic-ID and duplicate checks run only on `docs/claims/*.md`);
archived files retain their original deterministic IDs but are history.

- Active claims: `docs/claims/[0-9]*-*.md` (this index, ~31 files, M17+
  desktop completeness, audit followups, and recent hygiene).
- Archived claims: `docs/archive/claims/[0-9]*-*.md` (178 files, M3–M16 +
  early M1.5/M2 diagnostics; see `git log -- docs/archive/claims/` for
  the move). Do not add new claims there — new work always goes in
  `docs/claims/` via `bash tools/status/claim-id.sh`.

To browse history: `ls docs/archive/claims/ | wc -l` or
`grep -r "Status: ✅" docs/archive/claims/ | head`.
