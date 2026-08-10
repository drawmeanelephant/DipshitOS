# Milestone three — march tracker (`docs/march-m3.md`) and agent-split plan

Planning-first agent prompt for DipshitOS. Feed this file to the
implementing agent. Pure-docs card: create the per-milestone march tracker
for milestone three, mirroring `docs/march-m15.md`, so the remaining
userspace cards have per-step rows, evidence links, and a best-agent-split
table that sequences them without file collisions.

- Branch: `agent/.../m3-march-tracker` (claim first via `docs/claims/` +
  a log entry in `docs/logs/`; merge per ADR 0003)
- Date: 2026-08-09
- Depends on: — (can run concurrently with the EL0/SVC and syscall-ABI
  streams; it touches **no kernel files**)
- Inputs (read first): `AGENTS.md`, `docs/status.md`,
  `docs/roadmap.md` (Milestone three section), `docs/march-m15.md`
  (the structure to mirror), `docs/m3-syscall-abi-prompt.md`,
  `docs/m3-ragshit-dogfood-prompt.md` (the cards the tracker must cover),
  `docs/claims/README.md` + `docs/logs/README.md` (index formats).

## Scope

Create `docs/march-m3.md` with:

1. A **per-step tracker table** (one row per remaining milestone-three
   card, mirroring `docs/march-m15.md`'s step rows): step number, card
   title, status, evidence, notes. The cards to track, in canonical order:
   1. EL0/SVC kernel boundary (in flight — reference its claim)
   2. Syscall ABI + dispatch table (`docs/m3-syscall-abi-prompt.md`)
   3. uaccess: fault-safe copy-in/copy-out (EFAULT `-3` contract)
   4. Per-task user address spaces (user TTBR0, kernel TTBR1, UXN/PXN,
      MMIO exclusion)
   5. User task lifecycle: spawn/exit/reap, task states, idle task
   6. Load a real user program from the ESP (FAT driver, claim 6420) and
      exec into EL0
   7. Blocking syscalls: sleep/yield wired into the tick scheduler
   8. Milestone-three close-out: full class A + class B suite at the tag,
      status/roadmap/hardware-contract reconciliation, milestone tag
2. A **best-agent-split table** (mirroring march-m15's split table) that
   sequences the cards so two agents never edit the same file at the same
   time. Must encode the collision map: the EL0/SVC + syscall-ABI streams
   own `kernel/src/{exceptions,scheduler,monitor,main,console}.zig`,
   `docs/status.md`, `docs/gate-inventory.md`, and
   `tools/verify-live-*.sh`; docs/tooling cards (this one, ragshit) run
   concurrently; the runner card (`docs/m3-runner-scripted-input-prompt.md`)
   runs on `host/vm-runner/` (disjoint from `kernel/`).
3. A **"where we are" header** pointing at `docs/status.md` as canonical
   (status.md holds milestone-level facts; the tracker holds step-level
   detail — same split as march-m15/status).

## Do not

- Touch `docs/status.md`, `docs/gate-inventory.md`, `docs/roadmap.md`, or
  any kernel/tools/host file — those belong to the active streams.
- Invent claims, statuses, or evidence; every row references real claim
  files or is marked "not yet claimed".
- Hand-edit generated indexes; if you create a claim file (you should not
  need one beyond your own), run `bash tools/status/refresh-indexes.sh`.

## Process (hard gate)

1. Claim before you start (claim-id.sh, 🔄), append to your branch log.
2. Read `docs/march-m15.md` and mirror its structure and tone.
3. Write `docs/march-m3.md`.
4. Verify: `git diff` shows the new file only; `zig fmt --check` and
   `bash tools/verify-coordination.sh` still pass (they must — you touched
   no code).
5. Append the log, flip the claim to ✅, refresh indexes, open a draft PR
   with `gh` (ADR 0003).

## Definition of done

`docs/march-m3.md` exists, mirrors march-m15's structure, covers all eight
cards above with real claim references and honest statuses, and encodes a
collision-free agent split. No code changed; coordination gate green.
