# Review packet

Git range: `HEAD~5..HEAD`
Base: `HEAD~5` (`938d068cac03`)
Head: `HEAD` (`2f20e5aaad57`)
Index HEAD: `2f20e5aaad57`
Budget: 40000 chars
Actual size: 39896 chars

## Coverage summary

- changed_files: 10 / 49 (20%) (20 weak)
- changed_symbols: 15 / 68 (22%) (35 weak)
- decision_docs: 2 / 35 (5%) (7 weak)
- high_risk_files: 5 / 16 (31%) (13 weak)
- related_tests: 0 / 0 (100%)
- relevant_docs: 5 / 56 (8%) (16 weak)
- stale_warnings: 0 / 6 (0%)

## Highest-risk changes

1. `docs/claims/8623-docs-reconciliation-m15-status.md` -- score 100.0 (critical) -- 68 lines, 5 symbols -- base=3, doc_touched=4, lines=10, references=9, symbols=12
2. `docs/claims/6460-t0sz16-start-level.md` -- score 92.1 (critical) -- 167 lines, 3 symbols -- base=3, doc_touched=4, lines=10, references=9, symbols=9
3. `tools/verify-t0sz16.sh` -- score 89.5 (critical) -- 275 lines, 13 symbols -- base=3, lines=10, references=9, symbols=12
4. `docs/claims/0176-ragshit-review-coverage-truncation.md` -- score 84.2 (critical) -- 40 lines, 2 symbols -- base=3, doc_touched=4, lines=10, references=9, symbols=6
5. `docs/claims/7256-status-postmmu-reconcile.md` -- score 84.2 (critical) -- 49 lines, 2 symbols -- base=3, doc_touched=4, lines=10, references=9, symbols=6
6. `README.md` -- score 81.4 (critical) -- 16 lines, 5 symbols -- base=3, lines=8.17, references=7.75, symbols=12
7. `docs/claims/3320-ragshit-dogfood-hardening.md` -- score 81.4 (critical) -- 21 lines, 2 symbols -- base=3, doc_touched=4, lines=8.92, references=9, symbols=6
8. `build.zig` -- score 77.2 (high) -- 10 lines, 1 symbols -- base=3, critical_path=5, interface=3, lines=6.92, references=8.42, symbols=3

## Selected context

### docs/claims/8623-docs-reconciliation-m15-status.md:1-1
reason: changed-symbol
covers: changed_file:docs/claims/8623-docs-reconciliation-m15-status.md, changed_symbol:Claim: Docs-only reconciliation — make status.md / march-m15.md reflect already-landed evidence, high_risk:docs/claims/8623-docs-reconciliation-m15-status.md, symbol_range:docs/claims/8623-docs-reconciliation-m15-status.md:1-8
score: 15.00
cost: 619 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Claim: Docs-only reconciliation — make status.md / march-m15.md reflect already-landed evidence

```markdown
#
```

### docs/claims/8623-docs-reconciliation-m15-status.md:9-9
reason: changed-symbol
covers: changed_file:docs/claims/8623-docs-reconciliation-m15-status.md, changed_symbol:Notes, high_risk:docs/claims/8623-docs-reconciliation-m15-status.md, symbol_range:docs/claims/8623-docs-reconciliation-m15-status.md:9-27
score: 15.00
cost: 510 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Notes

```markdown
## Notes
... [truncated 17 line(s) omitted -- retained 1 of 18 line(s)]
```

### docs/claims/8623-docs-reconciliation-m15-status.md:28-28
reason: changed-symbol
covers: changed_file:docs/claims/8623-docs-reconciliation-m15-status.md, changed_symbol:Contradictions found (audit pre-edit), high_risk:docs/claims/8623-docs-reconciliation-m15-status.md, symbol_range:docs/claims/8623-docs-reconciliation-m15-status.md:28-45
score: 15.00
cost: 609 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Contradictions found (audit pre-edit)

```markdown
## Contradictions found (audit pre-edit)
... [truncated 16 line(s) omitted -- retained 1 of 17 line(s)]
```

### docs/claims/8623-docs-reconciliation-m15-status.md:46-46
reason: changed-symbol
covers: changed_file:docs/claims/8623-docs-reconciliation-m15-status.md, changed_symbol:Corrections (before → after semantics), high_risk:docs/claims/8623-docs-reconciliation-m15-status.md, symbol_range:docs/claims/8623-docs-reconciliation-m15-status.md:46-61
score: 15.00
cost: 612 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Corrections (before → after semantics)

```markdown
## Corrections (before → after semantics)
... [truncated 14 line(s) omitted -- retained 1 of 15 line(s)]
```

### docs/claims/8623-docs-reconciliation-m15-status.md:62-62
reason: changed-symbol
covers: changed_file:docs/claims/8623-docs-reconciliation-m15-status.md, changed_symbol:Verification plan, high_risk:docs/claims/8623-docs-reconciliation-m15-status.md, symbol_range:docs/claims/8623-docs-reconciliation-m15-status.md:62-68
score: 15.00
cost: 547 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Verification plan

```markdown
## Verification plan
... [truncated 6 line(s) omitted -- retained 1 of 7 line(s)]
```

### docs/claims/6460-t0sz16-start-level.md:1-1
reason: changed-symbol
covers: changed_file:docs/claims/6460-t0sz16-start-level.md, changed_symbol:Claim: M1.5 — T0SZ start-level diagnostic: does correcting the 4 KiB translation initial lookup level (T0SZ 25→16) restore post-MMU virtio-pci console TX? (class-D experiment), high_risk:docs/claims/6460-t0sz16-start-level.md, symbol_range:docs/claims/6460-t0sz16-start-level.md:1-26
score: 14.60
cost: 732 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Claim: M1.5 — T0SZ start-level diagnostic: does correcting the 4 KiB translation initial lookup level (T0SZ 25→16) restore post-MMU virtio-pci console TX? (class-D experiment)

```markdown
#
```

### docs/claims/6460-t0sz16-start-level.md:94-94
reason: changed-symbol
covers: changed_file:docs/claims/6460-t0sz16-start-level.md, changed_symbol:Result (2026-08-08) — class-D A/B on real VZ hardware, high_risk:docs/claims/6460-t0sz16-start-level.md, symbol_range:docs/claims/6460-t0sz16-start-level.md:94-167
score: 14.60
cost: 610 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Result (2026-08-08) — class-D A/B on real VZ hardware

```markdown
## Result (2026-08-08) — class-D A/B on real VZ hardware
... [truncated 73 line(s) omitted -- retained 1 of 74 line(s)]
```

### tools/verify-t0sz16.sh:94-94
reason: changed-symbol
covers: changed_file:tools/verify-t0sz16.sh, changed_symbol:run_one, high_risk:tools/verify-t0sz16.sh, symbol_range:tools/verify-t0sz16.sh:94-275
score: 14.47
cost: 411 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: run_one

```shell
run_one() {
... [truncated 181 line(s) omitted -- retained 1 of 182 line(s)]
```

### docs/claims/0176-ragshit-review-coverage-truncation.md:1-1
reason: changed-symbol
covers: changed_file:docs/claims/0176-ragshit-review-coverage-truncation.md, changed_symbol:Claim: Ragshit `review` — decision-useful coverage under hard budget truncation, high_risk:docs/claims/0176-ragshit-review-coverage-truncation.md, symbol_range:docs/claims/0176-ragshit-review-coverage-truncation.md:1-8
score: 14.21
cost: 603 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Claim: Ragshit `review` — decision-useful coverage under hard budget truncation

```markdown
#
```

### docs/claims/7256-status-postmmu-reconcile.md:1-1
reason: changed-symbol
covers: changed_file:docs/claims/7256-status-postmmu-reconcile.md, changed_symbol:Claim: Docs-only reconciliation follow-up — post-MMU blocker wording + newest landed evidence (claim 6460) across stable-context docs, high_risk:docs/claims/7256-status-postmmu-reconcile.md, symbol_range:docs/claims/7256-status-postmmu-reconcile.md:1-8
score: 14.21
cost: 671 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Claim: Docs-only reconciliation follow-up — post-MMU blocker wording + newest landed evidence (claim 6460) across stable-context docs

```markdown
#
```

### README.md:1-24
reason: changed-symbol
covers: changed_file:README.md, changed_symbol:DipshitOS, high_risk:README.md, symbol_range:README.md:1-53
score: 14.07
cost: 715 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: DipshitOS

```markdown
# DipshitOS
... [truncated 18 line(s) omitted]
  identity-map switch now completes on VZ; marker ladder reaches
  `M2_SERIA`); claim 0013 found the real console is a virtio-pci device
  outside the declared MMIO windows, but post-MMU access to its
  transport hangs on VZ (the MMU switch destroys access, claims
  0018/0020), so the VZ serial gate remains blocked. The
... [truncated 46 line(s) omitted -- retained 6 of 52 line(s)]
```

### README.md:54-54
reason: changed-symbol
covers: changed_file:README.md, changed_symbol:The guest, high_risk:README.md, symbol_range:README.md:54-74
score: 14.07
cost: 287 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: The guest

```markdown
#
```

### README.md:161-161
reason: changed-symbol
covers: changed_file:README.md, changed_symbol:Verification results (observed on this development host), high_risk:README.md, symbol_range:README.md:161-196
score: 14.07
cost: 506 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Verification results (observed on this development host)

```markdown
## Verification results (observed on this development host)
... [truncated 34 line(s) omitted -- retained 1 of 35 line(s)]
```

### README.md:197-209
reason: changed-symbol
covers: changed_file:README.md, changed_symbol:Observed behavior, high_risk:README.md, symbol_range:README.md:197-219
score: 14.07
cost: 716 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Observed behavior

```markdown
### Observed behavior
... [truncated 7 line(s) omitted]
  gate, mock console), and `bash tools/verify-host-console.sh` (M1.5 host
  plumbing). The M1.5 monitor (14 commands) is implemented and
  host-tested; the VZ serial gate's remaining blocker is post-MMU access
  to the virtio-pci console transport (claims 0018/0020; see
  `docs/status.md`).
... [truncated 16 line(s) omitted -- retained 6 of 22 line(s)]
```

### README.md:226-226
reason: changed-symbol
covers: changed_file:README.md, changed_symbol:Next steps, high_risk:README.md, symbol_range:README.md:226-252
score: 14.07
cost: 368 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Next steps

```markdown
## Next steps
... [truncated 26 line(s) omitted -- retained 1 of 27 line(s)]
```

### docs/claims/3320-ragshit-dogfood-hardening.md:1-1
reason: changed-symbol
covers: changed_file:docs/claims/3320-ragshit-dogfood-hardening.md, changed_symbol:Claim: Ragshit review dogfood-hardening — honest accounting, coverage, stale filter, shell importance, high_risk:docs/claims/3320-ragshit-dogfood-hardening.md, symbol_range:docs/claims/3320-ragshit-dogfood-hardening.md:1-8
score: 14.07
cost: 611 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Claim: Ragshit review dogfood-hardening — honest accounting, coverage, stale filter, shell importance

```markdown
#
```

### build.zig:14-14
reason: changed-symbol
covers: changed_file:build.zig, changed_symbol:build, high_risk:build.zig, symbol_range:build.zig:1-247
score: 13.86
cost: 377 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: build

```zig
pub fn build(b: *std.Build) void {
... [truncated 246 line(s) omitted -- retained 1 of 247 line(s)]
```

### kernel/src/mmu.zig:22-33
reason: changed-symbol
covers: changed_file:kernel/src/mmu.zig, changed_symbol:table_root, high_risk:kernel/src/mmu.zig, symbol_range:kernel/src/mmu.zig:1-35
score: 13.79
cost: 612 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: table_root

```zig
... [truncated 21 line(s) omitted]
const MemoryType = uefi.tables.MemoryType;
const handoff = @import("handoff.zig");
const build_options = @import("build_options");

... [truncated 7 line(s) omitted]
pub fn table_root() u64 {
... [truncated 30 line(s) omitted -- retained 5 of 35 line(s)]
```

### kernel/src/mmu.zig:43-45
reason: changed-symbol
covers: changed_file:kernel/src/mmu.zig, changed_symbol:plan_t0sz, high_risk:kernel/src/mmu.zig, symbol_range:kernel/src/mmu.zig:43-48
score: 13.79
cost: 525 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: plan_t0sz

```zig
pub const plan_t0sz: u64 = if (build_options.t0sz16) 16 else 25;

/// Clean the D-cache over [start, start+len) to the point of coherence so a
... [truncated 3 line(s) omitted -- retained 3 of 6 line(s)]
```

### kernel/src/mmu.zig:356-356
reason: changed-symbol
covers: changed_file:kernel/src/mmu.zig, changed_symbol:install_identity_map, high_risk:kernel/src/mmu.zig, symbol_range:kernel/src/mmu.zig:356-421
score: 13.79
cost: 447 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: install_identity_map

```zig
pub fn install_identity_map() void {
... [truncated 65 line(s) omitted -- retained 1 of 66 line(s)]
```

### docs/status.md:43-43
reason: changed-symbol
covers: changed_file:docs/status.md, changed_symbol:Gate status, high_risk:docs/status.md, symbol_range:docs/status.md:43-63
score: 13.29
cost: 387 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Gate status

```markdown
## Gate status
... [truncated 19 line(s) omitted -- retained 1 of 20 line(s)]
```

### docs/status.md:64-64
reason: changed-symbol
covers: changed_file:docs/status.md, changed_symbol:Current blocker (canonical — one description, one ordering), high_risk:docs/status.md, symbol_range:docs/status.md:64-69
score: 13.29
cost: 407 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Current blocker (canonical — one description, one ordering)

```markdown
#
```

### docs/status.md:70-70
reason: changed-symbol
covers: changed_file:docs/status.md, changed_symbol:What we directly observe about the serial gate and the bad-handoff fix, high_risk:docs/status.md, symbol_range:docs/status.md:70-183
score: 13.29
cost: 568 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: What we directly observe about the serial gate and the bad-handoff fix

```markdown
### What we directly observe about the serial gate and the bad-handoff fix
... [truncated 112 line(s) omitted -- retained 1 of 113 line(s)]
```

### docs/status.md:230-230
reason: changed-symbol
covers: changed_file:docs/status.md, changed_symbol:Hard gates (acceptance criteria), high_risk:docs/status.md, symbol_range:docs/status.md:230-240
score: 13.29
cost: 357 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Hard gates (acceptance criteria)

```markdown
#
```

### docs/status.md:250-250
reason: changed-symbol
covers: changed_file:docs/status.md, changed_symbol:What comes immediately afterward, high_risk:docs/status.md, symbol_range:docs/status.md:250-260
score: 13.29
cost: 453 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: What comes immediately afterward

```markdown
## What comes immediately afterward
... [truncated 9 line(s) omitted -- retained 1 of 10 line(s)]
```

### docs/status.md:261-261
reason: changed-symbol
covers: changed_file:docs/status.md, changed_symbol:Assumptions & gaps in this plan (checked against the merged `main`), high_risk:docs/status.md, symbol_range:docs/status.md:261-301
score: 13.29
cost: 559 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Assumptions & gaps in this plan (checked against the merged `main`)

```markdown
## Assumptions & gaps in this plan (checked against the merged `main`)
... [truncated 39 line(s) omitted -- retained 1 of 40 line(s)]
```

### docs/status.md:365-365
reason: changed-symbol
covers: changed_file:docs/status.md, changed_symbol:Immediate gate work (prerequisites for M1.5), high_risk:docs/status.md, symbol_range:docs/status.md:365-404
score: 13.29
cost: 490 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Immediate gate work (prerequisites for M1.5)

```markdown
## Immediate gate work (prerequisites for M1.5)
... [truncated 38 line(s) omitted -- retained 1 of 39 line(s)]
```

### docs/status.md:424-424
reason: changed-symbol
covers: changed_file:docs/status.md, changed_symbol:Related docs, high_risk:docs/status.md, symbol_range:docs/status.md:424-439
score: 13.29
cost: 317 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Related docs

```markdown
#
```

### docs/roadmap.md:62-62
reason: changed-symbol
covers: changed_file:docs/roadmap.md, changed_symbol:Milestone two — the kernel proper (implemented; VZ serial gate not passed), high_risk:docs/roadmap.md, symbol_range:docs/roadmap.md:62-88
score: 12.46
cost: 441 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Milestone two — the kernel proper (implemented; VZ serial gate not passed)

```markdown
#
```

### docs/roadmap.md:174-174
reason: changed-symbol
covers: changed_file:docs/roadmap.md, changed_symbol:Milestone 1.5 — interactive kernel monitor (current), high_risk:docs/roadmap.md, symbol_range:docs/roadmap.md:174-211
score: 12.46
cost: 401 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Milestone 1.5 — interactive kernel monitor (current)

```markdown
#
```

### docs/roadmap.md:212-212
reason: changed-symbol
covers: changed_file:docs/roadmap.md, changed_symbol:Later milestones (sketches only, not commitments), high_risk:docs/roadmap.md, symbol_range:docs/roadmap.md:212-229
score: 12.46
cost: 509 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Later milestones (sketches only, not commitments)

```markdown
## Later milestones (sketches only, not commitments)
... [truncated 17 line(s) omitted -- retained 1 of 18 line(s)]
```

### kernel/src/evidence.zig:603-603
reason: changed-symbol
covers: changed_file:kernel/src/evidence.zig, changed_symbol:fw_mmu_capture_diag, high_risk:kernel/src/evidence.zig, symbol_range:kernel/src/evidence.zig:603-681
score: 12.46
cost: 367 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: fw_mmu_capture_diag

```zig
p
```

### kernel/src/virtio_console.zig:165-165
reason: changed-symbol
covers: changed_file:kernel/src/virtio_console.zig, changed_symbol:virtio_pci_init, high_risk:kernel/src/virtio_console.zig, symbol_range:kernel/src/virtio_console.zig:165-395
score: 12.46
cost: 383 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: virtio_pci_init

```zig
p
```

### docs/architecture.md:9-9
reason: changed-symbol
covers: changed_file:docs/architecture.md, changed_symbol:Current state, high_risk:docs/architecture.md, symbol_range:docs/architecture.md:9-36
score: 12.37
cost: 336 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Current state

```markdown
#
```

### docs/architecture.md:48-48
reason: changed-symbol
covers: changed_file:docs/architecture.md, changed_symbol:Data flow, high_risk:docs/architecture.md, symbol_range:docs/architecture.md:48-66
score: 12.37
cost: 331 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Data flow

```markdown
#
```

### docs/architecture.md:67-67
reason: changed-symbol
covers: changed_file:docs/architecture.md, changed_symbol:Interfaces, high_risk:docs/architecture.md, symbol_range:docs/architecture.md:67-98
score: 12.37
cost: 333 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Interfaces

```markdown
#
```

### artifacts/docs-reconciliation-20260808/link-check.txt:1-1
reason: changed-symbol
covers: changed_file:artifacts/docs-reconciliation-20260808/link-check.txt, changed_symbol:artifacts/docs-reconciliation-20260808/link-check.txt, symbol_range:artifacts/docs-reconciliation-20260808/link-check.txt:1-49
score: 12.10
cost: 602 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: artifacts/docs-reconciliation-20260808/link-check.txt

```
relative link check over docs/status.md docs/march-m15.md
... [truncated 48 line(s) omitted -- retained 1 of 49 line(s)]
```

### docs/logs/freebuff-t0sz16-startlevel-diag.md:1-1
reason: changed-symbol
covers: changed_file:docs/logs/freebuff-t0sz16-startlevel-diag.md, changed_symbol:Log — `freebuff/t0sz16-startlevel-diag`, symbol_range:docs/logs/freebuff-t0sz16-startlevel-diag.md:1-32
score: 12.10
cost: 531 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Log — `freebuff/t0sz16-startlevel-diag`

```markdown
# Log — `freebuff/t0sz16-startlevel-diag`
... [truncated 31 line(s) omitted -- retained 1 of 32 line(s)]
```

### docs/hardware-contract.md:179-179
reason: changed-symbol
covers: changed_file:docs/hardware-contract.md, changed_symbol:MMIO / serial console (UART), symbol_range:docs/hardware-contract.md:179-218
score: 12.06
cost: 450 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: MMIO / serial console (UART)

```markdown
### MMIO / serial console (UART)
... [truncated 38 line(s) omitted -- retained 1 of 39 line(s)]
```

### artifacts/docs-reconciliation-20260808/stale-grep-after.txt:2-2
reason: changed-symbol
covers: changed_file:artifacts/docs-reconciliation-20260808/stale-grep-after.txt, changed_symbol:artifacts/docs-reconciliation-20260808/stale-grep-after.txt, symbol_range:artifacts/docs-reconciliation-20260808/stale-grep-after.txt:1-23
score: 11.99
cost: 597 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: artifacts/docs-reconciliation-20260808/stale-grep-after.txt

```
--- device absence ---
... [truncated 22 line(s) omitted -- retained 1 of 23 line(s)]
```

### docs/claims/README.md:56-56
reason: changed-symbol
covers: changed_file:docs/claims/README.md, changed_symbol:Active claims index, symbol_range:docs/claims/README.md:56-101
score: 11.99
cost: 323 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Active claims index

```markdown
#
```

### artifacts/docs-reconciliation-20260808/stale-grep-before.txt:2-2
reason: changed-symbol
covers: changed_file:artifacts/docs-reconciliation-20260808/stale-grep-before.txt, changed_symbol:artifacts/docs-reconciliation-20260808/stale-grep-before.txt, symbol_range:artifacts/docs-reconciliation-20260808/stale-grep-before.txt:1-17
score: 11.89
cost: 602 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: artifacts/docs-reconciliation-20260808/stale-grep-before.txt

```
--- device absence ---
... [truncated 16 line(s) omitted -- retained 1 of 17 line(s)]
```

### docs/logs/README.md:36-36
reason: changed-symbol
covers: changed_file:docs/logs/README.md, changed_symbol:Log index, symbol_range:docs/logs/README.md:36-76
score: 11.86
cost: 370 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Log index

```markdown
## Log index
... [truncated 40 line(s) omitted -- retained 1 of 41 line(s)]
```

### docs/logs/freebuff-docs-reconciliation-m15-status-20260808.md:1-1
reason: changed-symbol
covers: changed_file:docs/logs/freebuff-docs-reconciliation-m15-status-20260808.md, changed_symbol:Log — freebuff/docs-reconciliation-m15-status-20260808, symbol_range:docs/logs/freebuff-docs-reconciliation-m15-status-20260808.md:1-15
score: 11.84
cost: 627 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Log — freebuff/docs-reconciliation-m15-status-20260808

```markdown
# Log — freebuff/docs-reconciliation-m15-status-20260808
... [truncated 14 line(s) omitted -- retained 1 of 15 line(s)]
```

### docs/testing.md:34-34
reason: changed-symbol
covers: changed_file:docs/testing.md, changed_symbol:Verification sequence, symbol_range:docs/testing.md:34-128
score: 11.73
cost: 309 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Verification sequence

```markdown
#
```

### docs/testing.md:159-159
reason: changed-symbol
covers: changed_file:docs/testing.md, changed_symbol:Results log (as verified on the development host), symbol_range:docs/testing.md:159-212
score: 11.73
cost: 368 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Results log (as verified on the development host)

```markdown
#
```

### docs/gate-inventory.md:27-27
reason: changed-symbol
covers: changed_file:docs/gate-inventory.md, changed_symbol:Gate table, symbol_range:docs/gate-inventory.md:27-70
score: 11.60
cost: 307 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Gate table

```markdown
#
```

### docs/gate-inventory.md:71-71
reason: changed-symbol
covers: changed_file:docs/gate-inventory.md, changed_symbol:Machine-readable records, symbol_range:docs/gate-inventory.md:71-104
score: 11.60
cost: 336 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Machine-readable records

```markdown
#
```

### docs/logs/freebuff-start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2.md:1-1
reason: changed-symbol
covers: changed_file:docs/logs/freebuff-start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2.md, changed_symbol:Log — freebuff/start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2, symbol_range:docs/logs/freebuff-start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2.md:1-13
score: 11.59
cost: 749 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Log — freebuff/start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2

```markdown
#
```

### docs/march-m15.md:1-1
reason: changed-symbol
covers: changed_file:docs/march-m15.md, changed_symbol:M1.5 march — Interactive Kernel Monitor (living tracker), symbol_range:docs/march-m15.md:1-41
score: 11.53
cost: 381 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: M1.5 march — Interactive Kernel Monitor (living tracker)

```markdown
#
```

## Missing / weak coverage

- changed_files: missing `artifacts/docs-reconciliation-20260808/blocker-consistency-after.txt`, `artifacts/docs-reconciliation-20260808/coordination-gate.txt`, `artifacts/docs-reconciliation-20260808/diff-stat.txt`, `artifacts/docs-reconciliation-20260808/index-check.txt`, `build.zig`, `docs/architecture.md`, `docs/claims/0176-ragshit-review-coverage-truncation.md`, `docs/claims/3320-ragshit-dogfood-hardening.md` (+31 more)
- changed_symbols: missing `Active claims index`, `Assumptions & gaps in this plan (checked against the merged `main`)`, `BASELINE_FLAGS`, `BOOTS`, `BRANCH`, `CANDIDATE_FLAGS`, `COMPARE`, `Claim: Docs-only reconciliation follow-up — post-MMU blocker wording + newest landed evidence (claim 6460) across stable-context docs` (+45 more)
- decision_docs: missing `docs/claims/0001-bad-handoff-gate.md`, `docs/claims/0002-vz-serial-gate.md`, `docs/claims/0003-m15-host-plumbing.md`, `docs/claims/0004-m15-console-shell-core.md`, `docs/claims/0005-m15-commands-personality.md`, `docs/claims/0006-status-machinery.md`, `docs/claims/0007-status-sharding-hardening.md`, `docs/claims/0008-m15-transcript-test.md` (+25 more)
- high_risk_files: missing `build.zig`, `docs/architecture.md`, `docs/claims/0176-ragshit-review-coverage-truncation.md`, `docs/claims/3320-ragshit-dogfood-hardening.md`, `docs/claims/7256-status-postmmu-reconcile.md`, `docs/roadmap.md`, `docs/status.md`, `kernel/src/evidence.zig` (+3 more)
- relevant_docs: missing `.github/PULL_REQUEST_TEMPLATE.md`, `AGENTS.md`, `docs/architecture.md`, `docs/claims/0001-bad-handoff-gate.md`, `docs/claims/0002-vz-serial-gate.md`, `docs/claims/0003-m15-host-plumbing.md`, `docs/claims/0004-m15-console-shell-core.md`, `docs/claims/0005-m15-commands-personality.md` (+43 more)
- stale_warnings: missing `docs/claims/0017-preexit-virtio-tx.md:virtio_pci_init`, `docs/claims/0018-postexit-tx-bisect.md:BOOTS`, `docs/claims/0021-fw-mmu-capture.md:fw_mmu_capture_diag`, `docs/claims/0023-mainzig-module-split.md:virtio_pci_init`, `docs/logs/agent-buffy-m15-milestone-docs.md:Next steps`, `docs/m2-vz-serial-gate-prompt.md:Verification sequence`

## Weak / truncated coverage

- `docs/claims/8623-docs-reconciliation-m15-status.md`:1-1 -- changed-symbol `Claim: Docs-only reconciliation — make status.md / march-m15.md reflect already-landed evidence` -- excerpt lost the structural identity line
- `docs/claims/6460-t0sz16-start-level.md`:1-1 -- changed-symbol `Claim: M1.5 — T0SZ start-level diagnostic: does correcting the 4 KiB translation initial lookup level (T0SZ 25→16) restore post-MMU virtio-pci console TX? (class-D experiment)` -- excerpt lost the structural identity line
- `docs/claims/0176-ragshit-review-coverage-truncation.md`:1-1 -- changed-symbol `Claim: Ragshit `review` — decision-useful coverage under hard budget truncation` -- excerpt lost the structural identity line
- `docs/claims/7256-status-postmmu-reconcile.md`:1-1 -- changed-symbol `Claim: Docs-only reconciliation follow-up — post-MMU blocker wording + newest landed evidence (claim 6460) across stable-context docs` -- excerpt lost the structural identity line
- `README.md`:54-54 -- changed-symbol `The guest` -- excerpt lost the structural identity line
- `README.md`:161-161 -- changed-symbol `Verification results (observed on this development host)` -- excerpt lost the changed region (changed-line neighborhood)
- `README.md`:226-226 -- changed-symbol `Next steps` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/claims/3320-ragshit-dogfood-hardening.md`:1-1 -- changed-symbol `Claim: Ragshit review dogfood-hardening — honest accounting, coverage, stale filter, shell importance` -- excerpt lost the structural identity line
- `build.zig`:14-14 -- changed-symbol `build` -- excerpt lost the changed region (changed-line neighborhood)
- `kernel/src/mmu.zig`:356-356 -- changed-symbol `install_identity_map` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/status.md`:43-43 -- changed-symbol `Gate status` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/status.md`:64-64 -- changed-symbol `Current blocker (canonical — one description, one ordering)` -- excerpt lost the structural identity line
- `docs/status.md`:70-70 -- changed-symbol `What we directly observe about the serial gate and the bad-handoff fix` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/status.md`:230-230 -- changed-symbol `Hard gates (acceptance criteria)` -- excerpt lost the structural identity line
- `docs/status.md`:250-250 -- changed-symbol `What comes immediately afterward` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/status.md`:261-261 -- changed-symbol `Assumptions & gaps in this plan (checked against the merged `main`)` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/status.md`:365-365 -- changed-symbol `Immediate gate work (prerequisites for M1.5)` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/status.md`:424-424 -- changed-symbol `Related docs` -- excerpt lost the structural identity line
- `docs/roadmap.md`:62-62 -- changed-symbol `Milestone two — the kernel proper (implemented; VZ serial gate not passed)` -- excerpt lost the structural identity line
- `docs/roadmap.md`:174-174 -- changed-symbol `Milestone 1.5 — interactive kernel monitor (current)` -- excerpt lost the structural identity line
- `docs/roadmap.md`:212-212 -- changed-symbol `Later milestones (sketches only, not commitments)` -- excerpt lost the changed region (changed-line neighborhood)
- `kernel/src/evidence.zig`:603-603 -- changed-symbol `fw_mmu_capture_diag` -- excerpt lost the structural identity line
- `kernel/src/virtio_console.zig`:165-165 -- changed-symbol `virtio_pci_init` -- excerpt lost the structural identity line
- `docs/architecture.md`:9-9 -- changed-symbol `Current state` -- excerpt lost the structural identity line
- `docs/architecture.md`:48-48 -- changed-symbol `Data flow` -- excerpt lost the structural identity line
- `docs/architecture.md`:67-67 -- changed-symbol `Interfaces` -- excerpt lost the structural identity line
- `docs/hardware-contract.md`:179-179 -- changed-symbol `MMIO / serial console (UART)` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/claims/README.md`:56-56 -- changed-symbol `Active claims index` -- excerpt lost the structural identity line
- `docs/logs/README.md`:36-36 -- changed-symbol `Log index` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/testing.md`:34-34 -- changed-symbol `Verification sequence` -- excerpt lost the structural identity line
- `docs/testing.md`:159-159 -- changed-symbol `Results log (as verified on the development host)` -- excerpt lost the structural identity line
- `docs/gate-inventory.md`:27-27 -- changed-symbol `Gate table` -- excerpt lost the structural identity line
- `docs/gate-inventory.md`:71-71 -- changed-symbol `Machine-readable records` -- excerpt lost the structural identity line
- `docs/logs/freebuff-start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2.md`:1-1 -- changed-symbol `Log — freebuff/start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2` -- excerpt lost the structural identity line
- `docs/march-m15.md`:1-1 -- changed-symbol `M1.5 march — Interactive Kernel Monitor (living tracker)` -- excerpt lost the structural identity line

## Stale-context warnings

- `docs/claims/0017-preexit-virtio-tx.md`:21-77 -- mentions `virtio_pci_init` -- mentions changed symbol but not updated in range -- Claim: M1.5 — pre-ExitBootServices virtio-pci console TX experiment (diagnostic) > Notes
- `docs/claims/0018-postexit-tx-bisect.md`:88-139 -- mentions `BOOTS` -- mentions changed symbol but not updated in range -- Claim: M1.5 — post-exit virtio TX failure bisect with per-stage NVRAM markers > Result (2026-08-07) — 12 identical boots, bisect complete
- `docs/claims/0021-fw-mmu-capture.md`:72-119 -- mentions `fw_mmu_capture_diag` -- mentions changed symbol but not updated in range -- Claim: M2 — firmware MMU-state capture: TTBR0/1, MAIR, TCR + virtio BAR-window descriptor walk (diagnostic) > Result (2026-08-07) — firmware mapping recorded; attributes match the kernel's
- `docs/claims/0023-mainzig-module-split.md`:18-49 -- mentions `virtio_pci_init` -- mentions changed symbol but not updated in range -- Claim: mechanical split of kernel/src/main.zig into hardware modules > Notes > Module boundaries (moved verbatim, only import/name plumbing changes)
- `docs/logs/agent-buffy-m15-milestone-docs.md`:1-45 -- mentions `Next steps` -- mentions changed symbol but not updated in range -- Log — `agent/buffy/m15-milestone-docs`
- `docs/m2-vz-serial-gate-prompt.md`:135-174 -- mentions `Verification sequence` -- mentions changed symbol but not updated in range -- Milestone 1.5 — the VZ serial/MMU gate run (M1.5 march step 8, claim 0002) > Verification sequence (run in order; save every output)
- filtered generic symbols (no hints generated): `Current state` (generic-heading (appears in 4 documents)), `DipshitOS` (project-name; generic-heading (appears in 27 documents); ubiquitous (appears in 27 documents)), `Gate status` (generic-heading (appears in 3 documents)), `Notes` (generic-heading (appears in 35 documents); ubiquitous (appears in 35 documents)), `The guest` (generic-heading (appears in 6 documents)), `build` (ubiquitous (appears in 59 documents)), `install_identity_map` (ubiquitous (appears in 13 documents))

## Selection summary

- candidates considered: 161
- selected: 50
- rejected: 151
- budget utilization: 39896 / 40000 (99.7%)
- candidate content cost: 24279 chars (sum of selected block costs, before framing)
- note: mandatory content exceeded budget; excerpts were safely truncated to stay under budget
- baseline (naive impact-ranked) would select 12 at 39974 candidate chars
- diversity selector improved: changed_files, changed_symbols, relevant_docs vs baseline

## Rejected candidates (explain)

- `docs/claims/6460-t0sz16-start-level.md`:27-93 -- reason:changed-symbol -- score 14.6 cost 4358 -- budget pressure (mandatory content truncated to fit)
- `tools/verify-t0sz16.sh`:94-275 -- reason:changed-symbol -- score 14.5 cost 9096 -- budget pressure (needs 9096 chars, 5217 remaining) mandatory deferred
- `docs/claims/0176-ragshit-review-coverage-truncation.md`:9-40 -- reason:changed-symbol -- score 14.2 cost 2700 -- budget pressure (mandatory content truncated to fit)
- `docs/claims/7256-status-postmmu-reconcile.md`:9-49 -- reason:changed-symbol -- score 14.2 cost 3734 -- budget pressure (mandatory content truncated to fit)
- `README.md`:1-53 -- reason:changed-symbol -- score 14.1 cost 3225 -- budget pressure (needs 3225 chars, 659 remaining) mandatory deferred
- `README.md`:54-74 -- reason:changed-symbol -- score 14.1 cost 1572 -- budget pressure (needs 1572 chars, 659 remaining) mandatory deferred
- `README.md`:161-196 -- reason:changed-symbol -- score 14.1 cost 3609 -- budget pressure (needs 3609 chars, 659 remaining) mandatory deferred
- `README.md`:197-219 -- reason:changed-symbol -- score 14.1 cost 1692 -- budget pressure (needs 1692 chars, 659 remaining) mandatory deferred
- `README.md`:226-252 -- reason:changed-symbol -- score 14.1 cost 1905 -- budget pressure (needs 1905 chars, 659 remaining) mandatory deferred
- `docs/claims/3320-ragshit-dogfood-hardening.md`:1-8 -- reason:changed-symbol -- score 14.1 cost 1750 -- budget pressure (needs 1750 chars, 659 remaining) mandatory deferred
- `docs/claims/3320-ragshit-dogfood-hardening.md`:9-21 -- reason:changed-symbol -- score 14.1 cost 2199 -- budget pressure (mandatory content truncated to fit)
- `build.zig`:1-247 -- reason:changed-symbol -- score 13.9 cost 16176 -- budget pressure (needs 16176 chars, 659 remaining) mandatory deferred
- `kernel/src/mmu.zig`:1-35 -- reason:changed-symbol -- score 13.8 cost 1976 -- budget pressure (needs 1976 chars, 659 remaining) mandatory deferred
- `kernel/src/mmu.zig`:43-48 -- reason:changed-symbol -- score 13.8 cost 662 -- budget pressure (needs 662 chars, 659 remaining) mandatory deferred
- `kernel/src/mmu.zig`:356-421 -- reason:changed-symbol -- score 13.8 cost 4127 -- budget pressure (needs 4127 chars, 659 remaining) mandatory deferred
- `docs/status.md`:43-63 -- reason:changed-symbol -- score 13.3 cost 3691 -- budget pressure (needs 3691 chars, 659 remaining) mandatory deferred
- `docs/status.md`:64-69 -- reason:changed-symbol -- score 13.3 cost 2528 -- budget pressure (needs 2528 chars, 659 remaining) mandatory deferred
- `docs/status.md`:70-183 -- reason:changed-symbol -- score 13.3 cost 7527 -- budget pressure (needs 7527 chars, 659 remaining) mandatory deferred
- `docs/status.md`:230-240 -- reason:changed-symbol -- score 13.3 cost 1558 -- budget pressure (needs 1558 chars, 659 remaining) mandatory deferred
- `docs/status.md`:250-260 -- reason:changed-symbol -- score 13.3 cost 1749 -- budget pressure (needs 1749 chars, 659 remaining) mandatory deferred

## Determinism

- schema: ragshit.review/v1
- timing_ms is 0 (real timing on stderr); output is byte-identical for unchanged repo/index/range/args

stats: {'commits': 12, 'files_changed': 49, 'symbols_touched': 72, 'neighbors': 80, 'stale_hints': 6, 'candidates_considered': 161, 'candidates_selected': 50, 'candidates_rejected': 151} -- index HEAD: 2f20e5aaad57 -- deterministic
