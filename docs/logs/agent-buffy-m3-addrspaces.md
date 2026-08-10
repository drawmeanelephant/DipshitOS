# Log — per-task user address spaces (claim 5804)

- **Branch:** `agent/buffy/m3-addrspaces`
- **Claim:** [`docs/claims/5804-per-task-address-spaces.md`](../claims/5804-per-task-address-spaces.md)
- **Started:** 2026-08-10

## Progress

- **Survey** (2026-08-10): read the MMU installer, linker, loader, handoff,
  scheduler TCBs, syscall/uaccess/userspace layers, virtio transports,
  runtime-services call sites, and the elf2bin/loader entry math. Key
  findings that shape the design:
  - `@intFromPtr` of a *linker-script extern* (e.g. `__user_text_start`)
    bakes the **link offset** (the codebase adds `base` to recover the
    runtime address — `userspace.text_region`), while `@intFromPtr` of a
    *module symbol* (a function, `&user_stack`) is **PC-relative** and
    resolves to the runtime address. A KVA jump changes the second class
    (runtime addresses become KVA) and not the first (offsets stay
    offsets) — the user-VA conversion math uses `base` + link offsets,
    computed pre-jump.
  - The identity tree doubles as the TTBR1 KVA shadow: with
    `KVA_BASE = 2^64 − 2^48 ≡ 0 (mod 2^39)`, every walk index (bits
    [47:12]) is identical for `X` and `KVA_BASE + X`, so TTBR1 = the same
    root resolves `KVA_BASE + X → X` for the whole 4 GiB blanket +
    device windows. No second kernel map is needed.
  - Device-facing DMA addresses in all three virtio transports are written
    as `@intFromPtr(kernel_buffer)` — identity pre-jump (correct) but KVA
    post-jump (wrong for the device); they need `to_phys`. The console TX
    flush writes `desc.addr` on every post-jump line, so this is
    load-bearing, not cosmetic.

- **Original design implemented** (2026-08-10): TTBR1 KVA shadow at
  `KVA_BASE + X` with per-task TTBR0; `mmu.zig` gained the KVA install +
  jump, `mmio.zig` routed through `to_kva`, the virtio transports + walkprobe
  converted to `to_phys`, runtime services wrapped in `with_kernel_root`,
  the scheduler gained per-task `ttbr0`, the uaccess regions became user
  VAs, and the `addrspaces` monitor command (registry 24) landed. Class-A
  green; the new live gate failed at the KVA jump with zero serial.

- **TTBR1 bisect on real VZ** (2026-08-10) — the findings that forced the
  fallback. A fault probe (vectors installed pre-switch, ESR/FAR persisted
  through the proven NVRAM marker channel) pinned the failures:
  1. T1SZ=16, shared L0 root: `DFSC=0x05` (level-1 translation fault)
     with a valid L0/L1 chain — even with all 512 L0 entries replicated.
  2. T1SZ=16, dedicated root: level-1 fault again.
  3. T1SZ=25 (`KVA_BASE = 2^64 − 2^39`), dedicated 39-bit L1-rooted mirror
     whose contents were dumped and PROVEN valid (L1[1] = L2 table,
     L2[497] = L3 table, L3[132] = the faulting page leaf): `DFSC=0x06`
     (level-2 fault) at block AND page leaves. The first-descent-always-
     faults signature = a walker masking table addresses to 64 KiB.
  4. With 64 KiB-aligned table slots: the walk RESOLVES (block and page
     leaves), but a Normal-WB data access through TTBR1 aborts — first a
     TLB conflict abort (`DFSC=0x10`), then, after extra inner-shareable
     invalidations, a synchronous external abort (`DFSC=0x21`) on the
     kernel's own code pages; Device leaf reads succeeded. Conclusion: a
     kernel executing from a TTBR1 KVA shadow cannot work on VZ.

- **VZ fallback implemented** (2026-08-10): kernel stays identity-mapped in
  TTBR0 (TTBR1=0); `build_user_root` became `clone_into_user_root` — a
  recursive clone of the identity tree with the user text+stack leaves
  overlaid at their user VAs (blocks straddling a user aperture are split);
  the scheduler switches TTBR0 per task; the `addrspaces` monitor command
  reports TTBR1=0, T0SZ=16, per-task TTBR0 roots, and the user root's
  `el0`/`el0_device` leaf counts; the live gate asserts `el0_device=0`
  (MMIO excluded from EL0 by the EL1-only AP bits). All bisect scaffolding
  removed.

- **Verification** (2026-08-10): class A green (fmt, 165 unit tests,
  byte-identical transcript with the updated help line, build/image,
  coordination). Class B: `verify-live-addrspaces` **PASS 1/1** — banner,
  EL0 payload (`uaccess: efault ok n=8`, `sys_write` counters), `uaccess`
  monitor line (`valid=1 fault=1 recovered=1`), `addrspaces` output
  (TTBR1=0, t0sz=16, shell/worker on the kernel root, user-el0 on its OWN
  root, `el0=4`, `el0_device=0`), `echo` reply, no parking. All live
  regressions green 1/1: uaccess, svc, userspace, tasks, timer, exceptions,
  transcript.

- **Docs reconciled** (2026-08-10): ADR 0007 amendment, hardware-contract
  TTBR1 bullet, gate inventory (live-addrspaces PASS), status item 11 +
  milestone row, march-m3 row 4 + lane D, roadmap next-card pointer, claim
  flipped to ✅, indexes refreshed.

## Status

✅ done 2026-08-10 — per-task TTBR0 with an EL1-only kernel overlay (VZ
TTBR1 fallback), UXN/PXN enforced, MMIO excluded from EL0; live gate + all
regressions green.
