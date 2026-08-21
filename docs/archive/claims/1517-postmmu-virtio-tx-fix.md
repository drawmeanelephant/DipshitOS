# Claim: M1.5 — post-MMU virtio-pci console TX production fix (pay the ADR-0006 debt: corrected start level T0SZ=16 + TLBI at the switch)

- **Owner:** buffy (`freebuff/pull-git-and-check-status-to-make-sure-everything--9934c25c-63ea-4cf3-b3fb-4b98fb81b9f4`)
- **Prompt / plan:** user request 2026-08-08 — "implement the next card you see": the canonical next item in `docs/status.md`'s ordering is **reliable post-MMU access to the already-discovered virtio-pci console transport (post-MMU virtio TX, class B)**. Claims 6460 + 7896 already characterized and separated the failure and named the deterministic fix direction; this claim implements it in production.
- **Scope:** production MMU/console fix — correct the 4 KiB stage-1 translation start level (production T0SZ 25→16, matching the built L0-rooted hierarchy) and execute `tlbi vmalle1; dsb ish; isb` at the switch (paying the ADR-0006 no-TLBI debt, now safe because the walk resolves). Diagnostic re-plumbing: `-Dt0sz16` option becomes `-Dt0sz25` (legacy start level, default off), `-Dtlbi-after-switch` removed (TLBI is now unconditional production behavior), `-Dwalk-probe` kept. Update the ADR-0006/ADR-0004-D3 contracts, hardware contract, status/roadmap/march/gate-inventory/testing/README docs, and the `verify-mmu-debt.sh` gate to the new contract. No RX, no allocator/GIC/timer/scheduler/fs/network/graphics.
- **Depends on:** claim 6460 (T0SZ 25→16 restored post-MMU TX in 6/18 boots — hypothesis strengthened), claim 7896 (start-level mismatch real + deterministic; the residual is stale-TLB interference, NOT a device hang — cell B: T0SZ=16 + TLBI → 9/9 complete; fix direction: T0SZ=16 + `tlbi vmalle1` works 100% on this host), claim 0020 (MMU switch destroys access under the old regime), claim 0021 (firmware T0SZ=28, attributes byte-identical), ADR 0006 (no-TLBI debt boundary — superseded by this change)
- **Status:** ✅ done 2026-08-08 — **the milestone-two VZ serial gate passes**: `zig build run` 3/3 boots put the exact banner `DipshitOS kernel has seized control.`, the `memory-map descriptors=0x…` print, `kernel terminal state`, and the live `dipshit>` prompt in `vm-serial.log` (evidence under `artifacts/claim-1517/` — `run{1,2,3}.txt`, `vm-serial-run{1,2,3}.log`). Production now programs T0SZ=16 (correct start level for the L0-rooted tables) and executes `tlbi vmalle1; dsb ish; isb` at the switch (ADR-0006 debt paid); `-Dt0sz25` reproduces the legacy start level for class-D regression. All class-A gates pass (fmt, 50 unit tests, transcript gate, builds/image/inspect/context, swift build, coordination, test-coordination 15/15, mmu-debt); class-B re-runs green (bad-handoff `kernel_rc=0x2`, marker ladder reaches `M2_TXNT!`, nvram-console, host-console); walk-probe matrix re-mapped and validated on hardware (cell A = legacy 25 faults deterministically wp-depth=0; cell B = production + probe completes wp-depth=6 with payload).

## Notes

**Why this card:** the milestone-two VZ serial gate (`zig build run`) has been
blocked since 2026-08-05: the first post-MMU virtio-pci transport read hung.
Claims 6460/7896 proved on real VZ hardware that the root cause is a
**translation start-level mismatch** — the tables are L0-rooted but
production T0SZ=25 (W=39) starts the 4 KiB stage-1 walk at level 1, so any
fresh walk faults, and the no-TLBI crutch (ADR 0006) only survived by riding
stale firmware TLB entries. The controlled experiment (cell B vs D) proved
an empty TLB + a correct walk (T0SZ=16) completes the ENTIRE post-MMU
console path 9/9 boots. This claim lands that as production.

**The fix:**

1. `kernel/src/mmu.zig`: `plan_t0sz` production value becomes 16 (walk starts
   at level 0, matching the built L0→L1→L2→L3 hierarchy; every mapped VA
   stays far below the 2^48 bound, so nothing else changes).
2. `install_identity_map()` now ends with `tlbi vmalle1; dsb ish; isb` — the
   first post-switch access must re-walk the (now correct) tables. ADR 0006's
   no-TLBI validity window is replaced by the corrected-translation +
   full-invalidation contract; the "descriptors never change post-switch"
   rule and the invalidation list remain binding.
3. Diagnostic re-plumbing so the class-D tooling stays coherent: `-Dt0sz25`
   (legacy start level, default off) replaces `-Dt0sz16`; `-Dtlbi-after-switch`
   is removed (it is production now); `-Dwalk-probe` stays.

**Verification (all observed 2026-08-08 on this Apple M4 / macOS 27 VZ host):**

- Class A (portable): fmt, 50 unit tests, transcript gate, `zig build`,
  image, inspect, swift runner build, context, coordination,
  test-coordination (15/15), and the updated `verify-mmu-debt.sh` all pass.
- Class B: `zig build run` (the milestone-two serial gate) passes **3/3
  boots** — exact banner + `memory-map descriptors=0x…` + `kernel terminal
  state` + live `dipshit>` prompt in `vm-serial.log`
  (`artifacts/claim-1517/`). `verify-bad-handoff.sh` (kernel_rc=0x2),
  `verify-marker.sh` (ladder reaches `M2_TXNT!`), `verify-nvram-console.sh`,
  `verify-host-console.sh` all re-run green.
- Class D: walk-probe matrix re-mapped to the new flags and validated on
  hardware — cell A (`-Dt0sz25`, legacy) faults deterministically at the
  first re-walk (wp-depth=0); cell B (production + `-Dwalk-probe`)
  completes the full battery (wp-depth=6) and phase-C TX.
- KERNEL.BIN default build changed with this claim (was sha
  `55325752…` at the old T0SZ=25/no-TLBI default; the new production
  default is T0SZ=16 + TLBI).
