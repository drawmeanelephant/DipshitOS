# Claim: M32 window-manager server migration — ADR + roadmap

- **Owner:** buffy (`agent/buffy/docs-pass`)
- **Prompt / plan:** architecture analysis + decision (full userland WM migration, seam A) — see `docs/march-m32-wm-migration.md` and `docs/decisions/0015-window-server-render-seam.md`
- **Scope:** planning slice of M32 — the ADR (render seam, slot 65, kind 18) and the migration roadmap. Implementation claims follow per card.
- **Touches:** docs/decisions/0015-window-server-render-seam.md, docs/march-m32-wm-migration.md, docs/status.md, docs/logs/agent-buffy-docs-pass.md
- **Depends on:** none (post-M31 planning)
- **Heartbeat:** 2026-08-28
- **Status:** 🔄 agent/buffy/docs-pass

## Notes (2026-08-28 — issue scoping addendum)

The ten GitHub issues (#621–#630, milestone 16) were scoped from the card plan:
each body now carries a fixed template — Goal / Why this order (depends +
blocks) / In scope (checkboxes) / Out of scope / Acceptance (gate) / Risks /
Touches. Scoping additions beyond the draft, marked per-issue: WMS2 WM-death
teardown (kernel falls back to the shim when the registered WM exits), WMS3
bootstrap + hung-WM watchdog, WMS5 input-seam handover (the WM hit-tests; the
kernel only fans the stream out), WMS7 mailbox-size decision grounded in the
real 8×64 B mailbox bound, WMS9 prior art (slot 46 `sys_win_fill_batch`
already exists — measure it first, extend its payload, no new slot).
`docs/march-m32-wm-migration.md` carries the dependency-phases map; the
original planning notes below are unchanged.

## Notes

Today the entire desktop window-management *policy* is a ~4,740-line kernel
component (`kernel/src/driving_award.zig`) composited from the shell idle loop,
with apps reaching it only through draw syscalls. This claim scopes how we make
it viable to build on: move policy out into a userland **WM server**, leaving
the kernel a thin render + input + surface server (seam A), shim-and-slim so no
M18–M31 gate regresses. This claim delivers the two binding documents (ADR 0015
reserving slot 65 `sys_wmctl` + event kind 18 `COMPOSITE_TICK`, and the
`march-m32-wm-migration.md` card plan); the code is claimed per-card (WMS2+) by
their own claims citing ADR 0015.

**Verified when:** ADR 0015 present + not yet accepted, the march doc lists the
ordered cards, docs/status.md points to M32, and the branch log carries this
entry. Docs-only — no code in this claim.