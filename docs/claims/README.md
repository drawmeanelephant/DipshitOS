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
4. `git add` your new claim file and commit it — **do not** regenerate or
   commit the [Active claims index](#active-claims-index) below. Since
   claim 2599, `.github/workflows/indexes.yml` owns both index tables
   after every merge (the single serialized
   writer of a shared derived artifact); branch-side table churn is what
   made those two files collide on nearly every near-simultaneous merge.
   A local `bash tools/status/refresh-indexes.sh` is an optional preview.
5. On completion or blockers: flip Status in **your claim file** to `✅`
   (with evidence) or `⛔` (note why), append to `docs/logs/<branch>.md`,
   and commit — the bot updates the index on merge.

While 🔄, two fields keep you honest (optional for grandfathered claims):

- `- **Touches:**` — comma-separated repo paths/globs you will edit. The
  gate **fails** when two ACTIVE claims from different branches declare
  overlapping files.
- `- **Heartbeat:**` — bump the date by committing the claim file every
  week or two. A 🔄 claim with no commit for 14+ days draws a gate
  warning; past ~21 days anyone may flip it ⛔ via their own log entry.

Never edit another agent's claim file. Corrections are new entries in your
own branch's log that reference the old one.

## Active claims index

**This table is the canonical index** (status included) and it is
**generated** from the claim files by `.github/workflows/indexes.yml`
after every merge (claim 2599) — do not hand-edit it,
and never commit regenerated tables from a branch. `docs/status.md` points
here. The coordination gate (`bash tools/verify-coordination.sh`,
`just verify-coordination`, and CI) validates the table's structure on
PRs; sync is enforced on main by the bot, whose strict `--check` run fails
loudly if the generator or a table is broken.

<!-- CLAIMS_INDEX:START -->
| Claim | Owner (branch) | Status |
|-------|----------------|--------|
| [0098-in-guest-compiler](0098-in-guest-compiler.md) | antigravity (`agent/antigravity/in-guest-compiler`) | ✅ agent/antigravity/in-guest-compiler |
| [0130-m23-editor-depth-wave2](0130-m23-editor-depth-wave2.md) | Buffy (`agent/buffy/m23-editor-wave2`) | ✅ done — 96/96 host tests pass, build clean, live gate `tools/verify-live-editor.sh` PASS on VZ (9/9 assertions) |
| [0162-logs-cleanup](0162-logs-cleanup.md) | opencode (`t3code/fix-issue-267-git-current`) | ✅ done 2026-08-21 |
| [0163-m18-t5-colors](0163-m18-t5-colors.md) | buffy (`agent/buffy/m18-t5-colors`) | ✅ done 2026-08-22 |
| [0265-top-sort-filter](0265-top-sort-filter.md) | buffy (`agent/buffy/m15-c8-top-sort`) | ✅ done 2026-08-21 — `user/src/top.zig` sortable columns + filtering (`SortColumn pid/name/state/exit`, `compare_procs`, `name_contains` case-insensitive, stable insertion sort on `display_indices`, `filter_input TextInput 260,6,110,20` with label `Filter:`, header hit-test 52..68 click_column toggle ↑/↓, `rebuild_display` filtered+sorted, `handle_mouse_events` header+filter+row (display), `handle_keyboard_event` filter-focused priority + filtered Up/Down, `handle_timer`/`kill_selected` rebuild, `draw` header indicator accent + filtered rows). Host tests 23/23 PASS (8 new: compare, contains, sortable, filter, sort+filter, auto-refresh preserve, header click, row click), `TOP AppState 1352 <4KiB`, `zig build` PASS `TOP.BIN 10526` (+2355B), `verify-bss-budget` PASS `9788088/11534336` headroom `1746248`, `zig fmt --check` PASS. |
| [0434-m25-lane-a-bulk-props](0434-m25-lane-a-bulk-props.md) | ox-alpha (`agent/ox-alpha/m25-filemanager-depth`) | ✅ agent/ox-alpha/m25-filemanager-depth — F1+F2 live-gated |
| [0469-m18-t16-scripting](0469-m18-t16-scripting.md) | buffy (`agent/buffy/m18-t16-scripting`) | ✅ done 2026-08-22 |
| [0478-desktop-gate-calc-enoent](0478-desktop-gate-calc-enoent.md) | buffy (`agent/buffy/input-poll-563`) | ✅ done 2026-08-26 — gate PASSES end to end. Root cause (three stacked bugs, all pre-existing on clean main, previously masked by the first): (1) the FAT first-fit cluster allocator re-reads the same FAT sector once per cluster — the ESP's files span ~21.8k clusters, so every `write_file` (shell history + the M21 WINDOWS.SAV persist) issued ~21.8k sector reads; the polled virtio-blk transport (~1 in ~4k requests) timed out mid-burst, and a timed-out read during CALC's root-directory walk truncated the chain → ENOENT. (2) The M21 WINDOWS.SAV persist saved every 300 idle cycles — at the real ~250 Hz idle rate that is ~1/s, keeping the transport continuously busy. (3) M24 (595bc71) grew CALC.BIN's window to 424 tall, above the kernel's 384 user back-buffer — `user_open` rejected it (masked by the ENOENT; surfaced once the exec worked). Fixes: FAT-sector caching in the allocator scans (`FatScan`, 128× fewer reads — 109,107 → 684 per run), skip byte-identical WINDOWS.SAV persists, one retry-on-timeout in the virtio-blk submit (transient host-side spikes complete just past the poll budget), `user_buf_h` 384→424 (+ updated unit tests), and the gate's sweep commands reordered so the `done-desktop-sweep` expect marker prints LAST (the runner stops the VM the poll after the marker — the procs/syscalls report was truncated mid-print). Verification: `verify-live-desktop.sh` PASS (all 7 assertions), `verify-live-desktop-typing.sh` PASS (92 glyph samples), unit tests, `zig fmt --check`, coordination gate ok. |
| [0549-wms8-gate7-desktop-chrome-delete](0549-wms8-gate7-desktop-chrome-delete.md) | buffy (`agent/buffy/wms8-gate7-dead-blocks`) | ✅ done |
| [0590-devcons-typed-input-proof](0590-devcons-typed-input-proof.md) | buffy (`agent/buffy/input-poll-563`) | ✅ done 2026-08-26 — `verify-live-devcons.sh` PASS 2/2 with the issue #553 typed-input phase: after `devcons: ready`, `dir.bin\\n` is typed at the in-window prompt over the claim 9588 custom-virtio INPUT queue; the app buffers the 7 printable chars + Enter (`input` report events=8), executes `dir.bin` via sys_exec (child prints `dir: listing /data` + `dir: success` on serial), and the `> dir.bin` + `exec: ok (output on serial)` echoes render in the log pane (screenshot pixel proof: white text rows y 54..202 in the 2x window, 493 samples). |
| [0640-m26-net-experience](0640-m26-net-experience.md) | Buffy (`agent/buffy/m26-net-experience`) | ✅ complete |
| [0680-virtio-console-snapshots](0680-virtio-console-snapshots.md) | t3code (`t3code/finish-523-console-snapshots`) | ✅ done |
| [0688-wms9-dsk1-drawing-apps](0688-wms9-dsk1-drawing-apps.md) | buffy (`agent/buffy/wms9-dsk1-drawing-apps`) | ✅ done |
| [0720-m22-lane-d-wave2](0720-m22-lane-d-wave2.md) | buffy (`freebuff/make-sure-git-is-current-then-let-s-see-if-we-can--2972776f-3ba7-4bc6-bd62-264908623ff2`) | ✅ done |
| [0750-httpd-web-server](0750-httpd-web-server.md) | Buffy (`agent/buffy/input-poll-563`) | ✅ done 2026-08-27 — verified live on Apple Silicon VZ (tools/verify-live-httpd.sh) |
| [0819-scrollview](0819-scrollview.md) | Muse Spark (`agent/buffy/arc1-scrollview`) | ✅ done — ScrollView landed on main (GH #218, Arc1): `user/src/lib/ui.zig` ScrollView component + FILE.BIN list integration + 4 host tests, verified present in main's ui.zig (component at line ~1328). Flipped from 🔄 by claim 0590's owner per the 6204/6637 precedent during the 2026-08-26 open-claim sweep (log entry in docs/logs/agent-buffy-input-poll-563.md). |
| [0835-hscrollbar](0835-hscrollbar.md) | Muse Spark (`agent/buffy/arc1-progressbar`) | ✅ done 2026-08-21 — `user/src/lib/ui.zig` HScrollBar + 4 host tests, `zig test` 29/29, `verify-bss-budget` 9788088/11534336, `verify-coordination` PASS |
| [1079-m21-tiling-minimize-notif](1079-m21-tiling-minimize-notif.md) | Buffy (`agent/buffy/m21-compositor`) | ✅ done |
| [1264-system-tray](1264-system-tray.md) | Muse Spark (`agent/buffy/arc2-tray`) | ✅ done 2026-08-21 — `kernel/src/driving_award.zig` tray (Kind.taskbar id 255 20px @ y=700 right 80px: HH:MM via `format_hhmm` from tick, theme D/L/A `theme_letter` in `tray_theme_accent`, clipboard filled/empty rect via `tray_clipboard_filled`) + `Kind.clock` id 1 migration (no duplicate window, `arm` 4 windows, `drain`/`composite` tick without timer); `kernel/src/syscall.zig` z/count tests updated (4 base, z=4); host tests 140/140 PASS, `verify-bss-budget` PASS 9788088/11534336, `verify-coordination` PASS — branch `agent/buffy/arc2-tray` (commit 4521ff1) |
| [1306-m21-window-gate-sweep](1306-m21-window-gate-sweep.md) | Buffy (`agent/buffy/m21-window-depth`) | ✅ done 2026-08-26 (`agent/buffy/m21-window-depth`) |
| [1382-issue-563-input-poll-gui-app](1382-issue-563-input-poll-gui-app.md) | buffy (`agent/buffy/input-poll-563`) | ✅ done 2026-08-26 — root-caused: NOT a poll stall — guest routing is healthy; the repro burst drained into the in-flight `sys_exec` (strokes consumed by DESKTOP before EDIT's window existed), and the apparent `focused=3` misreading came from the desktop's hardcoded `open id=4` marker while real ids shift with restored WINDOWS.SAV state. Deliverables: `user/src/desktop.zig` prints the real window id; `tools/verify-live-desktop-typing.sh` live gate (split-injection: launch, then type `abcde` after `edit: ready`) PASSES — EDIT decodes all 5 strokes and renders them pixel-proof (92 white-glyph samples on screen). Note: `tools/verify-live-desktop.sh` currently fails on clean main (`err=6` ENOENT for CALC.BIN) — pre-existing, out of scope. |
| [1484-wms1-slot65-reservation](1484-wms1-slot65-reservation.md) | buffy (`agent/buffy/docs-pass`) | ✅ done 2026-08-28 (all checks green: verify-coordination, `zig |
| [1601-prune-claims-269](1601-prune-claims-269.md) | t3code (`t3code/prune-claims-269`) | ✅ done 2026-08-21 — moved 178 claim files M3–M16 (incl. early M1.5/M2 diagnostics) from `docs/claims/` (209 files, ~1.2M) to `docs/archive/claims/` (178 files, 1.0M); active `docs/claims/` now 31 files, 176K (README 16K + claims ~160K, `du -sh` 176K) with 6 🔄 audit/M17 + 13 M17 desktop (Arc1/Arc2/C2–C9) + 8 hygiene + 4 planning; updated `docs/claims/README.md` (98 lines, 16K, + Archived section) and `docs/archive/README.md` (claims/ paragraph) and `docs/march-m3/m6/m13.md` links (15 refs) to `archive/claims/`; `bash tools/status/refresh-indexes.sh` and `bash tools/verify-coordination.sh` both PASS |
| [1714-strace-marker-freshline](1714-strace-marker-freshline.md) | buffy (`agent/buffy/strace-marker-freshline`) | ✅ done — landed via PR #723 (2026-08-31). |
| [1751-m19-p7-background-jobs](1751-m19-p7-background-jobs.md) | ox-alpha (`agent/ox-alpha/m19-p7-background-jobs`) | ✅ done (2026-08-23) |
| [1757-context-menu](1757-context-menu.md) | Muse Spark (`agent/buffy/arc2-context-menu`) | ✅ done 2026-08-21 — right-click live on host: `events.zig` kinds 11 `MOUSE_RIGHT_DOWN` + 13 `MOUSE_RIGHT_UP` (ADR 0013 D2, kind 12 skipped for SCROLL), `user/src/lib/ui.zig` ContextMenu (show/dismiss/bounds/hit-test + 3 host tests) + FILE/NOTEPAD/TOP integration, `kernel/src/driving_award.zig` right-button routing (left/right split, WIN_RESIZE/DRAG gated left-only, `verify-bss-budget` PASS 9788088/11534336, `zig test` ui 32/32, driving_award 132/132, `zig fmt` PASS) |
| [1872-dialog](1872-dialog.md) | Muse Spark (`agent/buffy/arc1-progressbar`) | ✅ done 2026-08-21 — `user/src/lib/ui.zig` Dialog + 3 host tests, `zig test` 29/29, `verify-bss-budget` 9788088/11534336, `verify-coordination` PASS |
| [2203-trim-hardware-contract](2203-trim-hardware-contract.md) | ox-alpha (`agent/ox-alpha/hygiene-trim-hardware-contract`) | ✅ done (`agent/ox-alpha/hygiene-trim-hardware-contract`) |
| [2259-fleet-remainder](2259-fleet-remainder.md) | gates (`agent/gates/fleet-remainder`) | ✅ done 2026-08-24 — all scope delivered: 26 gates migrated (25 rc=0 individually on this host; live-desktop migrated-but-red, pre-existing CALC geometry regression reproduced on unmodified origin/main d1dc6fe baseline and left for its owner with citations); tabs race root-caused with three host-side layers fixed gate-side + precise handoff note for the open guest/tools question; seven pre-existing reds reproduced on the detached baseline; canary design notes in the branch log (no .github infra touched); concurrency proof under artifacts/fleet-remainder-concurrency/. PR opened from this branch. |
| [2336-file-inline-preview](2336-file-inline-preview.md) | buffy (`agent/buffy/m15-c7-file-preview`) | ✅ done 2026-08-21 — `user/src/file_browser.zig` inline preview (selection auto-loads `preview_content[512]` first 15 lines, `is_binary_content` ≥80% printable sniff → `(binary)` placeholder for non-TXT/binary, `preview_is_binary` flag) + breadcrumb bar (`breadcrumb_rect 60,6,440,12` muted, `format_breadcrumbs`/`breadcrumb_hit_test`/`truncate_to_segment`, `current_path[64]` session-only, `enter_directory`/`navigate_to_segment`/`breadcrumb_click`, `build_path` helper, `refresh_preview` on select/click/keyboard, `draw_details` preview below metadata) + `HScroll` deferred (preview wraps at `preview_cols 30`, no extra widget). Host tests 25/25 PASS (6 new: binary sniff, breadcrumbs hit-test, build_path, current_path nav, preview auto-load, breadcrumb_click), `zig build` PASS `FILE.BIN 10882` (+24B), `verify-bss-budget` PASS `9788088/11534336` (1746248 B headroom), `zig fmt --check` PASS. |
| [2382-sb4-damage-tracking](2382-sb4-damage-tracking.md) | buffy (`agent/buffy/m33-sb4-damage-tracking`) | ✅ |
| [2418-checkbox-toggle](2418-checkbox-toggle.md) | Muse Spark (`agent/buffy/arc1-checkbox-toggle`) | ✅ done — Checkbox + Toggle landed on main (GH #219, Arc1): `user/src/lib/ui.zig` Checkbox (12×12) + Toggle (48×20 pill) components, verified present in main's ui.zig (lines ~1497/1530). Flipped from 🔄 by claim 0590's owner per the 6204/6637 precedent during the 2026-08-26 open-claim sweep (log entry in docs/logs/agent-buffy-input-poll-563.md). |
| [2491-wms4-chrome-drain](2491-wms4-chrome-drain.md) | buffy (`agent/buffy/wms4-chrome-drain`) | ✅ done (PR closing #624) |
| [2539-m25-lane-b-mkdir-du-recent](2539-m25-lane-b-mkdir-du-recent.md) | ox-alpha (`agent/ox-alpha/m25-filemanager-depth`) | ✅ agent/ox-alpha/m25-filemanager-depth — F3 ✅ (mkdir gate |
| [2564-tracked-only-coordination-gate](2564-tracked-only-coordination-gate.md) | ox-alpha (`agent/ox-alpha/coordination-tracked-gate`) | ✅ done 2026-08-24 — PR #525 merged (`e22b375`): both coordination tools list files via `git ls-files -c`; sandbox in test-coordination.sh is a git repo; untracked-immunity regression case added (16/16); verified in a detached worktree at the pushed commit |
| [2572-sys-tcp-connect-spin-timeout](2572-sys-tcp-connect-spin-timeout.md) | buffy (`agent/buffy/issue-613-tcp-connect-spin`) | ✅ agent/buffy/issue-613-tcp-connect-spin |
| [2599-ci-generated-indexes](2599-ci-generated-indexes.md) | ox-alpha (`t3code/concurrent-agents-merge-conflicts`) | ✅ done 2026-08-24 — observed end-to-end on this host: PRs #532/#533/#534 merged; live runs fixed two real failures (no-bypass ruleset rejected direct push → auto-merge PR design; checkout's forced GITHUB_TOKEN header beat the PAT → extraheader unset + `gh auth setup-git`); run 32723105968 pushed `indexes/bot-regenerate`, PR #535 opened, required check passed (macOS build 4m42s), auto-squash-merged as `2954d68`; main's tables now carry the 2599/5069 rows (logs index 93 rows) with zero branch-side churn. Test suite 21/21. |
| [2616-dhcp-lifecycle-autonomous](2616-dhcp-lifecycle-autonomous.md) | buffy (`agent/buffy/audit-followup-3-dhcp-autonomy`) | ✅ done — the autonomous DHCP lifecycle landed on main: `dhcp.step_lifecycle()` (RFC 2131 §4.4.5) + `net_dhcp_poll()` in virtio_net, driven from the shell idle loop; both reworked live gates PASS on VZ (per the branch log). Flipped from 🔄 by claim 0590's owner per the 6204/6637 precedent during the 2026-08-26 open-claim sweep (log entry in docs/logs/agent-buffy-input-poll-563.md). |
| [2621-m21-w9-w11-w12-compositor-polish](2621-m21-w9-w11-w12-compositor-polish.md) | Buffy (`agent/buffy/m21-compositor-w9-w11-w12`) | ✅ done 2026-08-24 — work merged to main as 1a8dedf ("feat(m21): compositor polish — W9 focus rings, W11 window persistence, W12 window titles", verified `git merge-base --is-ancestor`); flipped from 🔄 by t3code in worktree `t3code/milestone-nine-triage` (claim 8777) per the claim-6637 precedent so the ACTIVE-Touches gate stops holding these files; recorded here and in `docs/logs/t3code-milestone-nine-triage.md` |
| [2762-window-snap-zones](2762-window-snap-zones.md) | buffy (`agent/buffy/m15-c3-snap-zones`) | ✅ done 2026-08-20 — `driving_award.zig:178` snap BSS (`last_rect`/`is_snapped`/`zone` ≈80 B) + `snap_zone_for_point`/`snap_window`/`snap_restore` + `pointer_tick` drag-out restore + `draw_chrome` preview, host tests `snap_zone`/`snap_window`/`preview` PASS, `verify-bss-budget` PASS `9787576/11534336` |
| [2852-wm-server-migration](2852-wm-server-migration.md) | buffy (`agent/buffy/docs-pass`) | 🔄 agent/buffy/docs-pass |
| [2860-trim-roadmap-completed-milestones](2860-trim-roadmap-completed-milestones.md) | t3code (`t3code/fetch-issue-264-details`) | ✅ done 2026-08-21 |
| [2873-alt-tab-cycling-ui](2873-alt-tab-cycling-ui.md) | buffy (`agent/buffy/m15-c2-alt-tab`) | ✅ done 2026-08-20 — `driving_award.zig:168` overlay BSS (32 B) + `input.zig:86` Alt+Shift latch + `shell.zig:191` hold-Alt commit, host tests PASS 125/125 `driving_award`, class-A `verify-bss-budget` PASS `9787576/11534336`, `zig fmt` + `zig build` + `test-console` PASS |
| [3141-cvc-echo-host-push](3141-cvc-echo-host-push.md) | ox-alpha (`t3code/c259b00a`) | ✅ done 2026-08-24 — `bash tools/verify-cvc-echo.sh` PASS 1/1 on this host (all host+guest assertions byte-exact; artifacts `live-cvc-*`); regression `verify-custom-virtio.sh` PASS unchanged; coordination suite ok |
| [3377-docs-pass-m31-sync](3377-docs-pass-m31-sync.md) | buffy (`agent/buffy/docs-pass`) | ✅ done |
| [3589-drag-resize](3589-drag-resize.md) | Muse Spark (`agent/buffy/arc2-resize`) | ✅ done 2026-08-21 — drag-to-resize live on host (merge 44ca7d2): `driving_award` 6×6 hit + clamped resize + WIN_RESIZE kind 10 + `sys_win_resize` slot 47 (implemented_count 47→48), 4 host tests, `verify-bss-budget` PASS 9788088/11534336, `verify-coordination` PASS — branch `agent/buffy/arc2-resize` merged to `main` (commit 17e7951) |
| [3633-sb3-surface-handoff](3633-sb3-surface-handoff.md) | buffy (`agent/buffy/m33-sb3-surface-handoff`) | ✅ |
| [3679-m18-t4-history](3679-m18-t4-history.md) | buffy (`agent/buffy/m18-t4-history`) | ✅ done 2026-08-22 |
| [3687-wms8-gate6-pointer-drag-delete](3687-wms8-gate6-pointer-drag-delete.md) | buffy (`agent/buffy/wms8-gate6-pointer-drag-delete`) | ✅ `agent/buffy/wms8-gate6-pointer-drag-delete` |
| [3744-wms6-tray-drain](3744-wms6-tray-drain.md) | buffy (`agent/buffy/wms6-tray-drain`) | ✅ (2026-08-29 — live gate PASS on VZ; all five issue-626 surfaces drain) |
| [3881-wms3-wnd-server](3881-wms3-wnd-server.md) | buffy (`agent/buffy/wms3-wnd-server`) | ✅ done (2026-08-29, PR closing #623) |
| [3904-wasm-line-of-sight-docs](3904-wasm-line-of-sight-docs.md) | buffy (`freebuff/okay-shower-thoughts-here-we-re-using-fat32-for-so-b0ce3067-2b04-4b81-984d-9fd76bfcf123`) | ✅ done |
| [4001-m31-dynamic-ecosystem](4001-m31-dynamic-ecosystem.md) | buffy (`agent/buffy/m30-dynamic-linking`) | ✅ done |
| [4278-wms5-gate2-geometry-policy](4278-wms5-gate2-geometry-policy.md) | buffy (`agent/buffy/wms5-gate2-geometry-policy`) | ✅ complete |
| [4341-m23-editor-completeness](4341-m23-editor-completeness.md) | Buffy (`agent/buffy/m23-editor-wave2`) | ✅ done |
| [4354-m23-m24-gate-evidence](4354-m23-m24-gate-evidence.md) | buffy (`agent/buffy/m23-m24-gate-sweep`) | ✅ done — the full K-row sweep landed 2026-08-26: `verify-live-calc-prog.sh` (K1) and the new `verify-live-calc-depth.sh` (K2/K3/K4/K6/K7/K9/K10/K12/K13/K14/K16) both PASS on VZ; two real bugs surfaced and fixed (see Notes). |
| [4379-m25-file-manager-depth](4379-m25-file-manager-depth.md) | buffy (`agent/buffy/m25-file-manager-depth`) | ✅ done 2026-08-26 (`agent/buffy/m25-file-manager-depth`) |
| [4402-m27-compositor-polish](4402-m27-compositor-polish.md) | Buffy (`agent/buffy/m21-compositor`) | ✅ done 2026-08-26 — completed and merged under full M27 sweep (claim 8041, PR #591) |
| [4429-archive-m5-m6-prompts](4429-archive-m5-m6-prompts.md) | buffy (`agent/buffy/hygiene-archive-m5-m6-prompts`) | ✅ done |
| [4510-wms6-altab-drain](4510-wms6-altab-drain.md) | buffy (`agent/buffy/wms6-altab-drain`) | ✅ complete |
| [4516-archive-ragshit-test-artifacts](4516-archive-ragshit-test-artifacts.md) | oxalpha (`t3code/handle-issue-268-git-current`) | ✅ done |
| [4790-wms8-tooltip-dwell-drain](4790-wms8-tooltip-dwell-drain.md) | buffy (`agent/buffy/wms8-desktop-overlay-drain`) | ✅ `agent/buffy/wms8-desktop-overlay-drain` |
| [4928-per-agent-worktrees](4928-per-agent-worktrees.md) | ox-alpha (`agent/ox-alpha/agent-worktrees`) | ✅ done 2026-08-24 — PR #526 merged: `just new-agent/resume-agent/drop-agent/list-agents`, canonical naming (`../dipshitos-<name>`, `agent/<name>/<slug>`), AGENTS.md mandates one worktree per agent; round-trip selftest + gates green; `just` installed on dev host (v1.58.0) |
| [5069-gate-fleet-migration](5069-gate-fleet-migration.md) | ox-alpha (`agent/ox-alpha/gate-fleet-migration`) | ✅ done |
| [5093-scroll-keys-chords](5093-scroll-keys-chords.md) | buffy (`agent/buffy/m18-t16-scripting`) | ✅ done 2026-08-22 |
| [5127-m20-text-rendering-lane-c](5127-m20-text-rendering-lane-c.md) | ox-alpha (`lane-c/m20-text-rendering`) | ✅ done 2026-08-22 — all 15 issues closed (#306–#320); |
| [5220-m22-lane-d-live-gates](5220-m22-lane-d-live-gates.md) | buffy (`agent/buffy/m22-devtools-d8-d16`) | ✅ done (agent/buffy/m22-devtools-d8-d16) |
| [5227-notepad-wrap-find](5227-notepad-wrap-find.md) | buffy (`agent/buffy/m15-c5c6-notepad`) | ✅ done 2026-08-20 — `user/src/notepad.zig` soft-wrap (`TextLayout` last_space, gutter, `Line X of Y`) + `find_next`/`replace`/`replace_all` (case_sensitive=false) + `AppState` find bar (`find_active`/`find_buf`/`replace_buf`) + `draw` highlight + `handle_keyboard_event` Ctrl+F/H, host tests `soft-wrap`/`find` PASS, `verify-bss-budget` PASS `9788088/11534336` |
| [5301-m24-calc-decompose-k1-k5](5301-m24-calc-decompose-k1-k5.md) | buffy (`agent/buffy/m24-calc-features`) | ✅ done 2026-08-22 — PR #482 |
| [5381-m24-k6-k16-calc-features](5381-m24-k6-k16-calc-features.md) | ox-alpha (`lane-b/m24-calc-features`) | ✅ done (code + host tests; live-gate bring-up pass pending for the set) |
| [5424-m19-p5-quoting-p6-globbing](5424-m19-p5-quoting-p6-globbing.md) | ox-alpha (`agent/ox-alpha/m19-p5p6-quoting-globbing`) | ✅ done (2026-08-23) |
| [5512-archive-march-m4-m5-trackers](5512-archive-march-m4-m5-trackers.md) | oxalpha (`agent/oxalpha/archive-march-m4-m5`) | ✅ done |
| [5759-m19-p3-chaining-p4-exit-status](5759-m19-p3-chaining-p4-exit-status.md) | ox-alpha (`agent/ox-alpha/m19-p3p4-chaining-exit-status`) | ✅ done (2026-08-23) |
| [5817-virelaios-rename](5817-virelaios-rename.md) | buffy (`freebuff/okay-i-think-we-need-to-work-through-this-big-one--076be815-d689-40da-9389-cfd56bae921f`) | ✅ done 2026-08-31 — rename sweep landed (ADR 0017 ACCEPTED). Verification: `zig build` PASS, shell tests 792/792, full unit suite PASS, `test-console` byte-identical (golden regenerated from mock e2e), `image`/`inspect`/`context` PASS, `zig fmt --check` PASS, ragshit pytest 147/147, post-sweep `rg -i dipshit` audit = zero occurrences outside protected/historical locations and GitHub repo-slug URLs. Coordination gate flags only the documented Touches overlap with pre-existing 🔄 claims 2852 (docs-pass) and 9731 (toolchain-env-check). DipshitOS memorialized at `docs/archive/dipshitos-name.md` (dedicated commit b92a8cd, tag `dipshitos-final`). |
| [5828-trim-gate-inventory](5828-trim-gate-inventory.md) | ox-alpha (`t3code/issue-265-fix`) | ✅ done (2026-08-21) |
| [5931-m26-net-experience-remainder](5931-m26-net-experience-remainder.md) | Buffy (`agent/buffy/m26-net-experience`) | ✅ complete |
| [6014-claim-touches-and-staleness](6014-claim-touches-and-staleness.md) | ox-alpha (`agent/ox-alpha/claim-lifecycle`) | ✅ done 2026-08-24 — PR #527 merged (8420a89): Touches overlap gate + staleness warnings live; test suite 19/19; AGENTS.md/TEMPLATE/README conventions landed |
| [6154-wms6-tooltip-drain](6154-wms6-tooltip-drain.md) | buffy (`agent/buffy/wms6-tooltip-drain`) | ✅ complete |
| [6155-wms8-unsaved-drain](6155-wms8-unsaved-drain.md) | buffy (`agent/buffy/wms8-unsaved-drain`) | ✅ `agent/buffy/wms8-unsaved-drain` |
| [6156-wms9-surface-seam-perf](6156-wms9-surface-seam-perf.md) | buffy (`agent/buffy/wms9-surface-seam-perf`) | ✅ done 2026-08-30 (`agent/buffy/wms9-surface-seam-perf`, PRs #674 + #678) |
| [6204-audit-2026-maintenance](6204-audit-2026-maintenance.md) | maintenance (`agent/maintenance/audit-2026-issues`) | ✅ done — all three scope items landed 2026-08-11 via PR #98 (commit 90625fc, merged 4c51c4c): #93 timer-gate evidence restored (verify-live-timer.sh PASS 3/3, artifacts/live-timer-*), #94 AGENTS.md current-milestone drift fixed (verified on main), #95 claim 7948 annotated as superseded (later archived to docs/archive/claims/7948-gic-timer-interrupts.md by the claim-1601 hygiene prune, since the annotation's 14 lines rode 90625fc). The claim was left 🔄 at merge time (no completion flip, no heartbeat), which is why the coordination gate flagged it 14+ days later; flipped to ✅ 2026-08-26 by claim 0590's owner per the coordination rules (log entry in docs/logs/agent-buffy-input-poll-563.md). |
| [6215-adr-0013-post-m14-abi-amendment](6215-adr-0013-post-m14-abi-amendment.md) | buffy (`freebuff/can-you-review-issues-223-247-and-try-to-provide-h-f6c8d8a0-9349-4ada-9bca-1705150f0bde`) | ✅ done 2026-08-20 (as **proposed** ADR; the status flips to **accepted** when M14 closes and the first post-M14 claim cites it) — `docs/decisions/0013-post-m14-abi-amendment.md` exists (~18 KiB, ~290 lines), with D1 slot reservation (47–54), D2 event-kind reservation (10–17 with kind-12/13/16 collision resolutions called out by name), D3 BSS budgets + D3.1 observed measurement, D4 ABI contract under reservation, D5 slot-allocation table after M14 + post-M14, D6 event-kind table, D7 layering rule, D8 modifier matrix, and an Open-issues section for the implementing claims. |
| [6344-history-recall-persistence](6344-history-recall-persistence.md) | buffy (`agent/buffy/history-recall-persistence`) | ✅ done — landed via PR #724 (2026-08-31). |
| [6437-progressbar](6437-progressbar.md) | Muse Spark (`agent/buffy/arc1-progressbar`) | ✅ done 2026-08-21 — `user/src/lib/ui.zig` ProgressBar + 5 host tests, `zig test` 22/22, `verify-bss-budget` 9788088/11534336, `verify-coordination` PASS |
| [6438-m28-smp](6438-m28-smp.md) | buffy (`agent/buffy/m28-smp`) | ✅ done |
| [6560-ci-class-a-bss-budget-gate](6560-ci-class-a-bss-budget-gate.md) | buffy (`freebuff/can-you-review-issues-223-247-and-try-to-provide-h-f6c8d8a0-9349-4ada-9bca-1705150f0bde`) | ✅ done 2026-08-20 — gate exists and runs clean on current main (`measured=6,119,552 B`, `budget=7,340,032 B`, `remaining=1,220,480 B`, `status=PASS`); smoke-tested by `BSS_BUDGET_BYTES=6000000 bash tools/verify-bss-budget.sh` which produces the expected FAIL with the documented guidance; wired into `just verify-portable` (runs as part of CI); wired into `.github/workflows/ci.yml` so every PR runs the gate on `macos-latest`; `docs/gate-inventory.md` lists the gate as `bss-budget` class A; resolves GitHub issue #248. |
| [6637-gate-run-isolation](6637-gate-run-isolation.md) | ox-alpha (`agent/ox-alpha/run-isolated-gates`) | ✅ done 2026-08-24 — PR #529 merged (957e452); flipped from 🔄 independently by ox-alpha in worktree `t3code/c259b00a` (for claim 3141) and in worktree `t3code-732c1e83` (for claim 5069) so the ACTIVE-Touches gate stops holding its files; both flips recorded here and in their branch logs |
| [6864-m33-sb6-perf-payoff](6864-m33-sb6-perf-payoff.md) | buffy (`agent/buffy/m33-sb6-perf-payoff`) | ✅ |
| [7033-m19-lane-a-shell](7033-m19-lane-a-shell.md) | buffy (`agent/buffy/m19-lane-a-shell`) | ✅ done — M19 Lane A complete on main: all 16 P-cards (pipes → P16 temp files) landed and march-m19.md rows all closed (P1 `verify-live-pipe.sh` PASS on VZ; P2–P16 with host tests 693/693 shell + 526/526 monitor green). Flipped from 🔄 by claim 0590's owner per the 6204/6637 precedent during the 2026-08-26 open-claim sweep (log entry in docs/logs/agent-buffy-input-poll-563.md). |
| [7127-audit-followup-gates-docs](7127-audit-followup-gates-docs.md) | buffy (`agent/buffy/audit-followup-1-gates-docs`) | ✅ done — all mechanical/doc items verified on main: verify-vz aggregate includes verify-live-exceptions.sh; win-move recipe dedup (single line); site/roadmap.md names the U4–U8 ladder; AGENTS.md current-milestone fixed ("Milestones zero through twelve…") with the obsolete G4–G6 sentence gone; status.md gains the milestone-eight row; docs/gate-inventory.md has the known-flakes registry. Flipped from 🔄 by claim 0590's owner per the 6204/6637 precedent during the 2026-08-26 open-claim sweep (log entry in docs/logs/agent-buffy-input-poll-563.md). |
| [7302-xhci-depth-pointer-reports](7302-xhci-depth-pointer-reports.md) | buffy (`agent/buffy/audit-followup-2-input-depth`) | ✅ done — the XHCI input-depth work landed on main: `max_report_bytes = 10` per-device report buffers + `intr_depth = 8` multi-TRB interrupt-IN with top-up re-arming, verified present in main's xhci.zig (lines ~304/332). Flipped from 🔄 by claim 0590's owner per the 6204/6637 precedent during the 2026-08-26 open-claim sweep (log entry in docs/logs/agent-buffy-input-poll-563.md). |
| [7397-m33-sb5-wm-compose-n](7397-m33-sb5-wm-compose-n.md) | buffy (`agent/buffy/m33-sb5-wm-compose-n`) | ✅ |
| [7418-sb1-shared-anon-contract](7418-sb1-shared-anon-contract.md) | buffy (`agent/buffy/m33-sb1-shared-anon-contract`) | ✅ done |
| [7557-wms6-notif-drain](7557-wms6-notif-drain.md) | buffy (`agent/buffy/wms6-notif-drain`) | ✅ complete |
| [7599-m34-hf4-app-delivery](7599-m34-hf4-app-delivery.md) | buffy (`agent/buffy/m34-hf4-exec`) | ✅ done |
| [7635-m26-netstat-fetch](7635-m26-netstat-fetch.md) | Buffy (`agent/buffy/m26-netstat-fetch`) | ✅ done — 428/428 kernel tests + all userland tests pass, |
| [7639-wms8-gate4-review-fixes](7639-wms8-gate4-review-fixes.md) | buffy (`agent/buffy/wms8-gate4-review-fixes`) | ✅ `agent/buffy/wms8-gate4-review-fixes` |
| [7656-plan-milestone-15-desktop-completeness](7656-plan-milestone-15-desktop-completeness.md) | buffy (`freebuff/can-you-review-issues-223-247-and-try-to-provide-h-f6c8d8a0-9349-4ada-9bca-1705150f0bde`) | ✅ done 2026-08-20 — `docs/m17-desktop-completeness.md` exists, 127 lines, 10 cards (C1–C10) with status legend, evidence column, dependency notes, best-agent split, notes section, and three open questions for the user. |
| [7675-m18-t2-selection](7675-m18-t2-selection.md) | buffy (`agent/buffy/m18-t2-selection`) | ✅ done 2026-08-22 |
| [7710-m34-hf1-hf2-wire-transport](7710-m34-hf1-hf2-wire-transport.md) | buffy (`agent/buffy/m34-hf1-hf2-host-file-channel`) | ✅ done |
| [7736-wms8-about-delete](7736-wms8-about-delete.md) | buffy (`agent/buffy/wms8-about-delete`) | ✅ `agent/buffy/wms8-about-delete` |
| [7746-m23-editor-undo-goto-tabs-syntax](7746-m23-editor-undo-goto-tabs-syntax.md) | Buffy (`agent/buffy/m23-text-editor`) | ✅ done — 75/75 host tests pass, build clean, gate written |
| [7921-m30-dynamic-linking](7921-m30-dynamic-linking.md) | buffy (`agent/buffy/m30-dynamic-linking`) | ✅ agent/buffy/m30-dynamic-linking |
| [8041-m27-desktop-polish](8041-m27-desktop-polish.md) | Buffy (`agent/buffy/m27-desktop-polish`) | ✅ done 2026-08-26 — M27 Desktop Polish & Completeness Sweep G1-G30 (#444-#473) complete: screenshot streaming BMP writer, help --all catalog, shortcuts matrix, WidgetState, ContextMenu separators/keys/shortcuts, standard Dialog helpers, empty state presenter, format_error, cursor feedback, focus restore, SYSMON.BIN dashboard, first-boot setup wizard in SETTINGS.BIN, dogfood audit report in docs/dogfood-m27.md, all unit tests pass. |
| [8247-m29-vm-depth](8247-m29-vm-depth.md) | buffy (`agent/buffy/m30-dynamic-linking`) | ✅ done |
| [8482-wms2-wmctl-register-seam](8482-wms2-wmctl-register-seam.md) | buffy (`agent/buffy/wms2-wmctl-register`) | ✅ done |
| [8777-m21-window-gate-sweep](8777-m21-window-gate-sweep.md) | t3code (`t3code/milestone-nine-triage`) | ✅ resolved — superseded by claim 1306 (`agent/buffy/m21-window-depth`), which is itself ✅ done 2026-08-26, so this sweep's scope is fully closed (the M21 W1–W16 gates landed via #488 + 1a8dedf + claim 1306). Flipped from ⛔ by claim 0590's owner during the 2026-08-26 open-claim sweep (log entry in docs/logs/agent-buffy-input-poll-563.md). |
| [8852-m26-net-offline-preflight](8852-m26-net-offline-preflight.md) | zcode (`agent/zcode/m26-net-offline-preflight`) | ✅ done 2026-08-28 — class-B gate `tools/verify-live-net-offline.sh` PASS 24/24 (evidence `artifacts/live-net-offline-*`); regressions `verify-live-n1-ping.sh`, `verify-live-fetch.sh`, `verify-live-netstat.sh` PASS; class A green (fmt, unit tests incl. 9 new netstatus tests, transcript byte-identical, build/image/inspect, coordination ×2, bss-budget, swift build). Two gate-engineering lessons recorded in the log: an empty `--vars` file is not a valid EFI variable store (`gate_begin` seeds one when `artifacts/efi-vars.bin` is absent — delete it like every net gate does), and the exit-report FIFO drains at the NEXT shell idle pass — a gate's `--script-expect` must key on the drained report line (or a later phase), never on an echo typed while the exiting task still owns the ring slot (the claim-1384/N6 lesson, relearned live). |
| [8878-sb2-shared-anon-capability](8878-sb2-shared-anon-capability.md) | buffy (`agent/buffy/m33-sb2-shared-anon-capability`) | ✅ done |
| [8879-m18-t3-search](8879-m18-t3-search.md) | buffy (`agent/buffy/m18-t3-search`) | ✅ done 2026-08-22 |
| [8961-m20-u1-u5-live-gates](8961-m20-u1-u5-live-gates.md) | ox-alpha (`agent/oxalpha/m20-text-unicode`) | ✅ done 2026-08-25 — all five march-m20 cards live-gated on |
| [9090-status-compress](9090-status-compress.md) | muse-spark (`agent/buffy/status-compress`) | ✅ done |
| [9091-calc-history](9091-calc-history.md) | buffy (`agent/buffy/m15-c9-calc-history`) | ✅ done 2026-08-21 — `user/src/calc.zig` history + keyboard (`history_max 10` ring `HistoryEntry [32]u8+result`, `history_area 8,8,239,60` 6 visible @10px with `^`/`v` scroll, `display_rect 8,72,239,28` below history, buttons y+64 shift, `push_history_entry`/`record_history_from_engine`/`history_up`/`history_down`/`get_history_entry`, `draw` history + indicator, `handle_mouse_events` evaluate records `pending/a/b → history`, `handle_keyboard_event` complete surface digits `0-9`, ops `+-*/%`, `.` no-op, `Enter` `0x28`/`=` evaluate+record, `Backspace` `0x08`/`0x2a`, `Esc` `0x29`/`0x1b` clear, `Up` `0x52`/`Down` `0x51` cycle, `m` MR, `c` clear, BODMAS documented). Host tests 22/22 PASS (3 new: ring wrap/scroll, Up/Down cycle+keys, AppState 1744 <4KiB), `zig build` PASS `CALC.BIN 8153` (+2324B), `verify-bss-budget` PASS `9788088/11534336`. |
| [9197-wms6-dock-drain](9197-wms6-dock-drain.md) | buffy (`agent/buffy/wms6-dock-drain`) | ✅ complete |
| [9363-host-file-channel-filed](9363-host-file-channel-filed.md) | buffy (`freebuff/okay-shower-thoughts-here-we-re-using-fat32-for-so-b0ce3067-2b04-4b81-984d-9fd76bfcf123`) | ✅ done |
| [9367-virtio-pointer-injection](9367-virtio-pointer-injection.md) | t3code (`t3code/finish-issue-523-progress`) | ✅ done 2026-08-24 — PASS observed live (see Evidence) |
| [9459-m34-hf3-mutation](9459-m34-hf3-mutation.md) | buffy (`agent/buffy/m34-hf3-mutation`) | ✅ done |
| [9588-virtio-input-channel](9588-virtio-input-channel.md) | virtio (`agent/virtio/virtio-input-channel`) | ✅ done (2026-08-24) |
| [9604-wms7-ipc-protocol](9604-wms7-ipc-protocol.md) | buffy (`agent/buffy/wms7-ipc-protocol`) | ✅ done 2026-08-29 — Gate A PASS on VZ (both boots), all host tests green, |
| [9612-wms10-shared-anon-split](9612-wms10-shared-anon-split.md) | buffy (`agent/buffy/wms10-split-adr`) | ✅ done |
| [9697-dock](9697-dock.md) | buffy (`agent/buffy/m15-c4-dock`) | ✅ done 2026-08-20 — `driving_award.zig:107` `Kind.dock` + `dock_*` BSS + `arm` window 253 + `paint` dock bar + `pointer_tick` dock launch/raise + `image/apps.txt` `dock=true` (5 apps) + `desktop.zig:27` `dock` parse, host tests `arm` 5→`count` + `hit_test` + `user_open` + `syscall` `win_query` + `monitor` `resources` update, `verify-bss-budget` PASS `9788k/11534k` |
| [9731-env-check](9731-env-check.md) | Buffy (`agent/buffy/toolchain-env-check`) | 🔄 agent/buffy/toolchain-env-check |
| [9815-m22-dev-tools-lane](9815-m22-dev-tools-lane.md) | ox-alpha (`lane-d/m22-dev-tools`) | ✅ done — M22 developer-tools lane complete on main: all D1–D16 cards closed in march-m22.md with PASS gates (ELF loader, strace seam, disas/asm, monitor dev utilities, resmon, crash-viewer, dmesg, time, ls -l, which/inventory, devcons). Flipped from 🔄 by claim 0590's owner per the 6204/6637 precedent during the 2026-08-26 open-claim sweep (log entry in docs/logs/agent-buffy-input-poll-563.md). |
| [9849-wms5-geometry-seam](9849-wms5-geometry-seam.md) | buffy (`agent/buffy/wms5-geometry-seam`) | ✅ done — PR #639 (WMS4, the dependency) + this claim's PR both merged |
| [9867-m18-t1-scrollback](9867-m18-t1-scrollback.md) | buffy (`agent/buffy/m18-t1-scrollback`) | ✅ done 2026-08-22 |
| [9879-wms8-gate5-geometry-keyboard-delete](9879-wms8-gate5-geometry-keyboard-delete.md) | buffy (`agent/buffy/wms8-gate5-geometry-keyboard-delete`) | ✅ `agent/buffy/wms8-gate5-geometry-keyboard-delete` |
| [9930-esp-create-disk-full](9930-esp-create-disk-full.md) | buffy (`agent/buffy/fix-728-esp-create-disk-full`) | ✅ done |
| [9980-wms8-dialog-drain](9980-wms8-dialog-drain.md) | buffy (`agent/buffy/wms8-dialog-drain`) | ✅ `agent/buffy/wms8-dialog-drain` |
| [9994-wms7-gateb-toolkit-repoint](9994-wms7-gateb-toolkit-repoint.md) | buffy (`agent/buffy/wms7-gateb-toolkit-repoint`) | ✅ done 2026-08-29 — Gate B PASS on VZ (both boots: the toolkit mail round-trip + the no-WM syscall fallback), all host tests green (ui 40 incl. the WireMirror guard, wmrpc 42 incl. the wnd_core byte-parity lock), `verify-live-wm-ipc.sh` (Gate A) re-run green, fmt + coordination + BSS budget clean. **WMS7 COMPLETE (issue #627 — Gate A + Gate B = the full card).** |
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
