# Claim: Milestone 14 Card S1 — clipboard / shared text service

- **Owner:** buffy (`agent/buffy/m14-s1-clipboard`)
- **Prompt / plan:** `docs/march-m14.md`
- **Scope:** Milestone 14, Card S1 (Issue #175): the shared clipboard
- **Depends on:** M14 plan (PR #180); ADR 0007 slots 38/39 (M13 left off at 37)
- **Status:** ✅ done 2026-08-19

## Notes

`sys_clipboard_set`/`sys_clipboard_get` (ADR 0007 slots 38/39), one bounded
kernel-global clipboard buffer (pure BSS, zero heap — no per-process
ownership: any process may read what any other wrote, the honest bound).
NOTEPAD gains copy/cut/paste wired through the seam (Ctrl+C/X/V — copy/cut
act on the current logical line; paste inserts at the cursor; no selection
model yet, documented). A headless `CLIPTEST.BIN` (the twenty-third ESP
program) drives the seam deterministically for the class-B gate
`tools/verify-live-clipboard.sh` (the M13 B1 `FSTEST.BIN` precedent).

Verified by: class-A green (fmt, unit tests incl. clipboard + syscall +
notepad, byte-identical transcript, build/image/inspect, swift build,
coordination), and the live gate on VZ (exec CLIPTEST.BIN → set/get/truncate/
empty/EFAULT markers + `sys_clipboard_set`/`sys_clipboard_get` calls in the
syscalls report + exit status). `implemented_count` 38 → 40, and every gate
asserting `implemented=38` is re-derived to 40.
