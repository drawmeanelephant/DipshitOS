> ARCHIVED (claim 3594 done)

# Milestone three — syscall ABI + dispatch table (the SVC contract)

Planning-first agent prompt for DipshitOS. Feed this file to the
implementing agent. It must produce a written plan **before** changing any
code, and it must read the in-flight EL0/SVC card's claim and PR first —
this card layers the dispatch table on top of whatever SVC entry plumbing
that card lands; it must not fight it.

- Branch: `agent/.../m3-syscall-abi` (claim first via a claim file in
  `docs/claims/` + a log entry in `docs/logs/`; merge per ADR 0003)
- Date: 2026-08-09
- Depends on: **the EL0/SVC card** (PR #60 — merged as `65ad6af`,
  branch `codex/el0-svc-task`, claim 8215 ✅ — smallest real EL0 task
  + SVC kernel boundary). Do not start the implementation until PR #60
  MERGES
  to main: it rewrites `exceptions.zig`'s dispatch surface (~400 lines),
  `scheduler.zig`, `mmu.zig`, `monitor.zig`, `shell.zig`, and
  `main.zig`, and adds `kernel/src/userspace.zig` +
  `tools/verify-live-userspace.sh` — work against current main would be
  rebased away.
- Inputs (read first; they are binding): `AGENTS.md`, `docs/status.md`,
  `docs/roadmap.md` (Milestone three section), `docs/testing.md`,
  `docs/gate-inventory.md`, `docs/hardware-contract.md`,
  `docs/decisions/0004-kernel-proper.md`,
  `docs/decisions/0005-runtime-built-function-tables.md`,
  claim 8215 + branch log + PR #60's diff (the landed SVC conventions),
  `kernel/src/exceptions.zig` (the `exc_dispatch` seam, the claim-9746
  vector frame, and the landed `set_svc_dispatcher`/`is_svc64_from_el0`),
  `kernel/src/scheduler.zig` (claim 5275), `kernel/src/monitor.zig` (the
  runtime-built command registry pattern), `kernel/src/console.zig`
  (the writer abstraction), `kernel/src/main.zig` (wiring seam).

---

You are working on DipshitOS, a from-scratch AArch64 operating system
(freestanding Zig guest, Swift + Virtualization.framework host, no QEMU
path). The EL0/SVC card just proved a user task can run at EL0 and cross
the `svc` boundary into EL1 and back. This card turns that boundary into a
**stable contract**: a numbered syscall table, register/return conventions,
and an ADR that locks them, so the follow-on cards (uaccess, per-task
address spaces, user lifecycle, ELF loading) build on a fixed ABI instead
of on each other's accidents.

Constraints that are non-negotiable:

- **No libc, no POSIX, no allocation, no heap.** The syscall layer is a
  fixed table in BSS with bounded, deterministic behavior.
- **The dispatch table must be built at runtime, not a `const` table**
  (ADR 0005 / claim 0015 root cause): a const function-pointer table holds
  link-time absolute addresses, wrong at the kernel's runtime-chosen load
  base. Same pattern as the command registry in `monitor.zig`
  (`registry_storage` + `ensure_registry`).
- **SVC is EL0-only.** Kernel code calls functions directly and never
  executes `svc`. SPSR.M 0x0 is EL0t, 0x4 is EL1t, and 0x5 is EL1h. An SVC
  taken from either EL1 mode is a kernel bug: report + park, exactly as today.
- **Console discipline:** an SVC handler runs in *synchronous* exception
  context, not IRQ context (claim 7948's no-console rule does not apply to
  it), but keep prints minimal, deterministic, and grep-able.

## The ABI (bake these decisions into the ADR; do not relitigate them)

### Numbering and dispatch

- The EL0/SVC card (PR #60, claim 8215) has already fixed the SVC
  convention and it is binding: **syscall number in x8**, instruction
  `svc #0` (`svc_immediate = 0` in `kernel/src/userspace.zig`), arguments
  in **x0–x5**, and result returned in **x0**. Its `syscall_ping` uses x8=0
  while round-tripping x0. Extend it, don't replace it. The SVC immediate
  (ESR_EL1 ISS bits [24:0]) stays 0 and is reserved.

  **Correction note:** docs-only commit `6b1b8cd` transcribed both number
  and result as x0. That is impossible for `ping(value) -> value` and
  contradicts merged `userspace.zig`, claim 8215, its log, and its VZ
  evidence. ADR 0007 and the implementation preserve the landed x8/x0
  contract.
- The number space is **0..63** (64 slots). Slot 0 is the EL0 card's
  `syscall_ping` — keep it untouched (it is the class-B live-gate
  evidence). Slots 4–63 are reserved and return `-ENOSYS`; adding a
  syscall later = one table row + one handler + one unit test, never a
  renumber.

### Numbered syscall list

| # | Name | Signature | Behavior |
|---|------|-----------|----------|
| 0 | `sys_ping` | `ping(value) -> value` | The EL0 card's proof syscall (PR #60, claim 8215): round-trips x0 through `svc #0` and returns it. Keep as-is — the class-B gate asserts its two-call sequence. |
| 1 | `sys_write` | `write(fd, buf, len) -> i64` | Only fd 1 (console). Writes `len` bytes from user address `buf` through the registered console writer. Returns bytes written (0..len) or a negative error. |
| 2 | `sys_yield` | `yield() -> i64` | Round-robin yield: hands the current user task to the scheduler (claim 5275). Returns 0. |
| 3 | `sys_exit` | `exit(status) -> noreturn` | Terminates the calling user task; the scheduler reaps it and the shell reports. Never returns. |
| 4–63 | reserved | — | Dispatch returns `-ENOSYS`. |

### Error codes (returned in x0, negative)

- `0` — success
- `-1` — `EINVAL`: bad/overlapping argument (e.g., `len` beyond the
  bounded write cap, or `buf + len` overflow)
- `-2` — `EBADF`: fd is not 1
- `-3` — `EFAULT`: reserved for the follow-on uaccess card (bad user
  pointer). Do **not** claim uaccess here — the write handler validates
  ranges with plain bounded arithmetic against the kernel-known EL0 text
  and stack apertures inside the guaranteed identity map, rejects
  privileged/MMIO ranges, and returns `EINVAL` for now. Record in the ADR
  that `-3` is allocated but unimplemented.
- `-4` — `ENOSYS`: unknown syscall number

### Return plumbing

- The dispatch result lands in **x0 of the saved vector frame** so the
  stub's register restore pops it into x0 on `eret`. The EL0/SVC card
  (PR #60) already owns entry routing and SP_EL0 save/restore
  (`exc_dispatch` returns `.{ frame, sp_el0 }`; `resume_sp_el0`). A handled
  AArch64 SVC needs no manual ELR advance: architectural ELR already points
  after the `svc`. The syscall module supplies the table + argument
  marshalling: read x8 = number and x0–x5 = args out of the frame,
  dispatch, write the result into x0. Yield/exit may minimally select a
  different existing scheduler frame through the same return seam; do not
  add a parallel entry path.

## Scope

1. **`kernel/src/syscall.zig` (new file):** the runtime-built dispatch
   table (64 slots, 4 implemented), argument marshalling from the vector
   frame (x0–x5; number in x8), the error-code enum, per-number call
   counters, and a `dispatch(number, args, frame) -> u64` entry point
   registered through the EL0 card's landed `set_svc_dispatcher` seam.
2. **Seam (already landed by the EL0/SVC card, PR #60):**
   `exceptions.set_svc_dispatcher(...)` registers the dispatcher and the
   `is_svc64_from_el0(kind, esr, spsr)` predicate routes EC 0x15 from EL0t
   to it before the report+park fallback; SVC from EL1t/EL1h still reports
   + parks. Do **not** add a parallel seam — this card implements the
   dispatcher (table + marshalling) and registers it through the landed
   one.
3. **Writer seam:** `syscall.init(writer)` where writer is
   `*const fn ([]const u8) void` — the same shape as `exceptions.init`.
   `sys_write` validates, then emits through this writer.
4. **`syscalls` monitor command (required by the live gate):** prints the
   implemented table (number + name) and per-number call counts —
   deterministic and grep-able, in the style of `tasks`/`timer`.
   Adding it bumps `registry_count` 22 → 23; see the transcript note in
   the gates.
5. **The ADR:** `docs/decisions/0007-syscall-abi.md` — context, the
   decisions above, the table, the error codes, constraints (no POSIX; the
   `-3` reservation; the immediate-field reservation; SVC is EL0-only),
   and a "what this is not" section (no process abstraction, no uaccess,
   no errno/POSIX — those are later cards that build on this ABI).

## Do not

- Modify `kernel/src/main.zig`'s takeover path (ExitBootServices, MMU,
  probe) or the scheduler's task model beyond what `sys_yield`/`sys_exit`
  strictly require (and prefer scheduling hooks over scheduler rewrites —
  coordinate with the EL0 card's claim if the user-task lifecycle already
  touches `scheduler.zig`).
- Implement uaccess, PAN, per-task address spaces, or user ELF loading —
  those are follow-on cards that build on this ABI.
- Use a `const` table for dispatch (ADR 0005); build it at runtime.
- Change the syscall numbers, signatures, or error codes once the ADR is
  drafted — the whole point is a frozen contract.
- Hand-edit generated indexes (`docs/claims/README.md`,
  `docs/logs/README.md`); run `bash tools/status/refresh-indexes.sh`.
- Claim any observed hardware behavior — this card is proven by unit,
  transcript, and live-gate evidence, not by new hardware discovery.

## Process (hard gate)

1. **Read the EL0/SVC card first.** List in your written plan exactly what
   it provides (SVC entry routing, architectural post-SVC ELR, frame return, the user
   task / any `user` or `exec` command, scheduler lifecycle hooks) and
   what this card adds on top.
2. **Claim before you start.** Create `docs/claims/<NNNN>-<slug>.md` from
   `docs/claims/TEMPLATE.md` (slug: `syscall-abi-dispatch`; derive the
   number with `bash tools/status/claim-id.sh "<branch>" "<slug>"`, set
   Status to `🔄 <branch>`) and append a log entry in
   `docs/logs/agent-...-m3-syscall-abi.md` *before* writing code. Run
   `bash tools/status/refresh-indexes.sh`.
3. Implement.
4. Verify per the gates below; save output under
   `artifacts/m3-syscall-abi-*.txt`.
5. Update `docs/status.md` (pointer-level: milestone-three tasks row +
   the "What comes immediately afterward" list) and, if needed, the
   roadmap's Milestone three section. Append the log, flip the claim to ✅,
   refresh the indexes.
6. Run `bash tools/verify-coordination.sh` before opening the PR; publish
   a **draft** PR against `main` with `gh` (ADR 0003 / branch protection).

## Verification gates

### Class A (portable / CI — must all pass)

1. `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig`
2. `bash tools/verify-unit-tests.sh` — new `zig test` coverage in
   `syscall.zig` (and the touched parts of `exceptions.zig`):
   - table is 64 slots, numbers 0–3 implemented, 4–63 reserved
   - no duplicate numbers; table well-formed (runtime build, ADR 0005)
   - `dispatch` decodes each implemented number; unknown → `-ENOSYS`
   - argument validation: `write` with fd≠1 → `-EBADF`; `len` over the
     write cap → `-EINVAL`; `buf + len` overflow → `-EINVAL`
   - `write` emits exactly `len` bytes through a mock writer and returns
     `len`; a 0-length write is legal and emits nothing
   - `yield` returns 0 and bumps the right counter
   - `exit` marks the task terminated (scheduler hook) and never returns
   - the EL0-only rule is a pure predicate and is pinned: SVC from
     EL1t/EL1h → not dispatched (report+park path), from EL0t → dispatched
   - per-number counters monotonic; `syscalls` output deterministic
3. `zig build test-console` — the mock transcript gate. **If you add the
   `syscalls` command, the byte-identical fixture will (correctly) fail
   because `help` derives from the registry — update the fixture
   deliberately; do not fake the diff.**
4. `zig build`, `zig build image`, `zig build inspect`,
   `swift build --package-path host/vm-runner`, `zig build context`
5. `bash tools/verify-coordination.sh`

### Class B (Apple silicon + VZ — run on a development host, `just verify-vz`)

1. **New gate `tools/verify-live-svc.sh`** (in the style of
   `tools/verify-live-tasks.sh` / `tools/verify-live-exceptions.sh`):
   boots the VM, drives the shell so the EL0 user task executes real
   `svc` instructions, and asserts in `vm-serial.log`:
   - the `sys_write` path emitted its bytes (e.g., a line like
     `syscall: write ok n=<N>`), and
   - the round trip completed: after the SVC the user task kept running
     and the shell answered a follow-up command (e.g., an
     `rx-svc-ok` echo reply), and
   - `syscalls` reports exactly one table snapshot with `ping=2` and
     `write=1`, `yield=1`, `exit=1`; match complete lines so `calls=10`
     cannot satisfy `calls=1`, and
   - the bounded write is one complete LF-terminated line, and a real timer
     preemption is observed before cooperative yield/exit.
   Register it in `docs/gate-inventory.md` (class B, gate) and in the
   `just verify-vz` aggregate if the justfile lists gates explicitly.
2. **Live regressions still green:** `verify-live-timer` (strict
   `irq=5 poll=0`), `verify-live-tasks`, `verify-live-exceptions`,
   `verify-live-transcript`, and claim 8215's `verify-live-userspace`
   (the EL0 boundary gate). Save the run under `artifacts/`.

Note: claim 8215's `verify-live-userspace.sh` already proves the raw
EL0→`svc`→EL1→EL0 round trip on VZ. The new gate's job is the syscall
**table** (write/yield/exit + per-number counters) — reuse that harness
where possible instead of re-proving the boundary.

## Definition of done

- A frozen, ADR-locked syscall ABI (numbers, registers, errors) with a
  working EL0→`svc`→EL1 dispatch → `eret` round trip on real VZ,
  proven by the class-A unit/transcript set and the new class-B
  `verify-live-svc.sh` gate.
- `sys_write` (console), `sys_yield` (scheduler), `sys_exit` (task
  termination) implemented; reserved slots return `-ENOSYS`.
- The dispatch table is runtime-built (ADR 0005); no `const` table.
- No hardware claim without saved `artifacts/` evidence; no POSIX/libc;
  no uaccess or address-space work smuggled in.
- Coordination green: claim ✅, branch log appended, indexes refreshed,
  `verify-coordination.sh` passes, draft PR open.
