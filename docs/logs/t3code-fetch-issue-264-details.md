# Log — `t3code/fetch-issue-264-details`

- 2026-08-21 — claim 2860 — 🔄 started: issue #264 repo hygiene — trim `docs/roadmap.md`
  (1444 lines) by moving each completed milestone's plan (M0–M16) verbatim into
  `docs/archive/roadmap-m{N}.md` files and leaving one-line pointers plus the
  forward-looking content (current position, wishlist, meta-requirement) in the main
  file. Live references in march trackers updated after the move. Docs only; no code.
- 2026-08-21 — claim 2860 — ✅ done: `docs/roadmap.md` 1444 → 197 lines; 18 verbatim
  archive files created (`docs/archive/roadmap-m{0,1,1.5,2,…,16}.md`, incl. the M4
  card bullets + N1–N6 network rungs from "Later milestones", the virtio device
  surface table under m7, and the claim-4951 bridge note under m9); relative links
  rewritten for archive depth; live references retargeted (`march-m4/m5/m6/m7`,
  `status.md` pointer line, `archive/README.md` scope). Drive-by fix recorded: three
  PRE-EXISTING broken links in `march-m6.md` (`tools/../tools/verify-live-*.sh`) →
  `../tools/…`. Verified: content-integrity phrase spot checks, relative-link check
  over 25 docs OK, no orphaned roadmap anchors, `refresh-indexes.sh` in sync,
  `verify-coordination.sh` ok, `zig fmt --check` pass. No code touched.
