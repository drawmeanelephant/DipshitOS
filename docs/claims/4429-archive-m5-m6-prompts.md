# Claim: Archive completed M5/M6 milestone prompt files

- **Owner:** buffy (`agent/buffy/hygiene-archive-m5-m6-prompts`)
- **Prompt / plan:** https://github.com/drawmeanelephant/DipshitOS/issues/263
- **Scope:** Repo hygiene — move the 9 completed M5/M6 prompt docs from `docs/` root to `docs/archive/` (names unchanged) and update every live reference so no link breaks: `docs/march-m4.md`, `docs/march-m5.md`, `docs/march-m6.md`, and the `kernel/src/text.zig` header comment. `docs/status.md` and `docs/roadmap.md` were checked and carry NO references to these files. Historical `docs/claims/` + `docs/logs/` entries are append-only and stay untouched.
- **Depends on:** —
- **Status:** ✅ done

## Notes

Files moved (issue #263 list, verified on disk 2026-08-21):
`m5-net-tx-prompt.md`, `m5-net-rx-prompt.md`, `m5-arp-prompt.md`,
`m5-ipv4-prompt.md`, `m5-udp-prompt.md`, `m5-udp-syscall-prompt.md`,
`m5-net-outbound-prompt.md`, `m6-gpu-prompt.md`, `m6-text-prompt.md`.

Why: agents listing `docs/` mistake completed prompts for active work.
The archive README already states the rule — `docs/` root holds only
active documentation.

Verification plan: repo-wide grep for the nine filenames shows zero
remaining references outside `docs/archive/` itself; class A gates
(fmt, build, coordination ×2) re-run green.

## Verification

- `git mv` of all 9 files → `git status` shows 9 renames into
  `docs/archive/`; names unchanged.
- Repo-wide grep for the nine filenames: zero references outside
  `docs/archive/`, historical `docs/claims/`, and append-only
  `docs/logs/`. Live docs updated: `docs/march-m4.md` (1 path mention),
  `docs/march-m5.md` (8 relative links + 1 path mention),
  `docs/march-m6.md` (2 relative links), `kernel/src/text.zig:24`
  (header comment). `docs/status.md` + `docs/roadmap.md`: NO references
  existed (checked before the move — the issue's guess about those two
  files did not hold; the real live references were the march trackers).
- `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig` → pass
- `zig build` → exit 0 (full guest build incl. all ESP programs)
- `bash tools/status/refresh-indexes.sh` → indexes in sync
- `bash tools/verify-coordination.sh` → ok
