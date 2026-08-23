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
5. Run `bash tools/status/refresh-indexes.sh` to regenerate the
   [Log index](#log-index) below — it is **generated from the log files**,
   so never hand-edit it (hand-appending rows to a shared table is how
   parallel branches collide on merge).

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
`bash tools/status/refresh-indexes.sh` — do not hand-edit it. The
coordination gate (`bash tools/verify-coordination.sh`, `just
verify-coordination`, and CI) fails if it drifts from the files.

<!-- LOGS_INDEX:START -->
| Branch | Log file |
|--------|----------|
| `agent/buffy/arc1-checkbox-toggle` | [`agent-buffy-arc1-checkbox-toggle.md`](agent-buffy-arc1-checkbox-toggle.md) |
| `agent/buffy/arc1-progressbar` | [`agent-buffy-arc1-progressbar.md`](agent-buffy-arc1-progressbar.md) |
| `agent/buffy/arc1-scrollview` | [`agent-buffy-arc1-scrollview.md`](agent-buffy-arc1-scrollview.md) |
| `agent/buffy/arc2-context-menu` | [`agent-buffy-arc2-context-menu.md`](agent-buffy-arc2-context-menu.md) |
| `agent/buffy/arc2-resize` | [`agent-buffy-arc2-resize.md`](agent-buffy-arc2-resize.md) |
| `agent/buffy/arc2-tray` | [`agent-buffy-arc2-tray.md`](agent-buffy-arc2-tray.md) |
| agent/buffy/audit-followup-1-gates-docs | [`agent-buffy-audit-followup-1-gates-docs.md`](agent-buffy-audit-followup-1-gates-docs.md) |
| agent/buffy/audit-followup-2-input-depth | [`agent-buffy-audit-followup-2-input-depth.md`](agent-buffy-audit-followup-2-input-depth.md) |
| agent/buffy/audit-followup-3-dhcp-autonomy | [`agent-buffy-audit-followup-3-dhcp-autonomy.md`](agent-buffy-audit-followup-3-dhcp-autonomy.md) |
| full-table glyph goldens (issue 125 hardening) | [`agent-buffy-full-table-glyph-goldens.md`](agent-buffy-full-table-glyph-goldens.md) |
| generalized bit-order mutation gate (claim 1027) | [`agent-buffy-generalized-mutations.md`](agent-buffy-generalized-mutations.md) |
| issue 125 follow-on: refresh the public site screenshot | [`agent-buffy-glyph-mirror-fix.md`](agent-buffy-glyph-mirror-fix.md) |
| glyph raster convention gate (claim 9100) | [`agent-buffy-glyph-raster-gate.md`](agent-buffy-glyph-raster-gate.md) |
| `agent/buffy/hygiene-archive-m5-m6-prompts` | [`agent-buffy-hygiene-archive-m5-m6-prompts.md`](agent-buffy-hygiene-archive-m5-m6-prompts.md) |
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
| # Branch log: agent/buffy/m21-compositor | [`agent-buffy-m21-compositor.md`](agent-buffy-m21-compositor.md) |
| `agent/buffy/m24-calc-features` | [`agent-buffy-m24-calc-features.md`](agent-buffy-m24-calc-features.md) |
| milestone nine interactive application events (claim 7463) | [`agent-buffy-m9-events.md`](agent-buffy-m9-events.md) |
| milestone nine tracker (claim 8234) | [`agent-buffy-m9-tracker.md`](agent-buffy-m9-tracker.md) |
| Roadmap refinement (claim 4951) | [`agent-buffy-roadmap-refinement.md`](agent-buffy-roadmap-refinement.md) |
| `agent/buffy/status-compress` | [`agent-buffy-status-compress.md`](agent-buffy-status-compress.md) |
| U4 CG-pointer route follow-on (claim 3692) | [`agent-buffy-u4-pointer-cg.md`](agent-buffy-u4-pointer-cg.md) |
| U4 real-mouse pointer follow-on (claim 9015) | [`agent-buffy-u4-pointer-classc.md`](agent-buffy-u4-pointer-classc.md) |
| First-boot experience (claim 8323) | [`agent-buffy-u6-first-boot.md`](agent-buffy-u6-first-boot.md) |
| sysinfo support snapshot (claim 2990) | [`agent-buffy-u7-sysinfo.md`](agent-buffy-u7-sysinfo.md) |
| persistent settings (claim 2649) | [`agent-buffy-u8-persistent-settings.md`](agent-buffy-u8-persistent-settings.md) |
| agent/ox-alpha/hygiene-trim-hardware-contract | [`agent-ox-alpha-hygiene-trim-hardware-contract.md`](agent-ox-alpha-hygiene-trim-hardware-contract.md) |
| `agent/oxalpha/archive-march-m4-m5` | [`agent-oxalpha-archive-march-m4-m5.md`](agent-oxalpha-archive-march-m4-m5.md) |
| milestone eight cards U4+U5: pointer focus/cursor + window HIG (zcode) | [`agent-zcode-m8-u4-u5-windows.md`](agent-zcode-m8-u4-u5-windows.md) |
| `docs-calm-lavoisier-memorial`: Memorial to calm-lavoisier & Git Alignment (claim 9357) | [`docs-calm-lavoisier-memorial.md`](docs-calm-lavoisier-memorial.md) |
| `docs/site-current-state-m15`: refresh the public GitHub Pages site to current reality (claim 7489) | [`docs-site-current-state-m15.md`](docs-site-current-state-m15.md) |
| `site-current-state`: refresh the public GitHub Pages site to current reality (claim 1662) | [`docs-site-current-state.md`](docs-site-current-state.md) |
| freebuff/can-you-check-out-our-status-and-work-on-the-next (milestone six, G4) | [`freebuff-20260814-001.md`](freebuff-20260814-001.md) |
| freebuff/can-you-figure-out-why-the-text-is-getting-flipped (issue #125 glyph orientation) | [`freebuff-20260815-001.md`](freebuff-20260815-001.md) |
| freebuff/hey-bestie-the-chat-got-lost-so-we-re-so-back-can--53baf792-c2f8-470d-a9f1-6344aa90847a (M14 shared user services) | [`freebuff-20260818-001.md`](freebuff-20260818-001.md) |
| `m14-s1-clipboard`: the bounded kernel clipboard (claim 0169) | [`freebuff-20260818-002.md`](freebuff-20260818-002.md) |
| freebuff/can-you-review-issues-223-247-and-try-to-provide-h (planning pass for issues #223–#247) | [`freebuff-20260820-001.md`](freebuff-20260820-001.md) |
| lane-b/m24-calc-features | [`lane-b-m24-calc-features.md`](lane-b-m24-calc-features.md) |
| `lane-c/m20-text-rendering` | [`lane-c-m20-text-rendering.md`](lane-c-m20-text-rendering.md) |
| `lane-d/m22-dev-tools` | [`lane-d-m22-dev-tools.md`](lane-d-m22-dev-tools.md) |
| `t3code/fetch-issue-264-details` | [`t3code-fetch-issue-264-details.md`](t3code-fetch-issue-264-details.md) |
| t3code/fix-issue-267-git-current (docs/logs hygiene) | [`t3code-fix-issue-267-git-current.md`](t3code-fix-issue-267-git-current.md) |
| `t3code/handle-issue-268-git-current` | [`t3code-handle-issue-268-git-current.md`](t3code-handle-issue-268-git-current.md) |
| `t3code/issue-265-fix` | [`t3code-issue-265-fix.md`](t3code-issue-265-fix.md) |
| t3code/prune-claims-269 | [`t3code-prune-claims-269.md`](t3code-prune-claims-269.md) |
<!-- LOGS_INDEX:END -->
