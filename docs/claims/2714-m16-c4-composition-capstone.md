# Claim: M16 C4 — the composition capstone (kernel grew up)

- **Owner:** buffy (`agent/buffy/m16-c4-composition`)
- **Prompt / plan:** `docs/march-m16.md` (card C4, issue #193)
- **Scope:** milestone sixteen card C4 — ONE desktop session proves C1+C2+C3
  together: a bigger app with real globals runs next to a guard-page-refused
  hostile app, and the desktop holds more concurrent programs than the old
  pool allowed.
- **Depends on:** C1 (`agent/buffy/m16-c1-image-format`) + C2
  (`agent/buffy/m16-c2-guards`) + C3 (`agent/buffy/m16-c3-resources`).
- **Status:** ✅ done — live gate PASS 1/1 (2026-08-19)

## Notes

The milestone's human-perceivable "kernel grew up" test, device-agnostic
(the default VM stays byte-identical; no sound/gfx/input flags). One boot
runs `GLOBALS.BIN` (C1: 28 KiB image, writable `.data` + zero-filled BSS,
exits 42), `GUARD.BIN` (C2: steps into the guard page, reaped 139) beside
a persistent `COUNTER.BIN` neighbor, then fills the grown pool with seven
`USER.BIN`s — eight live user programs, `resources: tasks=11/11` — the
capacity the OLD 7-slot pool refused.

Live gate: `verify-live-m16-composition.sh`, three scripted phases so the
transient C1/C2 programs are reaped (slot freed) before the C3 fill, then
a `procs` snapshot pinning eight running rows alongside the two exited
programs (`exit=42` / `exit=139`) and a responsive shell. **PASS 1/1 on VZ.**

**C4 finding — the page-table carve-out grows too.** The carve-out is a
TOTAL-roots budget (`mmu.table_count` is a monotonic cursor — table pages
are never reclaimed on reap), so the composition's roots — a 28 KiB
segmented app (~44 pages) + a hostile app + EIGHT concurrent programs —
total **282 pages**, exceeding the OLD 256-page carve-out: the last two
`USER.BIN`s were refused with `table_full` (not `pool_full`). This card
grows `mmu.table_page_count` 256 → 512 (2 MiB BSS) and re-derives the
scale gate + the monitor `resources` host test to the new capacity. The
observed post-growth accounting: `resources: tasks=11/11 procs=11/16
tables=282/512` — eight live programs, both transients reaped, 230 pages
of headroom.
