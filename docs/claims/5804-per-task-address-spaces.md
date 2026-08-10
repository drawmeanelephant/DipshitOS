# Claim: per-task user address spaces (TTBR0 per task, EL1-only kernel overlay)

- **Owner:** Buffy (`agent/buffy/m3-addrspaces`)
- **Prompt / plan:** milestone-three march card 4 ([`docs/march-m3.md`](../march-m3.md)),
  following the uaccess card (claim 6120). Card text: per-task user
  address spaces — **TTBR0 per task**, **kernel in TTBR1**, **UXN/PXN
  enforced**, **MMIO excluded from EL0**.
- **Scope:** the milestone-three address-space split. **VZ TTBR1
  fallback:** the original kernel-in-TTBR1 KVA-shadow design was measured
  incompatible on real VZ hardware (see the verification section), so the
  kernel stays identity-mapped in TTBR0 (TTBR1=0) and per-task isolation
  comes from switching TTBR0 between roots that all carry an **EL1-only
  kernel overlay**: the EL1h shell/worker share the plain **kernel root**
  (identity map, zero EL0 leaves); the EL0 task's **user root** is a clone
  of the identity tree with its text+stack leaves overlaid at the fixed
  user VAs — so EL0 can reach ONLY those leaves (kernel RAM, firmware, and
  MMIO are EL1-only AP=0b00 → permission faults), with UXN/PXN (W^X) on
  every user leaf. The scheduler switches TTBR0 on every context switch;
  runtime services (SetVariable/ResetSystem) run under the kernel root;
  uaccess regions are per-task user VAs; a new `addrspaces` monitor command
  + class-B live gate prove the split on real VZ hardware.
- **Depends on:** claim 6120 (uaccess EFAULT window — now VA-based), claims
  8215/5275 (EL0 task + scheduler — now per-address-space), 9746/9187
  (vectors + timer IRQ — must keep working across TTBR0 switches), 3594
  (syscall ABI), 0013/1517 (identity-map + T0SZ=16 transport reliability),
  0527/0011 (runtime services — must survive the address-space move).
- **Status:** ✅ done 2026-08-10

## Notes

**Why this card is the milestone's hinge:** since claim 8215, EL0
permissions are overlaid on the single identity map — the kernel and user
share TTBR0, so every task can in principle see the whole 4 GiB blanket and
the device windows. Card 4 splits the world per task: TTBR0 belongs to the
current task, and every root carries the kernel (EL1-only), so switching
TTBR0 cannot strand the kernel. The user root's EL0-accessible leaves are
exactly user text (EL0 R/X, PXN — EL1 cannot execute it) and user stack
(EL0 RW, UXN+PXN); a Device address under the user root is EL1-only and an
EL0 access takes a permission fault — never a device access.

**Why the TTBR1 fallback (measured on VZ, 2026-08-10):**

1. **4 KiB-aligned tables → the TTBR1 walker faults at the FIRST descent
   level in every configuration.** Shared L0 root (T1SZ=16): level-1 fault
   with a valid L0/L1 chain. Dedicated 48-bit L0 root: level-1 again.
   Dedicated 39-bit L1-rooted mirror (T1SZ=25, `KVA_BASE = 2^64 − 2^39`):
   level-2 fault with a provably-valid L1/L2 chain (the mirror contents
   were dumped from the live tables and verified). The signature — the
   first descent always faults no matter what the tables contain — matches
   a walker masking table addresses to 64 KiB.
2. **64 KiB-aligned tables → the walk resolves but Normal-WB data aborts.**
   With every table in a 64 KiB-aligned slot the TTBR1 walk of block AND
   page leaves resolves (Device leaf reads succeeded), but a Normal-WB data
   access through TTBR1 aborts: a TLB conflict abort (DFSC=0x10), then —
   after extra inner-shareable invalidations — a synchronous external abort
   (DFSC=0x21) on the kernel's code pages. A kernel executing from a KVA
   shadow cannot work on VZ.

**Design decisions (all verified against the codebase):**

1. **Kernel identity-mapped in TTBR0; TTBR1=0.** The install programs
   MAIR/TCR (T0SZ=16, T1SZ=25 with TTBR1=0 — no TTBR1 region), TTBR0 = the
   kernel root, full TLBI, and continues at identity addresses. No jump, no
   `kva_active`, no second map; `to_kva`/`to_phys` are the identity.
2. **Per-task TTBR0 with an EL1-only kernel overlay.** The Task TCB gains
   `ttbr0` (physical root). The EL1h shell + worker use the **kernel root**
   (the identity map — also the root runtime services run under); the EL0
   task uses the **user root** = `clone_into_user_root` (a recursive clone
   of the identity tree, splitting any 2 MiB block that straddles a user
   aperture) with the text+stack pages overlaid with EL0 leaves. The
   overlay's leaves keep the identity AP=0b00 (EL1-only), so the kernel
   stays reachable under the user root while EL0 is denied. `apply_pending`
   (tick/yield/exit) writes TTBR0 + full TLBI on every switch. The
   payload's `elr`/`sp_el0`/witness `x9` stay user VAs (the scheduler's
   `to_phys`-based conversion is the identity now).
3. **MMIO excluded from EL0 by AP, not absence.** The user root's Device
   leaves (the identity MMIO overlay) are EL1-only; an EL0 access takes a
   permission fault. `walk_leaves` counts `el0_leaves` (AP != 0b00) and
   `el0_device_leaves`; the gate asserts `el0_device=0`.
4. **uaccess stays VA-based.** The EL0 apertures are the user VAs
   (`userspace.text_va`/`stack_va`); the copy loops dereference user VAs
   through the loaded TTBR0, and the claim-6120 fault window is unchanged.
   The monitor `uaccess` diag temporarily installs the user root so its
   validated copy genuinely reads the user text through the user mapping.
5. **Device-facing addresses need no translation** (identity), so the
   mmio/virtio/runtime-services conversions from the original design remain
   correct under the fallback.

**Verification:** class A (unit tests: scheduler per-task roots + user-VA
frame, userspace user-VA helpers, uaccess VA regions, monitor `addrspaces`
command + registry, updated transcript fixture with the new help line,
full portable set). Class B: new `tools/verify-live-addrspaces.sh` —
boots the production image, drives `addrspaces` + `uaccess` + `tasks` and
asserts TTBR1=0 (T0SZ=16), the EL1h tasks on the kernel root, the EL0 task
on its OWN root, the user root's EL0-accessible leaves >= text+stack with
`el0_device=0` (MMIO excluded from EL0), and a recovered EL1 fault on the
uaccess raw copy; **PASS 1/1** on VZ with all live regressions green
(uaccess, svc, userspace, tasks, timer, exceptions, transcript — each 1/1).
Translation/hardware assumptions recorded in
[`docs/hardware-contract.md`](../hardware-contract.md) and the
[ADR 0007 amendment](../decisions/0007-syscall-abi.md).
