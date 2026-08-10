# Milestone three march — userspace (living tracker)

## Where we are

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds only
> milestone-three's per-card detail and collision-free agent split, following
> the same status/tracker boundary as [`docs/march-m15.md`](march-m15.md).
> Claim work first (`docs/claims/`), append to the branch log (`docs/logs/`),
> and link saved evidence before changing a row to `✅`.

The allocator, exception-vector, timer-interrupt, and first kernel-task cards
precede this tracker and are complete. The march below starts at the EL0/SVC
boundary and carries milestone three through its close-out.

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| 1 | **EL0/SVC kernel boundary.** Run the smallest real EL0 task, cross into EL1 through SVC, return to EL0, and remain preemptible alongside the EL1 tasks. | ✅ done | [Claim 8215](claims/8215-el0-task-svc-boundary.md) | Landed before this tracker: the strict class-B userspace gate passed 3/3 boots, with task/timer/exception live regressions and the portable suite green. It intentionally leaves process abstraction, separate address spaces, user loading, and the broader syscall ABI to later cards. |
| 2 | **Syscall ABI + dispatch table.** Freeze the numbered contract, runtime-built dispatch table, argument/result plumbing, errors, ADR, portable coverage, and a dedicated live SVC gate. | 🔄 in progress | [Claim 3594](claims/3594-syscall-abi-dispatch.md); card: [`docs/m3-syscall-abi-prompt.md`](m3-syscall-abi-prompt.md) | Claimed on `agent/codex/m3-syscall-abi` after step 1 landed. Extend the merged exception/SVC seam rather than adding a parallel entry path. The ABI card owns its contract corrections and evidence. |
| 3 | **uaccess: fault-safe copy-in/copy-out.** Add bounded user-memory transfer primitives and enforce the reserved `EFAULT` (`-3`) contract without letting a bad pointer crash EL1. | ⬜ not started | Not yet claimed | Starts only after step 2 freezes the syscall contract. Gate valid, boundary, overflow, unmapped, and permission-fault cases before migrating pointer-taking syscalls onto uaccess. |
| 4 | **Per-task user address spaces.** Give user tasks their own TTBR0 mappings while keeping the kernel in TTBR1; enforce UXN/PXN and exclude MMIO from EL0. | ⬜ not started | Not yet claimed | Depends on fault-safe uaccess. Record new translation and hardware assumptions in `docs/hardware-contract.md`; do not claim isolation until live and portable evidence cover switching and permissions. |
| 5 | **User task lifecycle.** Add spawn/exit/reap, explicit task states, and an idle task around the existing tick-driven scheduler. | ⬜ not started | Not yet claimed | Depends on per-task address spaces. Reconcile syscall exit semantics with scheduler ownership; keep lifecycle bounded and allocation behavior explicit. |
| 6 | **Load and exec a real user program from the ESP.** Read through the existing FAT32 storage path and enter the loaded program at EL0. | ⬜ not started | Not yet claimed; storage prerequisite: [claim 6420](claims/6420-fat32-storage-driver.md) | Depends on lifecycle and address-space work. Reuse the landed ESP FAT driver; this card proves loading and exec, not a new general filesystem. |
| 7 | **Blocking syscalls.** Wire sleep/yield and wakeup behavior into the tick scheduler without busy-waiting or breaking shell responsiveness. | ⬜ not started | Not yet claimed | Depends on stable user tasks and exec. Gate scheduler state transitions, timer-driven wakeups, return values, and live progress of other runnable tasks. |
| 8 | **Milestone-three close-out.** Run the complete class-A and class-B suites at the candidate tag, reconcile status/roadmap/hardware-contract, and create the milestone tag only after every gate passes. | ⬜ not started | Not yet claimed | Depends on steps 1–7. Save the full gate transcript under `artifacts/`; distinguish directly observed results from inferred design claims and tag only the verified commit. |

## Best agent split

| Agent / lane | Owns | Sequence / collision rule |
|--------------|------|---------------------------|
| **A — Concurrent docs/tooling** | This tracker (`docs/march-m3.md`) and the ragshit index/bundle/review card (`tools/ragshit/` plus ignored `artifacts/` evidence) | May run concurrently with the kernel-boundary lane. It does not edit the kernel, `docs/status.md`, `docs/gate-inventory.md`, or live-gate scripts. The ragshit card is defined in [`docs/m3-ragshit-dogfood-prompt.md`](m3-ragshit-dogfood-prompt.md). |
| **B — EL0/SVC then syscall ABI** | Steps 1–2. While active, this serialized lane owns `kernel/src/{exceptions,scheduler,monitor,main,console}.zig`, `docs/status.md`, `docs/gate-inventory.md`, and `tools/verify-live-*.sh`. | Step 1 lands first; step 2 rebases on that result and extends its seams. No other lane edits any listed file until the syscall ABI PR lands. Step 1 is complete via claim 8215; the rule remains binding for step 2. |
| **C — Optional runner input** | `host/vm-runner/` only, following [`docs/m3-runner-scripted-input-prompt.md`](m3-runner-scripted-input-prompt.md) | File-disjoint from lanes A and B, so it may run concurrently. Defer its manual VZ run whenever the EL0/SVC or syscall live gates use the same host; file independence does not remove host-level test contention. |
| **D — Follow-on userspace** | Steps 3–7, one claimed card at a time: uaccess → per-task address spaces → user lifecycle → ESP exec → blocking syscalls. | Starts after the syscall ABI PR lands. Each card bases on the preceding landed card and publishes before the next begins; this serializes their shared exception, scheduler, MMU, monitor, status, inventory, and live-gate surfaces. |
| **E — Close-out** | Step 8: complete gate rerun, documentation reconciliation, and milestone tag. | Starts only after steps 1–7 are landed and unclaimed work is clear. It owns the close-out docs and evidence surfaces until the tag is cut. |

Merge through short-lived PR branches per ADR 0003. Before starting any lane,
create its deterministic claim and branch log, refresh the generated indexes,
and check the active claims again; the split above is an ownership plan, not a
substitute for the repository's one-editor-per-file rule.
