# Coordination logs (append-only, per branch)

**Why this exists:** the project changelog used to live entirely inside
`docs/status.md`. Every agent appended to that one file, so parallel work
collided on every merge — PR #8/#10 collided once, and PR #12/#13 collided
again on the same section. Coordination state is now **sharded by branch**:
each branch owns its own log file, and cross-branch merges never touch the
same lines.

**The rule is unchanged and still binding** (AGENTS.md): log files are
**append-only**. Never rewrite or delete an entry — including entries in
other branches' logs. Corrections are *new* entries that reference the old
one.

## How to log

1. Your branch's log file is `docs/logs/<branch-slug>.md` (e.g.
   `agent/buffy/m15-commands` → `docs/logs/agent-buffy-m15-commands.md`).
   Create it on your first entry.
2. **Append** an entry in this format:

   `- **YYYY-MM-DD** — *owner (branch)*: claim → what changed → evidence → status.`

   Status legend: ⬜ claimed · 🔄 in progress · ✅ done · ⛔ blocked.
3. Cite `artifacts/` evidence files. No observed claim without a saved log.
4. Do **not** edit `docs/status.md` for logging — only for milestone-level
   facts (position, gates). Per-step progress goes in the per-milestone
   tracker (`docs/march-m15.md`); per-work detail goes here and in your
   claim file. If you must touch `README.md`/`roadmap.md`/`testing.md`,
   prefer pointer-level changes.
5. Do **not** regenerate or commit the [Log index](#log-index) below —
   since claim 2599, `.github/workflows/indexes.yml` owns it after every
   merge, so committing table churn from a branch is
   exactly what made the two index files collide on near-simultaneous
   merges. A local `bash tools/status/refresh-indexes.sh` is an optional
   preview only.

## Filenames & archive (issue #267)

Keep log **filenames** short: `<agent>-<yyyymmdd>-<seq>.md` when the branch
name itself is long or prompt-derived (the old
`freebuff-can-you-check-out…​-<uuid>.md` style is retired). The index table's
Branch column carries the full branch/title, so nothing is lost by a terse
filename. Logs whose last commit is older than ~7 days move to
[`docs/archive/logs/`](../archive/logs/) (same naming convention) — they are
history, not active coordination state, and fall outside the coordination
gate. Old-name → new-name mapping lives in
[`docs/claims/0162-logs-cleanup.md`](../claims/0162-logs-cleanup.md); file
contents were never rewritten, so the append-only rule holds.

## Log index

**This table is generated** from the log files by
`.github/workflows/indexes.yml` after every merge (claim 2599) — never
hand-edit it, and never commit regenerated tables
from a branch (that shared-file churn is what collided on merges; the bot
is the single serialized writer, landing tables via one auto-merge PR).
The coordination gate
(`bash tools/verify-coordination.sh`, `just verify-coordination`, and CI)
validates the table's structure on PRs; sync is enforced only where it is
meaningful — on main.

<!-- LOGS_INDEX:START -->
| Branch | Log file |
|--------|----------|
| `freebuff/m22-lane-d-wave2` | [`0720-m22-lane-d-wave2.md`](0720-m22-lane-d-wave2.md) |
| agent/antigravity/in-guest-compiler | [`agent-antigravity-in-guest-compiler.md`](agent-antigravity-in-guest-compiler.md) |
| `agent/buffy/arc1-checkbox-toggle` | [`agent-buffy-arc1-checkbox-toggle.md`](agent-buffy-arc1-checkbox-toggle.md) |
| `agent/buffy/arc1-progressbar` | [`agent-buffy-arc1-progressbar.md`](agent-buffy-arc1-progressbar.md) |
| `agent/buffy/arc1-scrollview` | [`agent-buffy-arc1-scrollview.md`](agent-buffy-arc1-scrollview.md) |
| `agent/buffy/arc2-context-menu` | [`agent-buffy-arc2-context-menu.md`](agent-buffy-arc2-context-menu.md) |
| `agent/buffy/arc2-resize` | [`agent-buffy-arc2-resize.md`](agent-buffy-arc2-resize.md) |
| `agent/buffy/arc2-tray` | [`agent-buffy-arc2-tray.md`](agent-buffy-arc2-tray.md) |
| agent/buffy/audit-followup-1-gates-docs | [`agent-buffy-audit-followup-1-gates-docs.md`](agent-buffy-audit-followup-1-gates-docs.md) |
| agent/buffy/audit-followup-2-input-depth | [`agent-buffy-audit-followup-2-input-depth.md`](agent-buffy-audit-followup-2-input-depth.md) |
| agent/buffy/audit-followup-3-dhcp-autonomy | [`agent-buffy-audit-followup-3-dhcp-autonomy.md`](agent-buffy-audit-followup-3-dhcp-autonomy.md) |
| agent/buffy/docs-pass | [`agent-buffy-docs-pass.md`](agent-buffy-docs-pass.md) |
| `agent/buffy/fix-728-esp-create-disk-full` | [`agent-buffy-fix-728-esp-create-disk-full.md`](agent-buffy-fix-728-esp-create-disk-full.md) |
| `agent/buffy/fix-boot-fat-geometry` | [`agent-buffy-fix-boot-fat-geometry.md`](agent-buffy-fix-boot-fat-geometry.md) |
| full-table glyph goldens (issue 125 hardening) | [`agent-buffy-full-table-glyph-goldens.md`](agent-buffy-full-table-glyph-goldens.md) |
| generalized bit-order mutation gate (claim 1027) | [`agent-buffy-generalized-mutations.md`](agent-buffy-generalized-mutations.md) |
| issue 125 follow-on: refresh the public site screenshot | [`agent-buffy-glyph-mirror-fix.md`](agent-buffy-glyph-mirror-fix.md) |
| glyph raster convention gate (claim 9100) | [`agent-buffy-glyph-raster-gate.md`](agent-buffy-glyph-raster-gate.md) |
| history recall persistence (claim 6344) | [`agent-buffy-history-recall-persistence.md`](agent-buffy-history-recall-persistence.md) |
| `agent/buffy/hygiene-archive-m5-m6-prompts` | [`agent-buffy-hygiene-archive-m5-m6-prompts.md`](agent-buffy-hygiene-archive-m5-m6-prompts.md) |
| agent/buffy/input-poll-563 | [`agent-buffy-input-poll-563.md`](agent-buffy-input-poll-563.md) |
| agent/buffy/issue-613-tcp-connect-spin | [`agent-buffy-issue-613-tcp-connect-spin.md`](agent-buffy-issue-613-tcp-connect-spin.md) |
| milestone ten userland filesystem & storage ABI (claim 0662) | [`agent-buffy-m10-fs.md`](agent-buffy-m10-fs.md) |
| milestone ten tracker (claim 2412) | [`agent-buffy-m10-tracker.md`](agent-buffy-m10-tracker.md) |
| Architecture & UI contract (ADR 0011) | [`agent-buffy-m11-a0-adr.md`](agent-buffy-m11-a0-adr.md) |
| Micro-widget toolkit & runtime | [`agent-buffy-m11-a1-ui-toolkit.md`](agent-buffy-m11-a1-ui-toolkit.md) |
| `CALC.BIN` (Interactive Graphical Calculator) | [`agent-buffy-m11-a2-calc.md`](agent-buffy-m11-a2-calc.md) |
| `NOTEPAD.BIN` (Graphical Text Editor) | [`agent-buffy-m11-a3-notepad.md`](agent-buffy-m11-a3-notepad.md) |
| `TOP.BIN` (Graphical Task Manager & Process Monitor) | [`agent-buffy-m11-a4-top.md`](agent-buffy-m11-a4-top.md) |
| `DESKTOP.BIN` (Desktop Launcher & Environment) & Capstone Gate | [`agent-buffy-m11-a5-desktop.md`](agent-buffy-m11-a5-desktop.md) |
| `CALC.BIN` polish: checked arithmetic, repeat-op, memory keys | [`agent-buffy-m11-calc-polish.md`](agent-buffy-m11-calc-polish.md) |
| NOTEPAD.BIN scrollable viewport, visible cursor, line wrapping (claim 1771) | [`agent-buffy-m11-notepad-scroll.md`](agent-buffy-m11-notepad-scroll.md) |
| `sys_exec`: the EL0 exec seam (ADR 0007 slot 28) | [`agent-buffy-m11-sys-exec.md`](agent-buffy-m11-sys-exec.md) |
| `sys_kill`: ADR 0007 slot 29, EL0 process termination | [`agent-buffy-m11-sys-kill.md`](agent-buffy-m11-sys-kill.md) |
| Milestone eleven march tracker | [`agent-buffy-m11-tracker.md`](agent-buffy-m11-tracker.md) |
| Milestone 12 Card N1: userland TCP syscall seam | [`agent-buffy-m12-n1-tcp-seam.md`](agent-buffy-m12-n1-tcp-seam.md) |
| Milestone 12 Card N2: bounded DNS client | [`agent-buffy-m12-n2-dns-client.md`](agent-buffy-m12-n2-dns-client.md) |
| Milestone 12 Card N3: capstone applications FETCH.BIN & CHAT.BIN | [`agent-buffy-m12-n3-capstone-apps.md`](agent-buffy-m12-n3-capstone-apps.md) |
| `m13-b1-fs-semantics`: the mutating filesystem syscalls (claim 5801) | [`agent-buffy-m13-b1-fs-semantics.md`](agent-buffy-m13-b1-fs-semantics.md) |
| `m13-b2-manifest`: the desktop application manifest + FP/SIMD vector save (claim 8877) | [`agent-buffy-m13-b2-manifest.md`](agent-buffy-m13-b2-manifest.md) |
| `m13-b3-file-browser`: FILE.BIN, the graphical DATA-partition file browser (claim 4742) | [`agent-buffy-m13-b3-file-browser.md`](agent-buffy-m13-b3-file-browser.md) |
| `m13-b4-desktop-composition`: desktop composition (claim 4046) | [`agent-buffy-m13-b4-desktop-composition.md`](agent-buffy-m13-b4-desktop-composition.md) |
| `m13-pointer-route`: VZ synthesized-pointer root cause (claim 4769) | [`agent-buffy-m13-pointer-route.md`](agent-buffy-m13-pointer-route.md) |
| `m13-u4-pointer-classb`: finish the U4 class-B CG gate (claim 5776) | [`agent-buffy-m13-u4-pointer-classb.md`](agent-buffy-m13-u4-pointer-classb.md) |
| `m13-win-dui-rename`: the `win` → `dui` monitor command rename (claim 2223) | [`agent-buffy-m13-win-dui-rename.md`](agent-buffy-m13-win-dui-rename.md) |
| `agent/buffy/m15-c2-alt-tab` | [`agent-buffy-m15-c2-alt-tab.md`](agent-buffy-m15-c2-alt-tab.md) |
| `agent/buffy/m15-c3-snap-zones` | [`agent-buffy-m15-c3-snap-zones.md`](agent-buffy-m15-c3-snap-zones.md) |
| `agent/buffy/m15-c4-dock` | [`agent-buffy-m15-c4-dock.md`](agent-buffy-m15-c4-dock.md) |
| `agent/buffy/m15-c5c6-notepad` | [`agent-buffy-m15-c5c6-notepad.md`](agent-buffy-m15-c5c6-notepad.md) |
| `agent/buffy/m15-c7-file-preview` | [`agent-buffy-m15-c7-file-preview.md`](agent-buffy-m15-c7-file-preview.md) |
| `agent/buffy/m15-c8-top-sort` | [`agent-buffy-m15-c8-top-sort.md`](agent-buffy-m15-c8-top-sort.md) |
| `agent/buffy/m15-c9-calc-history` | [`agent-buffy-m15-c9-calc-history.md`](agent-buffy-m15-c9-calc-history.md) |
| `agent/buffy/m16-c1-image-format` | [`agent-buffy-m16-c1-image-format.md`](agent-buffy-m16-c1-image-format.md) |
| `agent/buffy/m16-c2-guards` | [`agent-buffy-m16-c2-guards.md`](agent-buffy-m16-c2-guards.md) |
| `agent/buffy/m16-c3-resources` | [`agent-buffy-m16-c3-resources.md`](agent-buffy-m16-c3-resources.md) |
| `agent/buffy/m16-c4-composition` | [`agent-buffy-m16-c4-composition.md`](agent-buffy-m16-c4-composition.md) |
| `agent/buffy/m18-t16-scripting` | [`agent-buffy-m18-t16-scripting.md`](agent-buffy-m18-t16-scripting.md) |
| `agent/buffy/m19-lane-a-shell` | [`agent-buffy-m19-lane-a-shell.md`](agent-buffy-m19-lane-a-shell.md) |
| agent/buffy/m21-compositor-w9-w11-w12 | [`agent-buffy-m21-compositor-w9-w11-w12.md`](agent-buffy-m21-compositor-w9-w11-w12.md) |
| agent/buffy/m21-compositor | [`agent-buffy-m21-compositor.md`](agent-buffy-m21-compositor.md) |
| agent/buffy/m21-window-depth | [`agent-buffy-m21-window-depth.md`](agent-buffy-m21-window-depth.md) |
| `agent/buffy/m22-devtools-d8-d16` | [`agent-buffy-m22-devtools-d8-d16.md`](agent-buffy-m22-devtools-d8-d16.md) |
| `agent/buffy/m23-editor-wave2` | [`agent-buffy-m23-editor-wave2.md`](agent-buffy-m23-editor-wave2.md) |
| `agent/buffy/m23-m24-gate-sweep` | [`agent-buffy-m23-m24-gate-sweep.md`](agent-buffy-m23-m24-gate-sweep.md) |
| `agent/buffy/m23-text-editor` | [`agent-buffy-m23-text-editor.md`](agent-buffy-m23-text-editor.md) |
| `agent/buffy/m24-calc-features` | [`agent-buffy-m24-calc-features.md`](agent-buffy-m24-calc-features.md) |
| agent/buffy/m25-file-manager-depth | [`agent-buffy-m25-file-manager-depth.md`](agent-buffy-m25-file-manager-depth.md) |
| `agent/buffy/m26-net-experience` | [`agent-buffy-m26-net-experience.md`](agent-buffy-m26-net-experience.md) |
| agent/buffy/m26-netstat-fetch | [`agent-buffy-m26-netstat-fetch.md`](agent-buffy-m26-netstat-fetch.md) |
| agent/buffy/m27-desktop-polish | [`agent-buffy-m27-desktop-polish.md`](agent-buffy-m27-desktop-polish.md) |
| `agent/buffy/m28-smp` | [`agent-buffy-m28-smp.md`](agent-buffy-m28-smp.md) |
| `agent/buffy/m29-vm-depth` | [`agent-buffy-m29-vm-depth.md`](agent-buffy-m29-vm-depth.md) |
| `agent/buffy/m30-dynamic-linking` | [`agent-buffy-m30-dynamic-linking.md`](agent-buffy-m30-dynamic-linking.md) |
| `agent/buffy/m31-dynamic-ecosystem` | [`agent-buffy-m31-dynamic-ecosystem.md`](agent-buffy-m31-dynamic-ecosystem.md) |
| agent/buffy/m33-sb1-shared-anon-contract | [`agent-buffy-m33-sb1-shared-anon-contract.md`](agent-buffy-m33-sb1-shared-anon-contract.md) |
| agent/buffy/m33-sb2-shared-anon-capability | [`agent-buffy-m33-sb2-shared-anon-capability.md`](agent-buffy-m33-sb2-shared-anon-capability.md) |
| agent/buffy/m33-sb3-surface-handoff | [`agent-buffy-m33-sb3-surface-handoff.md`](agent-buffy-m33-sb3-surface-handoff.md) |
| agent/buffy/m33-sb4-damage-tracking | [`agent-buffy-m33-sb4-damage-tracking.md`](agent-buffy-m33-sb4-damage-tracking.md) |
| agent/buffy/m33-sb5-wm-compose-n | [`agent-buffy-m33-sb5-wm-compose-n.md`](agent-buffy-m33-sb5-wm-compose-n.md) |
| agent/buffy/m33-sb6-perf-payoff | [`agent-buffy-m33-sb6-perf-payoff.md`](agent-buffy-m33-sb6-perf-payoff.md) |
| `agent/buffy/m34-hf1-hf2-host-file-channel` | [`agent-buffy-m34-hf1-hf2-host-file-channel.md`](agent-buffy-m34-hf1-hf2-host-file-channel.md) |
| M34 HF3 mutation ops (issue #737) | [`agent-buffy-m34-hf3-mutation.md`](agent-buffy-m34-hf3-mutation.md) |
| M34 HF4 app delivery from the host folder (issue #738) | [`agent-buffy-m34-hf4-exec.md`](agent-buffy-m34-hf4-exec.md) |
| milestone nine interactive application events (claim 7463) | [`agent-buffy-m9-events.md`](agent-buffy-m9-events.md) |
| milestone nine tracker (claim 8234) | [`agent-buffy-m9-tracker.md`](agent-buffy-m9-tracker.md) |
| Roadmap refinement (claim 4951) | [`agent-buffy-roadmap-refinement.md`](agent-buffy-roadmap-refinement.md) |
| `agent/buffy/status-compress` | [`agent-buffy-status-compress.md`](agent-buffy-status-compress.md) |
| agent/buffy/strace-marker-freshline | [`agent-buffy-strace-marker-freshline.md`](agent-buffy-strace-marker-freshline.md) |
| agent/buffy/toolchain-env-check | [`agent-buffy-toolchain-env-check.md`](agent-buffy-toolchain-env-check.md) |
| U4 CG-pointer route follow-on (claim 3692) | [`agent-buffy-u4-pointer-cg.md`](agent-buffy-u4-pointer-cg.md) |
| U4 real-mouse pointer follow-on (claim 9015) | [`agent-buffy-u4-pointer-classc.md`](agent-buffy-u4-pointer-classc.md) |
| First-boot experience (claim 8323) | [`agent-buffy-u6-first-boot.md`](agent-buffy-u6-first-boot.md) |
| sysinfo support snapshot (claim 2990) | [`agent-buffy-u7-sysinfo.md`](agent-buffy-u7-sysinfo.md) |
| persistent settings (claim 2649) | [`agent-buffy-u8-persistent-settings.md`](agent-buffy-u8-persistent-settings.md) |
| `agent/buffy/vz-gates-in-ci` | [`agent-buffy-vz-gates-in-ci.md`](agent-buffy-vz-gates-in-ci.md) |
| agent/buffy/wms10-split-adr | [`agent-buffy-wms10-split-adr.md`](agent-buffy-wms10-split-adr.md) |
| agent/buffy/wms2-wmctl-register | [`agent-buffy-wms2-wmctl-register.md`](agent-buffy-wms2-wmctl-register.md) |
| agent/buffy/wms3-wnd-server | [`agent-buffy-wms3-wnd-server.md`](agent-buffy-wms3-wnd-server.md) |
| WMS4 chrome policy drain-out (SET_WINDOW descriptors) | [`agent-buffy-wms4-chrome-drain.md`](agent-buffy-wms4-chrome-drain.md) |
| `agent/buffy/wms5-gate2-geometry-policy` | [`agent-buffy-wms5-gate2-geometry-policy.md`](agent-buffy-wms5-gate2-geometry-policy.md) |
| WMS5 geometry policy drain-out (input seam + SET_WINDOW rects) | [`agent-buffy-wms5-geometry-seam.md`](agent-buffy-wms5-geometry-seam.md) |
| `agent/buffy/wms6-altab-drain` | [`agent-buffy-wms6-altab-drain.md`](agent-buffy-wms6-altab-drain.md) |
| `agent/buffy/wms6-dock-drain` | [`agent-buffy-wms6-dock-drain.md`](agent-buffy-wms6-dock-drain.md) |
| `agent/buffy/wms6-notif-drain` | [`agent-buffy-wms6-notif-drain.md`](agent-buffy-wms6-notif-drain.md) |
| `agent/buffy/wms6-tooltip-drain` | [`agent-buffy-wms6-tooltip-drain.md`](agent-buffy-wms6-tooltip-drain.md) |
| `agent/buffy/wms6-tray-drain` | [`agent-buffy-wms6-tray-drain.md`](agent-buffy-wms6-tray-drain.md) |
| `agent/buffy/wms7-gateb-toolkit-repoint` | [`agent-buffy-wms7-gateb-toolkit-repoint.md`](agent-buffy-wms7-gateb-toolkit-repoint.md) |
| `agent/buffy/wms7-ipc-protocol` | [`agent-buffy-wms7-ipc-protocol.md`](agent-buffy-wms7-ipc-protocol.md) |
| `agent/buffy/wms8-about-delete` | [`agent-buffy-wms8-about-delete.md`](agent-buffy-wms8-about-delete.md) |
| `agent/buffy/wms8-desktop-overlay-drain` | [`agent-buffy-wms8-desktop-overlay-drain.md`](agent-buffy-wms8-desktop-overlay-drain.md) |
| `agent/buffy/wms8-dialog-drain` | [`agent-buffy-wms8-dialog-drain.md`](agent-buffy-wms8-dialog-drain.md) |
| `agent/buffy/wms8-gate4-review-fixes` | [`agent-buffy-wms8-gate4-review-fixes.md`](agent-buffy-wms8-gate4-review-fixes.md) |
| `agent/buffy/wms8-gate5-geometry-keyboard-delete` | [`agent-buffy-wms8-gate5-geometry-keyboard-delete.md`](agent-buffy-wms8-gate5-geometry-keyboard-delete.md) |
| agent/buffy/wms8-gate6-pointer-drag-delete | [`agent-buffy-wms8-gate6-pointer-drag-delete.md`](agent-buffy-wms8-gate6-pointer-drag-delete.md) |
| agent/buffy/wms8-gate7-dead-blocks | [`agent-buffy-wms8-gate7-dead-blocks.md`](agent-buffy-wms8-gate7-dead-blocks.md) |
| `agent/buffy/wms8-unsaved-drain` | [`agent-buffy-wms8-unsaved-drain.md`](agent-buffy-wms8-unsaved-drain.md) |
| agent/buffy/wms9-dsk1-drawing-apps (WMS9/DSK1 drawing-app fix) | [`agent-buffy-wms9-dsk1-drawing-apps.md`](agent-buffy-wms9-dsk1-drawing-apps.md) |
| agent/buffy/wms9-surface-seam-perf | [`agent-buffy-wms9-surface-seam-perf.md`](agent-buffy-wms9-surface-seam-perf.md) |
| agent/gates fleet-remainder | [`agent-gates-fleet-remainder.md`](agent-gates-fleet-remainder.md) |
| per-agent worktrees | [`agent-ox-alpha-agent-worktrees.md`](agent-ox-alpha-agent-worktrees.md) |
| claim lifecycle: declared files + staleness | [`agent-ox-alpha-claim-lifecycle.md`](agent-ox-alpha-claim-lifecycle.md) |
| tracked-only coordination gate | [`agent-ox-alpha-coordination-tracked-gate.md`](agent-ox-alpha-coordination-tracked-gate.md) |
| gate fleet migration (issue #528) | [`agent-ox-alpha-gate-fleet-migration.md`](agent-ox-alpha-gate-fleet-migration.md) |
| agent/ox-alpha/hygiene-trim-hardware-contract | [`agent-ox-alpha-hygiene-trim-hardware-contract.md`](agent-ox-alpha-hygiene-trim-hardware-contract.md) |
| `agent/ox-alpha/m19-p3p4-chaining-exit-status` | [`agent-ox-alpha-m19-p3p4-chaining-exit-status.md`](agent-ox-alpha-m19-p3p4-chaining-exit-status.md) |
| `agent/ox-alpha/m19-p5p6-quoting-globbing` | [`agent-ox-alpha-m19-p5p6-quoting-globbing.md`](agent-ox-alpha-m19-p5p6-quoting-globbing.md) |
| `agent/ox-alpha/m19-p7-background-jobs` | [`agent-ox-alpha-m19-p7-background-jobs.md`](agent-ox-alpha-m19-p7-background-jobs.md) |
| agent/ox-alpha/m25-filemanager-depth | [`agent-ox-alpha-m25-filemanager-depth.md`](agent-ox-alpha-m25-filemanager-depth.md) |
| run-isolated gates via DiskImageKit overlays | [`agent-ox-alpha-run-isolated-gates.md`](agent-ox-alpha-run-isolated-gates.md) |
| `agent/oxalpha/archive-march-m4-m5` | [`agent-oxalpha-archive-march-m4-m5.md`](agent-oxalpha-archive-march-m4-m5.md) |
| `agent/oxalpha/m20-text-unicode` | [`agent-oxalpha-m20-text-unicode.md`](agent-oxalpha-m20-text-unicode.md) |
| t3code/c259b00a (cvc-echo host-push spike) | [`agent-t3code-c259b00a-cvc-echo.md`](agent-t3code-c259b00a-cvc-echo.md) |
| agent/t3code/m27-doc-sync | [`agent-t3code-m27-doc-sync.md`](agent-t3code-m27-doc-sync.md) |
| agent/virtio virtio-input-channel | [`agent-virtio-virtio-input-channel.md`](agent-virtio-virtio-input-channel.md) |
| agent/zcode/m26-net-offline-preflight | [`agent-zcode-m26-net-offline-preflight.md`](agent-zcode-m26-net-offline-preflight.md) |
| milestone eight cards U4+U5: pointer focus/cursor + window HIG (zcode) | [`agent-zcode-m8-u4-u5-windows.md`](agent-zcode-m8-u4-u5-windows.md) |
| `docs-calm-lavoisier-memorial`: Memorial to calm-lavoisier & Git Alignment (claim 9357) | [`docs-calm-lavoisier-memorial.md`](docs-calm-lavoisier-memorial.md) |
| `docs/site-current-state-m15`: refresh the public GitHub Pages site to current reality (claim 7489) | [`docs-site-current-state-m15.md`](docs-site-current-state-m15.md) |
| `site-current-state`: refresh the public GitHub Pages site to current reality (claim 1662) | [`docs-site-current-state.md`](docs-site-current-state.md) |
| freebuff/can-you-check-out-our-status-and-work-on-the-next (milestone six, G4) | [`freebuff-20260814-001.md`](freebuff-20260814-001.md) |
| freebuff/can-you-figure-out-why-the-text-is-getting-flipped (issue #125 glyph orientation) | [`freebuff-20260815-001.md`](freebuff-20260815-001.md) |
| freebuff/hey-bestie-the-chat-got-lost-so-we-re-so-back-can--53baf792-c2f8-470d-a9f1-6344aa90847a (M14 shared user services) | [`freebuff-20260818-001.md`](freebuff-20260818-001.md) |
| `m14-s1-clipboard`: the bounded kernel clipboard (claim 0169) | [`freebuff-20260818-002.md`](freebuff-20260818-002.md) |
| freebuff/can-you-review-issues-223-247-and-try-to-provide-h (planning pass for issues #223–#247) | [`freebuff-20260820-001.md`](freebuff-20260820-001.md) |
| freebuff/okay-i-think-we-need-to-work-through-this-big-one--076be815-d689-40da-9389-cfd56bae921f (Milestone 18 — Rename — VirelaiOS) | [`freebuff-20260831-001.md`](freebuff-20260831-001.md) |
| freebuff/b0ce3067 (host file channel — M34 planning) | [`freebuff-20260831-002.md`](freebuff-20260831-002.md) |
| lane-b/m24-calc-features | [`lane-b-m24-calc-features.md`](lane-b-m24-calc-features.md) |
| `lane-c/m20-text-rendering` | [`lane-c-m20-text-rendering.md`](lane-c-m20-text-rendering.md) |
| `lane-d/m22-dev-tools` | [`lane-d-m22-dev-tools.md`](lane-d-m22-dev-tools.md) |
| t3code concurrent-agents merge conflicts | [`t3code-concurrent-agents-merge-conflicts.md`](t3code-concurrent-agents-merge-conflicts.md) |
| `t3code/fetch-issue-264-details` | [`t3code-fetch-issue-264-details.md`](t3code-fetch-issue-264-details.md) |
| t3code/finish-523-console-snapshots | [`t3code-finish-523-console-snapshots.md`](t3code-finish-523-console-snapshots.md) |
| t3code/finish-issue-523-progress | [`t3code-finish-issue-523-progress.md`](t3code-finish-issue-523-progress.md) |
| t3code/fix-issue-267-git-current (docs/logs hygiene) | [`t3code-fix-issue-267-git-current.md`](t3code-fix-issue-267-git-current.md) |
| `t3code/handle-issue-268-git-current` | [`t3code-handle-issue-268-git-current.md`](t3code-handle-issue-268-git-current.md) |
| `t3code/issue-265-fix` | [`t3code-issue-265-fix.md`](t3code-issue-265-fix.md) |
| `t3code/milestone-nine-triage` | [`t3code-milestone-nine-triage.md`](t3code-milestone-nine-triage.md) |
| t3code/prune-claims-269 | [`t3code-prune-claims-269.md`](t3code-prune-claims-269.md) |
<!-- LOGS_INDEX:END -->
