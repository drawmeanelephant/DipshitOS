# Claim: Bad-handoff gate fix (M2 pre-exit return path)

- **Owner:** buffy (`agent/buffy/m2-badhandoff-fix`)
- **Prompt / plan:** `docs/m2-bad-handoff-fix-prompt.md`
- **Scope:** M1.5 hard gate 1 / milestone-two pre-exit failure path
- **Depends on:** —
- **Status:** ✅ fixed 2026-08-06

## Notes

Root cause was the naked `_start` shim clobbering the link register (no
save/restore of the loader's `x30`), so the shim's `ret` looped on itself
and the kernel never returned. Fixed with two instructions (`mov x20, x30`
before the `bl`, `mov x30, x20` before `ret`).

**Observed:** `verify-bad-handoff.sh` exits 0, `RC.TXT` →
`kernel_rc=0x0000000000000002` (`artifacts/m2-badhandoff-fix-after.txt`).
Log: `docs/logs/agent-buffy-m2-badhandoff-fix.md`.
