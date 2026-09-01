# Claim: M34-HF6 exec flake #803 — root cause

- **Owner:** buffy (`agent/buffy/m34-flake803`)
- **Prompt / plan:** `docs/claims/1432-m34-hf6-exec-flake803-rootcause1.md`
- **Scope:** root-cause + fix the intermittent corrupted-exception-frame panic in `verify-live-exec` (flake #803, filed from the HF6 gate sweep)
- **Touches:** kernel/src/exceptions.zig, kernel/src/main.zig, kernel/src/scheduler.zig, kernel/src/syscall.zig, kernel/src/console.zig, tools/verify-live-exec.sh, docs/claims/1432-*, docs/logs/agent-buffy-m34-flake803.md, docs/status.md
- **Depends on:** HF6 (#740, PR #806) — merged
- **Heartbeat:** 2026-09-01 — update while Status is 🔄 so staleness checks see life
- **Status:** 🔄 agent/buffy/m34-flake803

## Notes

The HF6 gate sweep (issue #740) exposed an intermittent crash in the
verify-live-exec gate: after EL0 exec from the host share, the kernel
panics with corrupted exception frames. Measured ~1/5 on my branch; the
pre-HF6 kernel through the *same* share gate passed 3/3 (issue #803 body
has the fingerprints — byte-identical elr/far/x0/x1/x2 and count=1437
across two boots, a deterministic kernel data-abort, not a random race).

Key crash registers (HF6-era build, KASLR base 0x7da7f000):
- esr=0x96000001 ec=0x25 data-abort-same, far=0xffffffffffffffff
- elr=0x7dabda08 (= text 0x3ea08, a `b` tail-call), x30=0x7da89d4c (= text 0xad4c)
- x1=0x7dacbe11 (= rodata 0x4ce11), x2=0x16 (=22, the length of
  "user: sleeping 2 ticks" — the app's last marker before the fault)

This claim reproduces on the current build, instruments the vector entry
to capture the raw sp/elr before the frame store if needed, then traces
the faulting syscall/console path and fixes the root cause.

Verification: verify-live-exec green 5/5 on VZ plus class-A regressions
(unit + transcript + mutations) stay green.