# Claim: Trim roadmap.md — archive completed milestone plans (GH #264)

- **Owner:** t3code (`t3code/fetch-issue-264-details`)
- **Prompt / plan:** https://github.com/DipshitOS/DipshitOS/issues/264
- **Scope:** Repo hygiene — `docs/roadmap.md` is 1444 lines, mostly completed-milestone
  detail (M0–M16). Move each completed milestone's full plan to
  `docs/archive/roadmap-m{N}.md`, replace it in the main file with a one-line pointer,
  and keep the forward-looking material (header, current position / next-work pointers,
  the wishlist hope chest, the meta-requirement) in place. Target: ~200–300 lines.
  Live references to moved sections updated so no link breaks (march-m4/m5/m6/m7).
  Historical `docs/claims/` + `docs/logs/` entries are append-only and stay untouched.
- **Depends on:** —
- **Status:** ✅ done 2026-08-21

## Notes

Why: the roadmap is the second file agents read after status.md; at 1444 lines most
of its content describes work that shipped weeks ago and burns context on every read.

Mapping (verified against the file at HEAD cc1857d):
- M0 → `docs/archive/roadmap-m0.md`; M1 → `roadmap-m1.md`; M2 → `roadmap-m2.md`;
  M1.5 → `roadmap-m1.5.md`; M3 → `roadmap-m3.md`.
- "Later milestones (sketches)" section: the done M4 card bullets → `roadmap-m4.md`;
  the network stack rungs N1–N6 → `roadmap-m5.md`.
- M6 graphics → `roadmap-m6.md`; M7 input + the virtio device surface table →
  `roadmap-m7.md`; M8 usability → `roadmap-m8.md`.
- Candidate-ladders section: bridge note + M9 → `roadmap-m9.md`; M10 → `roadmap-m10.md`;
  M11 → `roadmap-m11.md`; M12 → `roadmap-m12.md`; M13 → `roadmap-m13.md`;
  M14 → `roadmap-m14.md`; M15 → `roadmap-m15.md`; M16 → `roadmap-m16.md`.
- Stays in `docs/roadmap.md`: header/intro, the completed-milestone one-line index,
  current position + next-work pointers (M17+ detail already lives in
  `docs/m17-desktop-completeness.md` + `docs/march-arc2.md`), the wishlist
  (destinations, not commitments — still deferred-items source for status.md),
  and the meta-requirement.

Verification plan: line count of the new roadmap (~200–300), repo-wide grep showing
no live doc still points at removed roadmap anchors, `refresh-indexes.sh` +
`verify-coordination.sh` green, relative-link check on edited docs.

## Verification

- `docs/roadmap.md`: 1444 → 197 lines. Kept: header + archive pointer, the
  completed-milestone one-line index (M0–M16), a pointer-level "current position &
  next work (M17+)" section, the wishlist hope chest verbatim, and the
  meta-requirement.
- 18 archive files created under `docs/archive/` (`roadmap-m0.md` … `roadmap-m16.md`,
  incl. `roadmap-m1.5.md`): content extracted VERBATIM from the old roadmap; each has
  a standard archived-header pointing at `docs/status.md`; relative links rewritten
  for the new depth (`](status.md)` → `](../status.md)`, march/decisions likewise;
  M6's intra-roadmap anchor link now targets `roadmap-m7.md`). Special carries: the
  M1.5 close-out bullet → `roadmap-m1.5.md`; the done M4 card bullets from "Later
  milestones" → `roadmap-m4.md`; network rungs N1–N6 → `roadmap-m5.md`; the
  cross-milestone virtio device surface table (stale by archive time, noted in its
  header) → `roadmap-m7.md`; the claim-4951 architectural-bridge note → `roadmap-m9.md`.
- Content-integrity spot check: distinctive phrases from every moved section
  (`DIPSHITOS BOOTLOADER`, `adrp`, `seized control`, `first-fit bitmap allocator`,
  `VIRTIO_NET_F_MTU`, `HCSPARAMS1=0x10002010`, `Ctrl-A/E/K/U/L/C`, `CLICKME.BIN`,
  `TYPE.BIN`, `sys_clipboard_set`, `Twinkle Twinkle`, …) each found in exactly the
  expected archive file(s).
- Live references updated so no link breaks: `docs/march-m4.md`, `docs/march-m5.md`,
  `docs/march-m6.md`, `docs/march-m7.md` (roadmap pointers retargeted to the archive
  files), `docs/status.md` (per-milestone-detail pointer line now names the archived
  roadmap plans), `docs/archive/README.md` (scope sentence covers roadmap plans).
- Relative-link check over all 25 touched/new docs: OK. Three PRE-EXISTING broken
  links in `docs/march-m6.md` (`tools/../tools/verify-live-{text,roadpops,win}.sh`)
  found by the same check and fixed to `../tools/…` — drive-by, recorded honestly.
- No live doc references removed roadmap anchors (`grep 'roadmap\.md#'` clean outside
  archive/claims/logs).
- `bash tools/status/refresh-indexes.sh` → in sync; `bash tools/verify-coordination.sh`
  → ok; `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig` → pass (no code
  touched).
