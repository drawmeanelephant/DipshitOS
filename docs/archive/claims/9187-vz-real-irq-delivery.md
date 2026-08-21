# Claim: Re-open VZ interrupt delivery with fresh host and guest evidence

- **Owner:** Codex (`codex/vz-real-irq-delivery`)
- **Prompt / plan:** user mission 2026-08-09 — verify the host-side VZ GIC premise at current HEAD, then test only materially distinct guest interrupt paths (CNTV, forced GICv2, and usable virtio interrupt signaling) until an IRQ is delivered or the current platform boundary is evidenced precisely
- **Scope:** read-only SDK/framework capability audit; bounded diagnostics in `kernel/src/gic.zig`, `kernel/src/timer.zig`, the kernel seam, and `tools/`; a live class-B IRQ-delivery gate if a path works; saved evidence under `artifacts/`; final reconciliation in `docs/status.md` and `docs/hardware-contract.md`. Preserve the poll-driven heartbeat until a real taken IRQ is observed.
- **Depends on:** claim 9746 (live EL1 vectors), claim 7948 (blocked GIC/CNTP baseline), claim 6420 (current `main` and virtio-blk transport)
- **Status:** ✅ done 2026-08-09 on `codex/vz-real-irq-delivery` — real periodic CNTP PPI delivery observed through the guest's EL1 IRQ vector; strict live gate passes 3/3 with `irq=5 poll=0`

## Notes

Deterministic claim ID from
`bash tools/status/claim-id.sh 'codex/vz-real-irq-delivery' 'vz-real-irq-delivery'`
= `9187`.

Success is one of the mission's three evidence-backed outcomes: a real IRQ
taken into the claim-9746 vector, a usable alternative interrupt source, or
a definitive current-VZ negative result with the exact host-side enabler and
runner change specified. Claim 7948 remains immutable history; this claim
supersedes only its premise check at current HEAD.

## Result

The first materially distinct path succeeded, so CNTV, forced GICv2, and
virtio interrupt experiments were not needed. Claim 7948's negative result
exposed three guest-driver defects; the redistributor offset error was the
one that blocked delivery:

- ACPI MADT ARM GIC structure IDs were shifted: GICC/GICD/GICR are
  `0x0B`/`0x0C`/`0x0E`, not `0x0C`/`0x0B`/`0x0D`; version values are
  `1..4`, not `0x10..0x30`.
- GICv3 SGI/PPI registers were addressed in the RD frame. They live in the
  redistributor's `+0x10000` SGI frame (`IGROUPR0=0x10080`,
  `ISENABLER0=0x10100`, `ICFGR1=0x10c04`). Xcode 27's public
  Hypervisor.framework header independently confirms those offsets.
- PPI 30's ICFGR field wrote `0b01`, setting its RES0 bit. The GTDT reports
  the timer as level-triggered (`edge=0`), so both field bits must be clear.

The shifted MADT IDs were masked on this host by the existing fixed-layout
fallback, and the invalid ICFGR write still left the architectural trigger
bit clear (level). They were corrected for specification compliance; the
missing `+0x10000` SGI-frame offset is what left PPI 30 disabled.

The corrected driver selects the boot CPU redistributor, configures the
GTDT-discovered PPI, and records IRQ-only versus diagnostic-poll ticks. The
old production idle-loop poll was removed after the first successful run
showed it racing working level IRQ delivery (`irq=3 poll=2` at tick 5).
The strict rerun requires the first-IRQ report and
`timer heartbeat ticks=5 irq=5 poll=0`; it passed 3/3 boots while the shell
answered a scripted `echo`. Each boot directly observed GICv3 bases
`0x10000000`/`0x10010000`, active frame `0x10010000`, fallback discovery,
PPI 30, and the 24 MHz counter.

The Xcode 27 audit found no public interrupt-injection/GIC configuration
surface in Virtualization.framework. Hypervisor.framework separately
exposes `hv_gic_create`, `hv_gic_set_spi`, and `hv_gic_send_msi`, but no
runner change or host injection was required.

Evidence: `artifacts/live-timer-gate.txt`,
`artifacts/live-timer-report.txt`, `artifacts/live-timer-serial-01.log`
through `-03.log`, `artifacts/vz-irq-api-audit.txt`, and
`artifacts/verify-portable-9187.txt`. The complete class-A command set is
green (run directly because `just` is not installed).
