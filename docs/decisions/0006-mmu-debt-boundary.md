# ADR 0006: The MMU debt boundary — the no-TLBI takeover is a contract, not a completed VM subsystem

Status: **accepted (superseded in part 2026-08-08, claim 1517)** · Date: 2026-08-07 · Milestone: two

> **Claim-1517 supersession (2026-08-08): the no-TLBI crutch is PAID.** Claims
> 6460 + 7896 proved on real VZ hardware that the no-TLBI survival was only
> stale-firmware-TLB interference masking a real translation defect (the
> L0-rooted tables were walked with a start-level mismatch: T0SZ=25/W=39
> starts the 4 KiB stage-1 walk at level 1). Claim 1517 lands the production
> fix: T0SZ=16 (correct start level, walk starts at level 0 matching the
> built hierarchy) and `tlbi vmalle1; dsb ish; isb` at the switch — the
> first post-switch access now deterministically re-walks correct tables
> (cell B, claim 7896: 9/9 boots complete the whole post-MMU console path;
> claim 1517: the `zig build run` serial gate passes). The **invalidation
> list below remains binding** (descriptors still never change post-switch,
> and any re-mapping milestone must revisit it); the no-TLBI *mechanism* and
> its validity window are superseded — see the
> [claim-1517 contract](#claim-1517-supersession-the-debt-is-paid).

## Context

Milestone two's `install_identity_map()` (ADR 0004 D3) takes over the MMU by
writing MAIR_EL1, TCR_EL1, TTBR0_EL1 and — deliberately — **not** executing
any `tlbi`. Claim 0010 root-caused why: on Apple Virtualization.framework a
`tlbi vmalle1` at the switch forces a page-table re-walk that faults on every
observed VZ run, while omitting it lets the takeover complete (the marker
ladder advances `M2_MAPD! → M2_MMUP!`). Claim 0020 then proved the switch
itself is the transition that destroys guest access to the virtio-pci
console (phase B works, phase C hangs), and claim 0021 showed the firmware's
memory attributes for both RAM and the BAR are byte-identical to the
kernel's choices — so the debt is real and its mechanism is not an attribute
mismatch.

This ADR exists because "MMU takeover fixed" (claim 0010, hardware contract)
must **not** be readable as "TLB invalidation and remapping are proven". They
are not. Skipping the TLBI is safe only inside a narrow, explicit validity
window; the moment later kernel code steps outside it, the stale-TLB-entry
argument collapses and the VZ re-walk fault (uncharacterized) becomes a
correctness bug. This ADR fixes the boundary precisely so later agents know
what they may and may not assume.

## What the kernel actually guarantees (the contract)

`install_identity_map()` + the takeover path guarantee exactly this:

1. After the switch, the low address space (VA < 4 GiB, the "blanket") is
   covered by the kernel's tables: declared RAM maps Normal Write-Back,
   everything else maps Device nGnRnE. The kernel image, stack, handoff,
   map buffer and page tables all resolve Normal.
2. No descriptor in those tables is ever changed after the switch (this
   milestone never re-maps anything).
3. Because (1) and (2) hold, the firmware's TLB entries still resident after
   the switch — never invalidated — resolve identically to the new
   descriptors (VA == PA, same attributes), so skipping the TLBI is
   observationally harmless.
4. Above the blanket (VA ≥ 4 GiB), only EFI-declared regions and the virtio
   BAR window are mapped (Device), and **the milestone promises to touch
   none of them after the switch beyond what claim 0020 already measured**
   (the first post-switch read of the BAR window hangs — observed).

None of this is a general-purpose virtual-memory subsystem. There is no
allocator, no mmap/unmap, no permissions model, no ASID management, no
TTBR1 space, no user/kernel split, no TLB management of any kind.

## The safety argument and its validity window

The stale-firmware-TLB-entry argument is valid only while **all** of these
hold:

- **(S1)** No TLBI has executed since the switch (the firmware's TLB state
  is whatever `msr ttbr0_el1` left it, uncharacterized on VZ).
- **(S2)** Every translation the firmware may still hold stale resolves to
  the same VA → PA and the same effective attributes as the new descriptor.
  Below the blanket this is argued (identity + same attributes, claim 0021
  confirms RAM and MMIO attributes match); above the blanket it is **not**
  established — the firmware's 1 GiB block for the BAR window (claim 0021)
  differs structurally from the kernel's 4 K pages, and the post-switch read
  of that window hangs (claim 0020).
- **(S3)** The new tables are cache-coherent before first use (D-cache
  cleaned over the 512 KiB carve-out; claim 0010).
- **(S4)** The new descriptors never change (no re-mapping).

Outside this window, the argument is void: a stale entry would answer a
walk it no longer matches, and on VZ the alternative — a forced re-walk —
is the observed fault.

## Layers of certainty (architectural fact vs VZ observation vs assumption)

**Architectural facts (ARM ARM, not VZ-specific):**

- A `tlbi` is *required* before a translation that is still cached in the
  TLB may be changed; without it the old entry can persist indefinitely and
  answer accesses with stale translations/attributes.
- Descriptor changes are not visible to the walker until the relevant TLB
  entries are invalidated (and any cache-coherent walk of the new
  descriptors is correct only after the tables are clean).
- The TLB is not architecturally flushed by `msr ttbr0_el1` alone.

**VZ observations (this repo, claims 0009/0010/0020/0021):**

- A `tlbi vmalle1` at the switch forces a re-walk that faults (ladder stops
  at `M2_TTBR!`); the mechanism is uncharacterized.
- Omitting the TLBI, the takeover completes and post-switch runtime
  `SetVariable` + RAM access work.
- The first post-switch MMIO read of the virtio BAR window (above the
  blanket) does not return, while the same read pre-switch works.
- The firmware maps the BAR window as a 1 GiB Device block (identity,
  XN=1) and RAM as Normal WB pages; its memory-attribute bytes match the
  kernel's choices.

**Assumptions (recorded, not yet observed):**

- The firmware's TLB contents at the moment of the switch (what is cached).
- That every stale entry is identity-compatible below the blanket (argued
  from the firmware map, not dumped).
- That VZ's behavior is stable across firmware/macOS updates.

## What invalidates the safety argument (binding list)

Any of the following, performed after the switch, voids S2/S4 and therefore
the whole no-TLBI contract. Later milestones MUST NOT do any of these
without first characterizing the VZ re-walk fault and reintroducing TLB
management correctly (a dedicated claim; see the boundary statement):

1. **Descriptor changes** — modifying any entry in the installed tables
   (re-mapping a VA, changing granularity).
2. **Permission/attribute changes** — altering AF, AP, MAIR index, SH, XN,
   PXN, or shareability of any mapped region.
3. **Page reclamation** — returning a mapped page to a pool and later
   re-mapping it with a different meaning (the old entry can still be
   resident).
4. **Non-identity mappings** — any VA != PA translation (the stale
   firmware identity entries then answer the wrong address).
5. **ASID / address-space work** — `TLBI ASIDE1*`-class operations, TTBR1
   adoption, address-space switching, or any context that makes TLB entries
   selective.
6. **Unmapping** — removing any translation the firmware may still hold
   stale (including firmware regions we mapped Device to keep reachable).
7. **Mappings above the blanket** — the claim-0020 BAR hang is the live
   example: the firmware's block descriptor differs structurally from our
   4 K pages, and the first post-switch access already fails. Any new
   above-blanket mapping inherits this unresolved behavior.
8. **TCR/MAIR changes** — changing T0SZ/TG0/IPS or the MAIR attribute
   bytes after the switch invalidates the "same effective attributes" half
   of S2.

## Rules for later milestones

- The no-TLBI invariant is **load-bearing**: a change that makes it unsafe
  (the list above) must come with the VZ re-walk characterization and a
  correct TLBI/remap design in the SAME change, plus a regression gate.
- `tools/verify-mmu-debt.sh` (deterministic, no VM) fails CI if the
  contract is eroded: the no-TLBI comment in `install_identity_map()`, the
  blanket constant, the "map never changes descriptors post-switch"
  statement, and this ADR's invalidation list must all be present.
  **Limitation (stated):** the gate is a documentation/comment grep — it
  detects erosion of the *contract surface*, not a functional regression;
  re-adding a TLBI while keeping the comments would pass it, and a comment
  re-wrap can break it spuriously. It is the deterministic complement to
  the VZ ladder evidence (claims 0009/0010), not a substitute for it.
- Claim 0021's firmware capture is the reference for "the firmware's
  mapping of X"; any remap of a firmware-mapped region above the blanket
  must be validated against it first.

## Consequences

- ADR 0004 D3's "Skipping the invalidate is safe because …" text is now a
  pointer to this ADR rather than a standalone justification.
- The hardware contract records the VZ re-walk fault and no-TLBI survival
  as **[observed]** and the boundary here as the controlling language.
- "MMU takeover fixed" now means exactly: the identity map installs and the
  current milestone's accesses work — **not** that TLB invalidation,
  remapping, unmapping, or any general VM capability is proven.

## Claim-1517 supersession — the debt is paid

**2026-08-08 (claim 1517).** The no-TLBI validity window above is closed by
landing the fix it was protecting against:

- **Corrected start level.** Production `install_identity_map()` programs
  T0SZ=16 (W=48) so the 4 KiB stage-1 walk starts at level 0, matching the
  built L0-rooted hierarchy. (The old T0SZ=25/W=39 started at level 1 over
  the same tables — the claim-6460/7896 start-level mismatch; `-Dt0sz25`
  keeps reproducing it for class-D regression.)
- **Full invalidation at the switch.** `tlbi vmalle1; dsb ish; isb` now
  ends the switch, so the first post-switch access deterministically
  re-walks the (correct, D-cache-cleaned) tables instead of riding stale
  firmware TLB entries. This is what the old S1 condition forbade; it is
  now safe because S2's "same effective attributes" half holds for real
  (the walk resolves), not by luck.
- **What is unchanged.** The tables are still built once, cleaned before the
  switch, and never modified post-switch. The invalidation list in
  [What invalidates the safety argument](#what-invalidates-the-safety-argument-binding-list)
  remains binding for later milestones: re-mapping, unmapping, permission
  changes, non-identity mappings, ASID work, and TCR/MAIR changes after the
  switch must come with their own TLBI design and a regression gate.
- **Evidence.** Claims 6460/7896 (class-D A/B + 4-cell matrix on real VZ
  hardware) and claim 1517 (`zig build run` serial gate, `verify-marker`,
  `verify-bad-handoff`, `verify-nvram-console` re-run green; artifacts
  cited in the claim).
