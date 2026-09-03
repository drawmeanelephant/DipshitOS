# Claim: M37 DQ3 — Tab mouse interaction (issue #839)

- **Owner:** t3code (`agent/t3code/dq3-tab-interact`)
- **Prompt / plan:** `docs/march-m37-desktop-quality.md` (DQ3 row), issue #839
- **Scope:** DQ3 only — click a tab to switch (via `activate_tab`), `×`
  closes/detaches, drag-to-detach converts to standalone window.
  Strictly after DQ2 (pixels + shared hit geometry exist). No restyle
  (DQ4), no new syscalls by default.
- **Touches:** docs/claims/8605-dq3-tab-mouse-interaction.md, docs/logs/agent-t3code-dq3-tab-interact.md, docs/march-m37-desktop-quality.md, user/src/wnd.zig, tools/verify-live-tabclick.sh
- **Depends on:** DQ2 render (merged PR #847 — pixels + `tab_item_rect` /
  `tab_close_rect` / `tab_rect_contains` shared rules; card #840 open
  pending pixel proof, which does not block interaction: hit-testing is
  pure geometry over the same rules)
- **Heartbeat:** 2026-09-03
- **Status:** 🔄 agent/t3code/dq3-tab-interact

## Notes

Clicks route through the kind-19 pointer path WND already owns
(title-bar drag, snap-on-drop, dock/close/minimize clicks): hit-test
the strip with the DQ2 shared rules, dispatch to the existing
`activate_tab` / `detach_tab` fns. TABHOLD.BIN reuses as the held-tab
click target; live gate drives `--pointer-virtio` clicks (claim-9367
pattern) and asserts focus/visibility flips + detach in the serial log.
Scope design note on #839 before implementing.

## Status 2026-09-03: code complete, partial live proof (infra flake)

- **Shipped:** pure `tab_hit_at` + Chebyshev threshold + press state +
  pointer-path wiring (strip consumes edge before title grab) +
  `tab-drag` marker + `verify-live-tabclick.sh` (3 boots). Unit wnd
  105/105 (hit/close/miss/threshold). Build/BSS/coord clean. No
  kernel, TABHOLD, or runner changes.
- **Live click→activate: proven 4×** (`wnd: tab-activate id=3` via
  injected click, twice in clean rc=0 boots).
- **Live ×→detach: proven 1×** via a temporary instrumented run
  (local `artifacts/dbg-tabclick-x-detach-serial.log`, debug removed
  after): press id=3 close=1 → release drag=0 → `tab-detach child=3`,
  rc=0. The same run dumped mirrors proving the geometry the hit-test
  used (container id=2 visible 56,56,512,384; child id=3 hidden,
  parent=2).
- **Drag transition/drop: unit-pinned only** (threshold + dispatch
  share the proven press/detach paths). Full 3-boot green pending a
  quiet host — same session flake as #843 (early-WND 0xac faults,
  input drops with all steps enqueued, repeated EL1h parking).
- Triage technique that paid off: temporary down-edge + mirror-dump
  markers (removed before commit) distinguished guest-hit-miss from
  input-delivery-drop.
