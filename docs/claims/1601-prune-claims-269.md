# Claim: Prune completed claim files (M3–M16) — issue #269

- **Owner:** t3code (`t3code/prune-claims-269`)
- **Prompt / plan:** `https://github.com/drawmeanelephant/DipshitOS/issues/269`
- **Scope:** Repo hygiene — `docs/claims/` only. Move ~155 completed-milestone claim files (M3–M16) from `docs/claims/` to `docs/archive/claims/`, keep M17+/active (Arc1/Arc2, audit followups, recent hygiene) in place, update `docs/claims/README.md` index to point to archive, and keep `tools/status/refresh-indexes.sh` + `tools/verify-coordination.sh` green.
- **Depends on:** main at `6909f79` (post-#286); `docs/archive/claims/` does not yet exist.
- **Status:** ✅ done 2026-08-21 — moved 178 claim files M3–M16 (incl. early M1.5/M2 diagnostics) from `docs/claims/` (209 files, ~1.2M) to `docs/archive/claims/` (178 files, 1.0M); active `docs/claims/` now 31 files, 176K (README 16K + claims ~160K, `du -sh` 176K) with 6 🔄 audit/M17 + 13 M17 desktop (Arc1/Arc2/C2–C9) + 8 hygiene + 4 planning; updated `docs/claims/README.md` (98 lines, 16K, + Archived section) and `docs/archive/README.md` (claims/ paragraph) and `docs/march-m3/m6/m13.md` links (15 refs) to `archive/claims/`; `bash tools/status/refresh-indexes.sh` and `bash tools/verify-coordination.sh` both PASS

## Notes

Issue #269: `docs/claims/` holds 208 files (~1.2M); 184 at issue open. Every non-trivial work gets a claim file, they accumulate forever. Claims for completed milestones M3–M16 are historical records no agent needs during active development.

Plan:
1. Create `docs/archive/claims/` and move completed-milestone claims there. Keep active/upcoming: M17 desktop completeness (Arc1/Arc2 + m15-c* C2–C9: 0265,2336,5227,9091,2762,2873,9697 plus 0819,0835,1872,6437,1264,1757,3589), live audit followups 🔄 (6204,7127,7302,2616) and hygiene recently closed but still useful reference (2203,2860,5512,4429,4516,5828,0162,9090) — target ~30 files remain, matching issue's "active/future: ~30".
2. Update `docs/claims/README.md` — keep generated table for active claims (via refresh-indexes.sh) plus a new "Archived claims" section pointing to `docs/archive/claims/` and explaining the split. Update `docs/archive/README.md` to document the new subdirectory.
3. Adjust `tools/status/refresh-indexes.sh` and `tools/verify-coordination.sh` if needed to scope to `docs/claims/` (active) only — archived claims are history and must not fail the gate (they still retain deterministic IDs but are out of scope).
4. Run `bash tools/status/refresh-indexes.sh` and `bash tools/verify-coordination.sh` (and `just verify-coordination` if available) and verify `du -sh` shrinks active `docs/claims/` to ~200K.

Verification: `ls docs/claims/ | wc -l` before/after, `du -sh` before/after, `bash tools/status/refresh-indexes.sh --check` and `bash tools/verify-coordination.sh` green, and `git status` shows only intended moves.

