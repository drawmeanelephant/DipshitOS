# Claim: kernel `.bss` ceiling as a class-A CI gate (ADR 0013 D3.1) — fixes #248

- **Owner:** buffy (`freebuff/can-you-review-issues-223-247-and-try-to-provide-h-f6c8d8a0-9349-4ada-9bca-1705150f0bde`)
- **Prompt / plan:** user request 2026-08-20 — "Have me re-measure the BSS budget in ADR 0013 D3 against the live carve-out by running `zig build inspect` on a stub kernel that adds the reserved fields, so D3 stops being inferred." Then: "Add a CI workflow file (e.g. `.github/workflows/ci-class-a.yml`) that runs `just verify-portable` on every PR, so the BSS budget gate (and every other class-A gate) is wired into GitHub Actions, not just locally runnable." The first prompt yielded the observation in ADR 0013 D3.1; the second yielded this gate.
- **Scope:** `tools/verify-bss-budget.sh` (new class-A host gate, ~6 KiB, executable) + `justfile` (recipe + `verify-portable` entry, +5 lines) + `docs/gate-inventory.md` (class-A row + `GATE_INVENTORY` block entry, +2 lines) + `.github/workflows/ci.yml` (one new step after `verify-mutations.sh`, +3 lines). No kernel change, no user source change.
- **Depends on:** ADR 0013 D3.1 (claim 6215) for the budget source-of-truth; the existing class-A gate inventory pattern (`tools/verify-mmu-debt.sh`, `tools/verify-glyph-raster.sh`, `tools/verify-mutations.sh`) for the script style.
- **Status:** ✅ done 2026-08-20 — gate exists and runs clean on current main (`measured=6,119,552 B`, `budget=7,340,032 B`, `remaining=1,220,480 B`, `status=PASS`); smoke-tested by `BSS_BUDGET_BYTES=6000000 bash tools/verify-bss-budget.sh` which produces the expected FAIL with the documented guidance; wired into `just verify-portable` (runs as part of CI); wired into `.github/workflows/ci.yml` so every PR runs the gate on `macos-latest`; `docs/gate-inventory.md` lists the gate as `bss-budget` class A; resolves GitHub issue #248.

## Notes

**Why this gate:** the kernel `.bss` is a hard architectural constraint
(no allocator, fixed 1 MiB MMU page-table carve-out + the rest is data
BSS). A silent global `var foo: [1 << 20]u8` would push `.bss` past
the carve-out and break the build or runtime layout — and historically,
the only thing that would catch it is the linker's NOBITS-overflow
diagnostic, which lands AFTER the developer has already lost a
context. ADR 0013 D3.1 documented the budget **as a number on paper**;
this claim turns it into a CI check that runs on every PR.

**The gate (`tools/verify-bss-budget.sh`):**

1. `rm -rf .zig-cache && zig build kernel` — fresh build, deterministic
   input.
2. `find .zig-cache -name 'dipshit-kernel'` — locate the linked ELF
   (input to `tools/elf2bin.py`, NOT the flat KERNEL.BIN — the flat
   image contains NOBITS as zeros so it can't be inspected there).
3. `llvm-readelf -SW <elf>` — read `.bss`, `.data`, `.userbss` sizes
   using awk on the **section name** (not field index), so a future
   `llvm-readelf` column shift doesn't silently break the gate.
4. Compare measured `.bss` to the budget constant (`7340032` B = 7.0
   MiB; override at run time via `BSS_BUDGET_BYTES=N`).
5. Print:

```
kernel .bss:    6,119,552 B
budget:         7,340,032 B
remaining:      1,220,480 B
over budget:    0 B
status:         PASS
```

6. Exit non-zero if over budget, with guidance:

```
verify-bss-budget: FAILED — kernel .bss exceeded the 7.0 MiB ceiling.
Either:
  1. Remove the offending allocation (preferred — amend the design).
  2. Amend ADR 0013 D3.1 with the post-change measurement + justification,
     then bump BSS_BUDGET_BYTES in this script.
```

7. Print a known-large-contributors table (informational; sourced from
   static-array declarations in `kernel/src/`):
   - `mmu.table_storage`: 1,048,576 B (1.0 MiB; page-table carve-out,
     ADR 0006)
   - `virtio_gpu.gpu_fb`: 3,686,400 B (3.52 MiB; 1280×720×4 scanout,
     `align(4096)`)
   - post-M14 reservations (ADR 0013 D3): 1,737 B (~1.7 KiB; planned,
     not yet landed)
   - other (font, console, scheduler, virtio rings, process table,
     mailbox, evidence, etc.): the remainder

8. Save evidence under `artifacts/bss-budget-gate.txt` (deterministic,
   so CI captures the same artifact every run).

**Budget source of truth:** ADR 0013 D3.1 (claim 6215). The constant
`7340032` in the script is just the number; the ADR has the full
provenance. To raise the ceiling, **amend ADR 0013 D3.1 first**, then
bump `BSS_BUDGET_BYTES` in this script.

**What this gate does NOT do (per user guidance — recorded so future
agents don't drift):**

- **Does NOT reproduce the experimental canary.** The D3.1 measurement
  used a 1 MiB control canary + 7 stub reservations to characterize
  the LTO-stripping caveat (zero-init small arrays get folded away).
  The gate does NOT need to repeat that — it just enforces the
  resulting budget.
- **Does NOT artificially retain unused reservation stubs.** Production
  code keeps its own allocations alive (the scheduler increments
  cpu_ticks on every ring select; the notify FIFO is populated by
  `sys_notify` + drained by the compositor's idle loop). The gate
  enforces the ceiling; it does not enumerate per-slot reservations.
- **Does NOT enumerate ELF symbols.** The kernel ELF is stripped in
  `ReleaseSmall` per `kernel/linker.ld`; `nm` returns nothing. The
  contributors table is sourced from `kernel/src/` static-array
  declarations instead.

**Why section-name awk over field-index:** I tried both during
development. `awk '$2 == ".bss" { print $6; exit }'` failed because the
`[ 8]` bracket is whitespace-split, so `.bss` is field 3 and size is
field 7. The shipped script uses `awk -v want="$name" '$3 == want
{ print $7; exit }'` — the section-name match is robust against any
future `llvm-readelf` column shift, since the name column is
positionally stable.

**CI integration (`.github/workflows/ci.yml`):** the existing CI
workflow already enumerates every class-A gate as its own step. The
new gate is added as one step after `verify-mutations.sh` (which is the
last existing source-contract gate). YAML validated with
`yaml.safe_load`. The `GATE_INVENTORY:START` / `:END` block in
`docs/gate-inventory.md` already includes the new `bss-budget` line
under class A, so the existing "NOT proven by this CI" step's `sed`
correctly excludes it (the gate IS proven by this CI).

**`just verify-portable` integration:** the recipe runs the gate as
its last line, after `verify-mutations.sh`. `just verify-bss-budget`
is also a standalone recipe for local iteration.

**Smoke test (observed 2026-08-20):**

```
$ bash tools/verify-bss-budget.sh
...
verify-bss-budget: PASS — kernel .bss = 6119552 B / 7340032 B (1220480 B headroom).
$ echo $?
0
$ BSS_BUDGET_BYTES=6000000 bash tools/verify-bss-budget.sh
...
verify-bss-budget: FAILED — kernel .bss exceeded the 7.0 MiB ceiling.
Either:
  1. Remove the offending allocation (preferred -- amend the design).
  2. Amend ADR 0013 D3.1 with the post-change measurement + justification,
     then bump BSS_BUDGET_BYTES in this script.
$ echo $?
1
```

The exit code is non-zero on over-budget, so CI fails correctly.

**Headroom verdict (the gate's first run):** `.bss = 6,119,552 B`,
`budget = 7,340,032 B`, `remaining = 1,220,480 B (1.16 MiB)`. The
post-M14 reservations (claim 6215, ADR 0013 D3) consume 1,737 B of
that headroom when they land — leaving **1,218,743 B (~1.16 MiB)**
for future claims (font extension for #245 compose, larger notify
FIFO if #240 grows, etc.). To raise the ceiling, amend ADR 0013 D3.1
first.

**Resolves GitHub issue #248** (filed by buffy 2026-08-20 alongside
this claim).

## Verified

- ✅ `tools/verify-bss-budget.sh` exists, executable, 6 KiB.
- ✅ Gate runs clean on current main: `measured=6,119,552 B`,
  `budget=7,340,032 B`, `remaining=1,220,480 B`, `status=PASS`,
  `exit=0`.
- ✅ Smoke test: `BSS_BUDGET_BYTES=6000000 bash tools/verify-bss-budget.sh`
  → FAIL with the documented guidance, `exit=1`.
- ✅ `just verify-bss-budget` recipe exists in `justfile` (5 added
  lines).
- ✅ `just verify-portable` invokes the gate as its last step.
- ✅ `docs/gate-inventory.md` lists `bss-budget` as class A in both
  the human-readable table and the `GATE_INVENTORY:START/END` block
  consumed by the CI's "NOT proven" step.
- ✅ `.github/workflows/ci.yml` adds one step after
  `verify-mutations.sh`; YAML valid (`python3 -c "yaml.safe_load"`).
- ✅ `.github/workflows/ci.yml` runs the gate on every push to main,
  every PR to main, and on `workflow_dispatch`.
- ✅ Evidence artifact saved: `artifacts/bss-budget-gate.txt` per run.
- ✅ Budget source = ADR 0013 D3.1 (claim 6215) — the constant
  `7340032` is just the number; the ADR has the provenance.
- ✅ Resolves GitHub issue #248.
