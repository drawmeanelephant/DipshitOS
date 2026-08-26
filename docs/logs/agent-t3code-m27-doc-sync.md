# Log — agent/t3code/m27-doc-sync

## 2026-08-26 — t3code

**M27 tracker renumbering + issue grooming (docs only, no claim needed —
no source files touched).**

GitHub side (same day, via `gh issue edit`, no branch required):

- Rewrote six audit-shaped M27 issues into single-file-ownership cards:
  #452 (G9 menu helper), #454 (G11 two-phase clipboard matrix),
  #455 (G12 cursor feedback only), #456 (G13 focus behaviors split),
  #465 (G22 empty-state helper + bounded surfaces), #466 (G23 error
  formatter + bounded adoptions).

Branch side (`docs/march-m27.md`, `docs/status.md`):

- `march-m27.md` previously compressed M27 into six G-cards whose
  numbering did not match the GitHub issue list (#444–#473, G1–G30).
  Rewrote the card table to canonical numbering with per-card owning
  file, coordination status, and dependency/blocker notes. Verified the
  active claim 4402 (`agent/buffy/m21-compositor`, old "G1–G7") maps
  onto new G1, G3–G7 under the new numbering — no claim churn caused.
- Added suggested ordering (G27 screenshot tooling first, G30 dogfood
  last) and explicit blocked notes for G8/G29 merge decision,
  G15 vs M21 W13 overlap, and G17/G18 dependency on W11/T14.
- `status.md` milestone table row updated from "G1–G6" to the canonical
  "G1–G30 = issues #444–#473".

No code files touched; Buffy's driving_award.zig lane is unaffected.
