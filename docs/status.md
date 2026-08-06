# DipshitOS — project status (living document)

> This file is the canonical answer to "what is the state of the project right
> now?". **Update it whenever a gate changes.** Other docs
> (`README.md`, `docs/roadmap.md`, `docs/testing.md`, `docs/architecture.md`)
> point here instead of maintaining their own status prose, so they cannot
> drift apart. Last updated: 2026-08-06.

## One-paragraph summary

Milestones zero and one are complete and verified (boot pipeline proof; separate
kernel image with a clean handoff, including the resolved `KERNEL.TXT`
corruption, ADR 0002). Milestone two — the kernel proper (ADR 0004) — is
**implemented and builds cleanly, but its two hardware/behavior gates are not
passed**:

- The **VZ serial gate** (kernel banner in `vm-serial.log`) has no observed
  evidence yet.
- The **bad-handoff failure gate** (kernel must return non-zero to the loader
  pre-exit, producing `RC.TXT`) is **currently failing**: the kernel does not
  return to the loader at all. This was re-verified 2026-08-06.

All build gates pass on this host (Apple M4, macOS 27.0, Zig 0.16.0, Swift
6.2.3).

## Milestone state

| Milestone | State | Evidence |
|-----------|-------|----------|
| 0 — boot pipeline proof | ✅ complete | `BOOTED.TXT`, `artifacts/m1-*.txt` |
| 1 — separate kernel image + handoff | ✅ complete | `artifacts/m1-*`, `KERNEL.TXT` gated byte-perfect (ADR 0002) |
| 2 — kernel proper (ExitBootServices, MMU, serial) | 🟡 implemented, gates not passed | build gates green; VZ + failure gates unpassed (below) |
| 3+ — GIC/timer, allocator, ... | ⛔ not started | sketches only in `docs/roadmap.md` |

Branch: `agent/buffy/m2-kernel-proper` (targets `main` via PR). Guest is
freestanding Zig; host launcher is Swift + Virtualization.framework. There is
**no QEMU path**.

## Gate status (verified 2026-08-06)

| Gate | Command | Result | Last evidence |
|------|---------|--------|---------------|
| Format | `zig fmt --check boot/src/main.zig kernel/src/main.zig build.zig` | ✅ pass | re-run 2026-08-06 |
| Guest build | `zig build` | ✅ pass | re-run 2026-08-06 |
| Disk image | `zig build image` | ✅ pass | re-run 2026-08-06 |
| Binary + image inspect | `zig build inspect` | ✅ pass | re-run 2026-08-06 |
| Swift runner build | `swift build --package-path host/vm-runner` | ✅ pass | re-run 2026-08-06 |
| Context snapshot | `zig build context` | ✅ pass | re-run 2026-08-06 |
| **VZ serial gate** | `zig build run` | ❌ **not passed** | `vm-serial.log` empty (last run 2026-08-06 00:05) |
| **Bad-handoff failure gate** | `bash tools/verify-bad-handoff.sh` | ❌ **failing** | no `RC.TXT` (re-run 2026-08-06 07:16) |

### What we directly observe about the two failing gates

From the bad-handoff run (re-verified 2026-08-06), fresh from
`artifacts/bad-handoff.img`:

- `BOOTED.TXT` — written by the loader: **observed** (loader executed under
  firmware).
- `LOADER.TXT` — written by the loader: **observed** —
  `base=0x7e4df000 size=0x823e8 entry_offset=0x18`, and
  `ram_first8=0xaa0103eaaa0003e9`, which decodes to `mov x9, x0; mov x10, x1` —
  the first two instructions of the kernel's naked shim. The image content is
  at `base+0` and the jump lands on the shim as designed.
- `RC.TXT` — **absent**: the kernel never returned to the loader, so the
  pre-exit failure path did not complete. `vm-serial.log` is empty (expected
  for `ConOut`; the runner's `terminal=true` is only the no-marker default).

**Hypothesis (inferred, not yet proven):** the kernel dies early — before it can
either return (bad-handoff path) or reach serial init (good path). Both gates
may share one root cause, most likely in the new naked entry shim / stack
switch (`kernel/src/main.zig` `_start`) or in handoff validation. Proving this
is **next step 1**. Nothing in this paragraph is an observed claim about the
kernel's behavior.

## Next steps (ordered; each has a gate)

1. **Root-cause the failing bad-handoff gate.** The cheapest reproducible
   failure: the kernel must return a non-zero `u64` to the loader on a bad
   magic, and it does not. Inspect the shim (disassembly via
   `zig build inspect` / `llvm-objdump`), confirm the stack switch and
   `bl kernel_main` linkage, then add a minimal pre-return diagnostic if
   needed. **Prompt:** `docs/m2-bad-handoff-fix-prompt.md`.
   **Gate:** `bash tools/verify-bad-handoff.sh` exits 0 and
   `RC.TXT` shows `kernel_rc=0x2`. Save output under `artifacts/m2-badhandoff-fix-*.txt`.
2. **Re-run the VZ serial gate** once step 1 lands: `zig build run` on
   Apple M4 / macOS 27, saving `artifacts/m2-vz-run*.txt` and the complete
   `vm-serial.log`. **Prompt:** `docs/m2-vz-serial-gate-prompt.md`.
   **Gate:** exact banner `DipshitOS kernel has seized control.`,
   `memory-map descriptors=0x...`, and `kernel terminal state` in the log.
3. **If the serial probe finds no usable device on VZ**, implement the ADR 0004
   D4 fallback: dump the kernel's fixed physical memory marker (`takeover_marker`,
   `0x4d325f...` family) from the host runner. The marker exists in BSS; the
   runner currently has no dump path. **Gate:** saved host-side dump matching
   `M2_SERIA`/`M2_TABLE` markers.
4. **Milestone-two closeout** (only after 2/3): flip matching
   `[inferred] → [observed]` entries in `docs/hardware-contract.md`; update
   `README.md`, `docs/testing.md`, `docs/architecture.md`, and this file to
   milestone-two-complete; archive the milestone's evidence.
5. **Milestone three kickoff**: write ADR 0005 choosing the first real
   subsystem — GIC + interrupts + timer (the GIC is already an
   `[inferred]` contract entry) or the allocator + memory-map walk — and add
   process hardening: a single `just verify` that runs the full
   `docs/testing.md` sequence, and wire the bad-handoff verification into CI.

## Housekeeping conventions (keep the project nice as it evolves)

- **`docs/status.md` is the single source of truth for status.** Update it the
  moment a gate passes, fails, or a milestone completes. Do not write new
  status prose into `README.md`/`roadmap.md`/`testing.md` — link here instead.
- **Evidence lives under `artifacts/`** (gitignored, except `.gitkeep`). Every
  gate claim in this file names its evidence file and date. No evidence, no
  "observed".
- **Facts vs. inference:** this file marks unproven hypotheses as
  `(inferred)`. Flip hardware-contract tags only with matching saved logs
  (AGENTS.md evidence rules).
- **Branch hygiene:** feature work happens on `agent/...` branches with PRs
  against `main`; branch protection is documented in
  `docs/branch-protection.md` (ADR 0003).
- **OS junk:** `.DS_Store` files are gitignored; delete them when you notice
  them (`find . -name .DS_Store -not -path './.git/*' -delete`).

## Recent history (short)

- 2026-08-05: ADR 0004 accepted; milestone-two design (`m2-kernel-proper-design.md`)
  self-reviewed; implementation landed (`f6e1b6e`).
- 2026-08-05: milestone-one `KERNEL.TXT` corruption closed (ADR 0002, content at
  `base+0` fix); `zig build run` gates on its content.
- 2026-08-06: build gates re-verified; bad-handoff gate confirmed failing;
  this file created.

## Related docs

- [`roadmap.md`](roadmap.md) — milestone planning (the "where we're going").
- [`testing.md`](testing.md) — the verification sequence and evidence policy.
- [`hardware-contract.md`](hardware-contract.md) — hardware assumptions, `[observed]`/`[inferred]`.
- [`architecture.md`](architecture.md) — components and data flow.
- [`decisions/`](decisions/) — ADRs 0001–0004 (binding design records).
- [`../AGENTS.md`](../AGENTS.md) — project rules (now including the status-doc rule).
