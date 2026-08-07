# DipshitOS living status, goals & changelog

> This file is the project's **living status tracker** and its **multiagent
> coordination surface**: where we are, what we are trying to build next, how
> far along each step is, **who currently claims which piece of work**, and
> pointers to the append-only per-branch changelog. Claims and logs are
> sharded (see [Multiagent coordination](#multiagent-coordination)) so
> parallel agents never collide on one file. Update it as work lands —
> flip the checkboxes, fill in the notes, and **append** to your branch's
> log under `docs/logs/`.
> Claims stay honest per `AGENTS.md`: **observed** (log evidence under
> `artifacts/`) versus **inferred** (reasoning/docs only).

> **Premise check (2026-08-06):** this tracker was first frozen against the
> milestone-one-era `main`. On the same day, PRs #6/#7 merged the
> **milestone-two kernel proper** (ADR 0004), which changed the premises
> below: the kernel now calls `ExitBootServices`, owns an identity-map MMU,
> drives a polled TX-only MMIO serial console, and never returns. This file
> was refreshed accordingly — the plan's shape is kept, its factual anchors
> are reconciled with the merged state. PR #10 later unified this tracker
> with the milestone-two gate evidence and added the multiagent changelog
> (now sharded per branch under [docs/logs/](logs/README.md); see the
> [Changelog](#changelog-append-only-per-branch)).

## Current position

| Milestone | What it proved / is | Status |
|-----------|---------------------|--------|
| Zero — boot pipeline | A Zig AArch64 UEFI app on a FAT32 ESP boots under real firmware; output observed on host (`\BOOTED.TXT`) | ✅ done |
| One — kernel handoff | Separate freestanding `KERNEL.BIN` loaded, cache-maintained, jumped to, and returned (`\RC.TXT` = `kernel_rc=0x0`); ADR 0002 | ✅ done |
| Two — kernel proper | ExitBootServices, captured EFI map, identity TTBR0_EL1 tables, MMIO serial probe + polled TX console (ADR 0004) | 🔄 **attempted; gates not passed** (see [Gate status](#gate-status)); bad-handoff failure gate **passing since 2026-08-06**, VZ serial gate still blocked |
| **1.5 — Interactive Kernel Monitor ("Dipshit Monitor")** | A live, interactive command monitor served by the kernel's serial console (the milestone-two terminal loop becomes its payload) | 🎯 **current** |
| Three+ — allocator, interrupts, tasks | Physical allocator, GIC + timer, then processes | ⏳ deferred (roadmap) |

Resolved loose end: the milestone-one `KERNEL.TXT` corruption is **fixed**
(ADR 0002 — the loader now places image content at `base+0`; the write is
byte-perfect and gated by `zig build run`).

## Gate status

Every milestone-two claim below is backed by evidence re-verified
2026-08-06; files under `artifacts/`.

| Gate | Command | Result | Last evidence |
|------|---------|--------|---------------|
| Format | `zig fmt --check boot/src/main.zig kernel/src/main.zig build.zig` | ✅ pass | re-run 2026-08-06 |
| Guest build | `zig build` | ✅ pass | re-run 2026-08-06 |
| Disk image | `zig build image` | ✅ pass | re-run 2026-08-06 |
| Binary + image inspect | `zig build inspect` | ✅ pass | re-run 2026-08-06 |
| Swift runner build | `swift build --package-path host/vm-runner` | ✅ pass | re-run 2026-08-06 |
| Context snapshot | `zig build context` | ✅ pass | re-run 2026-08-06 |
| **VZ serial gate** | `zig build run` | ❌ **not passed** | `vm-serial.log` still 0 bytes (re-run 2026-08-06 21:19, `artifacts/m2-vz-run-20260806.txt`) |
| **Bad-handoff failure gate** | `bash tools/verify-bad-handoff.sh` | ✅ **pass** | `artifacts/m2-badhandoff-fix-after.txt`: `RC.TXT` → `kernel_rc=0x0000000000000002`, gate exits 0 (first observed 2026-08-06, fixed shim) |

### What we directly observe about the two failing gates

From the bad-handoff run before the fix (re-verified 2026-08-06), fresh from
`artifacts/bad-handoff.img`:

- `BOOTED.TXT` — written by the loader: **observed** (loader executed under
  firmware).
- `LOADER.TXT` — written by the loader: **observed** —
  `base=0x7e4df000 size=0x823e8 entry_offset=0x18`, and
  `ram_first8=0xaa0103eaaa0003e9`, which decodes to `mov x9, x0; mov x10, x1` —
  the first two instructions of the kernel's naked shim. The image content is
  at `base+0` and the jump lands on the shim as designed.
- `RC.TXT` — **absent** before the fix: the kernel never returned to the
  loader. `vm-serial.log` is empty (expected for `ConOut`; the runner's
  `terminal=true` is only the no-marker default).

**Bad-handoff root cause (now observed, fixed 2026-08-06):** the naked
`_start` shim's `bl kernel_main` overwrote the link register with the shim's
own return address (disassembly of the current kernel ELF: `bl 0x3c` at
shim offset `0x30`, so LR = `0x34`). The shim's final `ret` therefore looped
`0x34 → 0x38 → 0x34` forever instead of returning to the loader, so the
pre-exit `return bad_handoff` could never reach the loader and `RC.TXT` was
never written. Fix: save the loader's `x30` in `x20` (callee-saved under
AAPCS64, preserved by `kernel_main`) before the `bl` and restore it before
`ret` — two instructions in `kernel/src/main.zig` `_start`. After the fix:
`RC.TXT` = `kernel_rc=0x0000000000000002` and `verify-bad-handoff.sh` exits 0
(`artifacts/m2-badhandoff-fix-after.txt`).

The **VZ serial gate is a separate, still-open question**: with the fix, the
bad-handoff VM provably returns through the shim, but every good-path run
still produces no serial output and the kernel never returns. Re-run
2026-08-06 21:19 (claim 0002, `artifacts/m2-vz-run-20260806.txt`):
`vm-serial.log` **0 bytes** after a 30 s run; loader evidence intact
(`BOOTED.TXT` exact content, `LOADER.TXT` `base=0x7e4df000 size=0x823e8
entry_offset=0x18`, `ram_first8=0xaa0103eaaa0003e9` = the shim's first two
instructions `mov x9,x0; mov x10,x1` — the loader→shim jump is proven);
`RC.TXT` absent (good path, expected — D6). So the kernel dies **after
shim entry and before its first post-exit `uart_puts`**. The two
hypotheses: the probe finds no usable MMIO serial device on VZ
(`layout=none` → `M2_SERIA` BSS-marker halt, which produces exactly zero
output, consistent with the log), or an early post-exit crash (map build /
MMU install / probe read). The ADR 0004 D4 fixed-memory-marker fallback
(host-side dump of `takeover_marker`) discriminates them; the bad-handoff
fix already removed the shim/LR suspect (M1.5 march step 8,
`docs/march-m15.md`).

## Milestone 1.5 — the call

Do **not** add more kernel-proper plumbing before making the machine
interactive. The milestone-two kernel already owns the machine: it ends UEFI
Boot Services, installs its own page tables, probes the MMIO serial
candidates (PL011/16550/virtio-MMIO), and drives a polled **TX-only**
console (ADR 0004 — "no interrupts, no FIFO/DMA, no RX path") before
entering a terminal WFE loop. That console is exactly enough to serve an
interactive monitor — the monitor is simply the loop's payload. No new
firmware dependencies, no allocator, no interrupts, no storage drivers.

One immediate blocker, on both ends of the wire: the kernel console has **no
RX path at all** (ADR 0004), and until 2026-08-06 the VM runner's serial
attachment sent guest output to a file with a `nil` host-to-guest input
handle (`VZFileHandleSerialPortAttachment(fileHandleForReading: nil, ...)`
in `host/vm-runner/Sources/VMRunner/main.swift`). The M1.5 host-plumbing
slice (steps 4–7, landed 2026-08-06) added a `--console` mode that wires a
real stdin-backed input handle and tees guest output live; the evidence
path (`zig build run`) keeps the `nil`-input attachment, unchanged. Until
keystrokes can actually be read by the guest, the monitor is output-only.

### Definition of done — the target screen

```text
DIPSHITOS 0.1
AArch64 firmware-assisted kernel monitor
256 MiB detected
Type 'help' before touching anything expensive.

dipshit> help
about      explain this questionable system
cat        print a file from the ESP
clear      clean up the crime scene
echo       repeat your regrettable decisions
elephant   operational mascot diagnostics
handoff    display boot-to-kernel ABI data
ls         list files on the ESP
mem        summarize the EFI memory map
reboot     restart the machine
shutdown   request power-off
version    display build information
write      write text to a file

dipshit>
```

### Hard gates (acceptance criteria)

- [ ] `zig build`, `zig build image`, and the existing regression checks still pass. *(The bad-handoff regression gate was **failing**; its root cause (shim LR clobber) was fixed 2026-08-06 — the gate now passes, see [Gate status](#gate-status).)*
- [ ] `zig build console` reaches `dipshit>`.
- [ ] Host keystrokes reach the kernel (RX path closed end to end).
- [ ] At least ten commands work.
- [ ] `ls`, `cat`, and `write` persist through reboot — **needs re-scoping**: post-exit there is no ESP root / Simple File System (x3 carries handoff v2), so these need a pre-exit file window or a storage driver; see march step 15 (`docs/march-m15.md`).
- [ ] A scripted console session passes automatically (asserting in `vm-serial.log`).
- [ ] The VM can reboot or shut down from the shell.
- [ ] No allocator, MMU replacement, interrupts, scheduler, or userspace is falsely claimed.

## The march tracker (per milestone)

> **Moved 2026-08-06:** the per-step tracker and the best-agent-split
> tables used to live in this file; agents marking steps collided here
> with gate and milestone-status edits. They now live in the per-milestone
> tracker [`docs/march-m15.md`](march-m15.md) — update a step's row there,
> never here. This file holds milestone-level facts only (position, gates,
> hard gates) plus pointers.

## What comes immediately afterward

Once the monitor is stable, the command layer is portable; the plumbing is
already milestone-two. What remains after M1.5:

1. A real RX path (virtio-console or discovered MMIO UART RX) — the
   kernel's console is TX-only today (ADR 0004).
2. A physical page allocator over the captured EFI map.
3. Exception vectors, GIC + timer interrupts — then, and only then, talk
   about tasks or userspace.

That keeps a useful CLI on the milestone-two kernel without faking a
"complete OS", while the shell architecture survives the console driver
change.

## Assumptions & gaps in this plan (checked against the merged `main`)

- **ADR 0004 now exists and matches the plan's citation.** It is the
  milestone-two kernel-proper ADR; its console is polled TX-only with
  explicitly "no RX path" — exactly the constraint the plan warned about
  ("VZ may expose only a virtio console rather than a simple MMIO UART").
  The M2 kernel probes PL011/16550/virtio-MMIO candidates and selects one;
  which one wins on VZ is still **unobserved** (the VZ run gate is blocked).
- **Runner serial input was `nil`; it is now a real handle in `--console`
  mode.** The evidence path (`zig build run`) still uses
  `VZFileHandleSerialPortAttachment(fileHandleForReading: nil, ...)`
  unchanged; the M1.5 `--console` mode (landed 2026-08-06) wires a stdin
  pipe as `fileHandleForReading` and forwards host bytes into it
  (evidence: `artifacts/m15-host-console-gate.txt`).
- **Output observation: evidence path still file-polls; console mode
  streams.** `zig build run` still re-reads the serial log
  (`Data(contentsOf:)`) on a timer — unchanged, evidence semantics intact.
  The M1.5 `--console` mode uses a pipe-based duplex attachment and tees
  guest output live to the terminal and the log (no full-log reloads).
- **"256 MiB detected"** matches the runner's configured
  `memorySize = 256 * 1024 * 1024` (unchanged on merged `main`); `mem`
  should derive it from the captured map, not hardcode it.
- **The kernel is post-Boot-Services and never returns.** `ExitBootServices`
  is called (ADR 0004), `x3` is the handoff v2 struct (not the ESP root),
  and the kernel ends in a WFE loop. Consequences baked into the steps
  above: no UEFI Serial I/O protocol probe, no `GetMemoryMap`, no Simple
  File System — the monitor is the terminal loop's payload.
- **VZ firmware quirks still apply:** `ConOut` is not routed to the virtio
  serial port or framebuffer, and the milestone-two VZ run produced no
  serial output or `RC.TXT` (MMIO/MMU assumptions stay `[inferred]`).
  Transcript tests must gate on bytes the kernel actually sent via `uart_puts`.

## Multiagent coordination

This repo is developed by multiple agents and humans, sometimes on the same
day (e.g. PR #8's M1.5 tracker and PR #10's gate evidence landed within
hours of each other and collided; PR #12/#13 collided again on the same
changelog section). The rules below make that safe. They are **binding**
(mirrored in `AGENTS.md`).

### Rules

1. **Claim before you start.** Any non-trivial work gets a claim file in
   [`docs/claims/`](claims/README.md) and a log entry in
   [`docs/logs/`](logs/README.md) *before* code is written. Unclaimed work
   is fair game; claimed work is not.
2. **One editor per file at a time.** If two agents need the same file, the
   second waits, or merges through the integration branch — never both edit
   `kernel/src/main.zig` (or this file's tracked sections) simultaneously.
3. **Append-only logs, one per branch.** The changelog is split by branch
   under `docs/logs/<branch>.md` so parallel appends cannot collide.
   Append-only: never rewrite or delete an entry. Corrections are *new*
   entries that reference the old one.
4. **Update on completion (and on blockers).** Flip your claim file's
   status and append a log entry when done; append one when blocked so the
   next agent doesn't repeat the attempt.
5. **Own your evidence.** Every entry cites `artifacts/` files. No
   observed claim without a saved log.
6. **Doc edits go through this file.** Status prose lives here; other docs
   link to it. If you must touch `README.md`/`roadmap.md`/`testing.md`,
   prefer pointer-level changes and put the substance here.
7. **Never hand-edit a generated index.** The claim and log index tables
   in `docs/claims/README.md` / `docs/logs/README.md` are **generated**
   from the claim/log files by `tools/status/refresh-indexes.sh` — create
   your file, run the script, done. `tools/verify-coordination.sh`
   (`just verify-coordination`, also CI) fails if the indexes drift from
   the files, so a stale hand-edit cannot slip through a merge.

### Active claims

> **How to claim:** copy `docs/claims/TEMPLATE.md` to
> `docs/claims/<NNNN>-<slug>.md`, fill it in, set Status to `🔄 <branch>`
> **before** starting work, then run
> `bash tools/status/refresh-indexes.sh` — the claim and log index tables
> are **generated from the files**, so claiming never edits a shared
> table and never edits this file. Flip your claim file to `✅` (evidence)
> or `⛔` (note why) on completion and re-run the script. Unclaimed
> (`⬜`) claims are fair game; `🔄`/`✅` claims are not. The **canonical
> index with status is [`docs/claims/README.md`](claims/README.md)**;
> this file holds no claims table, so parallel claims never touch the
> same lines here.

## Changelog (append-only, per branch)

> **Moved 2026-08-06:** the changelog used to live in this file; every
> agent appended here and parallel work collided (PR #8/#10, then
> PR #12/#13). It is now **sharded by branch** under `docs/logs/` — each
> branch owns its own append-only log, so cross-branch merges never touch
> the same lines. All entries — including the final two stragglers,
> migrated verbatim to `docs/logs/agent-buffy-m15-commands.md` on
> 2026-08-06 — live in the per-branch logs; **this file holds no changelog
> entries**, so there is nothing here for parallel agents to collide on.
> See the [log index](logs/README.md) for the format and each branch's
> file.

## Immediate gate work (prerequisites for M1.5)

Ordered; each has a prompt doc and a gate. **Status lives in the claim
files** (canonical index: [`docs/claims/README.md`](claims/README.md)) —
this section is pointer-level only, so a gate passing never needs an edit
here.

1. **Root-cause the failing bad-handoff gate** — `docs/m2-bad-handoff-fix-prompt.md`.
   The kernel must return `0x2` to the loader on a bad magic; it does not.
   This unblocks M1.5 hard gate 1 and possibly the serial gate too.
   **Gate:** `bash tools/verify-bad-handoff.sh` exits 0 with
   `RC.TXT` → `kernel_rc=0x2`; good path unregressed.
   **Status:** see [`0001-bad-handoff-gate`](claims/0001-bad-handoff-gate.md)
   — ✅ fixed 2026-08-06 (root cause: shim LR clobber; evidence in the
   claim and `docs/logs/agent-buffy-m2-badhandoff-fix.md`). The serial gate
   (item 2) no longer shares that suspect.
2. **Run the VZ serial/MMU gate** — `docs/m2-vz-serial-gate-prompt.md`
   (M1.5 march step 8's "confirm the serial console", `docs/march-m15.md`).
   **Gate:** exact banner `DipshitOS kernel has seized control.`,
   `memory-map descriptors=0x...`, and `kernel terminal state` in
   `vm-serial.log`; then flip matching `[inferred] → [observed]` entries in
   `docs/hardware-contract.md`.
   **Status:** see [`0002-vz-serial-gate`](claims/0002-vz-serial-gate.md) — ⛔ blocked (re-run 2026-08-06 21:19: still zero serial bytes; kernel dies before its first post-exit print — see claim and `artifacts/m2-vz-run-20260806.txt`).
3. **If no usable serial device exists on VZ**, implement the ADR 0004 D4
   fixed-memory-marker fallback (host-side dump of the kernel's BSS
   `takeover_marker`). **Gate:** saved host-side dump matching the `M2_*`
   markers. **Status:** no claim yet — claim it (see
   [`docs/claims/README.md`](claims/README.md)) before starting.

## Housekeeping conventions (keep the project nice as it evolves)

- **This file is the single source of truth for status and coordination.**
  Update the moment a gate passes, fails, or a milestone completes; claim
  work before starting (claim file in `docs/claims/`); append to your
  branch's log under `docs/logs/`; regenerate the indexes with
  `bash tools/status/refresh-indexes.sh` after creating either. Run
  `bash tools/verify-coordination.sh` before opening a PR.
- **Evidence lives under `artifacts/`** (gitignored, except `.gitkeep`).
  Every gate claim names its evidence file and date. No evidence, no
  "observed".
- **Facts vs. inference:** hypotheses are marked `(inferred)`; hardware
  tags flip only with matching saved logs (AGENTS.md evidence rules).
- **Branch hygiene:** feature work on `agent/...` branches, PRs against
  `main` (ADR 0003, `docs/branch-protection.md`); M1.5 work merges through
  the integration branch.
- **OS junk:** `.DS_Store` files are gitignored; delete them when noticed
  (`find . -name .DS_Store -not -path './.git/*' -delete`).

## Related docs

- [`roadmap.md`](roadmap.md) — milestone planning (the "where we're going").
- [`march-m15.md`](march-m15.md) — the M1.5 per-step tracker and best-agent split (one file per milestone).
- [`testing.md`](testing.md) — the verification sequence and evidence policy.
- [`logs/README.md`](logs/README.md) — per-branch append-only changelog index (the sharded changelog).
- [`claims/README.md`](claims/README.md) — per-claim files index (the sharded claims table, generated).
- [`../tools/status/`](../tools/status/) — index generator (`refresh-indexes.sh`) and the coordination gate (`verify-coordination.sh`).
- [`hardware-contract.md`](hardware-contract.md) — hardware assumptions, `[observed]`/`[inferred]`.
- [`architecture.md`](architecture.md) — components and data flow.
- [`m2-bad-handoff-fix-prompt.md`](m2-bad-handoff-fix-prompt.md) — prompt: fix the failing failure-path gate (now passing; root cause was the shim LR clobber).
- [`m2-vz-serial-gate-prompt.md`](m2-vz-serial-gate-prompt.md) — prompt: run the VZ serial/MMU gate.
- [`m15-host-plumbing-prompt.md`](m15-host-plumbing-prompt.md) — prompt (agent A): duplex serial attachment, teeing, terminal safety, `zig build console`.
- [`m15-commands-prompt.md`](m15-commands-prompt.md) — prompt (agent C): command registry, identity/memory/utility/control commands, personality (mock-console based).
- [`decisions/`](decisions/) — ADRs 0001–0004 (binding design records).
- [`../AGENTS.md`](../AGENTS.md) — project rules (now including the multiagent coordination rules).
