# Review packet

Git range: `HEAD~5..HEAD`
Base: `HEAD~5` (`fbc0e146095b`)
Head: `HEAD` (`fff37a5e6af8`)
Index HEAD: `fff37a5e6af8`
Budget: 40000 chars
Actual size: 39879 chars

## Coverage summary

- changed_files: 23 / 41 (56%)
- changed_symbols: 40 / 40 (100%)
- decision_docs: 7 / 31 (22%)
- high_risk_files: 15 / 23 (65%)
- related_tests: 0 / 0 (100%)
- relevant_docs: 19 / 52 (36%)
- stale_warnings: 0 / 4 (0%)

## Highest-risk changes

1. `README.md` -- score 100.0 (critical) -- 35 lines, 5 symbols -- base=3, lines=10, references=9, symbols=12
2. `docs/claims/0594-verify-gate-classification.md` -- score 94.1 (critical) -- 74 lines, 2 symbols -- base=3, doc_touched=4, lines=10, references=9, symbols=6
3. `docs/claims/3109-stale-doc-cleanup.md` -- score 94.1 (critical) -- 31 lines, 2 symbols -- base=3, doc_touched=4, lines=10, references=9, symbols=6
4. `docs/claims/8592-status-preflight.md` -- score 93.6 (critical) -- 29 lines, 2 symbols -- base=3, doc_touched=4, lines=9.81, references=9, symbols=6
5. `docs/claims/3320-ragshit-dogfood-hardening.md` -- score 90.9 (critical) -- 21 lines, 2 symbols -- base=3, doc_touched=4, lines=8.92, references=9, symbols=6
6. `build.zig` -- score 89.4 (critical) -- 12 lines, 1 symbols -- base=3, critical_path=5, interface=3, lines=7.4, references=9, symbols=3
7. `docs/claims/9112-ragshit-review.md` -- score 85.8 (critical) -- 11 lines, 2 symbols -- base=3, doc_touched=4, lines=7.17, references=9, symbols=6
8. `docs/testing.md` -- score 83.1 (critical) -- 53 lines, 4 symbols -- base=3, lines=10, references=4.75, symbols=12, test_file=-1.5

## Selected context

### README.md:1-1
reason: changed-symbol
covers: changed_file:README.md, changed_symbol:DipshitOS, high_risk:README.md, symbol_range:README.md:1-52
score: 15.00
cost: 348 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: DipshitOS

```markdown
#…
... [truncated 50 line(s) omitted -- retained 1 of 51 line(s)]
```

### README.md:53-53
reason: changed-symbol
covers: changed_file:README.md, changed_symbol:The guest, high_risk:README.md, symbol_range:README.md:53-73
score: 15.00
cost: 351 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: The guest

```markdown
#…
... [truncated 19 line(s) omitted -- retained 1 of 20 line(s)]
```

### README.md:160-160
reason: changed-symbol
covers: changed_file:README.md, changed_symbol:Verification results (observed on this development host), high_risk:README.md, symbol_range:README.md:160-195
score: 15.00
cost: 449 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Verification results (observed on this development host)

```markdown
#…
... [truncated 34 line(s) omitted -- retained 1 of 35 line(s)]
```

### README.md:196-196
reason: changed-symbol
covers: changed_file:README.md, changed_symbol:Observed behavior, high_risk:README.md, symbol_range:README.md:196-217
score: 15.00
cost: 371 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Observed behavior

```markdown
#…
... [truncated 20 line(s) omitted -- retained 1 of 21 line(s)]
```

### README.md:224-224
reason: changed-symbol
covers: changed_file:README.md, changed_symbol:Next steps, high_risk:README.md, symbol_range:README.md:224-250
score: 15.00
cost: 357 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Next steps

```markdown
#…
... [truncated 26 line(s) omitted -- retained 1 of 27 line(s)]
```

### docs/claims/0594-verify-gate-classification.md:1-13
reason: changed-symbol
covers: changed_file:docs/claims/0594-verify-gate-classification.md, changed_symbol:Claim: Verification gate classification — portable/build CI vs Apple-VZ hardware gates, high_risk:docs/claims/0594-verify-gate-classification.md, symbol_range:docs/claims/0594-verify-gate-classification.md:1-13
score: 14.71
cost: 1372 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Claim: Verification gate classification — portable/build CI vs Apple-VZ hardware gates

```markdown
# Claim: Verification gate classification — portable/build CI vs Apple-VZ hardware gates

- **Owner:** buffy (`freebuff/pull-latest-dipshitos-main-ebe15999-a14a-4066-9551-00deb3d2323a`)
- **Prompt / plan:** inline — see Notes
- **Scope:** docs + command naming/wiring only. New `docs/gate-inventory.md`
  (canonical A/B/C/D classification with machine-readable records),
  `justfile` aggregates (`verify-portable`, `verify-vz`, `alias verify`),
  CI step labels + explicit "not proven by CI" step, `build.zig` step-help
  annotations, `docs/testing.md` classification section. NO kernel/host code
  changes, NO edit to `docs/status.md`.
- **Depends on:** —
- **Status:** ✅ done 2026-08-08 — classification + inventory + aggregates landed; full class-A set green, coordination gate green
```

### docs/claims/3109-stale-doc-cleanup.md:1-10
reason: changed-symbol
covers: changed_file:docs/claims/3109-stale-doc-cleanup.md, changed_symbol:Claim: Stale-doc cleanup — replace old blocker snapshots with pointers to docs/status.md, high_risk:docs/claims/3109-stale-doc-cleanup.md, symbol_range:docs/claims/3109-stale-doc-cleanup.md:1-10
score: 14.71
cost: 1321 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Claim: Stale-doc cleanup — replace old blocker snapshots with pointers to docs/status.md

```markdown
# Claim: Stale-doc cleanup — replace old blocker snapshots with pointers to docs/status.md

- **Owner:** buffy (`freebuff/stale-doc-cleanup`)
- **Prompt / plan:** inline — see Notes
- **Scope:** docs only (README, roadmap, architecture, testing, hardware-contract,
  march-m15, plus claims/logs as needed for the before/after report). NO code
  changes, NO edit to `docs/status.md`.
- **Depends on:** hardware findings already on `main` (claims 0009/0010/0013/0015/0017/0018/0020/0021)
- **Status:** ✅ done 2026-08-08 — stale blocker snapshots removed/corrected across README, roadmap, architecture, testing, hardware-contract, march-m15; before/after stale-phrase report in `artifacts/stale-doc-report.txt` (26 → 0 hits); link check clean; `docs/status.md` untouched
```

### docs/claims/3109-stale-doc-cleanup.md:11-31
reason: changed-symbol
covers: changed_file:docs/claims/3109-stale-doc-cleanup.md, changed_symbol:Notes, high_risk:docs/claims/3109-stale-doc-cleanup.md, symbol_range:docs/claims/3109-stale-doc-cleanup.md:11-31
score: 14.71
cost: 1492 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Notes

```markdown
## Notes

`docs/status.md` is the canonical, always-current status. Several other docs
accumulated snapshots of old blocker descriptions ("device discovery is
next", "no usable serial device in declared MMIO windows" as the whole
blocker, pre-claim-0010 M2 death-site descriptions, old M1.5 progress
percentages, "monitor not implemented", "machine controls fake", step-20
language that reads as milestone-closed). Goal: reduce stale duplication —
classify each non-status document's content:

1. timeless architecture/design/history → keep;
2. current gate status → replace with a short pointer to `docs/status.md`;
3. historical result → retain only if clearly labeled with date/context;
4. stale or contradictory statement → remove or correct.

Do NOT turn README/architecture/roadmap/testing into mirrors of status.md.
Prefer sentences like "Current VZ gate state: see docs/status.md."

Deliverable: grep/link-based stale-phrase check before/after, saved as a
report under `docs/` or `artifacts/` (gitignored) — the before/after diff is
the evidence. No milestone-status duplication added anywhere.
```

### docs/claims/8592-status-preflight.md:1-1
reason: changed-symbol
covers: changed_file:docs/claims/8592-status-preflight.md, changed_symbol:Claim: Final pre-status review — status-ready preflight report (artifacts/status-preflight.md), high_risk:docs/claims/8592-status-preflight.md, symbol_range:docs/claims/8592-status-preflight.md:1-16
score: 14.68
cost: 626 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Claim: Final pre-status review — status-ready preflight report (artifacts/status-preflight.md)

```markdown
#…
... [truncated 14 line(s) omitted -- retained 1 of 15 line(s)]
```

### docs/claims/3320-ragshit-dogfood-hardening.md:1-1
reason: changed-symbol
covers: changed_file:docs/claims/3320-ragshit-dogfood-hardening.md, changed_symbol:Claim: Ragshit review dogfood-hardening — honest accounting, coverage, stale filter, shell importance, high_risk:docs/claims/3320-ragshit-dogfood-hardening.md, symbol_range:docs/claims/3320-ragshit-dogfood-hardening.md:1-8
score: 14.54
cost: 673 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Claim: Ragshit review dogfood-hardening — honest accounting, coverage, stale filter, shell importance

```markdown
#…
... [truncated 6 line(s) omitted -- retained 1 of 7 line(s)]
```

### build.zig:1-1
reason: changed-symbol
covers: changed_file:build.zig, changed_symbol:build, high_risk:build.zig, symbol_range:build.zig:1-237
score: 14.47
cost: 343 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: build

```zig
/…
... [truncated 236 line(s) omitted -- retained 1 of 237 line(s)]
```

### docs/claims/9112-ragshit-review.md:1-4
reason: changed-symbol
covers: changed_file:docs/claims/9112-ragshit-review.md, changed_symbol:Claim: Ragshit `review` — deterministic budgeted reviewer context packet, high_risk:docs/claims/9112-ragshit-review.md, symbol_range:docs/claims/9112-ragshit-review.md:1-8
score: 14.29
cost: 954 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Claim: Ragshit `review` — deterministic budgeted reviewer context packet

```markdown
# Claim: Ragshit `review` — deterministic budgeted reviewer context packet

- **Owner:** buffy (`freebuff/ragshit-review`)
- **Prompt / plan:** task prompt 2026-08-08 — `ragshit review <repo> <git-range> --budget-chars` with budgeted selection, coverage model, redundancy control, mandatory content, truncation, JSON schema, tests, baseline, dogfood; plan in `artifacts/review-plan.md`
... [truncated 3 line(s) omitted -- retained 4 of 7 line(s)]
```

### docs/testing.md:1-7
reason: changed-symbol
covers: changed_file:docs/testing.md, changed_symbol:DipshitOS testing, high_risk:docs/testing.md, symbol_range:docs/testing.md:1-7
score: 14.15
cost: 609 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: DipshitOS testing

```markdown
# DipshitOS testing

> For the current state of each verification gate (pass/fail/blocked), see
> [`docs/status.md`](status.md). This file is the sequence and policy. The
> canonical A/B/C/D classification of every verification command is
> [`docs/gate-inventory.md`](gate-inventory.md).
```

### docs/testing.md:8-23
reason: changed-symbol
covers: changed_file:docs/testing.md, changed_symbol:Verification classes, high_risk:docs/testing.md, symbol_range:docs/testing.md:8-23
score: 14.15
cost: 1081 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Verification classes

```markdown
## Verification classes

Every verification command belongs to exactly one class (canonical inventory:
[`docs/gate-inventory.md`](gate-inventory.md)):

- **A — portable / build CI.** Deterministic, no Apple silicon, no VZ VM.
  This is the set GitHub CI proves. A green CI badge means exactly these
  passed — nothing more.
- **B — Apple-silicon Virtualization.framework hardware gate.** Boots a real
  VZ VM on Apple silicon. GitHub-hosted CI does **not** run these and cannot
  prove them; run `just verify-vz` on a development host.
- **C — interactive / manual hardware gate.** Requires a human at the
  keyboard (`zig build console`).
- **D — diagnostic experiment.** Answers a question (claims
  0017/0018/0020/0021); **not an acceptance gate**.
```

### docs/testing.md:34-34
reason: changed-symbol
covers: changed_file:docs/testing.md, changed_symbol:Verification sequence, high_risk:docs/testing.md, symbol_range:docs/testing.md:34-128
score: 14.15
cost: 400 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Verification sequence

```markdown
#…
... [truncated 93 line(s) omitted -- retained 1 of 94 line(s)]
```

### docs/testing.md:159-159
reason: changed-symbol
covers: changed_file:docs/testing.md, changed_symbol:Results log (as verified on the development host), high_risk:docs/testing.md, symbol_range:docs/testing.md:159-212
score: 14.15
cost: 459 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Results log (as verified on the development host)

```markdown
#…
... [truncated 53 line(s) omitted -- retained 1 of 54 line(s)]
```

### .github/workflows/ci.yml:1-13
reason: changed-symbol
covers: changed_file:.github/workflows/ci.yml, changed_symbol:name, high_risk:.github/workflows/ci.yml, symbol_range:.github/workflows/ci.yml:1-13
score: 14.03
cost: 1027 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: name

```yaml
# CI proves ONLY the portable/build gate set — class A in
# docs/gate-inventory.md: formatting, unit tests, transcript mock test,
# guest/image builds, inspect, Swift runner build, context generation, and
# the coordination gates. It does NOT and cannot run the Apple-silicon
# Virtualization.framework hardware gates (class B: bad-handoff, marker,
# NVRAM console, host-console PTY, live serial takeover, live transcript/RX),
# the interactive class-C console, or the class-D diagnostics. GitHub-hosted
# runners do not prove VZ hardware behavior — a green CI badge means "the
# portable gates passed", nothing more. Run `just verify-vz` on an Apple
# silicon host for the VZ gates.

name: CI
```

### .github/workflows/ci.yml:21-21
reason: changed-symbol
covers: changed_file:.github/workflows/ci.yml, changed_symbol:jobs, high_risk:.github/workflows/ci.yml, symbol_range:.github/workflows/ci.yml:21-86
score: 14.03
cost: 401 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: jobs

```yaml
j…
... [truncated 65 line(s) omitted -- retained 1 of 66 line(s)]
```

### docs/gate-inventory.md:1-10
reason: changed-symbol
covers: changed_file:docs/gate-inventory.md, changed_symbol:DipshitOS verification gate inventory, high_risk:docs/gate-inventory.md, symbol_range:docs/gate-inventory.md:1-10
score: 13.67
cost: 893 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: DipshitOS verification gate inventory

```markdown
# DipshitOS verification gate inventory

> Canonical classification of every verification command. **A green GitHub CI
> badge proves class A only** — it says nothing about the Apple-silicon
> Virtualization.framework hardware gates (class B), the interactive gates
> (class C), or the diagnostics (class D). Run the class-B set with
> `just verify-vz` on a real Apple silicon host. Per-gate pass/fail status
> lives in [`docs/status.md`](status.md); this file is the classification,
> not the status.
```

### docs/gate-inventory.md:11-26
reason: changed-symbol
covers: changed_file:docs/gate-inventory.md, changed_symbol:Classes, high_risk:docs/gate-inventory.md, symbol_range:docs/gate-inventory.md:11-26
score: 13.67
cost: 1161 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Classes

```markdown
## Classes

- **A — portable / build CI.** Deterministic, no Apple silicon, no VZ VM.
  Runs in GitHub CI (`.github/workflows/ci.yml`) and as `just verify-portable`
  (`just verify` is a legacy alias). A green CI badge means exactly these
  passed and nothing else.
- **B — Apple-silicon Virtualization.framework hardware gate.** Boots a real
  VZ VM on Apple silicon. GitHub-hosted CI does **not** run these and cannot
  prove them; run `just verify-vz` on a development host. Evidence lives
  under `artifacts/` and status in `docs/status.md`.
- **C — interactive / manual hardware gate.** Requires a human at the
  keyboard. Not automatable, not in CI.
- **D — diagnostic experiment.** Answers a question (claims 0017/0018/0020/
  0021); **not an acceptance gate**. Passing a diagnostic proves nothing
  about the milestone.
```

### docs/gate-inventory.md:27-27
reason: changed-symbol
covers: changed_file:docs/gate-inventory.md, changed_symbol:Gate table, high_risk:docs/gate-inventory.md, symbol_range:docs/gate-inventory.md:27-69
score: 13.67
cost: 405 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Gate table

```markdown
#…
... [truncated 41 line(s) omitted -- retained 1 of 42 line(s)]
```

### docs/gate-inventory.md:70-70
reason: changed-symbol
covers: changed_file:docs/gate-inventory.md, changed_symbol:Machine-readable records, high_risk:docs/gate-inventory.md, symbol_range:docs/gate-inventory.md:70-102
score: 13.67
cost: 434 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Machine-readable records

```markdown
#…
... [truncated 32 line(s) omitted -- retained 1 of 33 line(s)]
```

### docs/roadmap.md:62-62
reason: changed-symbol
covers: changed_file:docs/roadmap.md, changed_symbol:Milestone two — the kernel proper (implemented; VZ serial gate not passed), high_risk:docs/roadmap.md, symbol_range:docs/roadmap.md:62-88
score: 13.62
cost: 505 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Milestone two — the kernel proper (implemented; VZ serial gate not passed)

```markdown
#…
... [truncated 25 line(s) omitted -- retained 1 of 26 line(s)]
```

### docs/roadmap.md:159-173
reason: changed-symbol
covers: changed_file:docs/roadmap.md, changed_symbol:Milestone-two evidence status, high_risk:docs/roadmap.md, symbol_range:docs/roadmap.md:159-173
score: 13.62
cost: 1225 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Milestone-two evidence status

```markdown
### Milestone-two evidence status

Every VZ run so far observed an empty `vm-serial.log`. The **NVRAM marker
ladder** (ADR 0004 D4, claims 0009/0010, `artifacts/m2-mmu-takeover-gate.txt`)
is the working evidence channel: the MMU takeover is observed to complete
on VZ (ladder reaches `M2_MMUP!`), and claim 0013 observed the actual
console — a modern virtio-pci device (`VID=0x1af4 DID=0x1043`) outside the
declared windows (which it decoded as Apple's efivars store + an internal
debug UART). Post-exit access to the virtio transport hangs on VZ (claims
0013/0020), which is the serial gate's remaining blocker; the NVRAM console
channel (claim 0015) carries post-exit console bytes in the meantime. The
declared-window and virtio-pci findings are `[observed]` in
`docs/hardware-contract.md`; the device register layout stays `[inferred]`
until a real console is driven.
```

### docs/roadmap.md:174-174
reason: changed-symbol
covers: changed_file:docs/roadmap.md, changed_symbol:Milestone 1.5 — interactive kernel monitor (current), high_risk:docs/roadmap.md, symbol_range:docs/roadmap.md:174-211
score: 13.62
cost: 465 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Milestone 1.5 — interactive kernel monitor (current)

```markdown
#…
... [truncated 36 line(s) omitted -- retained 1 of 37 line(s)]
```

### docs/roadmap.md:212-228
reason: changed-symbol
covers: changed_file:docs/roadmap.md, changed_symbol:Later milestones (sketches only, not commitments), high_risk:docs/roadmap.md, symbol_range:docs/roadmap.md:212-228
score: 13.62
cost: 1377 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Later milestones (sketches only, not commitments)

```markdown
## Later milestones (sketches only, not commitments)

- **M1.5 close-out: post-exit console transport + serial RX.** The console
  is already identified (virtio-pci, claim 0013); the work is a
  post-exit-safe way to reach it (post-exit access hangs on VZ) and then
  the RX path (the milestone-two console is polled TX-only, ADR 0004; the
  kernel's `readByte` is a no-RX stub). This is what stands between the
  current mock-level monitor and a live `dipshit>` session.
- A memory allocator and boot-time memory map walk (the EFI memory map
  the kernel captured at exit, walked by the kernel itself).
- Interrupt setup (GIC) and a timer — the GIC is already recorded as an
  `[inferred]` hardware assumption.
- Eventually: a process abstraction, a filesystem, a network stack — each
  only when the ones below it are demonstrably working.

Each milestone must state what was **observed** versus **inferred** and must
record new hardware assumptions in `docs/hardware-contract.md`.
```

### docs/architecture.md:9-9
reason: changed-symbol
covers: changed_file:docs/architecture.md, changed_symbol:Current state, high_risk:docs/architecture.md, symbol_range:docs/architecture.md:9-35
score: 12.92
cost: 400 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Current state

```markdown
#…
... [truncated 25 line(s) omitted -- retained 1 of 26 line(s)]
```

### docs/architecture.md:47-65
reason: changed-symbol
covers: changed_file:docs/architecture.md, changed_symbol:Data flow, high_risk:docs/architecture.md, symbol_range:docs/architecture.md:47-65
score: 12.92
cost: 1460 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Data flow

```markdown
## Data flow

```
boot/src/main.zig  ──zig build──▶  zig-out/bin/BOOTAA64.EFI   (PE/COFF, AArch64)
                                        │
image/make-image.sh ──mkfat32.py──▶  artifacts/disk.img        (GPT + FAT32 ESP)
                                        │
        ▼
VZEFIBootLoader (macOS VZ)
   └─ UEFI firmware boots EFI/BOOT/BOOTAA64.EFI
        │
        └── ConOut ──▶ virtio console ──▶ artifacts/vm-serial.log  (empty: firmware doesn't route ConOut here)
        └── loader loads \\KERNEL.BIN ──▶ kernel entry
             │  milestone two: ExitBootServices, identity-map MMU
             │  post-exit evidence channel: NVRAM ladder (EFI var DipshitM2) ──▶ artifacts/efi-vars.bin  [observed: reaches M2_MMUP! → M2_SERIA]
             └── serial probe ──▶ declared windows decoded (efivars store + debug UART, claim 0013); real console = virtio-pci @ BAR 0x100010000 ──▶ post-exit transport access hangs ──▶ vm-serial.log empty
             └── M1.5 monitor loop (console/lineedit/tokenizer/shell) ──▶ exists, host-tested via MockConsole; parks in WFE on the real kernel (RX not wired — readByte is a no-RX stub)
```
```

### docs/architecture.md:66-66
reason: changed-symbol
covers: changed_file:docs/architecture.md, changed_symbol:Interfaces, high_risk:docs/architecture.md, symbol_range:docs/architecture.md:66-97
score: 12.92
cost: 397 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Interfaces

```markdown
#…
... [truncated 30 line(s) omitted -- retained 1 of 31 line(s)]
```

### docs/hardware-contract.md:106-115
reason: changed-symbol
covers: changed_file:docs/hardware-contract.md, changed_symbol:Milestone two: the kernel proper (implemented, ADR 0004 — MMU/serial findings are **[observed]** per claims 0010/0013/0020/0021; the remaining items below stay **[inferred]**), high_risk:docs/hardware-contract.md, symbol_range:docs/hardware-contract.md:106-115
score: 12.89
cost: 1294 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Milestone two: the kernel proper (implemented, ADR 0004 — MMU/serial findings are **[observed]** per claims 0010/0013/0020/0021; the remaining items below stay **[inferred]**)

```markdown
## Milestone two: the kernel proper (implemented, ADR 0004 — MMU/serial findings are **[observed]** per claims 0010/0013/0020/0021; the remaining items below stay **[inferred]**)

Milestone two is implemented in the guest; the MMU and serial findings
below are **[observed]** (claims 0010/0013/0020/0021 on a real Apple M4 /
macOS 27 VZ host), and the remaining items stay **[inferred]** until a
console is actually driven and serial output proves them. Code/build
success alone is not hardware evidence. The concrete numbers are
deliberately isolated so one observed probe can correct them without
redesign.
```

### docs/hardware-contract.md:179-179
reason: changed-symbol
covers: changed_file:docs/hardware-contract.md, changed_symbol:MMIO / serial console (UART), high_risk:docs/hardware-contract.md, symbol_range:docs/hardware-contract.md:179-214
score: 12.89
cost: 457 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: MMIO / serial console (UART)

```markdown
#…
... [truncated 34 line(s) omitted -- retained 1 of 35 line(s)]
```

### kernel/src/virtio_console.zig:165-165
reason: changed-symbol
covers: changed_file:kernel/src/virtio_console.zig, changed_symbol:virtio_pci_init, high_risk:kernel/src/virtio_console.zig, symbol_range:kernel/src/virtio_console.zig:165-395
score: 12.74
cost: 449 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: virtio_pci_init

```zig
p…
... [truncated 230 line(s) omitted -- retained 1 of 231 line(s)]
```

### justfile:101-101
reason: changed-chunk
covers: changed_file:justfile, high_risk:justfile
score: 12.53
cost: 275 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8

```
c…
... [truncated 45 line(s) omitted -- retained 1 of 46 line(s)]
```

### docs/claims/README.md:56-56
reason: changed-symbol
covers: changed_file:docs/claims/README.md, changed_symbol:Active claims index, symbol_range:docs/claims/README.md:56-96
score: 12.23
cost: 386 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Active claims index

```markdown
#…
... [truncated 40 line(s) omitted -- retained 1 of 41 line(s)]
```

### docs/logs/README.md:36-36
reason: changed-symbol
covers: changed_file:docs/logs/README.md, changed_symbol:Log index, symbol_range:docs/logs/README.md:36-71
score: 12.08
cost: 360 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Log index

```markdown
#…
... [truncated 35 line(s) omitted -- retained 1 of 36 line(s)]
```

### docs/logs/freebuff-ragshit-review.md:1-7
reason: changed-symbol
covers: changed_file:docs/logs/freebuff-ragshit-review.md, changed_symbol:Log — `freebuff/ragshit-review`, symbol_range:docs/logs/freebuff-ragshit-review.md:1-7
score: 11.76
cost: 1321 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Log — `freebuff/ragshit-review`

```markdown
# Log — `freebuff/ragshit-review`

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-08** — *buffy (freebuff/ragshit-review)*: claim 0020 — Ragshit `review` budgeted reviewer packet (task 2026-08-08); claim filed; reuse `tools/ragshit/impact` as input; scope `tools/ragshit/` only; plan in `artifacts/review-plan.md`. 🔄 in progress
- **2026-08-08** — *buffy (freebuff/ragshit-review)*: review implemented — `review/{candidates,coverage,redundancy,selection,report}.py` + CLI `--budget-chars/--json/--explain` + baseline + docs; tests 23 new, full suite 124 passed, doctor ok. 🔄
- **2026-08-08** — *buffy (freebuff/ragshit-review)*: dogfood done — HEAD~1/~5/~10 at 10k/25k/50k under `artifacts/review-packets/`; 10k contains most valuable impl, 25k improves coverage, 50k adds secondary evidence without duplicates; timing ~110ms HEAD~1, ~230ms HEAD~5, ~290ms HEAD~10 (index reuse); determinism verified. ✅ done
```

### docs/logs/freebuff-you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d.md:1-1
reason: changed-symbol
covers: changed_file:docs/logs/freebuff-you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d.md, changed_symbol:Log — freebuff/you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d, symbol_range:docs/logs/freebuff-you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d.md:1-4
score: 11.56
cost: 810 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Log — freebuff/you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d

```markdown
#…
... [truncated 3 line(s) omitted -- retained 1 of 4 line(s)]
```

### docs/logs/freebuff-stale-doc-cleanup.md:1-3
reason: changed-symbol
covers: changed_file:docs/logs/freebuff-stale-doc-cleanup.md, changed_symbol:Log — stale-doc cleanup (claim 3109), symbol_range:docs/logs/freebuff-stale-doc-cleanup.md:1-3
score: 11.47
cost: 1446 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Log — stale-doc cleanup (claim 3109)

```markdown
# Log — stale-doc cleanup (claim 3109)

- **2026-08-08** — *buffy (`freebuff/stale-doc-cleanup`)*: claim 3109 — reduced stale blocker duplication in non-status docs. Classified each doc's content (timeless kept; current gate status → pointer to `docs/status.md`; historical kept dated; stale removed/corrected). Fixed: "device discovery is next" → "post-exit console transport + RX" (README/roadmap/architecture); "no usable MMIO serial device in declared windows" as the whole blocker → claim-0013 decoded windows + virtio-pci console + post-exit hang (README/roadmap/architecture/testing); roadmap's "kernel dies between shim entry" + "marker fallback is the next step" (superseded); README bad-handoff table row stray 4th cell; hardware-contract M2 header + intro (inferred→observed/inferred mix) and "fivars"→"efivars" typo; march step 20 status cell now "✅ (docs only — milestone NOT closed)". Before/after stale-phrase report: `artifacts/stale-doc-report.txt` (26 → 0 hits); link check 38 links, 0 broken. `docs/status.md` untouched. ✅
```

### docs/logs/freebuff-pull-latest-dipshitos-main-after-all-preceding-rel-1fe779b0-133e-4303-81f1-397087634352.md:1-1
reason: changed-symbol
covers: changed_file:docs/logs/freebuff-pull-latest-dipshitos-main-after-all-preceding-rel-1fe779b0-133e-4303-81f1-397087634352.md, changed_symbol:Log — status-preflight review (claim 8592), symbol_range:docs/logs/freebuff-pull-latest-dipshitos-main-after-all-preceding-rel-1fe779b0-133e-4303-81f1-397087634352.md:1-4
score: 11.34
cost: 690 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Log — status-preflight review (claim 8592)

```markdown
#…
... [truncated 3 line(s) omitted -- retained 1 of 4 line(s)]
```

### docs/logs/freebuff-pull-latest-dipshitos-main-ebe15999-a14a-4066-9551-00deb3d2323a.md:1-3
reason: changed-symbol
covers: changed_file:docs/logs/freebuff-pull-latest-dipshitos-main-ebe15999-a14a-4066-9551-00deb3d2323a.md, changed_symbol:Log — verification gate classification (claim 0594), symbol_range:docs/logs/freebuff-pull-latest-dipshitos-main-ebe15999-a14a-4066-9551-00deb3d2323a.md:1-3
score: 11.25
cost: 1443 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: Log — verification gate classification (claim 0594)

```markdown
# Log — verification gate classification (claim 0594)

- **2026-08-08** — *buffy (`freebuff/pull-latest-dipshitos-main-ebe15999-a14a-4066-9551-00deb3d2323a`)*: claim 0594 — classify every verification command into A (portable/build CI) / B (Apple-silicon VZ hardware gate) / C (interactive/manual) / D (diagnostic, not an acceptance gate); new `docs/gate-inventory.md` with machine-readable `GATE` records (consumable by a status preflight via sed/grep); `just verify` → `verify-portable` (+ alias) and new `just verify-vz`; CI labelled by class + explicit "gates NOT proven by CI" step; `build.zig` step help annotated; `docs/testing.md` classification section. Full class-A set re-run green (fmt/unit/transcript/build/image/inspect/swift/context/coordination/tooling/mmu-debt), coordination gate green, justfile validated with just 1.38.0. No `docs/status.md` edits. ✅
```

### docs/march-m15.md:1-1
reason: changed-symbol
covers: changed_file:docs/march-m15.md, changed_symbol:M1.5 march — Interactive Kernel Monitor (living tracker), symbol_range:docs/march-m15.md:1-41
score: 11.18
cost: 445 chars
provenance: commit:fff37a5e6af8476c273dc959aefce0f412e11554 index:fff37a5e6af8
symbol: M1.5 march — Interactive Kernel Monitor (living tracker)

```markdown
#…
... [truncated 39 line(s) omitted -- retained 1 of 40 line(s)]
```

## Missing / weak coverage

- changed_files: missing `tools/ragshit/CHANGELOG.md`, `tools/ragshit/README.md`, `tools/ragshit/docs/architecture.md`, `tools/ragshit/docs/ranking.md`, `tools/ragshit/src/ragshit/cli.py`, `tools/ragshit/src/ragshit/impact/report.py`, `tools/ragshit/src/ragshit/impact/stale.py`, `tools/ragshit/src/ragshit/impact/symbols.py` (+10 more)
- decision_docs: missing `docs/claims/0001-bad-handoff-gate.md`, `docs/claims/0002-vz-serial-gate.md`, `docs/claims/0003-m15-host-plumbing.md`, `docs/claims/0004-m15-console-shell-core.md`, `docs/claims/0005-m15-commands-personality.md`, `docs/claims/0006-status-machinery.md`, `docs/claims/0007-status-sharding-hardening.md`, `docs/claims/0008-m15-transcript-test.md` (+16 more)
- high_risk_files: missing `tools/ragshit/CHANGELOG.md`, `tools/ragshit/README.md`, `tools/ragshit/docs/architecture.md`, `tools/ragshit/src/ragshit/cli.py`, `tools/ragshit/src/ragshit/impact/report.py`, `tools/ragshit/src/ragshit/impact/stale.py`, `tools/ragshit/src/ragshit/parsing/source.py`, `tools/ragshit/src/ragshit/review/report.py`
- relevant_docs: missing `.github/PULL_REQUEST_TEMPLATE.md`, `AGENTS.md`, `docs/branch-protection.md`, `docs/claims/0001-bad-handoff-gate.md`, `docs/claims/0002-vz-serial-gate.md`, `docs/claims/0003-m15-host-plumbing.md`, `docs/claims/0004-m15-console-shell-core.md`, `docs/claims/0005-m15-commands-personality.md` (+25 more)
- stale_warnings: missing `docs/claims/0017-preexit-virtio-tx.md:virtio_pci_init`, `docs/claims/0023-mainzig-module-split.md:virtio_pci_init`, `docs/logs/agent-buffy-m15-milestone-docs.md:Next steps`, `docs/m2-vz-serial-gate-prompt.md:Verification sequence`

## Stale-context warnings

- `docs/claims/0017-preexit-virtio-tx.md`:21-77 -- mentions `virtio_pci_init` -- mentions changed symbol but not updated in range -- Claim: M1.5 — pre-ExitBootServices virtio-pci console TX experiment (diagnostic) > Notes
- `docs/claims/0023-mainzig-module-split.md`:18-49 -- mentions `virtio_pci_init` -- mentions changed symbol but not updated in range -- Claim: mechanical split of kernel/src/main.zig into hardware modules > Notes > Module boundaries (moved verbatim, only import/name plumbing changes)
- `docs/logs/agent-buffy-m15-milestone-docs.md`:1-45 -- mentions `Next steps` -- mentions changed symbol but not updated in range -- Log — `agent/buffy/m15-milestone-docs`
- `docs/m2-vz-serial-gate-prompt.md`:135-174 -- mentions `Verification sequence` -- mentions changed symbol but not updated in range -- Milestone 1.5 — the VZ serial/MMU gate run (M1.5 march step 8, claim 0002) > Verification sequence (run in order; save every output)
- filtered generic symbols (no hints generated): `Current state` (generic-heading (appears in 4 documents)), `DipshitOS` (project-name; generic-heading (appears in 27 documents); ubiquitous (appears in 27 documents)), `Notes` (generic-heading (appears in 31 documents); ubiquitous (appears in 31 documents)), `The guest` (generic-heading (appears in 6 documents)), `build` (ubiquitous (appears in 53 documents)), `name` (ubiquitous (appears in 10 documents); generic-config-key (appears in 10 documents))

## Selection summary

- candidates considered: 108
- selected: 41
- rejected: 92
- budget utilization: 39879 / 40000 (99.7%)
- candidate content cost: 30732 chars (sum of selected block costs, before framing)
- note: mandatory content exceeded budget; excerpts were safely truncated to stay under budget
- baseline (naive impact-ranked) would select 23 at 39810 candidate chars
- diversity selector improved: changed_files, changed_symbols, decision_docs, high_risk_files, relevant_docs vs baseline

## Rejected candidates (explain)

- `docs/claims/0594-verify-gate-classification.md`:14-74 -- reason:changed-symbol -- score 14.7 cost 3428 -- budget pressure (mandatory content truncated to fit)
- `docs/claims/8592-status-preflight.md`:17-29 -- reason:changed-symbol -- score 14.7 cost 1066 -- budget pressure (mandatory content truncated to fit)
- `docs/claims/3320-ragshit-dogfood-hardening.md`:9-21 -- reason:changed-symbol -- score 14.5 cost 2199 -- budget pressure (mandatory content truncated to fit)
- `build.zig`:1-237 -- reason:changed-symbol -- score 14.5 cost 15349 -- budget pressure (needs 15349 chars, 11338 remaining) mandatory deferred
- `docs/claims/9112-ragshit-review.md`:9-11 -- reason:changed-symbol -- score 14.3 cost 937 -- budget pressure (mandatory content truncated to fit)
- `docs/testing.md`:34-128 -- reason:changed-symbol -- score 14.2 cost 6112 -- budget pressure (needs 6112 chars, 4153 remaining) mandatory deferred
- `docs/gate-inventory.md`:1-10 -- reason:changed-symbol -- score 13.7 cost 893 -- budget pressure (needs 893 chars, 555 remaining) mandatory deferred
- `docs/gate-inventory.md`:11-26 -- reason:changed-symbol -- score 13.7 cost 1161 -- budget pressure (needs 1161 chars, 555 remaining) mandatory deferred
- `docs/gate-inventory.md`:27-69 -- reason:changed-symbol -- score 13.7 cost 3763 -- budget pressure (needs 3763 chars, 555 remaining) mandatory deferred
- `docs/gate-inventory.md`:70-102 -- reason:changed-symbol -- score 13.7 cost 3063 -- budget pressure (needs 3063 chars, 555 remaining) mandatory deferred
- `docs/roadmap.md`:62-88 -- reason:changed-symbol -- score 13.6 cost 1982 -- budget pressure (needs 1982 chars, 555 remaining) mandatory deferred
- `docs/roadmap.md`:159-173 -- reason:changed-symbol -- score 13.6 cost 1225 -- budget pressure (needs 1225 chars, 555 remaining) mandatory deferred
- `docs/roadmap.md`:174-211 -- reason:changed-symbol -- score 13.6 cost 2573 -- budget pressure (needs 2573 chars, 555 remaining) mandatory deferred
- `docs/roadmap.md`:212-228 -- reason:changed-symbol -- score 13.6 cost 1377 -- budget pressure (needs 1377 chars, 555 remaining) mandatory deferred
- `docs/architecture.md`:9-35 -- reason:changed-symbol -- score 12.9 cost 2005 -- budget pressure (needs 2005 chars, 555 remaining) mandatory deferred
- `docs/architecture.md`:47-65 -- reason:changed-symbol -- score 12.9 cost 1460 -- budget pressure (needs 1460 chars, 555 remaining) mandatory deferred
- `docs/architecture.md`:66-97 -- reason:changed-symbol -- score 12.9 cost 2265 -- budget pressure (needs 2265 chars, 555 remaining) mandatory deferred
- `docs/hardware-contract.md`:106-115 -- reason:changed-symbol -- score 12.9 cost 1294 -- budget pressure (needs 1294 chars, 555 remaining) mandatory deferred
- `docs/hardware-contract.md`:179-214 -- reason:changed-symbol -- score 12.9 cost 2649 -- budget pressure (needs 2649 chars, 555 remaining) mandatory deferred
- `kernel/src/virtio_console.zig`:165-395 -- reason:changed-symbol -- score 12.7 cost 10512 -- budget pressure (needs 10512 chars, 555 remaining) mandatory deferred

## Determinism

- schema: ragshit.review/v1
- timing_ms is 0 (real timing on stderr); output is byte-identical for unchanged repo/index/range/args

stats: {'commits': 16, 'files_changed': 41, 'symbols_touched': 44, 'neighbors': 80, 'stale_hints': 4, 'candidates_considered': 108, 'candidates_selected': 41, 'candidates_rejected': 92} -- index HEAD: fff37a5e6af8 -- deterministic
