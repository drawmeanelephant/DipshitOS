# Log — agent/ox-alpha/m25-filemanager-depth

Append-only. One entry per unit of work; corrections are new entries
that reference the old one.

---

## 2026-08-23 — claims 0434 (Lane A) + 2539 (Lane B) opened

M25 file-manager depth, both lanes, sequential on this branch (the
lanes share `user/src/file_browser.zig`; one editor per file honored by
doing them in order).

Pre-flight findings recorded before any code:

- **Stale issue states upstream:** F11 closed correctly, but F12 (#392,
  hidden toggle) and F16 (#396, path copy) are already implemented on
  `main` (commit `658bd86`, PR #512) while their issues remain open.
  Will verify against HEAD and close with evidence pointers at the end.
- **F3 card is wrong about scope:** issue #383 says directory creation
  "uses existing `sys_file_create` (slot 25)" with no kernel work, but
  `ATTR_DIRECTORY` appears nowhere under `kernel/src` — there is no FAT32
  directory-create path today. Lane B therefore includes kernel-side
  directory creation (cluster allocation + zeroed cluster + `.`
  / `..` dot entries + ATTR-directory dir entry), extending slot 25's
  contract instead of minting a new slot (ABI budget: 56/64 used).
- `docs/march-m25.md` only tracks F1–F5; F6–F18 exist solely as GitHub
  issues. March file will be updated for the cards this branch lands;
  the rest stays open for follow-up claims.

Claims: [`docs/claims/0434-m25-lane-a-bulk-props.md`](../claims/0434-m25-lane-a-bulk-props.md),
[`docs/claims/2539-m25-lane-b-mkdir-du-recent.md`](../claims/2539-m25-lane-b-mkdir-du-recent.md).
Indexes refreshed.

---

## 2026-08-25 — claims resumed post-PR-561 (branch recreated)

Resuming both lanes after two idle days. Context since the claims were
opened: buffy's claim 4379 (⛔ yielded) landed PR #561 on main —
selection bitmap, Dialog/ProgressBar widget wiring, and a batch-index
fix — as explicitly reference groundwork. This branch builds F1–F5
properly on that base under the same claim identity (owner fields
updated in place with `Touches:` declarations; heartbeats bumped).

Scope adjustment (Lane B): the first coordination run failed — ACTIVE
claim 8777 (`t3code/milestone-nine-triage`, heartbeat 2026-08-25) holds
`kernel/src/monitor.zig`, `kernel/src/shell.zig`, and `docs/status.md`.
The `du` shell command needs a monitor registry entry, so Lane B splits:
this branch lands F3 + F5 + Lane A + a reusable
`fat.dir_size_recursive` walker and the FILE.BIN breadcrumb total; the
one-row `du` registry hookup (and its `-du.sh` live gate, and any
status.md prose) follows once 8777 lands. Correction to the 2026-08-23
entry: the create seam being extended is slot 23 (`sys_file_open`
flags — `MODE_CREATE` already lives there), not slot 25.

---

## 2026-08-25 — Lane A ✅ + most of Lane B landed; two honest deferrals

Implementation summary (all on `agent/ox-alpha/m25-filemanager-depth`,
rebuilt on the merged PR #561 groundwork):

- **F3 (claim 2539):** kernel `fat.create_dir` (first-fit cluster,
  zeroed contents, spec §6.5 dot entries — `..` = cluster 0 under root —
  ATTR_DIRECTORY slot), slot 23 flag extension `MODE_DIR` (+`-9 EEXIST`),
  EL0 `ui.file_mkdir`; FILE.BIN's overlay confirm now calls it. Host
  tests pin the on-disk dot-entry bytes and collision refusals.
- **F4 (claim 2539):** `fat.dir_size_recursive` BFS walker (module-scope
  buffers, depth ≤ 3 — a recursive listing would have stacked ~11 KiB per
  level on the kernel stack, claim 1809's lesson) + FILE.BIN breadcrumb
  total (`du=` in every listing marker). Shell `du` registry row DEFERRED
  while claim 8777 holds monitor.zig/shell.zig.
- **F5 (claim 2539):** ring persisted to `/data/RECENT.SAV` (leading-dot
  names are not representable in FAT 8.3 — first attempt `.recent`
  failed encode_83 live), loaded at init; virtual RECENT entry injected
  and pinned at row 0 of the root listing; read-only pseudo-listing with
  full-path opens; dedup move-to-front.
- **Lane A (claim 0434):** right-click context menu (ui.ContextMenu's
  first consumer) → Open/Rename/Delete/Properties; properties toggle
  markers; batch ops rebuilt as a stepwise engine — one unit per loop
  pass, ProgressBar genuinely advancing across frames, one serial marker
  per unit (`file: del i/n NAME`) — replacing the synchronous overdraw.
- **Infra (unclaimed files):** VMRunner chord vocabulary gains
  `ctrl-shift-x` / combined-modifier HID strokes (macChord + hidChord);
  EL0 `task_stack_size` 16 → 32 KiB after live guard-page status=139
  faults — AppState is ~7.3 KiB and real feature chains overflowed the
  rest; BSS delta inside verify-bss-budget headroom.

Live gates (class B, all PASS on this host): bulk, props, mkdir
(headless FSTEST walk), recent. Evidence under `artifacts/live-*`.

**Deferral 1 — Ctrl+Shift+N chord walk:** M21 W3's global Ctrl+N
minimize intercept fires on the Shift combo too and steals focus
mid-walk (observed: strokes 2+ landed in the monitor as "docs"). The
one-line shift-guard lives in `kernel/src/input.zig`, held ACTIVE by
claim 8777 (their Next list is literally the W3 gate) — the UI walk +
gate update follow when that lands. Overlay wiring is unit-pinned; the
SEAM is live-gated headlessly.

**Deferral 2 — shell `du`:** same coordination constraint, different
file (monitor.zig). Walker + breadcrumb half are live.

Correction to today's earlier entry: persistence path is RECENT.SAV
(8.3-representable), not .recent.
