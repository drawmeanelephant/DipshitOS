# Milestone-two gate run: the VZ serial/MMU takeover gate

Planning-first agent prompt for DipshitOS. Feed this file to the
implementing agent. This prompt is about **running and honestly recording**
the decisive hardware gate — it does not implement new kernel features.

- Branch: `agent/buffy/m2-kernel-proper` (suggested)
- Date: 2026-08-06
- Inputs (read first; they are binding): `AGENTS.md`, `docs/status.md`,
  `docs/testing.md`, `docs/hardware-contract.md`,
  `docs/decisions/0004-kernel-proper.md`,
  `docs/m2-kernel-proper-design.md` (especially §4 and §6)

---

You are working on DipshitOS, a from-scratch AArch64 operating system
(freestanding Zig guest, Swift + Virtualization.framework host on Apple
M4 / macOS 27, no QEMU path). Read the inputs before doing anything; they
are binding.

## The gate (ADR 0004 D6; `docs/status.md`)

The primary milestone-two gate: after a VZ boot, `vm-serial.log` — empty in
every prior run — must contain:

1. The exact banner `DipshitOS kernel has seized control.`
2. A `memory-map descriptors=0x...` line (plus descriptor size/version/key)
3. The `kernel terminal state` marker (the kernel entered its terminal WFE
   loop and did **not** return to the stub)

The kernel is already implemented to produce this output when a usable
serial transport exists (probe → PL011/16550/virtio selection, ADR 0004 D4
and `docs/m2-kernel-proper-design.md` §4).

## Scope

Run the gate on the real Apple M4 / macOS 27 host and record the result
honestly. **Run this after `docs/m2-bad-handoff-fix-prompt.md` lands:**
`docs/status.md` records the hypothesis that the two unpassed gates share
an early-crash root cause — if that holds, a serial run before the fix
cannot distinguish "no serial device" from "kernel died early", so the
run is only interpretable after step 1. Specifically:

- Run the full verification sequence from `docs/testing.md`, saving every
  command's output under `artifacts/` and the **complete** `vm-serial.log`.
- Analyze the serial log against the probe design: which candidate MMIO
  windows were read (the pre-exit map observed `0x01000000..0x01010000` and
  `0x20050000..0x20051000` — range evidence only), which signatures were
  found, which transport was selected, and what the kernel printed.
- Update the evidence-tagged docs (`docs/status.md`, `docs/testing.md`,
  `docs/hardware-contract.md`) only with what the log proves.

**Contingency — do not fake a pass.** If the run produces no banner
(no serial device found, or the probe fails), do **not** modify the kernel
to force output and do **not** claim success. Report the precise blocked
step per AGENTS.md and keep every hardware assumption `[inferred]`. The
ADR 0004 D4 fixed-memory-marker fallback (host-side dump of the kernel's
BSS `takeover_marker`) is a **separate** prompt — not part of this one.

## Process rule: observe-first (hard gate)

1. Read the binding docs; restate in your plan the exact evidence you
   expect for each possible outcome (banner / partial output / no output).
2. Run the build gates, then the VZ run. Save output verbatim.
3. Analyze the logs against the probe design **before** touching any
   evidence-tagged doc.
4. Then update docs with observed facts only.

## Verification gates

1. Build gates pass first: `zig fmt --check boot/src/main.zig
   kernel/src/main.zig build.zig`, `zig build`, `zig build image`,
   `zig build inspect`, `swift build --package-path host/vm-runner`,
   `zig build context`.
2. The run output is saved verbatim as `artifacts/m2-vz-run*.txt` and the
   complete serial log as `artifacts/vm-serial.log` (plus any probe log).
3. Every `[inferred] → [observed]` flip in `docs/hardware-contract.md`
   quotes the matching log line. No flip without a log.
4. `docs/status.md` gate table updated with the outcome and evidence file
   names; `docs/testing.md` results log updated to match.

## Outcomes

- **Pass:** banner + map line + terminal marker observed. Flip the matching
  contract entries, mark the VZ serial gate passed in `docs/status.md` /
  `docs/testing.md`, and report the milestone-two result honestly.
- **Blocked:** no banner. Record exactly what was observed, keep every
  `[inferred]` tag, and name the blocked step and the fallback prompt that
  follows.

## Definition of done

- The gate has been run on Apple M4 / macOS 27 with saved evidence.
- `docs/status.md` and `docs/testing.md` reflect the true outcome.
- Hardware-contract tags match the evidence exactly — no observed without a
  log, no inferred where a log exists.
- No kernel feature was added in this step; nothing was fabricated.
