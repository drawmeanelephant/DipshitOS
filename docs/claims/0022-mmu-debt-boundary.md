# Claim: M2 — MMU debt boundary: precise contract for the no-TLBI takeover (ADR 0006 + hardware contract + deterministic gate)

- **Owner:** buffy (`freebuff/mmu-debt-contract`)
- **Prompt / plan:** task prompt 2026-08-07 — the kernel survives the VZ MMU
  takeover by omitting a TLBI that previously caused a forced re-walk
  failure; treat this as technical debt requiring a precise contract, not a
  completed general-purpose VM subsystem. Reconstruct what is OBSERVED,
  separate architectural facts from VZ observations and assumptions,
  enumerate exactly what later operations invalidate the safety argument,
  add a deterministic regression/diagnostic gate, and update
  ADR/hardware-contract language so later agents cannot read "MMU takeover
  fixed" as "TLB invalidation/remapping is proven". No new VM subsystem, no
  allocator, no future milestones.
- **Scope:** docs only + one deterministic gate. `docs/decisions/0006-mmu-debt-boundary.md`
  (new ADR), a pointer + warning in `docs/decisions/0004-kernel-proper.md`
  D3, `docs/hardware-contract.md` MMU section, new
  `tools/verify-mmu-debt.sh` (deterministic, no VM) wired into `justfile`
  and CI. NO kernel code changes, NO edit to `docs/status.md`.
- **Depends on:** claim 0009 (marker ladder), claim 0010 (TLBI root cause),
  claim 0020 (transition matrix — MMU switch is the killer), claim 0021
  (firmware MMU-state capture — feeds the "what is OBSERVED" reconstruction)
- **Status:** ✅ done 2026-08-07 — ADR 0006 landed, ADR 0004 D3 addendum + hardware-contract updated, deterministic `verify-mmu-debt` gate wired into just verify + CI (evidence under `artifacts/mmu-debt-gate.txt`)

## Notes

**The debt (from claim 0010 + `kernel/src/main.zig` `install_identity_map`):**
the switch installs the kernel's identity map without any `tlbi`. Skipping
the invalidate is safe ONLY while the stale firmware TLB entries resolve
identically to the new descriptors (VA == PA below the 4 GiB blanket, RAM
Normal WB, MMIO Device) AND the new map never changes descriptors
post-switch. On VZ a TLBI-forced re-walk faults (observed, claim 0010);
the mechanism is uncharacterized. Claim 0020 adds a second observation: the
first post-switch MMIO read of the virtio BAR window — ABOVE the blanket,
mapped Device 4 K by the kernel — hangs, so the safety argument does not
cleanly extend above the blanket even though the map covers it.

**Task 1 — what is OBSERVED (reconstructed):**

- Firmware translation state before the switch: `TCR_EL1=0x18080351c`
  (T0SZ=28 → 2^36 VA space, TG0 bits [15:14] = 0b00 = 4 K granule,
  36-bit IPS), `SCTLR_EL1.M=1` (MMU on), guest is the ARMv8.1+ TCR layout
  (quoted from claim 0010; the raw `artifacts/m2-firmware-regs.txt` is
  missing from this checkout — re-captured by claim 0021).
- Table format: kernel builds its own 4 K-granule, 3-level (root + L1 + L2
  blocks; 4 K pages at region edges) identity tables in a fixed 512 KiB BSS
  carve-out; `T0SZ=25` (2^39 space) with the low 4 GiB "blanket" (2 MiB
  blocks, RAM Normal / everything else Device) plus explicit above-blanket
  Device maps for declared regions and the virtio BAR.
- Identity-map coverage: all of [0, 4 GiB) plus EFI-declared regions above
  the blanket; `mapped_normal()` consistency checks pass for the kernel
  image, stack, handoff, map buffer, tables.
- Where TLBI fails: claim 0010 bisect — with `tlbi vmalle1` at the switch
  the ladder ends at `M2_TTBR!` (post-TTBR write, post-TLBI) on every VZ
  run; without it the ladder advances to `M2_MMUP!` and beyond.
- Where skipping TLBI survives: the full takeover path — `M2_MAPD! →
  M2_MMUP! → M2_RAW!/M2_READY` — every run since claim 0010; post-switch
  runtime `SetVariable` (marker channel) and RAM access work.

**Task 2 — architectural facts vs VZ observations vs assumptions:** see ADR
0006's "Layers of certainty" section (facts: TLBI semantics, stale-entry
residency, descriptor-validity rules from the ARM ARM; VZ observations:
re-walk fault, no-TLBI survival, post-switch BAR read hang; assumptions:
firmware TLB contents at the switch, identity compatibility, map
immutability).

**Task 3 — operations that invalidate the safety argument (exhaustive
list):** descriptor changes (any entry re-write), permission/attribute
changes (AF/AP/MAIR/SH/XN), page reclamation (returning a mapped page to a
pool then re-mapping differently), non-identity mappings (VA != PA), ASID
or address-space changes (`TLBI ASIDE1`-class work, TTBR1 adoption),
unmapping any translation the firmware may still hold stale, and any new
mapping above the 4 GiB blanket whose attributes differ from what the
firmware had (the claim-0020 BAR hang is the live example). Each is
invalid because the stale firmware TLB entry — still resident because no
TLBI ran — would answer the walk instead of the new descriptor, and on VZ
the forced re-walk itself faults.

**Task 4 — deterministic gate:** `tools/verify-mmu-debt.sh` is a
documented, deterministic (no VM) gate that fails loudly if the debt
boundary is eroded: it asserts (a) ADR 0006 exists and contains the
invalidation list, (b) `docs/hardware-contract.md` carries the MMU-debt
pointer, and (c) `kernel/src/main.zig` still contains the no-TLBI safety
comment + the 4 GiB blanket constant + the "map never changes descriptors
post-switch" statement — so re-adding a TLBI or re-mapping code must
update the contract in the same change or CI fails.

**Task 5 — ADR/hardware-contract language:** new ADR 0006 records the debt
boundary and the "MMU takeover fixed ≠ TLB invalidation/remapping proven"
warning; ADR 0004 D3 gains a pointer to 0006; hardware-contract flips the
VZ re-walk fault and no-TLBI survival to [observed] and adds the debt
entry.

**Final output — "MMU debt boundary" statement (for the next status
review; docs/status.md itself is NOT edited):**

> **MMU debt boundary (claims 0010/0020/0021, ADR 0006):** the MMU
> takeover is a *contract, not a subsystem*: the kernel installs its own
> identity map and survives only by omitting the `tlbi vmalle1` that
> claims 0010/0020 proved faults on VZ (forced re-walk) and is the
> transition that destroys virtio-pci console access. The safety argument
> — stale firmware TLB entries are identity-compatible and the map never
> changes descriptors post-switch — is valid only below the 4 GiB
> blanket, only while no descriptor/attribute/unmap/ASID/non-identity
> change occurs, and only while the above-blanket regions (whose first
> post-switch read already hangs, claim 0020) stay untouched. Firmware
> and kernel memory attributes are byte-identical (claim 0021), so the
> hang is not an attribute mismatch and the VZ re-walk fault remains
> uncharacterized. "MMU takeover fixed" therefore means exactly: the
> identity map installs and the current milestone's accesses work — NOT
> that TLB invalidation, remapping, or unmapping is proven. Any later
> kernel operation that re-maps, unmaps, changes permissions, adds
> non-identity or above-blanket mappings, or does ASID work must first
> characterize the VZ re-walk fault and reintroduce TLB management
> correctly, in the same change, with `tools/verify-mmu-debt.sh` (CI)
> enforcing the boundary.

## Result (2026-08-07)

- **ADR 0006 `docs/decisions/0006-mmu-debt-boundary.md`** — new, accepted:
  the no-TLBI takeover as a precise contract — what the kernel actually
  guarantees, the safety argument (S1–S4) and its validity window, the
  three layers of certainty (architectural facts / VZ observations /
  assumptions), and the **binding invalidation list** (descriptor changes,
  permission/attribute changes, page reclamation, non-identity mappings,
  ASID/address-space work, unmapping, above-blanket mappings, TCR/MAIR
  changes).
- **ADR 0004 D3 addendum** — records that the `tlbi vmalle1` written in
  the original D3 is NOT executed, describes the actual switch sequence
  (mair → tcr → ttbr0 → isb → dsb ish → isb), and points to ADR 0006
  with the "MMU takeover fixed ≠ TLB invalidation proven" warning.
- **`docs/hardware-contract.md` MMU section** — the VZ re-walk fault /
  no-TLBI survival, the post-switch BAR hang, and the firmware
  translation state (claim 0021) are now **[observed]**; the debt
  boundary language and ADR 0006 pointer are recorded.
- **Deterministic gate `tools/verify-mmu-debt.sh`** (no VM, no build) —
  asserts ADR 0006 + its invalidation list, the ADR 0004 D3 addendum, the
  hardware-contract [observed] entries + warning, and the load-bearing
  kernel comments (no-TLBI, 4 GiB blanket constant, descriptors-immutable,
  stale-TLB argument) all remain present. Wired into `just verify` and CI
  (`bash tools/verify-mmu-debt.sh` step). Gate passes;
  `artifacts/mmu-debt-gate.txt`.
- **No kernel code changed by this claim; no edit to `docs/status.md`.**
