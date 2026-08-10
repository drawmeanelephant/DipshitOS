# Ragshit context bundle

## Request

"set_svc_dispatcher" "is_svc64_from_el0" "pub export fn kernel_main" "Completed with two deliberately narrow EL0 apertures" "The tiny ABI uses x8" "minimal x8/x0 SVC ABI" "Function-pointer tables must be built at runtime" "userspace is a later card" "userspace is the next milestone-three card" "registry_count" "startScriptInput" "scripted-input mode" "switch_context" "writer abstraction" "pub const Console = struct" "verify-live-userspace.sh" "syscall ABI"

## Repository state

- root: /private/tmp/dipshitos-ragshit-019fe9b9
- branch: agent/codex/m3-ragshit-dogfood
- head: 6b1b8cd2195fc543da149536074e9088542a7d57
- detached: False
- dirty_files: 4
- indexed_files: 227
- indexed_chunks: 2080
- fts5: True
- recent_commits:
  - 6b1b8cd: docs: align syscall ABI card with the EL0/SVC branch's landed SVC conventions
  - 163b9ab: docs: milestone-three card prompt docs (syscall ABI, march tracker, ragshit dogfood, runner scripted input)
  - 65ad6af: Add first EL0 task and SVC boundary
  - d19f063: Claim EL0 task and SVC boundary
  - b678d30: docs: reconcile status/hardware-contract/roadmap with merged IRQ delivery + custom-virtio (claim 1370)
  - 3436676: Merge pull request #58 from drawmeanelephant/agent/buffy/macos27-custom-virtio-spike
  - f649b9e: Tick-driven task scheduler: round-robin kernel tasks on the timer PPI (claim 5275)
  - 9f74989: Merge pull request #57 from drawmeanelephant/agent/buffy/macos27-custom-virtio-spike
  - 28809cf: Custom-virtio transport: full bidirectional queues + IRQ on VZ (claims 0828/4374/9492/9737/4837)
  - 257f67d: Merge pull request #56 from drawmeanelephant/agent/buffy/macos27-custom-virtio-spike

## Retrieval summary

- query: "set_svc_dispatcher" "is_svc64_from_el0" "pub export fn kernel_main" "Completed with two deliberately narrow EL0 apertures" "The tiny ABI uses x8" "minimal x8/x0 SVC ABI" "Function-pointer tables must be built at runtime" "userspace is a later card" "userspace is the next milestone-three card" "registry_count" "startScriptInput" "scripted-input mode" "switch_context" "writer abstraction" "pub const Console = struct" "verify-live-userspace.sh" "syscall ABI"
- requested_limit: 30
- included: 68
- omitted: 4
- total_characters: 118649
- top_scores: [10.23, 9.85, 9.29, 9.12, 8.81]

## Current diff

- working-tree changes: 2 file(s)
  - docs/claims/README.md (lines 98-98)
  - docs/logs/README.md (lines 57-57)
- untracked: docs/claims/1594-m3-ragshit-dogfood.md, docs/logs/agent-codex-m3-ragshit-dogfood.md

## Retrieved sources

===== BEGIN SOURCE =====
path: kernel/src/exceptions.zig
lines: 116-118
kind: symbol
symbol: set_svc_dispatcher
language: zig
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 10.23
  FTS rank: +4.73
  recent change: +0.50
  symbol exact: +5.00
===== CONTENT =====
pub fn set_svc_dispatcher(d: SvcDispatcher) void {
    svc_dispatcher = d;
}
===== END SOURCE =====

===== BEGIN SOURCE =====
path: kernel/src/exceptions.zig
lines: 231-233
kind: symbol
symbol: is_svc64_from_el0
language: zig
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 9.85
  FTS rank: +4.35
  recent change: +0.50
  symbol exact: +5.00
===== CONTENT =====
pub fn is_svc64_from_el0(kind: u64, esr: u64, spsr: u64) bool {
    return kind == kind_sync and ((esr >> 26) & 0x3f) == 0x15 and (spsr & 0xf) == 0;
}
===== END SOURCE =====

===== BEGIN SOURCE =====
path: kernel/src/monitor.zig
lines: 200-212
kind: symbol
symbol: registry_count
language: zig
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 9.29
  FTS rank: +3.79
  recent change: +0.50
  symbol exact: +5.00
===== CONTENT =====
pub const registry_count: usize = 22;

/// Command registry, built at runtime into BSS. A `const` table would hold
/// link-time absolute addresses for BOTH the string slices and the handler
/// function pointers, which are wrong at the kernel's runtime-chosen load
/// base (claim 0015 root cause: the first vtable dispatch crashed; the
/// flat loader applies no relocations, unlike macOS for host tests). Built
/// once here in RAM so every pointer resolves PC-relatively (ADRP) and is
/// correct at any load base. `help` derives its listing from this table,
/// so the two cannot drift.
var registry_storage: [registry_count]Command = undefined;
var registry_ready = false;
===== END SOURCE =====

===== BEGIN SOURCE =====
path: kernel/src/scheduler.zig
lines: 220-234
kind: symbol
symbol: switch_context
language: zig
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 9.12
  FTS rank: +3.62
  recent change: +0.50
  symbol exact: +5.00
===== CONTENT =====
pub fn switch_context(frame_sp: u64, elr: u64, spsr: u64, sp_el0: u64) void {
    if (task_count == 0) return;
    tasks[current].sp = frame_sp;
    tasks[current].elr = elr;
    tasks[current].spsr = spsr;
    tasks[current].sp_el0 = sp_el0;
    tasks[current].saves += 1;
    current = (current + 1) % task_count;
    pending_sp = tasks[current].sp;
    pending_elr = tasks[current].elr;
    pending_spsr = tasks[current].spsr;
    pending_sp_el0 = tasks[current].sp_el0;
    tasks[current].resumes += 1;
    switches += 1;
}
===== END SOURCE =====

===== BEGIN SOURCE =====
path: host/vm-runner/Sources/VMRunner/main.swift
lines: 793-823
kind: symbol
symbol: startScriptInput
language: swift
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 8.81
  FTS rank: +3.31
  recent change: +0.50
  symbol exact: +5.00
===== CONTENT =====
func startScriptInput() {
    guard let scriptPath else { return }
    let q = DispatchQueue(label: "dipshitos.script")
    q.async {
        let scriptData: Data
        do {
            scriptData = try Data(contentsOf: URL(fileURLWithPath: scriptPath))
        } catch {
            FileHandle.standardError.write(Data("ERROR: could not read script file '\(scriptPath)': \(error)\n".utf8))
            exit(1)
        }
        let waitDeadline = Date().addingTimeInterval(40)
        var sent = false
        while Date() < waitDeadline {
            if let text = try? String(contentsOf: serialURL, encoding: .utf8),
               text.contains("kernel terminal state") {
                Thread.sleep(forTimeInterval: 0.5)
                do { try consoleInputPipe.fileHandleForWriting.write(contentsOf: scriptData) }
                catch {
                    FileHandle.standardError.write(Data("ERROR: could not forward script to the guest serial attachment: \(error)\n".utf8))
                }
                sent = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if !sent {
            FileHandle.standardError.write(Data("ERROR: guest did not reach the terminal state within 40s; script input not sent\n".utf8))
        }
    }
}
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-syscall-abi-prompt.md
lines: 1-58
kind: section
symbol: Milestone three — syscall ABI + dispatch table (the SVC contract)
heading: Milestone three — syscall ABI + dispatch table (the SVC contract)
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 15.00
  FTS rank: +8.00
  heading match: +2.00
  recent change: +0.50
  symbol match: +2.00
  symbol partial: +2.50
===== CONTENT =====
# Milestone three — syscall ABI + dispatch table (the SVC contract)

Planning-first agent prompt for DipshitOS. Feed this file to the
implementing agent. It must produce a written plan **before** changing any
code, and it must read the in-flight EL0/SVC card's claim and PR first —
this card layers the dispatch table on top of whatever SVC entry plumbing
that card lands; it must not fight it.

- Branch: `agent/.../m3-syscall-abi` (claim first via a claim file in
  `docs/claims/` + a log entry in `docs/logs/`; merge per ADR 0003)
- Date: 2026-08-09
- Depends on: **the EL0/SVC card** (PR #60 — draft, branch
  `codex/el0-svc-task`, claim 8215 ✅ — smallest real EL0 task + SVC
  kernel boundary). Do not start the implementation until PR #60 MERGES
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
  executes `svc`. An SVC taken from EL1 (SPSR.M == 0x4 is EL0t; M == 0x5 is
  EL1t) is a kernel bug: report + park, exactly as today.
- **Console discipline:** an SVC handler runs in *synchronous* exception
  context, not IRQ context (claim 7948's no-console rule does not apply to
  it), but keep prints minimal, deterministic, and grep-able.
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/decisions/0005-runtime-built-function-tables.md
lines: 1-4
kind: section
symbol: ADR 0005: Function-pointer tables must be built at runtime, not const in `.rodata` (the flat-loader relocation bug)
heading: ADR 0005: Function-pointer tables must be built at runtime, not const in `.rodata` (the flat-loader relocation bug)
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 10.94
  FTS rank: +4.44
  heading match: +2.00
  symbol match: +2.00
  symbol partial: +2.50
===== CONTENT =====
# ADR 0005: Function-pointer tables must be built at runtime, not const in `.rodata` (the flat-loader relocation bug)

Status: **accepted** · Date: 2026-08-07 · Milestone: 1.5 (found by claim 0015)
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-syscall-abi-prompt.md
lines: 110-137
kind: section
symbol: Scope
heading: Milestone three — syscall ABI + dispatch table (the SVC contract) > Scope
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 9.11
  FTS rank: +6.61
  heading match: +2.00
  recent change: +0.50
===== CONTENT =====
## Scope

1. **`kernel/src/syscall.zig` (new file):** the runtime-built dispatch
   table (64 slots, 4 implemented), argument marshalling from the vector
   frame (x1–x5; number in x0), the error-code enum, per-number call
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
4. **`syscalls` monitor command (optional but recommended):** prints the
   implemented table (number + name) and per-number call counts —
   deterministic and grep-able, in the style of `tasks`/`timer`.
   Adding it bumps `registry_count` 22 → 23; see the transcript note in
   the gates.
5. **The ADR:** `docs/decisions/0007-syscall-abi.md` — context, the
   decisions above, the table, the error codes, constraints (no POSIX; the
   `-3` reservation; the immediate-field reservation; SVC is EL0-only),
   and a "what this is not" section (no process abstraction, no uaccess,
   no errno/POSIX — those are later cards that build on this ABI).
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-runner-scripted-input-prompt.md
lines: 1-21
kind: section
symbol: Milestone three — host runner scripted-input mode (OPTIONAL / deferrable)
heading: Milestone three — host runner scripted-input mode (OPTIONAL / deferrable)
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 9.09
  FTS rank: +4.09
  heading match: +1.00
  recent change: +0.50
  symbol match: +1.00
  symbol partial: +2.50
===== CONTENT =====
# Milestone three — host runner scripted-input mode (OPTIONAL / deferrable)

Planning-first agent prompt for DipshitOS. Feed this file to the
implementing agent. **Optional card:** add a fixture-driven scripted-input
mode to the Swift host runner so live gates can inject deterministic
keystroke sequences into the guest serial input without a human at the
keyboard. Defer if it risks the EL0/SVC or syscall-ABI streams' live-gate
runs (they rebuild and boot the runner on the same dev host).

- Branch: `agent/.../m3-runner-scripted-input` (claim first via
  `docs/claims/` + a log entry in `docs/logs/`; merge per ADR 0003)
- Date: 2026-08-09
- Depends on: — (touches `host/vm-runner/` only — disjoint from
  `kernel/`, `tools/`, and `docs/`; agents on separate branches build the
  runner from their own branch, so concurrent live-gate runs are not
  affected by in-flight edits)
- Inputs (read first): `AGENTS.md`, `host/vm-runner/Package.swift`,
  `host/vm-runner/Sources/VMRunner/main.swift` (the `--console` duplex
  attachment and the evidence-path attachment — claims 0003/6684),
  `docs/status.md` (live-gate section), `docs/gate-inventory.md`.
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-syscall-abi-prompt.md
lines: 204-227
kind: section
symbol: Class B (Apple silicon + VZ — run on a development host, `just verify-vz`)
heading: Milestone three — syscall ABI + dispatch table (the SVC contract) > Verification gates > Class B (Apple silicon + VZ — run on a development host, `just verify-vz`)
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 6.24
  FTS rank: +1.74
  heading match: +3.00
  recent change: +0.50
  symbol match: +1.00
===== CONTENT =====
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
   - `syscalls` reports a count ≥ 1 for the exercised number(s).
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
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-userspace.sh
lines: 22-22
kind: symbol
symbol: SCRIPT
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 5.48
  FTS rank: +1.48
  recent change: +0.50
  symbol match: +1.00
  symbol partial: +2.50
===== CONTENT =====
SCRIPT="artifacts/live-userspace-script.txt"
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-syscall-abi-prompt.md
lines: 155-176
kind: section
symbol: Process (hard gate)
heading: Milestone three — syscall ABI + dispatch table (the SVC contract) > Process (hard gate)
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 4.96
  FTS rank: +2.46
  heading match: +2.00
  recent change: +0.50
===== CONTENT =====
## Process (hard gate)

1. **Read the EL0/SVC card first.** List in your written plan exactly what
   it provides (SVC entry routing, ELR advance, frame return, the user
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
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-syscall-abi-prompt.md
lines: 59-60
kind: section
symbol: The ABI (bake these decisions into the ADR; do not relitigate them)
heading: Milestone three — syscall ABI + dispatch table (the SVC contract) > The ABI (bake these decisions into the ADR; do not relitigate them)
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 4.88
  FTS rank: +1.38
  heading match: +2.00
  recent change: +0.50
  symbol match: +1.00
===== CONTENT =====
## The ABI (bake these decisions into the ADR; do not relitigate them)
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-syscall-abi-prompt.md
lines: 228-240
kind: section
symbol: Definition of done
heading: Milestone three — syscall ABI + dispatch table (the SVC contract) > Definition of done
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 4.75
  FTS rank: +2.25
  heading match: +2.00
  recent change: +0.50
===== CONTENT =====
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
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-syscall-abi-prompt.md
lines: 76-85
kind: section
symbol: Numbered syscall list
heading: Milestone three — syscall ABI + dispatch table (the SVC contract) > The ABI (bake these decisions into the ADR; do not relitigate them) > Numbered syscall list
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 4.57
  FTS rank: +1.07
  heading match: +2.00
  recent change: +0.50
  symbol match: +1.00
===== CONTENT =====
### Numbered syscall list

| # | Name | Signature | Behavior |
|---|------|-----------|----------|
| 0 | `sys_ping` | `ping(value) -> value` | The EL0 card's proof syscall (PR #60, claim 8215): round-trips x0 through `svc #0` and returns it. Keep as-is — the class-B gate asserts its two-call sequence. |
| 1 | `sys_write` | `write(fd, buf, len) -> i64` | Only fd 1 (console). Writes `len` bytes from user address `buf` through the registered console writer. Returns bytes written (0..len) or a negative error. |
| 2 | `sys_yield` | `yield() -> i64` | Round-robin yield: hands the current user task to the scheduler (claim 5275). Returns 0. |
| 3 | `sys_exit` | `exit(status) -> noreturn` | Terminates the calling user task; the scheduler reaps it and the shell reports. Never returns. |
| 4–63 | reserved | — | Dispatch returns `-ENOSYS`. |
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/decisions/0005-runtime-built-function-tables.md
lines: 5-29
kind: section
symbol: Context
heading: ADR 0005: Function-pointer tables must be built at runtime, not const in `.rodata` (the flat-loader relocation bug) > Context
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 4.50
  heading match: +2.00
  symbol partial: +2.50
===== CONTENT =====
## Context

The kernel ELF is **linked at address 0 with no relocation sections**. The
boot stub copies the flat image to a **runtime-chosen base** (observed on
VZ: `0x7e4d1000` / `0x7e4da000` — the loader picks a free
`EfiLoaderCode`-type window from the captured map) and jumps to it without
relocating anything. PC-relative code (`bl`, `adrp`/`add`) is correct at
any base, but **absolute addresses baked into data tables are not**.

Zig places `const` structs containing function pointers (and `const`
arrays of string slices) into `.rodata` with **link-time absolute**
addresses — e.g. `vtable.write = 0x44c4`, the image-relative offset of
`writeFn`. At runtime the function actually lives at
`runtime_base + 0x44c4`, so the first indirect call through the table
jumps to physical address `0x44c4` — instantly faulting.

Until claim 0015, **no kernel code path ever dispatched through a data
table on real hardware**: the serial console was blocked on VZ, so the
shell loop (which uses vtables) had never run; host-side tests pass
because macOS relocates test binaries, so they never exposed the bug.
Claim 0015's NVRAM-console build finally ran the shell loop post-exit on
VZ and crashed at the first vtable dispatch (observed: chunk 30
persisted — the last direct `uart_puts` line — and the first
vtable-dispatched write never did; `writeFn` was never entered).
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-userspace.sh
lines: 80-97
kind: symbol
symbol: n
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 4.17
  FTS rank: +1.17
  recent change: +0.50
  symbol partial: +2.50
===== CONTENT =====
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-userspace boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-userspace: PASS — EL0 executed, completed an SVC return round-trip, and was timer-preempted back to the responsive EL1h shell ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-userspace: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot serial logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-syscall-abi-prompt.md
lines: 177-178
kind: section
symbol: Verification gates
heading: Milestone three — syscall ABI + dispatch table (the SVC contract) > Verification gates
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 3.96
  FTS rank: +1.46
  heading match: +2.00
  recent change: +0.50
===== CONTENT =====
## Verification gates
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-syscall-abi-prompt.md
lines: 86-98
kind: section
symbol: Error codes (returned in x0, negative)
heading: Milestone three — syscall ABI + dispatch table (the SVC contract) > The ABI (bake these decisions into the ADR; do not relitigate them) > Error codes (returned in x0, negative)
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 3.67
  FTS rank: +1.17
  heading match: +2.00
  recent change: +0.50
===== CONTENT =====
### Error codes (returned in x0, negative)

- `0` — success
- `-1` — `EINVAL`: bad/overlapping argument (e.g., `len` beyond the
  bounded write cap, or `buf + len` overflow)
- `-2` — `EBADF`: fd is not 1
- `-3` — `EFAULT`: reserved for the follow-on uaccess card (bad user
  pointer). Do **not** claim uaccess here — the write handler validates
  ranges with plain bounded arithmetic against the identity map and
  returns `EINVAL` for now. Record in the ADR that `-3` is allocated but
  unimplemented.
- `-4` — `ENOSYS`: unknown syscall number
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-syscall-abi-prompt.md
lines: 99-109
kind: section
symbol: Return plumbing
heading: Milestone three — syscall ABI + dispatch table (the SVC contract) > The ABI (bake these decisions into the ADR; do not relitigate them) > Return plumbing
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 3.66
  FTS rank: +1.16
  heading match: +2.00
  recent change: +0.50
===== CONTENT =====
### Return plumbing

- The dispatch result lands in **x0 of the saved vector frame** so the
  stub's register restore pops it into x0 on `eret`. The EL0/SVC card
  (PR #60) already owns entry routing, ELR advance past the 32-bit `svc`,
  and the SP_EL0 save/restore (`exc_dispatch` returns `.{ frame, sp_el0
  }`; `resume_sp_el0`). The syscall module supplies only the table +
  argument marshalling: read x0 = number and x1–x5 = args out of the
  frame, dispatch, write the result into x0. Do not re-implement the
  entry path.
===== END SOURCE =====

===== BEGIN SOURCE =====
path: kernel/src/console.zig
lines: 1-23
kind: symbol
symbol: Console
language: zig
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 3.57
  FTS rank: +1.07
  symbol partial: +2.50
===== CONTENT =====
//! Dipshit Monitor console abstraction (Milestone 1.5, commands & personality).
//!
//! A tiny, transport-agnostic console interface. The command layer never
//! knows whether bytes eventually reach a PL011, a 16550, a virtio-console,
//! or a host-side test mock: it only holds a `Console` value with a
//! function-pointer vtable and an opaque context pointer.
//!
//! Kernel wiring: the later Console & Shell Core stream supplies an adapter
//! over the milestone-two polled TX `uart_*` console (ADR 0004 D4).
//! Host tests: `MockConsole` captures output into a bounded buffer.
//!
//! No libc, no POSIX, no allocation, no dynamic registration, no global
//! mutable state. All formatting is byte-streamed so output stays bounded.

const std = @import("std");

/// Value-type console handle: `ctx` plus a stateless function-pointer vtable.
/// Every method below degrades to `write`, so a transport only has to
/// provide one function (plus a no-op-friendly `flush`).
pub const Console = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-syscall-abi-prompt.md
lines: 61-75
kind: section
symbol: Numbering and dispatch
heading: Milestone three — syscall ABI + dispatch table (the SVC contract) > The ABI (bake these decisions into the ADR; do not relitigate them) > Numbering and dispatch
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 3.53
  FTS rank: +1.03
  heading match: +2.00
  recent change: +0.50
===== CONTENT =====
### Numbering and dispatch

- The EL0/SVC card (PR #60, claim 8215) has already fixed the SVC
  convention and it is binding: **syscall number in x0**, instruction
  `svc #0` (`svc_immediate = 0` in `kernel/src/userspace.zig`), result
  returned in **x0** (its `syscall_ping` round-trips exactly this).
  Extend it, don't replace it: args arrive in **x1–x5** (the saved GPRs of
  the vector frame), the number in x0, the result written back to x0. The
  SVC immediate (ESR_EL1 ISS bits [24:0]) stays 0 and is reserved.
- The number space is **0..63** (64 slots). Slot 0 is the EL0 card's
  `syscall_ping` — keep it untouched (it is the class-B live-gate
  evidence). Slots 4–63 are reserved and return `-ENOSYS`; adding a
  syscall later = one table row + one handler + one unit test, never a
  renumber.
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-syscall-abi-prompt.md
lines: 138-154
kind: section
symbol: Do not
heading: Milestone three — syscall ABI + dispatch table (the SVC contract) > Do not
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 3.53
  FTS rank: +1.03
  heading match: +2.00
  recent change: +0.50
===== CONTENT =====
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
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-syscall-abi-prompt.md
lines: 179-203
kind: section
symbol: Class A (portable / CI — must all pass)
heading: Milestone three — syscall ABI + dispatch table (the SVC contract) > Verification gates > Class A (portable / CI — must all pass)
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 3.38
  FTS rank: +0.88
  heading match: +2.00
  recent change: +0.50
===== CONTENT =====
### Class A (portable / CI — must all pass)

1. `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig`
2. `bash tools/verify-unit-tests.sh` — new `zig test` coverage in
   `syscall.zig` (and the touched parts of `exceptions.zig`):
   - table is 64 slots, numbers 0–2 implemented, 3–63 reserved
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
===== END SOURCE =====

===== BEGIN SOURCE =====
path: kernel/src/exceptions.zig
lines: 911-918
kind: symbol
symbol: exceptions: only AArch64 SVC from EL0t reaches the SVC seam
language: zig
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 3.25
  FTS rank: +1.75
  recent change: +0.50
  symbol match: +1.00
===== CONTENT =====
test "exceptions: only AArch64 SVC from EL0t reaches the SVC seam" {
    const svc_esr: u64 = (0x15 << 26) | 0x42;
    try std.testing.expect(is_svc64_from_el0(kind_sync, svc_esr, 0x0));
    try std.testing.expect(!is_svc64_from_el0(kind_irq, svc_esr, 0x0));
    try std.testing.expect(!is_svc64_from_el0(kind_sync, svc_esr, 0x5));
    try std.testing.expect(!is_svc64_from_el0(kind_sync, 0, 0x0));
}
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-userspace.sh
lines: 1-15
kind: symbol
symbol: ROOT
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 3.09
  FTS rank: +2.59
  recent change: +0.50
===== CONTENT =====
#!/usr/bin/env bash
#
# verify-live-userspace.sh -- claim 8215 class-B gate: a real EL0t task,
# synchronous SVC boundary, and timer-preempted return to the EL1h shell.
#
# The success line is emitted only after the lower-EL synchronous vector has
# accepted TWO correctly sequenced SVCs. The second entry proves the first SVC
# returned to EL0 with x0 restored. The shell prints the deferred line only
# after the timer preempts the EL0 task and schedules EL1h again.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/roadmap.md
lines: 242-284
kind: section
symbol: Milestone three — allocator, interrupts, tasks (implemented through the first tasks card)
heading: DipshitOS roadmap > Milestone three — allocator, interrupts, tasks (implemented through the first tasks card)
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 3.06
  FTS rank: +0.56
  heading match: +1.00
  recent change: +0.50
  symbol match: +1.00
===== CONTENT =====
## Milestone three — allocator, interrupts, tasks (implemented through the first tasks card)

> The milestone-three plan, in canonical order (mirroring
> `docs/status.md`'s "What comes immediately afterward"): physical
> allocator → exception vectors → GIC + timer → kernel tasks → userspace.
> Every card through the first tasks card is **done**; **userspace is the
> next milestone-three card**.

- ~~A physical page allocator over the captured EFI map.~~ **First step
  DONE 2026-08-08 (claim 3972):** first-fit bitmap allocator over the
  captured map's ConventionalMemory (fixed 128 KiB BSS bitmap over the
  4 GiB identity-map span), wired post-exit; `pages`/`pages selftest`
  monitor commands; 18 unit tests; live-observed on VZ. **Loader/boot-
  services pooling DONE 2026-08-09 (claim 5162):** the pool now covers
  conventional + loader + boot-services RAM, with explicit exclusion
  ranges protecting the live kernel image, stack, handoff page, and
  captured-map buffer (25 unit tests, class-A green, `pages` reports
  `excluded=`). The boot-time map walk is already served by
  `memmap.MapView` + `mem`/`pages`.
- ~~Exception vectors (VBAR_EL1 + basic synchronous/IRQ handlers).~~
  **DONE 2026-08-08 (claim 9746)** — a real vector table + sync/IRQ
  handlers installed post-MMU; `dipshit> fault` triggers a synchronous
  exception that is reported and resumed live on VZ (class B gate
  `tools/verify-live-exceptions.sh`).
- ~~Interrupt setup (GIC) and a timer.~~ **DONE 2026-08-09 (claim 9187,
  superseding claim 7948's blocker conclusion):** corrected ACPI MADT GIC
  type IDs, GICv3 redistributor SGI-frame offsets, and ICFGR trigger-bit
  programming. A real periodic CNTP PPI 30 now enters the claim-9746 EL1
  IRQ vector on VZ, is acknowledged/EOI’d and re-armed; the strict live
  gate requires `ticks=5 irq=5 poll=0` and passes 3/3 boots.
- ~~Tasks (kernel tasks first).~~ **DONE 2026-08-09 (claim 5275)** — a
  tick-driven round-robin scheduler between two kernel tasks: the
  shell/main task and a demo worker on its own static BSS stack preempt
  at every timer PPI, with a minimal save/restore (the claim-9746 stubs
  already keep the register file on the stack, so the scheduler only
  saves the vector-frame pointer + ELR/SPSR per task). `dipshit> tasks`
  reports per-task saves/resumes/advances; host tests cover the switch
  logic; the class-B live gate `tools/verify-live-tasks.sh` proves both
  tasks advance across ticks on VZ (worker report line after ≥ 2 real
  context switches + a responsive shell), and the strict live-timer gate
  still passes under preemption. No userspace, no MMU changes — a later
  card adds userspace.
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/decisions/0005-runtime-built-function-tables.md
lines: 32-69
kind: section
symbol: D1. Build every function-pointer table at runtime, in BSS
heading: ADR 0005: Function-pointer tables must be built at runtime, not const in `.rodata` (the flat-loader relocation bug) > Decisions > D1. Build every function-pointer table at runtime, in BSS
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 3.00
  heading match: +2.00
  symbol match: +1.00
===== CONTENT =====
### D1. Build every function-pointer table at runtime, in BSS

`&fn` evaluated inside executed code compiles to a PC-relative `adrp`/`add`
sequence, which resolves correctly at any load base. So instead of:

```zig
const vtable = console.Console.VTable{ .write = writeFn, ... }; // .rodata, link-time absolute
```

the kernel builds the table into module-level BSS storage on first use:

```zig
var vtable_storage: console.Console.VTable = undefined;
var vtable_ready = false;
fn ensure_vtable() *const console.Console.VTable {
    if (!vtable_ready) {
        vtable_storage = .{ .write = writeFn, .flush = flushFn, .readByte = readByteFn };
        vtable_ready = true;
    }
    return &vtable_storage;
}
```

The storage must be **module-level**, never a stack local (a pointer to a
stack frame would dangle). The same pattern now covers every indirect-dispatch
table in the kernel:

- `M15Console`'s console vtable (`kernel/src/main.zig`)
- `monitor.registry` — the 14-command table with `.handler = cmd_*`
  pointers (`kernel/src/monitor.zig`)
- `machine.control()` and the `disabled()`/`MockMachineControl` control
  vtables (`kernel/src/machine.zig`, `monitor.zig`)
- `BootMessages.messages` and `elephant_lines` — `const` arrays of string
  slices (same bug class: the *data pointers inside the slices* were
  link-time absolute; the garbled banner line was the symptom)
- `memmap.MapView`/`monitor` field tables and any other `const` table that
  holds pointers
===== END SOURCE =====

===== BEGIN SOURCE =====
path: kernel/src/main.zig
lines: 153-595
kind: symbol
symbol: kernel_main
language: zig
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 3.00
  recent change: +0.50
  symbol partial: +2.50
===== CONTENT =====
fn kernel_main(base: u64, size: u64, st: *const SystemTable, handoff_rec: *HandoffV2) callconv(.c) u64 {
    if (!valid_handoff(base, size, st, handoff_rec)) {
        print_pre_exit_error(st, "DipshitOS: invalid handoff\r\n");
        return bad_handoff;
    }

    // M1.5 machine controls: capture the EFI Runtime Services table
    // pre-exit. Runtime services (unlike boot services) survive
    // ExitBootServices, so `ResetSystem` remains callable after the
    // takeover — the same table whose SetVariable drives the marker
    // ladder below (observed working post-exit on VZ, claims 0009/0010).
    machine.init(st.runtime_services);

    // Claim 0015: capture the same table for the NVRAM console channel.
    // Active only in `-Dnvram-console` builds; otherwise the module's
    // writes are never called.
    nvram_console.init(st.runtime_services);

    print_pre_exit_error(st, "DipshitOS: kernel entered\r\n");
    evidence.set_marker(marker_entry);
    evidence.write_marker_var(st, marker_entry);
    // Second pre-exit write immediately after the first: if the persisted
    // variable still reads M2_ENTRY, a *repeated* SetVariable failed (the
    // marker ladder would be stuck); if it reads M2_CMAP!, the kernel died
    // inside capture_map below.
    evidence.write_marker_var(st, marker_cmap);

    const bs = st.boot_services orelse {
        print_pre_exit_error(st, "DipshitOS: no Boot Services\r\n");
        return map_failure;
    };

    var map_buffer = capture_map(bs) catch {
        print_pre_exit_error(st, "DipshitOS: GetMemoryMap failed\r\n");
        return map_failure;
    };

    // Claim 0013 diagnostic (PRE-EXIT, all firmware memory still readable):
    // record the declared MMIO windows, the EFI configuration table
    // (sniffing for the flattened device tree, magic 0xd00dfeed), and the
    // ACPI tables (SPCR names the console UART) into the probe-dump buffer.
    // Persist ONCE, immediately: big SetVariable writes are proven to work
    // pre-exit but hang post-exit on VZ (observed: the ladder stopped at
    // M2_RAW! with a 2.6 KB re-write pending), and a post-switch fault must
    // not lose this evidence. The post-exit probe appends only a small tail
    // (write_probe_tail).
    evidence.dump_mmio_descriptors(map_buffer.map);
    evidence.dump_config_table(st);
    pci.dump_acpi(st);
    // Claim 3475: the probe dump is persisted ONCE, after the serial
    // selection is known, and only in `-Dprobe-var` diagnostic builds. The
    // serial log carries the probe records (base/layout/records below), and
    // VZ's append-per-write variable store fills up fast: the ~32 KiB
    // persist per boot (16 chunks × 2 KiB) left ~64 B free by the time the
    // shell ran, so the ESP file window's `write` always failed with
    // EFI_OUT_OF_RESOURCES (observed, claim 3475). Claim 0015 already
    // gated the persist off in nvram-console builds for the same
    // starvation; `-Dprobe-var` restores it for diagnostics.
    const pre = probe_serial_pre(map_buffer.map, st);
    console_kind = pre.kind;
    console_base = pre.base;
    evidence.dump_sel(pre.kind, pre.base);
    if (comptime build_options.probe_var) evidence.write_probe_var(st);

    // Claim 0017 diagnostic (build-gated `-Dpreexit-tx`): transmit a fixed
    // line through the SAME virtio-pci transport the post-exit path uses
    // while Boot Services and the firmware address space are still active.
    // Runs after the probe evidence is persisted (a hang must not lose it)
    // and immediately before the pre-exit marker / ExitBootServices. The
    // marker ladder brackets the flush (M2_PEXT! ... M2_TXST!/M2_TXNT!/
    // M2_TXPL! ... M2_PEXD!); vm-serial.log is the "bytes reached the host"
    // gate (tools/verify-preexit-tx.sh). Diagnostic only — the post-exit
    // banner TX is untouched.
    if (comptime build_options.preexit_tx) virtio_console.preexit_tx_experiment(st);
    // Claim 0020 phase A: the same fixed line through the same transport,
    // still pre-ExitBootServices. Runs immediately before the pre-exit
    // marker so a hang cannot lose the persisted probe evidence.
    if (comptime tx_transition_a) virtio_console.transition_tx_experiment(st, .a);
    // Claim 0021 diagnostic (build-gated `-Dfw-mmu-capture`): while the
    // firmware translation is still live, record the firmware's MMU
    // registers + a bounded walk of its TTBR0 tables for the virtio BAR0
    // window (the claim-0020 post-switch hang target) and a RAM control
    // address, plus the kernel's planned values. Persisted as its own small
    // ASCII variable, immediately before the pre-exit marker/exit so a hang
    // cannot lose it.
    if (comptime fw_mmu_capture) evidence.fw_mmu_capture_diag(st, handoff_rec, virtio_console.vp_ready, virtio_console.vp_bar0);

    // Pre-exit stage: proves the kernel passed valid_handoff + capture_map
    // and reached the exit call. The persisted NVRAM marker being M2_ENTRY
    // instead means the kernel died in that window.
    evidence.write_marker_var(st, marker_prex);

    // Claim 6420: the virtio-pci block transport (the runner's disk is a
    // VZVirtioBlockDeviceConfiguration — modern virtio-blk, DID 0x1041).
    // Armed PRE-EXIT like the console (config-space + BAR reads hang
    // post-exit on VZ, claim 0013); its BAR0 window is handed to the
    // identity map below so post-MMU sector I/O reaches the device
    // (claim 1517's transport reliability applies).
    const blk_ready = virtio_blk.virtio_blk_init();

    // Claim 0828: the custom-virtio spike device (DID 0x1082) — PRE-EXIT
    // discovery only (config-space reads, the claim-0013 discipline). VZ's
    // firmware BAR assignment moves between boots (0x50001000 in the claim-
    // 5844 run; ABOVE the 4 GiB blanket on a later boot), so the transport
    // BAR is handed to the identity map below like the console/blk windows.
    const cv_probed = virtio_custom.probe();

    // Claim 6420: the ESP file window. The FAT32 volume on the ESP is
    // mounted through the virtio-blk transport and the root directory
    // snapshotted into the window (names/sizes/content for small files) —
    // replacing claim 3475's pre-exit Simple File System snapshot AND its
    // NVRAM persistence medium: `write` now writes the live FAT volume, so
    // files survive reboot on the disk itself. Best effort; a failed mount
    // leaves the window empty and the monitor reports it honestly.
    if (blk_ready) _ = esp.set_disk(virtio_blk.disk_ops());

    var exited = false;
    var attempt: usize = 0;
    while (attempt < 8) : (attempt += 1) {
        // The map buffer is already allocated. Re-reading it is the only
        // permitted operation between an INVALID_PARAMETER retry.
        if (bs.exitBootServices(@ptrFromInt(handoff_rec.image_handle), map_buffer.map.info.key)) |_| {
            exited = true;
            break;
        } else |err| switch (err) {
            error.InvalidParameter => {
                const refreshed = bs.getMemoryMap(map_buffer.buffer) catch {
                    print_pre_exit_error(st, "DipshitOS: map refresh failed\r\n");
                    return map_failure;
                };
                map_buffer.map = refreshed;
            },
            else => {
                print_pre_exit_error(st, "DipshitOS: ExitBootServices failed\r\n");
                return exit_failure;
            },
        }
    }
    if (!exited) {
        print_pre_exit_error(st, "DipshitOS: ExitBootServices failed after 8 attempts\r\n");
        halt_forever();
    }
    evidence.set_marker(marker_exit);
    evidence.write_marker_var(st, marker_exit); // first post-exit runtime-services call
    // Claim 0020 phase B: the FIRST post-exit TX attempt, immediately after
    // a successful ExitBootServices while the firmware's translation regime
    // is still active (DipshitOS page tables are not yet built). This is
    // the controlled test of whether ExitBootServices itself destroys
    // access to the transport window.
    if (comptime tx_transition_b) virtio_console.transition_tx_experiment(st, .b);

    // After successful exit, no longer allowed: AllocatePool/AllocatePages,
    // GetMemoryMap, SimpleTextOutput, Simple File System,
    // LoadImage/StartImage, SetTimer, any event services, any other Boot
    // Services call. The map buffer is now owned by this kernel and all
    // subsequent work is direct memory/register access only.
    const map_after_exit = map_buffer.map;
    // Claim 0023 (+ 6420): the virtio console + block BAR windows
    // (discovered pre-exit) are handed to mmu.build_identity_map as the
    // extra Device windows above the blanket; mmu.zig stays
    // transport-agnostic.
    var extra_windows: [3]mmu.DeviceWindow = undefined;
    var extra_count: usize = 0;
    if (virtio_console.vp_ready and virtio_console.vp_bar0 != 0) {
        extra_windows[extra_count] = .{ .base = virtio_console.vp_bar0, .len = 0x10000 };
        extra_count += 1;
    }
    if (virtio_blk.blk_ready and virtio_blk.blk_bar0 != 0) {
        extra_windows[extra_count] = .{ .base = virtio_blk.blk_bar0, .len = 0x10000 };
        extra_count += 1;
    }
    // Claim 0828: the custom-virtio transport BAR (pre-exit resolved).
    // mmu.zig maps windows above the blanket; below it the 4 GiB blanket
    // already covers the BAR, so the entry is a harmless no-op there.
    if (cv_probed and virtio_custom.cv_bar != 0) {
        extra_windows[extra_count] = virtio_custom.device_window();
        extra_count += 1;
    }
    const user_text = userspace.text_region(base);
    const user_stack = userspace.stack_region(base);
    const user_regions = [_]mmu.UserRegion{
        .{ .base = user_text.base, .len = user_text.len, .writable = false, .executable = true },
        .{ .base = user_stack.base, .len = user_stack.len, .writable = true, .executable = false },
    };
    if (!mmu.build_identity_map(map_after_exit, map_buffer.buffer, base, size, handoff_rec, extra_windows[0..extra_count], &user_regions)) {
        evidence.set_marker(marker_table);
        evidence.write_marker_var(st, marker_table);
        halt_forever();
    }
    // Pre-install write (still on the firmware identity map, reliable): if the
    // persisted ladder stops here, the kernel died between this write and the
    // post-install M2_MMUP! write — i.e. inside install_identity_map() or at
    // the first post-switch call (claim 0009: observed — every VZ run stops
    // at M2_MAPD!, so the MMU takeover window is the death site; the kernel
    // never reaches the serial probe).
    evidence.write_marker_var(st, marker_mapd);
    mmu.install_identity_map();
    // Claim 9746 (roadmap item 5, first half): install the VBAR_EL1
    // exception vectors + basic synchronous/IRQ handlers NOW — after
    // ExitBootServices and the identity-map switch, when the kernel owns
    // EL1 and no pre-exit firmware Boot Services are still active. Writing
    // VBAR_EL1 earlier (pre-ExitBootServices) is catastrophic on VZ
    // (observed: the pre-exit firmware calls hang ~7/8 boots — firmware
    // exceptions would land in the kernel's vectors, claim 9746). From
    // here on any fault produces an `[EXC]` report instead of a silent
    // hang. The report writer degrades to a no-op until the serial console
    // is probed below (console_kind == .none); the GIC is NOT programmed
    // here — that is the next card.
    userspace.init();
    exceptions.init(exception_report_writer);
    exceptions.set_svc_dispatcher(userspace.handle_svc);
    exceptions.install();
    // Claim 7948 (roadmap item 5, second half): GIC + generic timer. The
    // MADT/GTDT discovery ran PRE-EXIT inside pci.dump_acpi (post-exit ACPI
    // reads hang on VZ, claim 0013); program the controller + timer NOW —
    // post-MMU, when the kernel owns EL1 and device MMIO is reachable
    // (claim 1517), with the claim-9746 vectors already installed so any
    // misstep reports instead of hanging. Only then register the IRQ chain
    // and unmask IRQs, so no interrupt can arrive before the whole path
    // (GIC -> vector -> dispatcher -> timer) is armed.
    gic.init(timer.ppi, timer.interrupt_edge);
    timer.init();
    exceptions.set_irq_dispatcher(irq_dispatch);
    exceptions.irq_unmask();
    evidence.set_marker(marker_mmu);
    evidence.write_marker_var(st, marker_mmu);
    // Claim 1517: the TLBI is now executed inside install_identity_map()
    // (corrected start level T0SZ=16 + full invalidation at the switch —
    // the ADR-0006 no-TLBI debt is paid). With -Dwalk-probe (class D,
    // default off), run the cold-address probe battery so the ladder names
    // the first address that does not resolve.
    if (comptime build_options.walk_probe) walkprobe.run(st);
    // Claim 0020 phase C: the FIRST MMIO access to the transport after the
    // identity-map switch, before the post-switch probe (M2_RAW!) or any
    // other runtime-service/diagnostic work. Tests whether installing the
    // DipshitOS page tables destroys access (the claim-0013/0018
    // hypothesis), with the marker write above being the only prior
    // post-switch call.
    if (comptime tx_transition_c) virtio_console.transition_tx_experiment(st, .c);

    const selected = probe_serial(map_after_exit, st);
    console_kind = selected.kind;
    console_base = selected.base;
    if (selected.kind == .none) {
        evidence.set_marker(marker_seria);
        evidence.write_marker_var(st, marker_seria);
        evidence.write_marker_fallback(&virtio_console.virtio_tx, base, size, map_after_exit);
        halt_forever();
    }
    evidence.set_marker(marker_ready);
    evidence.write_marker_var(st, marker_ready);

    virtio_console.st_tx = st; // for flush stage markers
    // Claim 0020 phase D: TX at the normal final location — the same site
    // where the production banner transmits. Same payload as phases A/B/C.
    if (comptime tx_transition_d) virtio_console.transition_tx_experiment(st, .d);
    uart_puts("DipshitOS kernel has seized control.\n");
    // Claim 0013: after the first TX, record whether the TX path returned
    // (bytes may still be dropped by the device; the serial log is the gate,
    // but M2_TXOK! separates "TX hung" from "TX returned silently").
    evidence.write_marker_var(st, marker_txok);
    uart_puts("memory-map descriptors=");
    uart_hex(@intCast(map_after_exit.info.len));
    uart_puts(" descriptor_size=");
    uart_hex(@intCast(map_after_exit.info.descriptor_size));
    uart_puts(" version=");
    uart_hex(@intCast(map_after_exit.info.descriptor_version));
    uart_puts(" key=");
    uart_hex(@intFromEnum(map_after_exit.info.key));
    uart_puts("\n");

    var it = map_after_exit.iterator();
    while (it.next()) |desc| {
        uart_puts("map type=");
        uart_hex(@intFromEnum(desc.type));
        uart_puts(" base=");
        uart_hex(desc.physical_start);
        uart_puts(" pages=");
        uart_hex(desc.number_of_pages);
        uart_puts(" attr=");
        uart_hex(@bitCast(desc.attribute));
        uart_puts("\n");
    }

    uart_puts("probe base=");
    uart_hex(console_base);
    uart_puts(" layout=");
    uart_puts(layout_name(console_kind));
    uart_puts(" records=");
    uart_hex(@intCast(probe_count));
    uart_puts("\n");
    for (probe_records[0..probe_count]) |record| {
        uart_puts("probe candidate=");
        uart_hex(record.base);
        uart_puts(" magic=");
        uart_hex(record.magic);
        uart_puts(" version=");
        uart_hex(record.version);
        uart_puts(" device=");
        uart_hex(record.device);
        uart_puts(" layout=");
        uart_hex(record.layout);
        uart_puts("\n");
    }

    // Claim 9187: the interrupt-controller/timer state lands in the serial
    // log at every boot — the live gate's first assertion (before the
    // scripted `timer` command runs).
    uart_puts("interrupts: gic=");
    uart_puts(gic.kind_name());
    uart_puts(" armed=");
    uart_puts(if (gic.armed() and timer.armed()) "1" else "0");
    uart_puts(" dist=");
    uart_hex(gic.dist_base);
    uart_puts(" redist=");
    uart_hex(gic.redist_base);
    uart_puts(" active=");
    uart_hex(gic.active_redist_base);
    uart_puts(" fallback=");
    uart_puts(if (gic.used_fallback) "1" else "0");
    uart_puts(" ppi=");
    uart_hex(timer.ppi);
    uart_puts(" edge=");
    uart_puts(if (timer.interrupt_edge) "1" else "0");
    uart_puts(" freq=");
    uart_hex(timer.freq);
    uart_puts("\n");

    // Claim 6420: the ESP file window summary (the FAT volume mount result
    // + the root listing count). A second boot's line showing the file
    // `write` stored in boot one is the persistence-through-reboot
    // evidence in the serial log — the file now lives on the disk, not in
    // NVRAM variables (claim 3475's medium is replaced).
    uart_puts("esp window: esp=");
    uart_hex(@intCast(esp.esp_count()));
    uart_puts(" disk=");
    uart_puts(if (esp.disk_ready()) "1" else "0");
    uart_puts("\n");

    // Claim 6420: VZ resets the virtio-blk device at ExitBootServices (its
    // status reads 0 post-exit and the queue is dead). Re-arm the queue
    // now that the identity map is live, so the shell's `write` (live FAT
    // reads/writes through the transport) works. The pre-exit queue was
    // used only for the boot-time ESP mount.
    if (virtio_blk.blk_common != 0) _ = virtio_blk.blk_rearm();

    uart_puts("kernel terminal state\n");

    // macOS 27 custom-virtio spike (claim 0828): the smallest guest driver
    // for the spike device (`zig build spike-virtio`, DID 0x1082, claim
    // 5844). Probing, negotiation, DRIVER_OK, the queue-0 kick, and the
    // used-ring IRQ experiment all run POST-exit — post-MMU ECAM reads
    // work (claims 1517/6684) and the device's BAR2 window (0x50001000)
    // sits below the 4 GiB blanket. Silent no-op when the device is absent
    // (default builds are unchanged). Evidence: host runner stdout
    // (DRIVER_OK / notification / dequeued payload / returnToQueue) + this
    // serial report. The SPI window is disarmed after the report so the
    // shell runs without interrupt noise; the claim-9187 timer PPI stays
    // armed and the polled console paths are untouched.
    custom_virtio_spike();

    // ------------------------------------------------------------------
    // M1.5 console & shell core seam (agent B). The takeover path above
    // (exit, map, MMU, probe, uart_*) is byte-identical; this section only
    // wires the mock-proven shell loop onto the polled TX console. RX
    // reads are [inferred] and gated on the VZ serial gate (claim 0002,
    // unpassed): no device register is read, rx_wired() is false, so the
    // banner + prompt print and the kernel parks below — it never spins
    // hot. The loop's correctness is proven in kernel/src/shell.zig
    // against a scripted MockConsole (artifacts/m15-shell-core-loop.txt).
    // ------------------------------------------------------------------
    var m15 = M15Console{};
    const map_view = memmap.MapView.init(map_buffer.buffer, map_after_exit.info.descriptor_size, map_after_exit.info.len);
    // Physical page allocator (claims 3972 + 5162): arm the pool from the
    // captured map's conventional + loader + boot-services regions,
    // excluding the live kernel image, stack, handoff page, and captured
    // map buffer. Fixed BSS bitmap, no allocation; the `pages` monitor
    // command reports the pool. Not armed (silently) when the map declares
    // no poolable memory in span.
    const exclusions = [_]alloc.Exclusion{
        alloc.exclusion_from_bytes(handoff_rec.kernel_base, handoff_rec.kernel_size),
        alloc.exclusion_from_bytes(handoff_rec.stack_base, handoff_rec.stack_size),
        alloc.exclusion_from_bytes(@intFromPtr(handoff_rec), memmap.page_size),
        alloc.exclusion_from_bytes(@intFromPtr(map_buffer.buffer.ptr), map_buffer.buffer.len),
    };
    _ = alloc.init(map_view, &exclusions);
    const console_name = layout_name(console_kind);
    var mon = monitor.Monitor.init(
        m15.to_console(),
        .{
            // Claim 0023: the shared handoff.zig type is used directly.
            .handoff = handoff_rec.*,
            .map = map_view,
            .console_name = console_name[0 .. console_name.len - 1],
        },
        machine.control(),
    );
    // Claim 0015 diagnostic: mark the seam entry so a missing shell banner
    // is attributable to the seam setup vs. the shell write path.
    if (comptime build_options.nvram_console) {
        evidence.write_marker_var(st, marker_seam);
        // Stack + console-pointer probe: the banner write path crashed
        // without entering M15Console.writeFn, so record the state at the
        // seam (sp, vtable/ctx addresses, and a direct vtable dispatch).
        var sp: u64 = undefined;
        asm volatile ("mov %[sp], sp"
            : [sp] "=r" (sp),
        );
        uart_puts("[seam] sp=");
        uart_hex(sp);
        uart_puts(" base=");
        uart_hex(handoff_rec.stack_base);
        uart_puts(" ctx=");
        uart_hex(@intFromPtr(mon.console.ctx));
        uart_puts(" vt=");
        uart_hex(@intFromPtr(mon.console.vtable));
        uart_puts("\n");
        const probe_con = m15.to_console();
        probe_con.print_line("[seam] direct dispatch");
    }
    // Claim 5275: the first milestone-three tasks card — a tick-driven
    // round-robin scheduler. Task 0 is the EL1h shell/main task itself (its
    // context is captured on the first preemption); task 1 is the EL1h demo
    // worker on its own static stack; task 2 is the claim-8215 EL0t payload
    // with separate EL1 exception and EL0 execution stacks. Scheduling starts
    // only HERE, once the shell loop is the running context, so boot-time
    // printing (banner,
    // map, spike) is never preempted. The first tick then preempts the
    // shell, worker, and EL0 task run one quantum each — every timer PPI
    // (claim 9187) is a context switch.
    _ = scheduler.init();
    _ = scheduler.register_worker(@intFromPtr(&worker_entry));
    _ = scheduler.register_user(@intFromPtr(&userspace.entry));
    scheduler.start();
    shell.boot_and_park(&mon, m15.rx_wired());
    // No return after takeover. WFE is a terminal state, not a firmware call.
    // Note: with RX wired (nvram builds) boot_and_park loops forever, so
    // this flush is unreachable there — the trailing prompt is flushed by
    // readByteFn when the scripted session ends. Kept as a safety net for
    // the no-RX path, where boot_and_park returns after the prompt.
    if (comptime build_options.nvram_console) nvram_console.flush();
    halt_forever();
}
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-ragshit-dogfood-prompt.md
lines: 22-42
kind: section
symbol: Scope
heading: Milestone three — ragshit dogfood pass (index, bundle, review) > Scope
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 2.66
  FTS rank: +2.16
  recent change: +0.50
===== CONTENT =====
## Scope

1. **Index:** `./tools/ragshit/ragshit index .` — confirm the index is
   fresh and complete for the milestone-three surface (kernel/src,
   docs/status.md, docs/roadmap.md, docs/claims/, the new prompt docs).
2. **Bundle:** `./tools/ragshit/ragshit bundle . "milestone three
   userspace syscall ABI" --output artifacts/m3-ragshit-bundle.md` (or the
   equivalent query for the EL0/SVC + syscall-ABI surface).
3. **Fix gaps found:** if the bundle truncates or drops relevant chunks
   (claim 0176's failure mode), fix the engine/configuration in
   `tools/ragshit/` and re-run. Do not hack the bundle by hand.
4. **Dogfood review:** use the bundle to review `docs/m3-syscall-abi-prompt.md`
   against `docs/status.md` + `docs/roadmap.md` — flag contradictions,
   stale references, and missing dependencies (e.g., the EL0/SVC
   depends-on, ADR 0005's runtime-built-table rule, the registry-count
   bump, the transcript-fixture note). Findings go in your branch log and
   as a short "review findings" section in the claim; if a finding is a
   concrete doc fix, propose it — do not edit the prompt docs yourself
   unless trivial (they are the syscall card's contract).
5. **`doctor`:** `./tools/ragshit/ragshit doctor .` passes.
===== END SOURCE =====

===== BEGIN SOURCE =====
path: kernel/src/exceptions.zig
lines: 919-931
kind: symbol
symbol: exceptions: SVC dispatcher mutates x0 and resumes the same EL0 frame
language: zig
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 2.46
  FTS rank: +0.96
  recent change: +0.50
  symbol match: +1.00
===== CONTENT =====
test "exceptions: SVC dispatcher mutates x0 and resumes the same EL0 frame" {
    var frame: VectorFrame = [_]u64{0} ** vector_frame_slots;
    try std.testing.expect(frame_write(&frame, 0, 41));
    test_svc_immediate = 0;
    set_svc_dispatcher(test_svc_handler);
    const esr: u64 = (0x15 << 26) | 0x1234;
    const dispatch_result = exc_dispatch(&frame, esr, 0, 0x4000, 0, kind_sync);
    try std.testing.expectEqual(@intFromPtr(&frame), dispatch_result.frame);
    try std.testing.expectEqual(@as(u64, 0), dispatch_result.sp_el0); // host has no SP_EL0
    try std.testing.expectEqual(@as(u16, 0x1234), test_svc_immediate);
    try std.testing.expectEqual(@as(u64, 42), frame_read(&frame, 0));
}
===== END SOURCE =====

===== BEGIN SOURCE =====
path: kernel/src/scheduler.zig
lines: 428-454
kind: symbol
symbol: scheduler: mixed EL1h and EL0t round-robin restores SP_EL0
language: zig
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 2.18
  FTS rank: +1.68
  recent change: +0.50
===== CONTENT =====
test "scheduler: mixed EL1h and EL0t round-robin restores SP_EL0" {
    _ = init();
    _ = register_worker(0x2000).?;
    _ = register_user(0x3000).?;
    start();
    const initial_user_sp = tasks[2].sp_el0;

    switch_context(0x1000, 0x1000, spsr_el1h_irqs, 0xaaaa); // shell -> worker
    try std.testing.expectEqual(@as(usize, 1), current);
    switch_context(0x2000, 0x2000, spsr_el1h_irqs, 0xbbbb); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), current);
    try std.testing.expectEqual(spsr_el0t_irqs, pending_spsr);
    try std.testing.expectEqual(initial_user_sp, pending_sp_el0);

    const preempted_user_sp: u64 = initial_user_sp - 16;
    switch_context(0x3000, 0x3004, spsr_el0t_irqs, preempted_user_sp); // user -> shell
    try std.testing.expectEqual(@as(usize, 0), current);
    try std.testing.expectEqual(@as(u64, 0xaaaa), pending_sp_el0);
    try std.testing.expectEqual(preempted_user_sp, tasks[2].sp_el0);

    switch_context(0x1000, 0x1004, spsr_el1h_irqs, 0xaaaa);
    switch_context(0x2000, 0x2004, spsr_el1h_irqs, 0xbbbb);
    try std.testing.expectEqual(@as(usize, 2), current);
    try std.testing.expectEqual(preempted_user_sp, pending_sp_el0);
    try std.testing.expectEqual(@as(u64, 0x3004), pending_elr);
}
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/claims/1370-docs-reconcile-prs-55-56.md
lines: 9-39
kind: section
symbol: Notes
heading: Claim: Reconcile docs with the merged PRs #55 + #56 (real IRQ delivery + custom-virtio) > Notes
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 2.10
  FTS rank: +0.60
  heading match: +1.00
  recent change: +0.50
===== CONTENT =====
## Notes

Most of the mission's status.md checklist already landed inside the code
commits (ed2a3ac flipped the milestone-table row and item 6 for claim 9187;
e57362a set the macOS 27+ floor and the 21-command count; f649b9e
documented the tasks card). This claim verifies those and fills the
genuine gaps:

1. **`docs/status.md`** — verified present: milestone-table real IRQ
   delivery (claim 9187, 3/3), item 6 flipped, macOS 27+ floor.
   **Correction:** the mission's "21 commands" predates claim 5275's
   `tasks` command — the merged registry is **22** (`registry_count` in
   `kernel/src/monitor.zig`; branch log records "registry 21→22"), so the
   hard-gate count is updated to 22 with the provenance (20 → 21 via
   `pci`/claim 5844, → 22 via `tasks`/claim 5275).
2. **`docs/hardware-contract.md`** — the GIC/timer `[observed]` entries
   with the corrected SGI-frame offsets (`GICR+0x10080`, claim 9187) were
   already in place; the **custom-virtio discovery `[observed]`** (VID
   0x1af4 / DID 0x1082, BAR0 `0x100020000`, firmware leaving the PCI
   command register disabled, real SPI 69 used-ring IRQ, VZ's feature
   negotiation surface, per-burst IRQ coalescing; claims
   5844/0828/4374/9492/9737/4837) was missing and is added, both as a
   host-device bullet and as a dedicated section.
3. **`docs/roadmap.md`** — the milestone-three cards sat under "Later
   milestones (sketches only, not commitments)"; they are now presented as
   an ordered **Milestone three** section (physical allocator → exception
   vectors → GIC + timer → kernel tasks → userspace next), matching the
   canonical ordering in `docs/status.md`.

Gate: `bash tools/status/refresh-indexes.sh` then
`bash tools/verify-coordination.sh` (must stay green; also runs in CI).
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-userspace.sh
lines: 79-79
kind: symbol
symbol: pass
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 2.00
  FTS rank: +1.50
  recent change: +0.50
===== CONTENT =====
pass=0
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/decisions/0005-runtime-built-function-tables.md
lines: 30-31
kind: section
symbol: Decisions
heading: ADR 0005: Function-pointer tables must be built at runtime, not const in `.rodata` (the flat-loader relocation bug) > Decisions
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 2.00
  heading match: +2.00
===== CONTENT =====
## Decisions
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/decisions/0005-runtime-built-function-tables.md
lines: 70-78
kind: section
symbol: D2. Audit rule: no const data table may hold an address
heading: ADR 0005: Function-pointer tables must be built at runtime, not const in `.rodata` (the flat-loader relocation bug) > Decisions > D2. Audit rule: no const data table may hold an address
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 2.00
  heading match: +2.00
===== CONTENT =====
### D2. Audit rule: no const data table may hold an address

A `const` table is only safe if every field is immediate data (ints,
enums, fixed-size arrays of scalars) or **Zig-resolved** — never a
function pointer and never a string slice whose `.ptr` must be relocated.
The flat loader does no relocations, so any such table must be built at
runtime. Host tests do not catch violations (the host OS relocates test
binaries); only a live VZ run does.
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/decisions/0005-runtime-built-function-tables.md
lines: 79-95
kind: section
symbol: Consequences
heading: ADR 0005: Function-pointer tables must be built at runtime, not const in `.rodata` (the flat-loader relocation bug) > Consequences
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 2.00
  heading match: +2.00
===== CONTENT =====
## Consequences

- The first vtable dispatch on real hardware (claim 0015's shell seam) is
  now observed working: the shell runs, executes the scripted
  `version`/`mem`/`echo`/`help` commands post-exit, and its output
  reconstructs through the NVRAM console channel
  (`artifacts/nvram-console-gate.txt`).
- This was a **latent kernel bug**: any future const-pointer table (a
  driver ops table, an exception-handler table, a filesystem vtable) would
  have crashed on first dispatch at the same spot. The rule in D2 is the
  guard.
- The fix costs a few dozen bytes of BSS per table — negligible. The
  runtime-built tables are indistinguishable from const tables at the call
  site, so no API changes were needed.
- Not a fix for the broader "no relocations" design (ADR 0002/0004 keep
  the flat loader by design for this milestone); this ADR only removes the
  data-table landmine the design leaves in place.
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-userspace.sh
lines: 20-20
kind: symbol
symbol: BOOTS
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 2.00
  FTS rank: +1.50
  recent change: +0.50
===== CONTENT =====
BOOTS="${BOOTS:-1}"
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-userspace.sh
lines: 21-21
kind: symbol
symbol: REPORT
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.98
  FTS rank: +1.48
  recent change: +0.50
===== CONTENT =====
REPORT="artifacts/live-userspace-report.txt"
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-userspace.sh
lines: 29-29
kind: symbol
symbol: REVISION
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.97
  FTS rank: +1.47
  recent change: +0.50
===== CONTENT =====
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-userspace.sh
lines: 30-30
kind: symbol
symbol: BRANCH
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.96
  FTS rank: +1.46
  recent change: +0.50
===== CONTENT =====
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/claims/8215-el0-task-svc-boundary.md
lines: 15-52
kind: section
symbol: Notes
heading: Claim: EL0 task and SVC boundary > Notes
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.93
  FTS rank: +1.43
  recent change: +0.50
===== CONTENT =====
## Notes

This is the smallest milestone-three card that proves execution at EL0 rather
than merely preparing structures for it. The intended evidence is a live VZ
transcript showing an EL0 task enter through `eret`, invoke a kernel service
through a real synchronous `svc` exception, continue across timer preemption,
and leave the existing EL1 shell responsive. The ABI will expose only the
minimum operation needed for a deterministic proof; broader processes,
syscalls, loading, and virtual-address isolation remain later work.

Completed with two deliberately narrow EL0 apertures in the shared identity
map: a page-isolated `.usertext` range mapped EL0 read-only/executable and
PXN, and a page-isolated `.userbss` stack mapped EL0 read/write and XN. All
neighboring kernel Normal RAM and every Device mapping remain EL1-only. This
is not process or address-space isolation: the task is statically linked and
continues to share TTBR0 with the kernel.

The scheduler now round-robins the EL1h shell, EL1h worker, and EL0t payload
while preserving each task's SP_EL0. The exception-return ABI carries both the
selected register frame and SP_EL0; the lower-EL synchronous seam accepts only
AArch64 SVC from EL0t. The tiny ABI uses x8 as the operation selector and x0
as argument/result. While making that boundary honest, this card also fixed
the architectural SPSR mode decode (observed M=0x5 is EL1h) and the saved
vector-frame x0/x30 offsets.

Directly observed on Apple silicon VZ: the strict userspace gate passed 3/3
boots with the exact evidence line
`userspace: el0=1 svc=2 roundtrips=1 arg=2 result=2 rejected=0`; the second
sequenced SVC proves return to EL0 after the first, and the deferred shell-side
line proves timer preemption returned to a responsive EL1h context. Focused
live regressions for tasks, timer IRQ delivery, and exception reporting each
passed 1/1. The full portable gate set, all host module tests, the
byte-identical transcript gate, the freestanding build/image/inspection, and
coordination/MMU-debt gates also pass. Evidence is saved under
`artifacts/live-userspace-*`, `artifacts/live-tasks-*`,
`artifacts/live-timer-*`, `artifacts/live-exceptions-*`,
`artifacts/el0-sections-8215.txt`, and
`artifacts/verify-portable-8215.txt`.
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-userspace.sh
lines: 16-19
kind: symbol
symbol: GATE_LOG
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.93
  FTS rank: +1.43
  recent change: +0.50
===== CONTENT =====
GATE_LOG="artifacts/live-userspace-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-userspace.sh
lines: 23-28
kind: symbol
symbol: EXPECT
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.85
  FTS rank: +1.35
  recent change: +0.50
===== CONTENT =====
EXPECT="userspace: el0=1 svc=2 roundtrips=1 arg=2 result=2 rejected=0"

echo "=== verify-live-userspace: claim 8215 — EL0t + SVC round-trip + timer preemption, $BOOTS boot(s) ==="
zig version
swift --version 2>&1 | head -1
sw_vers
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-userspace.sh
lines: 31-41
kind: symbol
symbol: DIRTY
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.75
  FTS rank: +1.25
  recent change: +0.50
===== CONTENT =====
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

printf 'tasks\necho rx-el0-ok\n' > "$SCRIPT"
===== END SOURCE =====

===== BEGIN SOURCE =====
path: kernel/src/scheduler.zig
lines: 390-427
kind: symbol
symbol: scheduler: round-robin alternates and round-trips saved context
language: zig
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.70
  FTS rank: +1.20
  recent change: +0.50
===== CONTENT =====
test "scheduler: round-robin alternates and round-trips saved context" {
    _ = init();
    const worker_entry: u64 = 0x2000;
    _ = register_worker(worker_entry).?;
    start();
    // First switch: the shell is preempted at pc 0x1000; the worker is
    // restored to its synthetic frame.
    switch_context(0x1000, 0x1000, 0x5, 0xaaaa);
    try std.testing.expectEqual(@as(usize, 1), current);
    try std.testing.expectEqual(@as(u64, 1), switches);
    try std.testing.expectEqual(@as(u64, 1), tasks[0].saves);
    try std.testing.expectEqual(@as(u64, 0), tasks[0].resumes);
    try std.testing.expectEqual(@as(u64, 1), tasks[1].resumes);
    try std.testing.expectEqual(@as(u64, 0), tasks[1].saves);
    try std.testing.expectEqual(tasks[1].sp, pending_sp);
    try std.testing.expectEqual(worker_entry, pending_elr);
    try std.testing.expectEqual(spsr_el1h_irqs, pending_spsr);
    // Second switch: the worker is preempted; the shell is restored to its
    // exact saved context.
    switch_context(0x2000, 0x2000, 0x5, 0xbbbb);
    try std.testing.expectEqual(@as(usize, 0), current);
    try std.testing.expectEqual(@as(u64, 2), switches);
    try std.testing.expectEqual(@as(u64, 1), tasks[1].saves);
    try std.testing.expectEqual(@as(u64, 1), tasks[0].resumes);
    try std.testing.expectEqual(@as(u64, 0x1000), pending_sp);
    try std.testing.expectEqual(@as(u64, 0x1000), pending_elr);
    try std.testing.expectEqual(@as(u64, 0x5), pending_spsr);
    try std.testing.expectEqual(@as(u64, 0xaaaa), pending_sp_el0);
    // Third switch returns to the worker's saved context (the round-trip).
    switch_context(0x1000, 0x1001, 0x5, 0xaaaa);
    try std.testing.expectEqual(@as(usize, 1), current);
    try std.testing.expectEqual(@as(u64, 3), switches);
    try std.testing.expectEqual(@as(u64, 2), tasks[0].saves);
    try std.testing.expectEqual(@as(u64, 1), tasks[0].resumes);
    try std.testing.expectEqual(@as(u64, 1), tasks[1].saves);
    try std.testing.expectEqual(@as(u64, 2), tasks[1].resumes);
}
===== END SOURCE =====

===== BEGIN SOURCE =====
path: kernel/src/scheduler.zig
lines: 242-265
kind: symbol
symbol: tick
language: zig
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.59
  FTS rank: +1.09
  recent change: +0.50
===== CONTENT =====
pub fn tick() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (!scheduling_active()) return;
    var elr: u64 = 0;
    var spsr: u64 = 0;
    asm volatile ("mrs %[v], elr_el1"
        : [v] "=r" (elr),
    );
    asm volatile ("mrs %[v], spsr_el1"
        : [v] "=r" (spsr),
    );
    switch_context(exceptions.resume_frame, elr, spsr, exceptions.resume_sp_el0);
    exceptions.resume_frame = pending_sp;
    exceptions.resume_sp_el0 = pending_sp_el0;
    asm volatile ("msr elr_el1, %[v]"
        :
        : [v] "r" (pending_elr),
    );
    asm volatile ("msr spsr_el1, %[v]"
        :
        : [v] "r" (pending_spsr),
    );
    asm volatile ("isb");
}
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-ragshit-dogfood-prompt.md
lines: 58-63
kind: section
symbol: Definition of done
heading: Milestone three — ragshit dogfood pass (index, bundle, review) > Definition of done
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.56
  FTS rank: +1.06
  recent change: +0.50
===== CONTENT =====
## Definition of done

A fresh index, a complete milestone-three bundle under `artifacts/`, any
coverage/ranking fixes landed in `tools/ragshit/`, a dogfood review of the
syscall-ABI prompt doc with findings logged, `ragshit doctor` green, and
no code outside `tools/ragshit/` changed.
===== END SOURCE =====

===== BEGIN SOURCE =====
path: AGENTS.md
lines: 15-28
kind: section
symbol: Current milestone
heading: AGENTS.md — rules for working in this repository > Current milestone
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.55
  FTS rank: +1.05
  recent change: +0.50
===== CONTENT =====
## Current milestone

Milestones zero, one, two, and 1.5 are implemented (1.5 — the interactive
kernel monitor — closed and tagged `m1.5-interactive-monitor` on
2026-08-09; milestone two's VZ serial gate passes since 2026-08-08, claim
1517). The current stream is **milestone three's first cards**: the
physical page allocator is done (claims 3972/5162), GIC + timer interrupts
now deliver a real periodic PPI into the EL1 IRQ vector on VZ (claim 9187,
3/3 strict live gate), and the first tasks card — a tick-driven
round-robin scheduler between two kernel tasks (claim 5275, live gate
`tools/verify-live-tasks.sh`) — is done; userspace is a later card.
`docs/status.md` is the canonical, always-current answer to "where are we,
and what's next".
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-march-tracker-prompt.md
lines: 20-49
kind: section
symbol: Scope
heading: Milestone three — march tracker (`docs/march-m3.md`) and agent-split plan > Scope
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.54
  FTS rank: +1.04
  recent change: +0.50
===== CONTENT =====
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
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-march-tracker-prompt.md
lines: 1-19
kind: section
symbol: Milestone three — march tracker (`docs/march-m3.md`) and agent-split plan
heading: Milestone three — march tracker (`docs/march-m3.md`) and agent-split plan
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.51
  FTS rank: +1.01
  recent change: +0.50
===== CONTENT =====
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
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-runner-scripted-input-prompt.md
lines: 22-36
kind: section
symbol: Scope
heading: Milestone three — host runner scripted-input mode (OPTIONAL / deferrable) > Scope
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.50
  heading match: +1.00
  recent change: +0.50
===== CONTENT =====
## Scope

1. Add a `--script <file>` mode (or equivalent flag) to the Swift runner:
   read a keystroke fixture (plain text, one line per input burst or a
   simple delay grammar) and inject it into the guest serial input handle,
   teeing guest output live as `--console` does.
2. Keep the default `--console` behavior and the evidence path
   (`zig build run`) byte-compatible and unchanged.
3. Prove it with a deterministic fixture: boot the VM, run a short script
   (e.g., `help` → `version` → `echo scripted-ok`), and assert the
   replies in the teed log. This is the seed for future live gates like
   the syscall card's `tools/verify-live-svc.sh` (which may adopt it or
   keep its own harness — do not edit that script; it is the syscall
   card's file).
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-runner-scripted-input-prompt.md
lines: 37-45
kind: section
symbol: Do not
heading: Milestone three — host runner scripted-input mode (OPTIONAL / deferrable) > Do not
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.50
  heading match: +1.00
  recent change: +0.50
===== CONTENT =====
## Do not

- Touch `kernel/`, `tools/verify-*.sh`, or `docs/status.md` /
  `docs/gate-inventory.md` (active-stream files; the syscall card owns the
  live-svc gate).
- Change the evidence-path attachment semantics (nil-input file handle for
  `zig build run` must stay nil-input — claims 0003/6684).
- Claim any new hardware behavior; this is host tooling, class C/D at most.
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-runner-scripted-input-prompt.md
lines: 46-56
kind: section
symbol: Process (hard gate)
heading: Milestone three — host runner scripted-input mode (OPTIONAL / deferrable) > Process (hard gate)
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.50
  heading match: +1.00
  recent change: +0.50
===== CONTENT =====
## Process (hard gate)

1. Claim before you start (claim-id.sh, 🔄), append to your branch log.
2. Implement in `host/vm-runner/`; add host-side tests if the runner has
   any test scaffolding (keep them out of the kernel test suite).
3. Verify: `swift build --package-path host/vm-runner` (both default and
   the macOS-27 spike define used by CI), plus one manual/scripted VZ run
   with evidence saved under `artifacts/m3-runner-script-*`.
4. Append the log, flip the claim to ✅, refresh indexes, open a draft PR
   with `gh` (ADR 0003).
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-runner-scripted-input-prompt.md
lines: 57-63
kind: section
symbol: Definition of done
heading: Milestone three — host runner scripted-input mode (OPTIONAL / deferrable) > Definition of done
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.50
  heading match: +1.00
  recent change: +0.50
===== CONTENT =====
## Definition of done

A `--script` fixture mode that injects a deterministic input sequence and
tees the transcript, proven by a saved VZ run, with the evidence path and
`--console` unchanged. If the syscall card's live-gate runs are on the
same host at the same time, **defer this card** — the queue is long enough
without risking a flaky class-B gate.
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/logs/codex-el0-svc-task.md
lines: 1-21
kind: section
symbol: Log — `codex/el0-svc-task`
heading: Log — `codex/el0-svc-task`
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.43
  FTS rank: +0.93
  recent change: +0.50
===== CONTENT =====
# Log — `codex/el0-svc-task`

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-09** — *Codex*: claim 8215 filed at `3436676`; isolated worktree
  created so the concurrent PRs #55/#56 documentation reconciliation remains
  untouched. Scope is a minimal real EL0 task, SVC kernel boundary, focused
  host tests, and live VZ evidence; no process/address-space abstraction and no
  edits to `docs/status.md`, `docs/hardware-contract.md`, or `docs/roadmap.md`.
  · 🔄 in progress

- **2026-08-09** — *Codex*: claim 8215 completed. Added one page-isolated
  EL0t payload with dedicated EL0 text/stack permissions, per-task SP_EL0
  scheduling, a minimal x8/x0 SVC ABI, and a strict live VZ gate. Corrected
  the SPSR M=0x5 decode to EL1h and the vector-frame x0/x30 layout while
  extending exception return to carry the selected SP_EL0. Direct evidence:
  userspace gate PASS 3/3 with two sequenced SVCs; tasks, timer, and exception
  live regressions PASS 1/1 each; complete portable suite, byte-identical
  transcript, ELF section inspection, coordination, and MMU-debt gates PASS.
  The work deliberately leaves processes, loaders, separate address spaces,
  and the concurrent milestone documentation files untouched. · ✅ done
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/claims/6684-virtio-rx-live-transcript.md
lines: 9-63
kind: section
symbol: Notes
heading: Claim: M1.5 — virtio RX path + live-transcript gate (class B live-transcript-rx): host keystrokes reach the kernel end to end > Notes
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.32
  FTS rank: +0.32
  heading match: +1.00
===== CONTENT =====
## Notes

**Why this card:** the milestone-two console was polled TX-only (ADR 0004);
the shell loop's `readByte` was an [inferred] no-RX stub, so no host
keystroke could reach a live VM. With post-MMU transport access fixed
(claim 1517), the receive side is the last piece between the mock-level
monitor and a real interactive `dipshit>` session — and it unblocks the
class-B `live-transcript-rx` gate (assert the transcript in `vm-serial.log`
on a live VZ run).

**Guest RX design (virtio-console queue 0):**

- Queue 0 is the console receiveq (virtio-console spec: queue 0 = receive,
  queue 1 = transmit). Configure it in `virtio_pci_init` (pre-exit, where
  config-space access is deterministic) between queue 1 and DRIVER_OK:
  select 0, size 1 (power of two), one 256-byte BSS buffer descriptor with
  VIRTQ_DESC_F_WRITE, ring GPA registers written as 32-bit halves (claim
  0013 access-size quirk), queue_enable, read queue 0's notify offset, then
  supply the initial avail entry and kick queue 0 right after DRIVER_OK.
- Polled RX (`virtio_read_byte`): invalidate the used ring line, if the
  device returned the buffer (used.idx advanced) drain it into a bounded
  512-byte FIFO, re-supply the descriptor (clean + kick), pop one byte.
  Never blocks; never allocates.
- `M15Console.readByte`/`rx_wired` dispatch to the virtio RX path when the
  console is virtio (nvram-console builds keep the scripted session).
- The shell's WFE idle wait is replaced by a bounded nop delay for RX-wired
  mode: the device delivers input with no interrupt, so WFE would sleep
  forever and never re-poll.

**Host + gate:** runner gains `--script <file>` and `--script-expect
<substring>`: a non-interactive duplex mode that waits for the guest
terminal state in the serial log, forwards the scripted keystrokes into the
serial attachment, tees guest output to the log, and exits 0 iff the
expected transcript substring appears (timeout/early-stop → 1).
`tools/verify-live-transcript.sh` boots the production image and asserts
the live transcript (banner, `dipshit> help` echo, command output, echo
reply) in `vm-serial.log`.

**Verification (all observed 2026-08-08 on this Apple M4 / macOS 27 VZ host):**

- Class A: fmt, 50 unit tests, transcript gate (mock transcript still
  byte-identical), `zig build`, image, inspect, swift runner build,
  context, coordination, test-coordination (15/15), mmu-debt — all pass.
- Class B: `tools/verify-live-transcript.sh` **3/3 boots PASS** — the
  live session (`help`/`version`/`mem`/`echo rx-live-ok`) shows the
  takeover banner, echoed keystrokes at `dipshit>`, `available
  commands:`, `dipshit-kernel` version output, `mem: descriptors=…` map
  summary, and the `rx-live-ok` echo reply in `vm-serial.log`, with
  byte-identical 4421-byte transcripts per boot. `zig build run` (serial
  gate) still passes (TX unregressed); `verify-bad-handoff.sh`
  (`kernel_rc=0x2`), `verify-marker.sh` (`M2_TXST!`), nvram-console,
  host-console re-run green.
- KERNEL.BIN default build changed with this claim (the RX queue + FIFO
  state were added; TX path unchanged). The runner gained `--script` /
  `--script-expect` (non-interactive scripted-input mode).
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-userspace.sh
lines: 42-78
kind: symbol
symbol: run_one
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.31
  FTS rank: +0.81
  recent change: +0.50
===== CONTENT =====
run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-expect "$EXPECT" --timeout 60 \
        > "artifacts/live-userspace-run-$tag.txt" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-userspace-serial-$tag.log" || true

    local bytes=0 banner=0 tasks=0 user_row=0 worker=0 svc=0 echo_ok=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && banner=1
        grep -qF -- "tasks: enabled=1" artifacts/vm-serial.log && tasks=1
        grep -qE -- "user-el0 +saves=[0-9]+ resumes=[0-9]+ advances=0" artifacts/vm-serial.log && user_row=1
        grep -qE -- "tasks worker advances=[1-9][0-9]*" artifacts/vm-serial.log && worker=1
        grep -qF -- "$EXPECT" artifacts/vm-serial.log && svc=1
        grep -qF -- "rx-el0-ok" artifacts/vm-serial.log && echo_ok=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: rc=$rc serial-bytes=$bytes banner=$banner tasks=$tasks user-row=$user_row worker=$worker svc=$svc echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$tasks" = 1 ] && \
        [ "$user_row" = 1 ] && [ "$worker" = 1 ] && [ "$svc" = 1 ] && \
        [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-userspace gate (claim 8215) — EL0t/SVC/timer round-trip on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "expect: $EXPECT"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/status.md
lines: 29-42
kind: section
symbol: Current position
heading: DipshitOS living status, goals & changelog > Current position
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.20
  FTS rank: +0.70
  recent change: +0.50
===== CONTENT =====
## Current position

| Milestone | What it proved / is | Status |
|-----------|---------------------|--------|
| Zero — boot pipeline | A Zig AArch64 UEFI app on a FAT32 ESP boots under real firmware; output observed on host (`\BOOTED.TXT`) | ✅ done |
| One — kernel handoff | Separate freestanding `KERNEL.BIN` loaded, cache-maintained, jumped to, and returned (`\RC.TXT` = `kernel_rc=0x0`); ADR 0002 | ✅ done |
| Two — kernel proper | ExitBootServices, captured EFI map, identity TTBR0_EL1 tables, MMIO serial probe + polled TX console (ADR 0004) | ✅ **gates passed 2026-08-08** (claim 1517): bad-handoff failure gate passing since 2026-08-06, VZ serial gate now **passing** (post-MMU virtio TX fixed) |
| **1.5 — Interactive Kernel Monitor ("Dipshit Monitor")** | A live, interactive command monitor served by the kernel's serial console (the milestone-two terminal loop becomes its payload) | ✅ **done 2026-08-09** — all 7 hard gates pass; the last (filesystem, claim 3475) closed 2026-08-09 and upgraded to a real FAT32 storage driver (claim 6420); tagged `m1.5-interactive-monitor` |
| Three — allocator, interrupts, tasks | Physical allocator, GIC + timer, then tasks | 🚧 **active** — allocator done (claims 3972/5162); a real periodic timer PPI now reaches the EL1 IRQ vector on VZ (claim 9187, 3/3); **tasks are now real: the tick-driven round-robin scheduler landed 2026-08-09 (claim 5275)** — two kernel tasks (shell + worker) preempt at every timer tick, `tasks` command, host tests, and a live class-B gate (`tools/verify-live-tasks.sh`) proving both advance across ticks; userspace is a later card |

Resolved loose end: the milestone-one `KERNEL.TXT` corruption is **fixed**
(ADR 0002 — the loader now places image content at `base+0`; the write is
byte-perfect and gated by `zig build run`).
===== END SOURCE =====

===== BEGIN SOURCE =====
path: kernel/src/userspace.zig
lines: 1-23
kind: symbol
symbol: syscall_ping
language: zig
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.18
  FTS rank: +0.68
  recent change: +0.50
===== CONTENT =====
//! DipshitOS first EL0 execution boundary (claim 8215).
//!
//! This is deliberately smaller than a process subsystem: one statically
//! linked EL0t task, one static user stack, the existing TTBR0 identity map,
//! and one SVC operation. Only the page-aligned user text and stack ranges are
//! EL0-accessible; neighboring Normal RAM, kernel data, and Device mappings
//! remain privileged. Separate address spaces, loading, processes, and a broad
//! syscall ABI are later cards.
//!
//! The live proof is stronger than a one-way `eret`: the EL0 loop increments
//! x0, round-trips it through `svc #0`, receives the kernel's result in x0,
//! and invokes SVC again. Seeing the second valid call proves the first SVC
//! returned to EL0. Reporting is deferred to the shell idle loop because the
//! polled console is not reentrant in exception context.

const std = @import("std");
const builtin = @import("builtin");
const console = @import("console.zig");
const exceptions = @import("exceptions.zig");

const user_text_section = if (builtin.object_format == .elf) ".usertext" else "__TEXT,__usertext";

pub const syscall_ping: u64 = 0;
===== END SOURCE =====

===== BEGIN SOURCE =====
path: docs/m3-ragshit-dogfood-prompt.md
lines: 1-21
kind: section
symbol: Milestone three — ragshit dogfood pass (index, bundle, review)
heading: Milestone three — ragshit dogfood pass (index, bundle, review)
language: markdown
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.17
  FTS rank: +0.67
  recent change: +0.50
===== CONTENT =====
# Milestone three — ragshit dogfood pass (index, bundle, review)

Planning-first agent prompt for DipshitOS. Feed this file to the
implementing agent. A recurring tooling workstream (prior art: claims
9112, 4922, 0176, 3320, 0019): index the current tree with the local
context engine, emit a milestone-three review bundle, fix any coverage
truncation or ranking gaps found, and dogfood the bundle by reviewing the
new card docs for gaps against the canonical status.

- Branch: `agent/.../m3-ragshit-dogfood` (claim first via `docs/claims/` +
  a log entry in `docs/logs/`; merge per ADR 0003)
- Date: 2026-08-09
- Depends on: — (concurrent-safe: touches `tools/ragshit/` + `artifacts/`
  only; no kernel files, no VZ runs)
- Inputs (read first): `AGENTS.md`, `docs/status.md`, `docs/roadmap.md`,
  `tools/ragshit/README.md` (command set + ranking formula),
  the ragshit prior claims (9112/4922/0176/3320/0019) for the known gaps
  (e.g., 0176 = coverage truncation),
  `docs/m3-syscall-abi-prompt.md`, `docs/m3-march-tracker-prompt.md`,
  `docs/m3-runner-scripted-input-prompt.md`.
===== END SOURCE =====

===== BEGIN SOURCE =====
path: kernel/src/exceptions.zig
lines: 415-477
kind: symbol
symbol: exc_dispatch
language: zig
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 1.07
  FTS rank: +0.57
  recent change: +0.50
===== CONTENT =====
export fn exc_dispatch(
    frame: *VectorFrame,
    esr: u64,
    far: u64,
    elr: u64,
    spsr: u64,
    kind: u64,
) callconv(.c) Resume {
    handled_count_value += 1;
    resume_frame = @intFromPtr(frame);
    resume_sp_el0 = source_sp_el0(frame, spsr);
    // Claim 7948: taken IRQs route to the registered dispatcher (GIC ack
    // -> timer handle -> scheduler tick -> GIC eoi); the stub restores the
    // frame and erets. IRQs were masked until the whole chain was armed,
    // so a dispatcher that is present is always ready. Without one (host
    // tests, or the pre-GIC milestone), IRQs fall through to the report +
    // park path. Claim 5275: stage the interrupted task's frame pointer so
    // the scheduler can save it (and rewrite it to the next task's frame);
    // the stub's `mov sp, x0` restores from whatever frame is left staged.
    if (kind == kind_irq) {
        if (irq_dispatcher) |d| {
            d();
            return .{ .frame = resume_frame, .sp_el0 = resume_sp_el0 };
        }
    }
    if (is_svc64_from_el0(kind, esr, spsr)) {
        if (svc_dispatcher) |d| {
            const immediate: u16 = @truncate(esr & 0xffff);
            if (d(frame, immediate)) {
                return .{ .frame = @intFromPtr(frame), .sp_el0 = resume_sp_el0 };
            }
        }
    }
    const will_resume = should_resume(kind, resume_armed);
    var buf: [512]u8 = undefined;
    const report = format_report(
        &buf,
        kind,
        esr,
        far,
        elr,
        spsr,
        handled_count_value,
        frame_read(frame, 0),
        frame_read(frame, 30),
        will_resume,
    );
    if (report_writer) |w| w(report);
    if (will_resume) {
        resume_armed = false;
        resume_count_value += 1;
        // Skip the 32-bit faulting instruction (the test `udf`), so the
        // resumed code continues right after it instead of re-faulting.
        // Only ever reached while resume_armed was set by the test trigger.
        asm volatile ("msr elr_el1, %[v]"
            :
            : [v] "r" (elr + 4),
        );
        asm volatile ("isb");
        return .{ .frame = @intFromPtr(frame), .sp_el0 = resume_sp_el0 };
    }
    return .{ .frame = 0, .sp_el0 = resume_sp_el0 };
}
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-tasks.sh
lines: 1-54
kind: symbol
symbol: ROOT
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 0.87
  FTS rank: +0.37
  recent change: +0.50
===== CONTENT =====
#!/usr/bin/env bash
#
# verify-live-tasks.sh -- claim 5275 class-B gate: the tick-driven
# round-robin kernel task scheduler on real VZ hardware. The production
# image boots with the claim-9746 vectors, the claim-9187 GIC + CNTP timer
# (a real periodic PPI entering the EL1 IRQ vector), and the scheduler
# armed with three tasks: the EL1h shell/main task, an EL1h demo worker,
# and the claim-8215 EL0t task. This regression gate keeps proving its
# original shell+worker contract inside that larger round-robin pool.
#
# The gate proves BOTH tasks advance across ticks:
#   * the worker runs and bumps its advance counter — reported from the
#     shell idle loop as `tasks worker advances=N` (main-context console,
#     claim 9187 discipline; N >= 1 proves a worker quantum completed, and
#     the line only exists after a full worker quantum, the EL0 quantum,
#     and a shell idle loop, i.e. >= 3 real context switches);
#   * the shell survives repeated preemptions — it still executes the
#     scripted `tasks` + `echo` commands (echo reply `rx-tasks-ok`), so its
#     saved/restored context is intact. (The `tasks` command output is
#     captured inside the shell's FIRST quantum — the runner forwards
#     keystrokes ~0.5 s after the terminal state — so its switches/advances
#     fields are diagnostic only; the report line is the live proof.)
#
# Mechanism: the runner's non-interactive scripted-input mode (claim 6684,
# --script / --script-expect) forwards keystrokes into the serial
# attachment; guest output is teed to vm-serial.log; the runner exits 0
# iff the expected transcript appears. The success signal is the worker
# report line — it only appears after a full worker quantum, the EL0 quantum,
# and a shell idle loop, i.e. after at least three real context switches,
# so the runner cannot exit before both tasks have demonstrably run.
#
# Per boot this reports:
#   rc              the runner's exit code (0 iff the worker report appeared)
#   serial-bytes    vm-serial.log size
#   banner / interrupts / tasks-cmd / shell-row / worker-row / worker-adv /
#   echo / heartbeat  per-assertion flags
#
# Class B — Apple silicon + VZ only; boots a real VM. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-tasks.sh          # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-live-tasks.sh
#
# Evidence saved under artifacts/: live-tasks-gate.txt (full output),
# live-tasks-report.txt (per-boot detail), live-tasks-run-<NN>.txt (runner
# output), live-tasks-serial-<NN>.log (vm-serial.log copy),
# live-tasks-script.txt (the forwarded keystrokes).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
===== END SOURCE =====

===== BEGIN SOURCE =====
path: justfile
lines: 101-183
kind: window
language: plaintext
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 0.83
  FTS rank: +0.33
  recent change: +0.50
===== CONTENT =====
# Create the FAT32+GPT boot disk image (class A — zig build image)
image:
    zig build image

# Boot with the Swift Virtualization.framework runner (class B gate — the live serial takeover gate, claim 0002; PASSING since claim 1517; Apple silicon only)
run:
    zig build run

# Boot an interactive host serial console (class C — interactive/manual hardware gate; requires a human at the keyboard; Apple silicon only)
console:
    zig build console

# Inspect the EFI binary and disk image (class A — zig build inspect)
inspect:
    zig build inspect

# Regenerate artifacts/context.md (class A — zig build context)
context:
    zig build context

# Local Git-aware context engine — tools/ragshit (ragshit index/query/bundle/doctor ...)
ragshit *ARGS:
    python3 tools/ragshit/ragshit {{ARGS}}

# Verify the MMU takeover contract is intact (class A — ADR 0006 supersession + kernel T0SZ=16/TLBI comments; deterministic, no VM — claims 0022/1517)
verify-mmu-debt:
    bash tools/verify-mmu-debt.sh

# Verify the multiagent coordination surface (class A — claims/logs files + generated indexes)
verify-coordination:
    bash tools/verify-coordination.sh

# Test the coordination tooling itself (class A — escaped cells, deterministic claim IDs, structural validation)
test-coordination:
    bash tools/status/test-coordination.sh

# Regenerate the claim/log index tables from the files (developer tooling, not a gate — run after creating a claim or branch log)
refresh-indexes:
    bash tools/status/refresh-indexes.sh

# Verify the pre-exit failure path (class B — boots a VZ VM; Apple silicon only)
verify-bad-handoff:
    bash tools/verify-bad-handoff.sh

# Verify the live RX path + live dipshit> transcript (class B — boots a VZ VM; host scripted keystrokes reach the kernel end to end; claim 6684; Apple silicon only)
verify-live-transcript:
    bash tools/verify-live-transcript.sh

# Verify the live exception-vector gate (class B — boots a VZ VM; drives `fault`, asserts the [EXC] sync report + resume in vm-serial.log; claim 9746; Apple silicon only)
verify-live-exceptions:
    bash tools/verify-live-exceptions.sh

# Verify real timer IRQ delivery (class B — boots a VZ VM; drives `timer`, then requires five CNTP PPIs through the EL1 IRQ vector with irq=5/poll=0; claim 9187; Apple silicon only)
verify-live-timer:
    bash tools/verify-live-timer.sh

# Verify the live tick-driven task scheduler (class B — boots a VZ VM; proves the shell + worker both advance across real timer-tick context switches; claim 5275; Apple silicon only)
verify-live-tasks:
    bash tools/verify-live-tasks.sh

# Verify the first real EL0 task and SVC boundary (class B — two sequenced SVC entries prove return to EL0; timer preemption returns to the EL1h shell; claim 8215)
verify-live-userspace:
    bash tools/verify-live-userspace.sh

# Verify the live ESP file window (class B — boots VZ VMs; ls/cat from the pre-exit ESP snapshot + write persisted to EFI NVRAM and read back across a reboot; claim 3475, hard gate 5; Apple silicon only)
verify-live-fs:
    bash tools/verify-live-fs.sh

# Verify the live reboot/shutdown observation (class B — boots VZ VMs; a real EFI ResetSystem from a live dipshit> shell: reboot resets the machine, shutdown powers it off; claim 0527, hard gate 6; Apple silicon only)
verify-live-reboot:
    bash tools/verify-live-reboot.sh

# Verify the M1.5 host-side interactive serial plumbing (class B — boots VZ VMs; Apple silicon only)
verify-host-console:
    bash tools/verify-host-console.sh

# Git-aware change-impact reviewer context (developer tooling — ragshit impact)
impact *ARGS:
    python3 tools/ragshit/ragshit impact {{ARGS}}

# Deterministic budgeted reviewer packet (ragshit review)
review *ARGS:
    python3 tools/ragshit/ragshit review {{ARGS}}
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-custom-virtio.sh
lines: 1-67
kind: symbol
symbol: ROOT
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 0.80
  FTS rank: +0.30
  recent change: +0.50
===== CONTENT =====
#!/usr/bin/env bash
#
# verify-custom-virtio.sh -- claims 0828/4374/9492/9737/4837 class-B gate:
# the custom-virtio transport on the macOS 27 spike device (VID 0x1af4 /
# DID 0x1082, `zig build spike-virtio`, claim 5844). Requires the macOS 27
# SDK: the runner is built with -DSPIKE.
#
# What one boot proves (all through the reusable driver in
# kernel/src/virtio_custom.zig):
#
#   * claim 0828 (queue transport + used-ring IRQ): the host delegate
#     dequeues the exact payload, echoes it back into the guest's write
#     descriptor, returnToQueue advances the used ring, and a real SPI IRQ
#     (INTID 0x45 = SPI 69) enters the claim-9746 vector.
#   * claim 4374 (ring allocator + multi-queue): four CONCURRENT in-flight
#     exchanges on queue 0 (the allocator hands out four chains), then a
#     second batch that reallocates the EXACT same head indices
#     (`cvspike: q0 heads=... recycle=1`); queue 1 is armed and kicked
#     too (`guest notified queue 1`).
#   * claim 9492 (multi-descriptor payloads): a 12,340-byte payload across
#     three device-read descriptors; the host reassembles the spans
#     (`dequeued 12340 byte(s)`) and echoes the full payload back, and the
#     guest verifies it byte-for-byte (`cvspike: q0 big n=0x3034 echo=ok`).
#   * claim 9737 (feature negotiation depth): the guest reads the full
#     64-bit device-features word, accepts VIRTIO_F_ANY_LAYOUT (bit 27)
#     and VIRTIO_F_NOTIFICATION_DATA (bit 38) when offered, and reports
#     `cvspike: feat=0x... acc=0x... nd=<1|0> al=<1|0> notify=<32|16>bit`.
#     The negotiated behavior is exercised: 32-bit notification-datum
#     kicks when NOTIFICATION_DATA is on, and the big-payload chain posts
#     its write descriptor FIRST when ANY_LAYOUT is on.
#   * claim 4837 (guest log transport): three guest log lines ride queue 1
#     (`cvspike: q1 log="cvlog-N" ack="ACK:7"`), the host echoes each to
#     its stdout (`CUSTOM-VIRTIO-LOG: cvlog-N`) and replies ACK:<len>,
#     which the guest verifies (`cvspike: q1 ok=3`).
#
# Mechanism: the runner's scripted-input mode (claim 6684) forwards `pci`
# (proving the device is on the bus + the shell is alive) and an echo after
# the terminal state; the runner exits 0 iff the echo output
# ("cvspike-shell-ok") appears in the serial log — i.e. AFTER the script
# was actually forwarded. (The "cvspike: irq=" report prints before the
# script runs, so expecting it would exit the runner before pci/echo are
# ever sent.)
#
# Per boot this reports:
#   rc               the runner's exit code
#   serial-bytes     vm-serial.log size
#   host-driver-ok / host-notified-q0 / host-notified-q1 / host-dequeued /
#   host-big / host-logs / host-returned
#   guest-ready / guest-feat / guest-q0 / guest-recycle / guest-big /
#   guest-q0ok / guest-q1 / guest-irq / pci-device / shell-echo
#
# Class B — Apple silicon + VZ + macOS 27 SDK only; boots a real VM.
#
# Usage:
#   bash tools/verify-custom-virtio.sh          # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-custom-virtio.sh
#
# Evidence saved under artifacts/: live-cvspike-gate.txt (full output),
# live-cvspike-report.txt (per-boot detail), live-cvspike-run-<NN>.txt
# (runner output incl. the host CUSTOM-VIRTIO lines),
# live-cvspike-serial-<NN>.log (vm-serial.log copy), live-cvspike-script.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-exceptions.sh
lines: 1-39
kind: symbol
symbol: ROOT
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 0.52
  FTS rank: +0.52
===== CONTENT =====
#!/usr/bin/env bash
#
# verify-live-exceptions.sh -- claim 9746 class-B gate: live exception
# vectors. The production image boots on real VZ hardware with the VBAR_EL1
# vector table installed; host scripted keystrokes drive `dipshit> fault`,
# which deliberately triggers a synchronous exception (`udf`). The kernel's
# exception handler emits the `[EXC]` report (ESR/FAR/ELR/SPSR + x0/x30),
# skips the faulting instruction, and the shell resumes. The gate asserts
# the report and the resume in vm-serial.log, plus a follow-up command to
# prove the shell is still alive after the exception.
#
# Mechanism: the runner's non-interactive scripted-input mode (claim 6684,
# --script / --script-expect) forwards keystrokes into the serial
# attachment; guest output is teed to vm-serial.log; the runner exits 0 iff
# the expected reply appears.
#
# The script drives: help (live listing), fault (the exception), and echo
# (the runner's success signal). Per boot this reports:
#   rc              the runner's exit code (0 iff the expected reply appeared)
#   serial-bytes    vm-serial.log size
#   banner/help/fault-trigger/exc-sync/exc-ec/exc-resume/resumed/echo   flags
#
# Class B — Apple silicon + VZ only; boots a real VM. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-exceptions.sh          # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-live-exceptions.sh
#
# Evidence saved under artifacts/: live-exceptions-gate.txt (full output),
# live-exceptions-report.txt (per-boot detail), live-exceptions-run-<NN>.txt
# (runner output), live-exceptions-serial-<NN>.log (vm-serial.log copy),
# live-exceptions-script.txt (the forwarded keystrokes).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-transcript.sh
lines: 1-41
kind: symbol
symbol: ROOT
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 0.50
  FTS rank: +0.50
===== CONTENT =====
#!/usr/bin/env bash
#
# verify-live-transcript.sh -- claim 6684 class-B gate: live RX. Host
# scripted keystrokes reach the kernel end to end through the polled virtio
# receive queue (queue 0), and the exact `dipshit>` transcript lands in
# vm-serial.log on a real VZ run.
#
# Mechanism: the production image is booted with the runner's non-interactive
# scripted-input mode (--script / --script-expect, claim 6684): the runner
# waits for the guest's takeover terminal state, forwards the scripted
# keystrokes into the serial attachment (the guest's virtio RX buffer was
# supplied pre-exit), tees guest output to vm-serial.log, and exits 0 iff the
# expected transcript substring appears.
#
# The script drives real commands: help, version, mem, and an echo whose
# reply ("rx-live-ok") is the runner's success signal. The gate then asserts
# the live transcript in vm-serial.log: the takeover banner, the `dipshit>`
# prompt with the echoed keystrokes, the command outputs, and the echo reply.
#
# Per boot this reports:
#   rc              the runner's exit code (0 iff the expected reply appeared)
#   serial-bytes    vm-serial.log size
#   banner / prompt / help / version / mem / echo   per-assertion flags
#
# Class B — Apple silicon + VZ only; boots a real VM. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-transcript.sh          # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-live-transcript.sh
#
# Evidence saved under artifacts/: live-transcript-gate.txt (full output),
# live-transcript-report.txt (per-boot detail), live-transcript-run-<NN>.txt
# (runner output), live-transcript-serial-<NN>.log (vm-serial.log copy),
# live-transcript-script.txt (the forwarded keystrokes).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
===== END SOURCE =====

===== BEGIN SOURCE =====
path: tools/verify-live-timer.sh
lines: 1-45
kind: symbol
symbol: ROOT
language: shell
commit: 6b1b8cd2195fc543da149536074e9088542a7d57
score: 0.46
  FTS rank: +0.46
===== CONTENT =====
#!/usr/bin/env bash
#
# verify-live-timer.sh -- claim 9187 class-B gate: real timer IRQ delivery
# on real VZ hardware. The production image boots with the claim-9746
# vectors installed and the GIC + CNTP timer programmed (discovered
# pre-exit from the MADT/GTDT); IRQs are unmasked after the chain is
# armed. The timer's EL1 physical-timer comparator fires once a second.
#
# Claim 9187 corrected claim 7948's guest driver: the old MADT structure
# IDs were shifted, SGI/PPI MMIO targeted the redistributor RD frame instead
# of its +0x10000 SGI frame, and ICFGR wrote the RES0 bit rather than the
# trigger bit. This gate distinguishes the IRQ path from the diagnostic
# poll counter. It requires the first-IRQ report and the fifth
# heartbeat to say all five ticks came through the IRQ vector with zero
# poll-consumed ticks.
#
# Mechanism: the runner's non-interactive scripted-input mode (claim 6684,
# --script / --script-expect) forwards keystrokes into the serial
# attachment; guest output is teed to vm-serial.log; the runner exits 0 iff
# the expected transcript appears. The script sends `timer` + `echo` at
# once; the runner keeps polling the log until the fifth IRQ heartbeat
# appears (about 5 s after boot, so --timeout must cover it).
#
# Per boot this reports:
#   rc              the runner's exit code (0 iff the heartbeat appeared)
#   serial-bytes    vm-serial.log size
#   banner / interrupts-armed / timer-cmd-armed / echo / irq / heartbeat
#
# Class B — Apple silicon + VZ only; boots a real VM. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-timer.sh          # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-live-timer.sh
#
# Evidence saved under artifacts/: live-timer-gate.txt (full output),
# live-timer-report.txt (per-boot detail), live-timer-run-<NN>.txt (runner
# output), live-timer-serial-<NN>.log (vm-serial.log copy),
# live-timer-script.txt (the forwarded keystrokes).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
===== END SOURCE =====

### Omitted

omitted 'docs/logs/agent-buffy-macos27-custom-virtio-spike.md:1-16' (score 0.57) to fit the 120000-character budget
omitted 'docs/claims/0527-m15-live-reboot-shutdown.md:9-48' (score 0.43) to fit the 120000-character budget
omitted 'tools/verify-live-reboot.sh:1-63' (score 0.33) to fit the 120000-character budget
omitted 'docs/claims/0527-m15-live-reboot-shutdown.md:1-8' (score 0.33) to fit the 120000-character budget

## Missing or unresolved evidence

- kernel/src/monitor.zig:205 [root cause] /// base (claim 0015 root cause: the first vtable dispatch crashed; the
- docs/m3-syscall-abi-prompt.md:48 [root cause] (ADR 0005 / claim 0015 root cause): a const function-pointer table holds
- kernel/src/main.zig:518 [[inferred]] // reads are [inferred] and gated on the VZ serial gate (claim 0002,
- docs/claims/6684-virtio-rx-live-transcript.md:12 [[inferred]] the shell loop's `readByte` was an [inferred] no-RX stub, so no host
