# Claim: Line-of-sight tracker sync — Lane-0 split, #708/#749/#761 board state

- **Owner:** buffy (`freebuff/okay-shower-thoughts-here-we-re-using-fat32-for-so-b0ce3067-2b04-4b81-984d-9fd76bfcf123`)
- **Prompt / plan:** Sync `docs/line-of-sight.md` to the board state after the review pass: #706 split into four parallel cards (#773–#776), #708 re-scoped to VL6-only depending on #749, #761 re-framed to the host link contract, HF4 merged (PR #769, claim 7599), milestone #20 count 16 → 20 open.
- **Scope:** Doc-only — no kernel/userland code. Update `docs/line-of-sight.md` (M34 table + pain-point rows, #708/#706 lanes, ladder table + honest notes, sequencing, open-threads table, claim order) and land via a small docs PR with the coordination records.
- **Touches:** docs/line-of-sight.md docs/claims/1263-line-of-sight-board-sync.md docs/logs/freebuff-20260901-001.md
- **Depends on:** PR #767 merged (line-of-sight on main); HF4 merged (PR #769, claim 7599); the GitHub-side review pass (issues #773–#776, #708, #749, #761, #707 comment)
- **Heartbeat:** 2026-09-01
- **Status:** ✅ done

## Notes

Facts verified before editing: HF4 closed by PR #769 (head `agent/buffy/m34-hf4-exec`, claim 7599 file on main); M32 milestone closed 9/9; `driving_award.zig` still on main with `sys_win_open`/`user_bufs` (so #707's target exists; M33 caveat commented); the ELF loader is class-agnostic (Z4b re-framed to host link contract). All GitHub-side edits landed in the review pass; this claim is the in-repo tracker sync only.
