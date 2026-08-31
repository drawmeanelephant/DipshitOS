# ADR 0017: VirelaiOS codename — retire "DipshitOS"

Status: **ACCEPTED** (claim 5817) · Date: 2026-08-31 · Milestone: Rename —
VirelaiOS (issue #676, GH milestone 18) · Proposed by: issue #676
(PROPOSED — PARKED, 2026-08-30); executed and accepted by claim 5817

> **Accepted 2026-08-31 by claim 5817 (the rename sweep).** Issue #676
> originally drafted this ADR as "0016", but `0016` was claimed while the ADR
> sat PARKED: the M33 seam-B contract (`docs/decisions/0016-shared-anonymous-
> mmap.md`, claim 7418) was ACCEPTED 2026-08-30. The codename ADR therefore
> takes the next free number, **0017**.

## Context

The project's name is a joke; the engineering is not. After eleven milestones,
a zero-open-issue tracker, and an evidence discipline that gates every byte on
real hardware, the name had become a band t-shirt: worn with affection, but
visibly outgrown. Issue #676 green-lit a rename to **VirelaiOS** and parked
this ADR until execution.

The name with receipts (Rule 1: directly observed, never inferred):

- **VIRELAIOS is an exact anagram of LAVOISIER** (`sorted("virelaios") ==
  sorted("lavoisier")`) — the conservation epigraph enacting itself on the
  name: the letters were conserved, only the arrangement was transformed.
- A **virelai** is a medieval French *forme fixe* (ballade, rondeau,
  virelai) built on a returning refrain — the refrain that returns on
  schedule here is a gate that runs on every merge.
- **Collision-proof by construction**: a sweep of Webster's Second
  International (1934, 235,976 entries) for 7-letter words over
  `{a,e,i,i,l,r,v}` returns zero hits — the dictionary does not even
  contain `virelai` itself.
- `github.com/VirelaiOS` was unclaimed (404, observed 2026-08-29).
- Rejected candidates: *Calm Lavoisier* (shelved — existing "Calm OS" in the
  search space), *Oil Varies* (the internet's other Lavoisier anagram), and
  *Octoburger* (taxonomically fraudulent; reassigned to menu duty, #677).

## Decision

Retire the name **DipshitOS** everywhere except protected/historical
locations and URLs, per the mechanical scope below, and rename the project to
**VirelaiOS**. The old name is memorialized in a protected archive location
(`docs/archive/dipshitos-name.md`) so the historical reference survives by
design, not by accident.

### Scope (executed under claim 5817)

- **R1 — Guest identity** (issue #697): boot prompt `dipshit>` → `virelai>`;
  hostname `dipshit` → `virelai`; `dipshit-kernel` → `virelai-kernel`;
  `.dipshitrc` → `.virelairc`; `dipshit.local` → `virelai.local`. Every form
  is byte-width-identical (`dipshit` ↔ `virelai`, 8 letters), so exact-byte
  transcript gates keep their rhythm.
- **R2 — Build + infra + themes** (issue #698): `build.zig.zon` → `.name =
  .virelaios` (fingerprint regenerated: `0x3aede7e1b1ff4f1c`); kernel
  artifact → `virelai-kernel`; `DIPSHITOS_REV` → `VIRELAIOS_REV`; CI artifact
  `dipshitos-artifacts-macos` → `virelaios-artifacts-macos`; host Swift
  `dipshitos.*` dispatch labels → `virelaios.*`, `dipshit-overlay-` →
  `virelai-overlay-`; `themes/dipshitos` → `themes/virelaios` (dir, CSS,
  layouts, workflow refs); worktree prefix `../dipshitos-` → `../virelaios-`
  (justfile + AGENTS.md).
- **R3 — Test fixtures + golden transcripts** (issue #699): every class-A
  transcript assert, gate-script `--script-expect` target, and the golden
  `tests/transcript-console.txt` (regenerated from the mock e2e output, not
  hand-edited). Internal NVRAM protocol names (`DipshitM2`, `DipshitC0`,
  `DIPSHITC`, `DipshitP*`, `DIPSHITOS PREEXIT VIRTIO TX`) renamed in lockstep
  across kernel and host.
- **R4 — Docs prose + audit** (issue #700): README / site / living-docs
  prose; `site/names.md` gains the name (lore lands when the code lands);
  post-sweep `rg -i dipshit` audit.

### Protected / untouched

- `docs/archive/**` (including the new `docs/archive/dipshitos-name.md`),
  `docs/claims/**`, `docs/logs/**`, ADRs 0001–0016,
  `tools/ragshit/CHANGELOG.md`, and `artifacts/**` — history is append-only.
- GitHub repo slug, badges, and Pages URLs stay `DipshitOS` until the repo
  itself is renamed (protected-URL sweep; this ADR does not rename GitHub).

## Supersedes

ADR 0008's "the prompt stays `dipshit>` " clause (HIG). The interactive
prompt is now `virelai> ` — same byte width, same exact-byte transcript
rhythm, same gate.

## Verification

`bash tools/verify-unit-tests.sh` PASS; `zig build test-console` PASS
(transcript byte-identical to the regenerated golden); `zig build` +
`zig build image` + `zig build inspect` + `zig build context` PASS;
`zig fmt --check` PASS; ragshit pytest 147/147 PASS; post-sweep
`rg -i dipshit` audit: zero occurrences outside protected/historical
locations and GitHub repo-slug URLs. The coordination gate's only failure is
the documented Touches overlap with pre-existing 🔄 claims 2852 and 9731
(the cross-cutting rename inherently touches those files).

## Conservation

*"Rien ne se perd, rien ne se crée, tout se transforme."* The chemist became
a poem; nothing was lost. The old name lives on in history, in the archive,
and in the gate logs that still read it out loud — and `virelai>` carries the
refrain forward.
