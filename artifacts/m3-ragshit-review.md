# Milestone-three ragshit dogfood review

Repository HEAD: `6b1b8cd2195fc543da149536074e9088542a7d57`

This is a documentation/code-contract review. It makes no VZ run and no new
hardware claim. Statements labelled **observed** come directly from the
indexed tree; implications labelled **inferred** are review conclusions.

## Retrieval outcome

- **Observed:** the fresh index contains 227 eligible tracked files and 2,080
  chunks; `ragshit doctor` passes every required check.
- The prompt's broad example query retrieved the planning docs but did not
  rank every landed SVC/scheduler/runner seam into its 60-candidate window.
  This was an under-specified query, not a demonstrated engine defect.
- Re-running `bundle` with exact identifiers and contract phrases produced
  `artifacts/m3-ragshit-bundle.md`: 68 included chunks covering the syscall
  prompt, landed claim/log, ADR 0005, status/roadmap, main/userspace/
  exceptions/scheduler/monitor/console seams, host script mode, and the
  userspace/live-transcript gates. Four omitted chunks are unrelated,
  sub-0.6-score reboot/custom-virtio context; no relevant source was dropped.
  No bundle content was hand-edited and no `tools/ragshit/` change was
  justified.

## Syscall-card findings

1. **Observed — selector/register contract contradicts landed code.**
   `docs/m3-syscall-abi-prompt.md:63-69` says x0 is the syscall selector and
   x1-x5 are arguments, while claim 8215 and `kernel/src/userspace.zig:88-108`
   use x8 as the selector and x0 as argument/result. Slot 0 cannot both select
   `sys_ping` and carry `ping(value)` in x0. The card must preserve x8 and
   marshal arguments from x0 onward.
2. **Observed — mode decoding is wrong in the prompt.**
   `docs/m3-syscall-abi-prompt.md:52-54` calls 0x4 EL0t and 0x5 EL1t.
   `kernel/src/exceptions.zig:215-233` correctly decodes 0x0=EL0t,
   0x4=EL1t, and 0x5=EL1h and dispatches lower-EL SVC only for mode 0.
3. **Observed — the prompt attributes an ELR advance that did not land.**
   `docs/m3-syscall-abi-prompt.md:101-108` and its planning checklist say
   claim 8215 advances ELR past `svc`; the handled path at
   `kernel/src/exceptions.zig:440-445` returns the same frame without writing
   ELR. The architectural SVC return already resumes after the instruction;
   the card should describe that return behavior, not a software increment.
4. **Observed + inferred — yield/exit lack the required return/lifecycle
   seams.** `SvcDispatcher` returns only `bool` and handled SVC always resumes
   the same frame (`kernel/src/exceptions.zig:108-118,440-445`). The scheduler
   has fixed registration plus a tick-only context switch and no yield,
   terminate, reap, task-state, or idle-task API
   (`kernel/src/scheduler.zig:118-182,220-264`). Therefore `sys_yield` and
   non-returning `sys_exit` cannot satisfy the card through table marshalling
   alone. The card must explicitly extend the exception return/scheduler seam
   or defer those operations. Reaping here also overlaps the later user-task
   lifecycle card (spawn/exit/reap).
5. **Observed + inferred — `sys_write` needs a real safety/concurrency
   contract.** Bounded `buf + len` arithmetic alone does not prove a pointer
   is within the two EL0 apertures; the shared identity map lets EL1 dereference
   privileged mappings on a user's behalf. The landed region helpers expose
   text/stack bounds (`kernel/src/userspace.zig:27-45`), but no allowed-range
   check is specified. Also, the shell defers timer/task/userspace output
   because the polled console is not reentrancy-safe
   (`kernel/src/shell.zig:114-124`), while the card assumes direct
   synchronous-exception writes are safe. Since the timer may preempt a shell
   console operation before scheduling EL0, direct SVC output needs explicit
   serialization or deferred/buffered emission.
6. **Observed — internal acceptance criteria disagree.** The ABI/table and
   scope define four implemented slots 0-3 and reserve 4-63
   (`docs/m3-syscall-abi-prompt.md:70-84,112-116`), but the class-A test list
   says 0-2 implemented and 3-63 reserved (line 184). The monitor command is
   labelled optional (lines 127-131), yet class-A requires deterministic
   `syscalls` output and class-B requires its counter (lines 195, 215); it is
   functionally mandatory.
7. **Observed — `sys_ping` is described more strongly than the landed proof.**
   The prompt says arbitrary `ping(value) -> value`; the landed handler
   validates a monotonic sequence and returns the call count
   (`kernel/src/userspace.zig:103-108`). Its two live calls happen to return
   their inputs. The frozen ABI must choose and document echo semantics or
   preservation of the existing sequence proof.
8. **Observed — prerequisite/status prose is stale.** The prompt still calls
   PR #60 a draft and says to wait for its merge (lines 12-19), although main
   contains commit `65ad6af` and claim 8215 is done. Canonical status still
   calls userspace a later card (`docs/status.md:37`), and roadmap calls it the
   next card/no-userspace (`docs/roadmap.md:242-248,272-283`). The syscall
   branch should reconcile those canonical surfaces when it lands.

Confirmed aligned details: the runtime-built BSS table requirement matches
ADR 0005; `registry_count` is currently 22 so 22 -> 23 is accurate; the
transcript-fixture warning is present; and the new class-B gate plus gate
inventory/aggregate registration are explicitly required.

## Runner-card finding

**Observed:** `docs/m3-runner-scripted-input-prompt.md:24-35,57-60` asks for
`--script`, duplex injection, output teeing, an expected-reply assertion, and a
live fixture. Claim 6684 already records those as done;
`host/vm-runner/Sources/VMRunner/main.swift:129-148,283-300,788-855,903-909`
implements `--script`/`--script-expect`, preserves the nil-input evidence
path, sends the fixture after the terminal marker, tees output, and polls for
success. `tools/verify-live-transcript.sh:3-18,74-104` already drives
help/version/mem/echo and asserts the live transcript. The only described
capability not present is per-burst timing/delay grammar: current code writes
the whole plain-text file in one operation. The optional card should be
cancelled as already satisfied or narrowed to that grammar instead of
reimplementing claim 6684.
