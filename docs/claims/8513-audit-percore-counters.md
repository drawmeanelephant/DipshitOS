# Claim: cross-core IRQ-context counter audit — every shared counter is now per-core (claim 7339 follow-up)

- **Owner:** buffy (`agent/buffy/audit-percore-counters`)
- **Prompt / plan:** audit the kernel for remaining process-wide globals written from exception context on secondary cores (like `handled_count_value`), and make the racy ones per-core or atomic
- **Scope:** IRQ/exception-context diagnostics on the multi-vCPU path; NOT the core-0-only scheduler pending-staging or the (also core-0) uaccess/SVC machinery
- **Touches:** kernel/src/exceptions.zig, kernel/src/gic.zig, kernel/src/virtio_custom.zig, kernel/src/main.zig, kernel/src/monitor.zig, docs/claims/8513-audit-percore-counters.md, docs/logs/agent-buffy-audit-percore-counters.md
- **Depends on:** claim 7339 (per-core resume handoff, issue #810) — merged
- **Heartbeat:** 2026-09-02
- **Status:** ✅ done

## Notes

**Audit result.** Walked the full secondary-core exception path (vector stub →
`exc_dispatch` → `irq_dispatch` → `handle_sgi`/`timer.arm`/`note_irq` → eoi)
and classified every module global it can write on cores 1–3:

- **Racy (fixed):** `exceptions.handled_count_value` (plain RMW `+= 1` at
  `exc_dispatch` entry on EVERY core), `gic.irqs_acked` + `gic.first_intid`
  (plain RMW from `note_irq` on every core's ack — secondary cores ack
  their own timer PPIs and any SGI in parallel with core 0).
- **Provably single-core today, hardened anyway:** `virtio_custom.irq_count`/
  `irq_first` — SPIs are IROUTER-pinned to PE 0 (`gic.arm_spi_window`), so
  core 0 is the only writer, but the irq_dispatch path is reachable on
  every core; per-core costs nothing and removes the trap if SPI routing
  ever becomes any-core (the #810 lesson: "provably single-core" is
  fragile).
- **Safe by construction (verified, not just assumed):** `timer.*` counters
  (only `timer.handle()` writes them, gated to core 0 by irq_dispatch;
  core 1 only re-arms per-core CNTP registers), `smp.ipi_counts` (each core
  increments its own row), `smp.core_ticks` (unwritten), `exceptions.
  resume_count_value`/`resume_armed` (will_resume path is sync-kind-only —
  secondary cores take only IRQs in their WFE loop), the dispatcher
  function pointers (`report_writer`, `irq_dispatcher`, `svc_dispatcher`,
  `fault_dispatcher` — single boot-time writer on core 0, read-only in
  exception context), and `uaccess.*` (SVC context, core 0 only).

**Fix.** Per-core arrays in all three modules, following the claim-7339
idiom: `exceptions.handled_count_value: [resume_cores]u64` (incremented at
dispatch entry via the already-computed `cidx`; `handled_count()` sums the
slots; the `[EXC]` report passes the summed total). gic and virtio_custom
each declare a literal `cpu_cores = 4` with the same comment as
`exceptions.resume_cores` (smp imports gic → gic cannot import smp) and a
host-guarded `core_index()` reading MPIDR_EL1.Aff0. `gic.note_irq` writes
`irqs_acked[cidx]`/`first_intid[cidx]`; the monitor `timer` line prints
`acked_total()` and `first_intid[0]` (PE-0 first is the meaningful boot
diagnostic — SPIs are pinned there). `virtio_custom.note_irq`/
`reset_irq_observation` are per-core; main.zig's cvspike observation
window reads slot 0 — the `cvspike: irq=.. first=0x45` line that
verify-cvc-echo/verify-custom-virtio pin is byte-identical (core 0 is the
only writer today).

**Evidence.** Full unit suite PASS (incl. virtio_custom counters, exceptions
handled-count), BSS budget PASS (511 208 B headroom), fmt/coordination
clean, and three class-B gates under plain exec: verify-live-zc **4/4**,
verify-cvc-echo **1/1** (guest-irq + `first=0x45` assertions green),
verify-live-vf **4/4**. All printed diagnostic lines unchanged in shape.

Verified: unit suite + BSS green; verify-live-zc 4/4, verify-cvc-echo 1/1,
verify-live-vf 4/4 plain-exec.