# Review packet

Git range: `HEAD~5..HEAD`
Base: `HEAD~5` (`938d068cac03`)
Head: `HEAD` (`2f20e5aaad57`)
Index HEAD: `2f20e5aaad57`
Budget: 60000 chars
Actual size: 57357 chars

## Coverage summary

- changed_files: 29 / 49 (59%) (7 weak)
- changed_symbols: 44 / 68 (64%) (12 weak)
- decision_docs: 6 / 35 (17%) (1 weak)
- high_risk_files: 13 / 16 (81%) (5 weak)
- related_tests: 0 / 0 (100%)
- relevant_docs: 18 / 56 (32%) (5 weak)
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

### docs/claims/8623-docs-reconciliation-m15-status.md:1-3
reason: changed-symbol
covers: changed_file:docs/claims/8623-docs-reconciliation-m15-status.md, changed_symbol:Claim: Docs-only reconciliation — make status.md / march-m15.md reflect already-landed evidence, high_risk:docs/claims/8623-docs-reconciliation-m15-status.md, symbol_range:docs/claims/8623-docs-reconciliation-m15-status.md:1-8
score: 15.00
cost: 849 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Claim: Docs-only reconciliation — make status.md / march-m15.md reflect already-landed evidence

```markdown
# Claim: Docs-only reconciliation — make status.md / march-m15.md reflect already-landed evidence

- **Owner:** buffy (`freebuff/docs-reconciliation-m15-status-20260808`)
... [truncated 4 line(s) omitted -- retained 3 of 7 line(s)]
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
cost: 971 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Claim: M1.5 — T0SZ start-level diagnostic: does correcting the 4 KiB translation initial lookup level (T0SZ 25→16) restore post-MMU virtio-pci console TX? (class-D experiment)

```markdown
# Claim: M1.5 — T0SZ start-level diagnostic: does correcting the 4 KiB translation initial lookup level (T0SZ 25→16) restore post-MMU virtio-pci console TX? (class-D experiment)
... [truncated 24 line(s) omitted -- retained 1 of 25 line(s)]
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

### docs/claims/0176-ragshit-review-coverage-truncation.md:1-3
reason: changed-symbol
covers: changed_file:docs/claims/0176-ragshit-review-coverage-truncation.md, changed_symbol:Claim: Ragshit `review` — decision-useful coverage under hard budget truncation, high_risk:docs/claims/0176-ragshit-review-coverage-truncation.md, symbol_range:docs/claims/0176-ragshit-review-coverage-truncation.md:1-8
score: 14.21
cost: 865 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Claim: Ragshit `review` — decision-useful coverage under hard budget truncation

```markdown
# Claim: Ragshit `review` — decision-useful coverage under hard budget truncation

- **Owner:** buffy (`freebuff/start-from-current-dipshitos-main-record-the-exact-af2bed0e-1f29-49ea-b233-bf528e5ce88e`)
... [truncated 4 line(s) omitted -- retained 3 of 7 line(s)]
```

### docs/claims/7256-status-postmmu-reconcile.md:1-3
reason: changed-symbol
covers: changed_file:docs/claims/7256-status-postmmu-reconcile.md, changed_symbol:Claim: Docs-only reconciliation follow-up — post-MMU blocker wording + newest landed evidence (claim 6460) across stable-context docs, high_risk:docs/claims/7256-status-postmmu-reconcile.md, symbol_range:docs/claims/7256-status-postmmu-reconcile.md:1-8
score: 14.21
cost: 987 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Claim: Docs-only reconciliation follow-up — post-MMU blocker wording + newest landed evidence (claim 6460) across stable-context docs

```markdown
# Claim: Docs-only reconciliation follow-up — post-MMU blocker wording + newest landed evidence (claim 6460) across stable-context docs

- **Owner:** buffy (`freebuff/start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2`)
... [truncated 4 line(s) omitted -- retained 3 of 7 line(s)]
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

### README.md:54-72
reason: changed-symbol
covers: changed_file:README.md, changed_symbol:The guest, high_risk:README.md, symbol_range:README.md:54-74
score: 14.07
cost: 794 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: The guest

```markdown
## The guest

... [truncated 12 line(s) omitted]
installs identity TTBR0_EL1 tables, probes PL011/16550/virtio-MMIO candidates,
and is designed to print the takeover banner and enter a terminal WFE loop
(**not yet observed on VZ** — post-MMU access to the virtio-pci console
transport hangs; see `docs/status.md`). Its fixed page tables and virtio queue storage are BSS
carve-outs; there is no general allocator or libc/POSIX. Milestone 1.5 adds
... [truncated 13 line(s) omitted -- retained 7 of 20 line(s)]
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

### docs/claims/3320-ragshit-dogfood-hardening.md:1-3
reason: changed-symbol
covers: changed_file:docs/claims/3320-ragshit-dogfood-hardening.md, changed_symbol:Claim: Ragshit review dogfood-hardening — honest accounting, coverage, stale filter, shell importance, high_risk:docs/claims/3320-ragshit-dogfood-hardening.md, symbol_range:docs/claims/3320-ragshit-dogfood-hardening.md:1-8
score: 14.07
cost: 895 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Claim: Ragshit review dogfood-hardening — honest accounting, coverage, stale filter, shell importance

```markdown
# Claim: Ragshit review dogfood-hardening — honest accounting, coverage, stale filter, shell importance

- **Owner:** buffy (`freebuff/you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d`)
... [truncated 4 line(s) omitted -- retained 3 of 7 line(s)]
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

### docs/status.md:64-67
reason: changed-symbol
covers: changed_file:docs/status.md, changed_symbol:Current blocker (canonical — one description, one ordering), high_risk:docs/status.md, symbol_range:docs/status.md:64-69
score: 13.29
cost: 2286 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Current blocker (canonical — one description, one ordering)

```markdown
### Current blocker (canonical — one description, one ordering)

**Blocker — reliable post-MMU access to the already-discovered virtio-pci console transport (class B) is required before live RX and a real interactive `dipshit>` session.** The console is a modern virtio-pci device (bus 0 D5 `0x1af4/0x1043`, BAR0 `0x100010000`, claim 0013); the transport arms pre-exit (`M2_READY`) and TX works pre-exit (claim 0017) and post-ExitBootServices on the firmware translation (claim 0020 phase B), but **hangs on the first post-MMU BAR/common-config read after the DipshitOS identity-map install** (claims 0018/0020, phase C/D). ExitBootServices itself is exonerated; the MMU switch (B→C) is the transition that destroys access (claim 0020). Firmware and kernel memory attributes are byte-identical (claim 0021), so the hang is not an attribute mismatch; the no-TLBI safety contract and its validity window are in **ADR 0006** (claim 0022). The **NVRAM fallback console (claim 0015)** carries post-exit bytes via runtime `SetVariable` (69–70 chunks, shell + commands observed) but is not the virtio serial pipe; the **mock transcript (`zig build test-console`, class A)** is a portable host test, not VZ hardware. Ordering is explicit: **post-MMU virtio TX first, then virtio RX / live transcript** — RX cannot bypass the unresolved TX/MMU layer. Newest diagnostic on this exact layer (claim 6460, class D, 2026-08-08): correcting the T0SZ start-level mismatch (25→16) restored end-to-end post-MMU TX in 6/18 boots across three runs — hypothesis strengthened, not reproducible; production T0SZ stays 25 (see `docs/gate-inventory.md`). Class definitions: `docs/gate-inventory.md` (class A = portable/CI, class B = Apple-silicon/VZ hardware, class C = interactive, class D = diagnostic); a green CI badge proves class A only.

... [truncated 1 line(s) omitted -- retained 4 of 5 line(s)]
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

### docs/status.md:230-238
reason: changed-symbol
covers: changed_file:docs/status.md, changed_symbol:Hard gates (acceptance criteria), high_risk:docs/status.md, symbol_range:docs/status.md:230-240
score: 13.29
cost: 1267 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Hard gates (acceptance criteria)

```markdown
### Hard gates (acceptance criteria)

... [truncated 2 line(s) omitted]
- [ ] Host keystrokes reach the kernel (RX path closed end to end).
- [ ] At least ten commands work.
- [ ] `ls`, `cat`, and `write` persist through reboot — **deferred by decision (march step 15, 2026-08-06):** filesystem commands are deferred to a storage-driver milestone; post-exit there is no ESP root / Simple File System (x3 carries handoff v2, ADR 0004 D5), so a pre-exit file window or a real storage driver is required — no `ls`/`cat`/`write` in this stream. See `docs/march-m15.md` step 15.
- [ ] A scripted console session passes automatically (asserting in `vm-serial.log`).
- [ ] The VM can reboot or shut down from the shell. *(Real EFI `ResetSystem` mechanism shipped + unit-proven — claim 0011; the live gate stays open until a VZ reset is actually observed.)*
... [truncated 3 line(s) omitted -- retained 7 of 10 line(s)]
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

### docs/status.md:424-439
reason: changed-symbol
covers: changed_file:docs/status.md, changed_symbol:Related docs, high_risk:docs/status.md, symbol_range:docs/status.md:424-439
score: 13.29
cost: 989 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Related docs

```markdown
## Related docs

... [truncated 10 line(s) omitted]
- [`m15-host-plumbing-prompt.md`](m15-host-plumbing-prompt.md) — prompt (agent A): duplex serial attachment, teeing, terminal safety, `zig build console`.
- [`m15-commands-prompt.md`](m15-commands-prompt.md) — prompt (agent C): command registry, identity/memory/utility/control commands, personality (mock-console based).
- [`decisions/`](decisions/) — ADRs 0001–0006 (binding: 0004 kernel proper, 0005 runtime-built function tables, 0006 MMU debt boundary).
- [`../AGENTS.md`](../AGENTS.md) — project rules (now including the multiagent coordination rules).
... [truncated 10 line(s) omitted -- retained 6 of 16 line(s)]
```

### docs/roadmap.md:62-87
reason: changed-symbol
covers: changed_file:docs/roadmap.md, changed_symbol:Milestone two — the kernel proper (implemented; VZ serial gate not passed), high_risk:docs/roadmap.md, symbol_range:docs/roadmap.md:62-88
score: 12.46
cost: 979 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Milestone two — the kernel proper (implemented; VZ serial gate not passed)

```markdown
## Milestone two — the kernel proper (implemented; VZ serial gate not passed)

... [truncated 18 line(s) omitted]
decoded the declared windows (Apple's efivars store + an internal debug
UART) and found the real console — a virtio-pci device outside them — but
post-MMU access to its transport hangs on VZ (the MMU switch destroys
access, claim 0020), which remains the VZ serial gate's blocker. The canonical, always-current gate table lives in
[`docs/status.md`](status.md).

... [truncated 18 line(s) omitted -- retained 8 of 26 line(s)]
```

### docs/roadmap.md:174-209
reason: changed-symbol
covers: changed_file:docs/roadmap.md, changed_symbol:Milestone 1.5 — interactive kernel monitor (current), high_risk:docs/roadmap.md, symbol_range:docs/roadmap.md:174-211
score: 12.46
cost: 790 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Milestone 1.5 — interactive kernel monitor (current)

```markdown
## Milestone 1.5 — interactive kernel monitor (current)
... [truncated 20 line(s) omitted]
remains ⛔ blocked on post-MMU access to the virtio transport, so live
... [truncated 12 line(s) omitted]
on post-MMU access to the virtio-pci console transport — reliable
post-MMU transport access and the RX path are the next steps (see
... [truncated 33 line(s) omitted -- retained 4 of 37 line(s)]
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

### kernel/src/evidence.zig:603-664
reason: changed-symbol
covers: changed_file:kernel/src/evidence.zig, changed_symbol:fw_mmu_capture_diag, high_risk:kernel/src/evidence.zig, symbol_range:kernel/src/evidence.zig:603-681
score: 12.46
cost: 873 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: fw_mmu_capture_diag

```zig
pub fn fw_mmu_capture_diag(st: *const SystemTable, handoff_rec: *const handoff.HandoffV2, vp_ready: bool, vp_bar0: u64) void {
... [truncated 53 line(s) omitted]
    // The kernel's planned values, for the host-side diff. T0SZ is
    // mmu.plan_t0sz (production 25; claim-6460 -Dt0sz16 selects 16), so the
    // capture reports the true planned TCR in both variants.
... [truncated 4 line(s) omitted]
    mmu_hex(mmu.plan_t0sz | (ips << 32));
... [truncated 74 line(s) omitted -- retained 5 of 79 line(s)]
```

### kernel/src/virtio_console.zig:165-262
reason: changed-symbol
covers: changed_file:kernel/src/virtio_console.zig, changed_symbol:virtio_pci_init, high_risk:kernel/src/virtio_console.zig, symbol_range:kernel/src/virtio_console.zig:165-395
score: 12.46
cost: 936 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: virtio_pci_init

```zig
pub fn virtio_pci_init(st: *const SystemTable) bool {
... [truncated 91 line(s) omitted]
    // unreachable pre-exit (observed: after rebasing to 0x10000, reads of
... [truncated 1 line(s) omitted]
    // the low address). The firmware-assigned base is used for setup and
    // mapped in place post-switch (mmu.zig); no post-exit rebase runs — the
    // attempt was abandoned because post-exit config writes cannot move the
    // BAR on VZ (claims 0013/0020, docs/hardware-contract.md).
... [truncated 225 line(s) omitted -- retained 6 of 231 line(s)]
```

### docs/architecture.md:9-31
reason: changed-symbol
covers: changed_file:docs/architecture.md, changed_symbol:Current state, high_risk:docs/architecture.md, symbol_range:docs/architecture.md:9-36
score: 12.37
cost: 753 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Current state

```markdown
## Current state
... [truncated 13 line(s) omitted]
now completes on VZ; claim 0013 found the real console (a virtio-pci
... [truncated 1 line(s) omitted]
blocker is post-MMU access to its transport (claims 0018/0020), not a
crash. Milestone 1.5
... [truncated 4 line(s) omitted]
serial channel is still blocked on post-MMU console transport access / RX.
... [truncated 22 line(s) omitted -- retained 5 of 27 line(s)]
```

### docs/architecture.md:48-65
reason: changed-symbol
covers: changed_file:docs/architecture.md, changed_symbol:Data flow, high_risk:docs/architecture.md, symbol_range:docs/architecture.md:48-66
score: 12.37
cost: 1050 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Data flow

```markdown
## Data flow

```
... [truncated 10 line(s) omitted]
             │  milestone two: ExitBootServices, identity-map MMU
             │  post-exit evidence channel: NVRAM ladder (EFI var DipshitM2) ──▶ artifacts/efi-vars.bin  [observed: reaches M2_MMUP! → M2_SERIA]
             └── serial probe ──▶ declared windows decoded (efivars store + debug UART, claim 0013); real console = virtio-pci @ BAR 0x100010000 ──▶ post-MMU transport access hangs ──▶ vm-serial.log empty
             └── M1.5 monitor loop (console/lineedit/tokenizer/shell) ──▶ exists, host-tested via MockConsole; parks in WFE on the real kernel (RX not wired — readByte is a no-RX stub)
```
... [truncated 10 line(s) omitted -- retained 8 of 18 line(s)]
```

### docs/architecture.md:67-92
reason: changed-symbol
covers: changed_file:docs/architecture.md, changed_symbol:Interfaces, high_risk:docs/architecture.md, symbol_range:docs/architecture.md:67-98
score: 12.37
cost: 798 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Interfaces

```markdown
## Interfaces
... [truncated 18 line(s) omitted]
  decoded them as Apple's efivars store + an internal debug UART and
  found the real console is a modern virtio-pci device (BAR
  `0x100010000`) whose post-MMU transport access hangs on VZ (claims
  0018/0020), so no console is driven on VZ yet and the register layout
... [truncated 2 line(s) omitted]
  reliable post-MMU console transport access + RX.
... [truncated 25 line(s) omitted -- retained 6 of 31 line(s)]
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

### docs/claims/README.md:56-96
reason: changed-symbol
covers: changed_file:docs/claims/README.md, changed_symbol:Active claims index, symbol_range:docs/claims/README.md:56-101
score: 11.99
cost: 2425 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Active claims index

```markdown
## Active claims index

**This table is the canonical index** (status included) and it is
... [truncated 31 line(s) omitted]
| [0176-ragshit-review-coverage-truncation](0176-ragshit-review-coverage-truncation.md) | buffy (`freebuff/start-from-current-dipshitos-main-record-the-exact-af2bed0e-1f29-49ea-b233-bf528e5ce88e`) | ✅ done 2026-08-08 — anchor-aware truncation + weak/truncated coverage landed (`tools/ragshit/src/ragshit/review/{candidates,coverage,selection,report}.py`, framing-loop plateau fix in `cli.py`); full suite 147 passed / 1 skipped, doctor ok, dogfood at 20k/30k/40k/60k with exact size accounting and byte-identical duplicate runs; before/after packets under `artifacts/ragshit-0176/` |
... [truncated 3 line(s) omitted]
| [3320-ragshit-dogfood-hardening](3320-ragshit-dogfood-hardening.md) | buffy (`freebuff/you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d`) | ✅ done 2026-08-08 — A/B/C/D/F/G landed; stale BAR-rebase comment corrected (E); suite 137 passed + 1 skipped, doctor/coordination/portable gates green; evidence under `artifacts/ragshit-dogfood-20260808/` |
| [4922-verify-ragshit-0176-landing](4922-verify-ragshit-0176-landing.md) | buffy (`freebuff/make-sure-git-main-is-current-7f307de5-d3c0-4d90-966c-3a4221ad4d24`) | 🔄 in progress — claim created before verification runs |
| [6460-t0sz16-start-level](6460-t0sz16-start-level.md) | buffy (`freebuff/t0sz16-startlevel-diag`) | ✅ done 2026-08-08 — **T0SZ=16 lets the first post-MMU virtio-pci TX complete end-to-end in 6/18 boots across three independent runs (2/6, 3/6, 1/6): phase C returns, `used.idx` advances, exact payload in `vm-serial.log`, kernel reaches the live `dipshit>` shell; 12/18 still hang at the same boundary — hypothesis strengthened, not reproducible** (evidence under `artifacts/t0sz16-compare-final.txt`, `t0sz16-report-baseline.txt`, `t0sz16-report-candidate-18.txt`, `t0sz16-gate.txt`, `t0sz16-{baseline,candidate}-{run,marker,serial}-*.{txt,log}`, `t0sz16-run{1,2,3}/` per-run batches) |
... [truncated 39 line(s) omitted -- retained 7 of 46 line(s)]
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

### docs/testing.md:34-62
reason: changed-symbol
covers: changed_file:docs/testing.md, changed_symbol:Verification sequence, symbol_range:docs/testing.md:34-128
score: 11.73
cost: 779 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Verification sequence

```markdown
## Verification sequence
... [truncated 23 line(s) omitted]
    pre-exit loader marker `\\BOOTED.TXT` remains required. `RC.TXT` is
    expected only for a deliberate pre-exit failure fixture, not success.
    **Currently not passed** — the VZ serial gate stays open (post-MMU
    access to the virtio-pci console transport hangs on VZ — the MMU switch
    destroys access, claim 0020; see `docs/status.md`).
... [truncated 88 line(s) omitted -- retained 6 of 94 line(s)]
```

### docs/testing.md:159-203
reason: changed-symbol
covers: changed_file:docs/testing.md, changed_symbol:Results log (as verified on the development host), symbol_range:docs/testing.md:159-212
score: 11.73
cost: 872 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Results log (as verified on the development host)

```markdown
## Results log (as verified on the development host)
... [truncated 21 line(s) omitted]
      as Apple's efivars store + an internal debug UART and found the real
      console is a virtio-pci device outside them).
      The remaining blocker is post-MMU access to that virtio-pci console
      transport (claims 0018/0020), not a crash.
... [truncated 18 line(s) omitted]
      blocker is post-MMU access to the virtio-pci console transport,
... [truncated 48 line(s) omitted -- retained 6 of 54 line(s)]
```

### docs/gate-inventory.md:27-57
reason: changed-symbol
covers: changed_file:docs/gate-inventory.md, changed_symbol:Gate table, symbol_range:docs/gate-inventory.md:27-70
score: 11.60
cost: 770 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Gate table

```markdown
## Gate table

... [truncated 24 line(s) omitted]
| `tx-transition` | D | diagnostic | no | no | yes | `bash tools/verify-tx-transition.sh` — claim 0020 |
| `fw-mmu-capture` | D | diagnostic | no | no | yes | `bash tools/verify-fw-mmu-capture.sh` — claim 0021 |
| `t0sz16` | D | diagnostic | no | no | yes | `bash tools/verify-t0sz16.sh` (mechanism: `zig build kernel -Dt0sz16`) — claim 6460 |

Notes:
... [truncated 36 line(s) omitted -- retained 7 of 43 line(s)]
```

### docs/gate-inventory.md:71-104
reason: changed-symbol
covers: changed_file:docs/gate-inventory.md, changed_symbol:Machine-readable records, symbol_range:docs/gate-inventory.md:71-104
score: 11.60
cost: 805 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Machine-readable records

```markdown
## Machine-readable records

... [truncated 28 line(s) omitted]
GATE id=tx-transition class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-tx-transition.sh
GATE id=fw-mmu-capture class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-fw-mmu-capture.sh
GATE id=t0sz16 class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-t0sz16.sh
<!-- GATE_INVENTORY:END -->
... [truncated 28 line(s) omitted -- retained 6 of 34 line(s)]
```

### docs/logs/freebuff-start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2.md:1-1
reason: changed-symbol
covers: changed_file:docs/logs/freebuff-start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2.md, changed_symbol:Log — freebuff/start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2, symbol_range:docs/logs/freebuff-start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2.md:1-13
score: 11.59
cost: 915 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Log — freebuff/start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2

```markdown
# Log — freebuff/start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2
... [truncated 12 line(s) omitted -- retained 1 of 13 line(s)]
```

### docs/logs/freebuff-start-from-current-dipshitos-main-record-the-exact-af2bed0e-1f29-49ea-b233-bf528e5ce88e.md:1-3
reason: changed-symbol
covers: changed_file:docs/logs/freebuff-start-from-current-dipshitos-main-record-the-exact-af2bed0e-1f29-49ea-b233-bf528e5ce88e.md, changed_symbol:Log — ragshit review coverage truncation (claim 0176), symbol_range:docs/logs/freebuff-start-from-current-dipshitos-main-record-the-exact-af2bed0e-1f29-49ea-b233-bf528e5ce88e.md:1-6
score: 11.53
cost: 1374 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Log — ragshit review coverage truncation (claim 0176)

```markdown
# Log — ragshit review coverage truncation (claim 0176)

- **2026-08-08** — *buffy (freebuff/start-from-current-dipshitos-main-record-the-exact-af2bed0e-1f29-49ea-b233-bf528e5ce88e)*: claimed 🔄 — start from current main `fff37a5e6af8476c273dc959aefce0f412e11554`; make `ragshit review` coverage claims decision-useful under mandatory-budget truncation (large changed structural symbol must not count as usefully covered on a one-line prefix). Claim file `docs/claims/0176-ragshit-review-coverage-truncation.md`; deterministic ID 0176 via `tools/status/claim-id.sh`. Evidence to land under `artifacts/` — before/after packets, test output, determinism byte-compare.
... [truncated 3 line(s) omitted -- retained 3 of 6 line(s)]
```

### docs/march-m15.md:1-29
reason: changed-symbol
covers: changed_file:docs/march-m15.md, changed_symbol:M1.5 march — Interactive Kernel Monitor (living tracker), symbol_range:docs/march-m15.md:1-41
score: 11.53
cost: 2100 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: M1.5 march — Interactive Kernel Monitor (living tracker)

```markdown
# M1.5 march — Interactive Kernel Monitor (living tracker)

> **Why this file exists:** the per-step tracker and the best-agent-split
... [truncated 16 line(s) omitted]
|---:|------|-------------------|--------|------------------|
| 1 | **Freeze the target.** Name it Milestone 1.5: Interactive Kernel Monitor. Keep the milestone-two kernel exactly as merged (no new firmware work). | Scope document says exactly what counts as done and what is deferred. | ✅ | `docs/status.md` is the scope/status doc (frozen 2026-08-06; see `docs/logs/m1.5-tracker.md`). |
| 2 | **Define the finish line.** Boot into a terminal, display a banner, accept commands at `dipshit>`, execute ≥ 10 useful commands. | Written acceptance checklist (in `docs/status.md`) prevents agents from wandering into scheduler astrology. | ✅ | Hard gates in `docs/status.md`; fs gate **deferred** to a storage-driver milestone (step 15, 2026-08-06; see `docs/logs/m1.5-tracker.md`). |
... [truncated 6 line(s) omitted]
| 9 | **Build a console abstraction.** `write`, `putc`, `flush` on top of the M2 `uart` module; `readByte` is the RX gap to close (step 4 host side + a guest RX path). | Kernel code stops caring which MMIO candidate carries the bytes. | ✅ | `Console.VTable` gained a polled `readByte: ?u8` (null = no input now); `MockConsole` gained a scripted input queue (`feed`/`readByte`, overflow-flagged). Host-tested (`artifacts/m15-shell-core-tests.txt`). Live RX stays gated on the VZ serial gate (claim 0002, ⛔ blocked; refined 2026-08-07 to post-MMU transport access, claims 0018/0020): the kernel adapter's `readByte` is an `[inferred]` no-RX stub — no device register read. |
... [truncated 33 line(s) omitted -- retained 7 of 40 line(s)]
```

### artifacts/docs-reconciliation-20260808/diff-stat.txt:1-1
reason: changed-symbol
covers: changed_file:artifacts/docs-reconciliation-20260808/diff-stat.txt, changed_symbol:artifacts/docs-reconciliation-20260808/diff-stat.txt, symbol_range:artifacts/docs-reconciliation-20260808/diff-stat.txt:1-5
score: 11.47
cost: 567 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: artifacts/docs-reconciliation-20260808/diff-stat.txt

```
 docs/claims/README.md |   1 +
... [truncated 4 line(s) omitted -- retained 1 of 5 line(s)]
```

### docs/logs/freebuff-you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d.md:1-3
reason: changed-symbol
covers: changed_file:docs/logs/freebuff-you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d.md, changed_symbol:Log — freebuff/you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d, symbol_range:docs/logs/freebuff-you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d.md:1-4
score: 11.40
cost: 1556 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: Log — freebuff/you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d

```markdown
# Log — freebuff/you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d

- **2026-08-08** — *buffy (freebuff/you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d)*: claimed → `ragshit review` dogfood-hardening (claim 3320): accounting honesty (A), coverage model (B), generic-symbol stale filter (C), shell symbol importance (D), BAR-rebase comment verification (E), dogfood assertion gate (F), optional language-tagged fences (G). Baseline reproduced on main 938d068: 163 candidates/40 selected, `Actual size 39787` vs `budget utilization 27570/40000`, `decision_docs 0/25`, `relevant_docs 0/39`, 20 generic stale warnings, shell-assignment mandatory domination. → 🔄 in progress.
... [truncated 1 line(s) omitted -- retained 3 of 4 line(s)]
```

### artifacts/docs-reconciliation-20260808/coordination-gate.txt:1-2
reason: changed-symbol
covers: changed_file:artifacts/docs-reconciliation-20260808/coordination-gate.txt, changed_symbol:artifacts/docs-reconciliation-20260808/coordination-gate.txt, symbol_range:artifacts/docs-reconciliation-20260808/coordination-gate.txt:1-2
score: 11.21
cost: 572 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: artifacts/docs-reconciliation-20260808/coordination-gate.txt

```
coordination indexes are in sync
verify-coordination: ok
```

### artifacts/docs-reconciliation-20260808/blocker-consistency-after.txt:1-1
reason: changed-symbol
covers: changed_file:artifacts/docs-reconciliation-20260808/blocker-consistency-after.txt, changed_symbol:artifacts/docs-reconciliation-20260808/blocker-consistency-after.txt, symbol_range:artifacts/docs-reconciliation-20260808/blocker-consistency-after.txt:1-1
score: 11.06
cost: 2039 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: artifacts/docs-reconciliation-20260808/blocker-consistency-after.txt

```
docs/status.md:66:**Blocker — reliable post-MMU access to the already-discovered virtio-pci console transport (class B) is required before live RX and a real interactive `dipshit>` session.** The console is a modern virtio-pci device (bus 0 D5 `0x1af4/0x1043`, BAR0 `0x100010000`, claim 0013); the transport arms pre-exit (`M2_READY`) and TX works pre-exit (claim 0017) and post-ExitBootServices on the firmware translation (claim 0020 phase B), but **hangs on the first post-MMU BAR/common-config read after the DipshitOS identity-map install** (claims 0018/0020, phase C/D). ExitBootServices itself is exonerated; the MMU switch (B→C) is the transition that destroys access (claim 0020). Firmware and kernel memory attributes are byte-identical (claim 0021), so the hang is not an attribute mismatch; the no-TLBI safety contract and its validity window are in **ADR 0006** (claim 0022). The **NVRAM fallback console (claim 0015)** carries post-exit bytes via runtime `SetVariable` (69–70 chunks, shell + commands observed) but is not the virtio serial pipe; the **mock transcript (`zig build test-console`, class A)** is a portable host test, not VZ hardware. Ordering is explicit: **post-MMU virtio TX first, then virtio RX / live transcript** — RX cannot bypass the unresolved TX/MMU layer. Class definitions: `docs/gate-inventory.md` (class A = portable/CI, class B = Apple-silicon/VZ hardware, class C = interactive, class D = diagnostic); a green CI badge proves class A only.
```

### artifacts/docs-reconciliation-20260808/index-check.txt:1-1
reason: changed-symbol
covers: changed_file:artifacts/docs-reconciliation-20260808/index-check.txt, changed_symbol:artifacts/docs-reconciliation-20260808/index-check.txt, symbol_range:artifacts/docs-reconciliation-20260808/index-check.txt:1-1
score: 11.06
cost: 518 chars
provenance: commit:2f20e5aaad571440ab88e8caf6a246a2e9329aab index:2f20e5aaad57
symbol: artifacts/docs-reconciliation-20260808/index-check.txt

```
coordination indexes are in sync
```

## Missing / weak coverage

- changed_files: missing `build.zig`, `docs/hardware-contract.md`, `docs/logs/README.md`, `tools/ragshit/CHANGELOG.md`, `tools/ragshit/README.md`, `tools/ragshit/docs/architecture.md`, `tools/ragshit/docs/ranking.md`, `tools/ragshit/src/ragshit/cli.py` (+12 more)
- changed_symbols: missing `Assumptions & gaps in this plan (checked against the merged `main`)`, `BASELINE_FLAGS`, `BOOTS`, `BRANCH`, `CANDIDATE_FLAGS`, `COMPARE`, `DIRTY`, `GATE_LOG` (+16 more)
- decision_docs: missing `docs/claims/0001-bad-handoff-gate.md`, `docs/claims/0002-vz-serial-gate.md`, `docs/claims/0003-m15-host-plumbing.md`, `docs/claims/0004-m15-console-shell-core.md`, `docs/claims/0005-m15-commands-personality.md`, `docs/claims/0006-status-machinery.md`, `docs/claims/0007-status-sharding-hardening.md`, `docs/claims/0008-m15-transcript-test.md` (+21 more)
- high_risk_files: missing `build.zig`, `tools/ragshit/README.md`, `tools/ragshit/src/ragshit/parsing/source.py`
- relevant_docs: missing `.github/PULL_REQUEST_TEMPLATE.md`, `AGENTS.md`, `docs/claims/0001-bad-handoff-gate.md`, `docs/claims/0002-vz-serial-gate.md`, `docs/claims/0003-m15-host-plumbing.md`, `docs/claims/0004-m15-console-shell-core.md`, `docs/claims/0005-m15-commands-personality.md`, `docs/claims/0006-status-machinery.md` (+30 more)
- stale_warnings: missing `docs/claims/0017-preexit-virtio-tx.md:virtio_pci_init`, `docs/claims/0018-postexit-tx-bisect.md:BOOTS`, `docs/claims/0021-fw-mmu-capture.md:fw_mmu_capture_diag`, `docs/claims/0023-mainzig-module-split.md:virtio_pci_init`, `docs/logs/agent-buffy-m15-milestone-docs.md:Next steps`, `docs/m2-vz-serial-gate-prompt.md:Verification sequence`

## Weak / truncated coverage

- `README.md`:161-161 -- changed-symbol `Verification results (observed on this development host)` -- excerpt lost the changed region (changed-line neighborhood)
- `README.md`:226-226 -- changed-symbol `Next steps` -- excerpt lost the changed region (changed-line neighborhood)
- `build.zig`:14-14 -- changed-symbol `build` -- excerpt lost the changed region (changed-line neighborhood)
- `kernel/src/mmu.zig`:356-356 -- changed-symbol `install_identity_map` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/status.md`:43-43 -- changed-symbol `Gate status` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/status.md`:70-70 -- changed-symbol `What we directly observe about the serial gate and the bad-handoff fix` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/status.md`:250-250 -- changed-symbol `What comes immediately afterward` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/status.md`:261-261 -- changed-symbol `Assumptions & gaps in this plan (checked against the merged `main`)` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/status.md`:365-365 -- changed-symbol `Immediate gate work (prerequisites for M1.5)` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/roadmap.md`:212-212 -- changed-symbol `Later milestones (sketches only, not commitments)` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/hardware-contract.md`:179-179 -- changed-symbol `MMIO / serial console (UART)` -- excerpt lost the changed region (changed-line neighborhood)
- `docs/logs/README.md`:36-36 -- changed-symbol `Log index` -- excerpt lost the changed region (changed-line neighborhood)

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
- selected: 56
- rejected: 140
- budget utilization: 57357 / 60000 (95.6%)
- candidate content cost: 45684 chars (sum of selected block costs, before framing)
- note: mandatory content exceeded budget; excerpts were safely truncated to stay under budget
- baseline (naive impact-ranked) would select 21 at 59951 candidate chars
- diversity selector improved: changed_files, changed_symbols, decision_docs, high_risk_files, relevant_docs vs baseline

## Rejected candidates (explain)

- `docs/claims/6460-t0sz16-start-level.md`:27-93 -- reason:changed-symbol -- score 14.6 cost 4358 -- budget pressure (mandatory content truncated to fit)
- `docs/claims/0176-ragshit-review-coverage-truncation.md`:9-40 -- reason:changed-symbol -- score 14.2 cost 2700 -- budget pressure (mandatory content truncated to fit)
- `docs/claims/7256-status-postmmu-reconcile.md`:9-49 -- reason:changed-symbol -- score 14.2 cost 3734 -- budget pressure (mandatory content truncated to fit)
- `docs/claims/3320-ragshit-dogfood-hardening.md`:9-21 -- reason:changed-symbol -- score 14.1 cost 2199 -- budget pressure (mandatory content truncated to fit)
- `build.zig`:1-247 -- reason:changed-symbol -- score 13.9 cost 16176 -- budget pressure (needs 16176 chars, 6562 remaining) mandatory deferred
- `kernel/src/mmu.zig`:356-421 -- reason:changed-symbol -- score 13.8 cost 4127 -- budget pressure (needs 4127 chars, 3924 remaining) mandatory deferred
- `docs/status.md`:43-63 -- reason:changed-symbol -- score 13.3 cost 3691 -- budget pressure (needs 3691 chars, 617 remaining) mandatory deferred
- `docs/status.md`:64-69 -- reason:changed-symbol -- score 13.3 cost 2528 -- budget pressure (needs 2528 chars, 617 remaining) mandatory deferred
- `docs/status.md`:70-183 -- reason:changed-symbol -- score 13.3 cost 7527 -- budget pressure (needs 7527 chars, 617 remaining) mandatory deferred
- `docs/status.md`:261-301 -- reason:changed-symbol -- score 13.3 cost 3103 -- budget pressure (needs 3103 chars, 617 remaining) mandatory deferred
- `docs/status.md`:365-404 -- reason:changed-symbol -- score 13.3 cost 3315 -- budget pressure (needs 3315 chars, 617 remaining) mandatory deferred
- `docs/status.md`:424-439 -- reason:changed-symbol -- score 13.3 cost 1925 -- budget pressure (needs 1925 chars, 617 remaining) mandatory deferred
- `docs/roadmap.md`:62-88 -- reason:changed-symbol -- score 12.5 cost 2026 -- budget pressure (needs 2026 chars, 617 remaining) mandatory deferred
- `docs/roadmap.md`:174-211 -- reason:changed-symbol -- score 12.5 cost 2579 -- budget pressure (needs 2579 chars, 617 remaining) mandatory deferred
- `docs/roadmap.md`:212-229 -- reason:changed-symbol -- score 12.5 cost 1418 -- budget pressure (needs 1418 chars, 617 remaining) mandatory deferred
- `kernel/src/evidence.zig`:603-681 -- reason:changed-symbol -- score 12.5 cost 2986 -- budget pressure (needs 2986 chars, 617 remaining) mandatory deferred
- `kernel/src/virtio_console.zig`:165-395 -- reason:changed-symbol -- score 12.5 cost 10512 -- budget pressure (needs 10512 chars, 617 remaining) mandatory deferred
- `docs/architecture.md`:9-36 -- reason:changed-symbol -- score 12.4 cost 2025 -- budget pressure (needs 2025 chars, 617 remaining) mandatory deferred
- `docs/architecture.md`:48-66 -- reason:changed-symbol -- score 12.4 cost 1459 -- budget pressure (needs 1459 chars, 617 remaining) mandatory deferred
- `docs/architecture.md`:67-98 -- reason:changed-symbol -- score 12.4 cost 2272 -- budget pressure (needs 2272 chars, 617 remaining) mandatory deferred

## Determinism

- schema: ragshit.review/v1
- timing_ms is 0 (real timing on stderr); output is byte-identical for unchanged repo/index/range/args

stats: {'commits': 12, 'files_changed': 49, 'symbols_touched': 72, 'neighbors': 80, 'stale_hints': 6, 'candidates_considered': 161, 'candidates_selected': 56, 'candidates_rejected': 140} -- index HEAD: 2f20e5aaad57 -- deterministic
