# Claim: Root-cause and fix the `install_identity_map()` fault on VZ (MMU-takeover window)

- **Owner:** buffy (`freebuff/grab-newest-files-from-github-and-pick-something-t-a3eb337e-4b37-4bae-8548-242c49be7456`)
- **Prompt / plan:** follow-up named in claim 0009 ("root-cause the
  `install_identity_map()` fault on VZ (TCR/MAIR/TTBR0 sequence, or the first
  post-switch access)") and `docs/status.md` gate work item 2 / the
  hardware-contract "MMU-takeover window" finding
- **Scope:** M2 — `kernel/src/main.zig` (TCR_EL1 value, identity-map coverage
  and attributes, the MMU-switch barrier sequence); docs: `docs/status.md`,
  `docs/hardware-contract.md`, `docs/march-m15.md` step 8, `docs/testing.md`,
  `README.md`. No new milestones, no new features.
- **Depends on:** claim 0009 (NVRAM ladder gate, landed 2026-08-07) — the
  ladder is the verification channel for this fix
- **Status:** ✅ fixed 2026-08-07 — the MMU takeover completes on VZ; the
  ladder now reaches `M2_SERIA` (claim-0009's diagnostic prediction). The VZ
  serial gate's remaining blocker is isolated: no usable MMIO serial device
  in the declared windows.

## Root cause (observed, in order)

Claim 0009 showed the ladder always ending at `M2_MAPD!` (map built,
pre-install) — the kernel died in the MMU-takeover window. Claim 0010
discriminated the cause with three additive experiments, all gated by the
NVRAM ladder:

1. **TCR granule: ruled out (measured, not inferred).** A pre-switch
   register capture (second NVRAM variable `DipTCR`) recorded the firmware's
   own MMU file: `TCR_EL1=0x18080351c` (T0SZ=28, **TG0 at bits [15:14] =
   0b00 = 4 KB**), `SCTLR_EL1.M=1`, `ID_AA64MMFR0` PARange = 36-bit
   (`artifacts/m2-firmware-regs.txt`). The guest implements the ARMv8.1+
   layout, so the previous `1 << 8` was IRGN0, not TG0 — the granule was
   never wrong. The fixed TCR (`25 | (ips << 32)`, TG0 0b00 in both field
   positions) is kept defensively; IPS stays at bits [34:32] per Apple xnu
   `proc_reg.h` (`TCR_IPS_SHIFT 32`).
2. **Map coverage/attributes: the enabling half of the fix.** A host-side
   replay of `build_identity_map` against the real EFI map (`MEMMAP.TXT`)
   proved the descriptor-only map and even a Normal-blanket leave the
   firmware's runtime NVRAM controller (not declared in the EFI map)
   unmapped or Normal-cacheable — either of which kills the first post-switch
   `SetVariable` (the marker channel itself). The identity map now maps
   **declared RAM as Normal WB and everything else (incl. undeclared
   firmware MMIO) as Device nGnRnE**, 2 MiB blocks with 4 KiB granularity at
   region edges; a host-side walk verifies every kernel address resolves
   (`artifacts/m2-table-walk.txt`, 15/128 tables).
3. **The death site: `tlbi vmalle1` (the fix).** Bisect stages written
   between the switch steps proved: the switch completes and the first
   post-switch runtime call **succeeds** (`M2_TTBR!` present), but any
   re-walk *forced* by a `tlbi vmalle1` then faults on VZ — the ladder ended
   at `M2_TTBR!` with the TLBI present (`artifacts/m2-mmu-bisect-tlbi.txt`),
   and with the TLBI removed it advances `M2_TTBR! → M2_TLBI! → M2_MMUP! →
   M2_SERIA`. The TLBI is dropped at the switch: the stale firmware TLB
   entries are identity-compatible (same VA==PA; RAM Normal WB, MMIO
   Device), and the map never changes descriptors post-switch in this
   milestone. The D-cache is also cleaned over the 512 KiB table carve-out
   before the switch (architecturally correct hardening; not itself the
   fix — verified independently).

## Result

`bash tools/verify-marker.sh` (2026-08-07): ladder
`M2_ENTRY → M2_CMAP! → M2_PREX! → M2_EXIT! → M2_MAPD! → M2_MMUP! → M2_SERIA`
(`artifacts/m2-mmu-takeover-gate.txt`). The **MMU takeover now completes on
VZ** — the `M2_MMUP!` post-install stage appears for the first time — and the
serial probe runs to completion and finds no usable PL011/16550/virtio
device in the declared windows (`M2_SERIA`). This confirms claim 0009's
diagnostic prediction: the VZ serial gate's blocker is the **absence of a
usable MMIO serial device**, not a kernel crash. `docs/hardware-contract.md`
and `docs/status.md` updated accordingly.
