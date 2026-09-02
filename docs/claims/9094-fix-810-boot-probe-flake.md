# Claim: Fix the boot-time EL0 probe hang/park flake (issue #810)

- **Owner:** buffy (`freebuff/get-git-up-to-date-there-were-quite-a-few-things-d-fe3ff43a-1217-4ca3-a9ad-b6faa6fbe86f`)
- **Prompt / plan:** root-cause + fix issue #810 — an intermittent
  boot-time failure AFTER the kernel's EL0 boot probe prints
  `userspace: el0=1 …` but before `tasks user-el0 exited status=7`: the
  runner never forwards the gate script. Two observed signatures:
  (a) SILENT STOP — serial simply ends after the probe report (run 1
  boot 1); (b) PARKED EXCEPTION — an EL1h data abort with
  `esr=0x97090010`, `far=0x80000178`, `elr=text+0x3e194`, `spsr=0x80000005`,
  frame `sp=0`, x1 rodata, `x2=0x8000` (32 KiB), x20/x25 = 0x80000000 /
  0x40000000, x26 ≈ GICR+0x80, x23 = 0x1e (30 = timer PPI), then
  `[EXC] parking`. Observed 8/24 boots in the HF7 session; the HF7 gate
  now retries around it, but the kernel bug is real (same family as #803,
  whose cmd_write fix was ONE stack offender — this looks like a second
  class in the timer/exit path, right after `tasks worker advances=2112`).
- **Evidence:** `artifacts/live-vf-serial-{2,6}.log` (runs 2/5/6),
  `artifacts/live-vf-run-{2,6}.txt`; committed at 30efba2 + 4cc4c25;
  issue #810 (2 comment updates filed 2026-09-02).
- **Hypotheses to test (in order):** (1) the timer IRQ / tick path reads
  a device register at 0x80000178 during the probe task's exit (x23=0x1e
  = timer PPI; crash sits between tick prints); read the GTDT/CNTP
  constants in tree; (2) a corrupted task context with SP=0 being context-
  switched (frame sp=0); (3) a stack offender in the probe-exit path
  (reap/teardown) corrupting the exception frame (the #803 class).
- **Touches:** kernel/src/{exceptions.zig,main.zig,scheduler.zig,
  timer.zig,console.zig,mmu.zig} (whichever the root cause lands in) ·
  docs/claims/9094-fix-810-boot-probe-flake.md ·
  docs/logs/agent-buffy-m34-hf7-clone-dedup.md (appended entry) ·
  possibly docs/status.md, docs/hardware-contract.md
- **Depends on:** — (flake observed on main-era builds; #808's
  instrumentation is already in tree)
- **Heartbeat:** 2026-09-02
- **Status:** 🔄 in progress — claim 9094 (id via `bash tools/status/claim-id.sh`)

## Notes

Verification: root cause named from the disassembly + source; fix lands;
class-A green (fmt/build/unit/BSS); `verify-live-vf` 6/6 on VZ (the HF7
gate's retries must NOT be what absorbs the flake on the fixed build —
a repeat run should pass without retries, or with measurably fewer).