# Log — `agent/buffy/m15-milestone-docs`

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-07** — **Claim (buffy, `agent/buffy/m15-milestone-docs`):**
  claimed march step 20 (close the milestone honestly) as
  `docs/claims/0012-m15-milestone-docs.md`. Branch created from current
  `origin/main` (`d1d5df9`, post license PR #21; claims 0009/0010 landed).
  Scope: docs-only pointer-level refresh of README/roadmap/architecture/
  testing to the 2026-08-07 reality (marker ladder, MMU-takeover fix, M1.5
  monitor, transcript gate, host console) with `docs/status.md` as the
  canonical source; regen `artifacts/context.md`; close-out checklist
  logged; verify-coordination green. Not touching status.md / march-m15.md
  / kernel / host / tools / build.zig / justfile / any gate. 🔄 in
  progress — no doc edits yet.
- **2026-08-07** — **M1.5 milestone docs done (buffy,
  `agent/buffy/m15-milestone-docs`):** refreshed the four outer docs to
  the 2026-08-07 state of `main` with pointer-level edits linking to
  `docs/status.md` as canonical. README: Observed-behavior bullet now
  lists the passing gates (verify-bad-handoff, verify-marker / NVRAM
  ladder, test-console transcript gate, verify-host-console) and the
  M1.5 monitor; Next steps lead with device discovery + RX path, then
  the VZ serial gate itself, and fixed a glued-in `## Next steps`
  heading. Roadmap: milestone-two heading no longer says "VZ gate
  blocked" as a label — implemented, VZ serial gate not passed, blocker
  isolated to device absence (claims 0009/0010); M1.5 section and Later
  milestones lead with device discovery / RX / allocator. Architecture:
  Current state gains the marker ladder + MMU fix + M1.5 monitor;
  data-flow diagram labels now read probe-ran-to-completion
  (`layout=none`), monitor-loop-parked (RX not wired), NVRAM ladder as
  the evidence channel; console interface bullet updated. Testing:
  verification sequence renumbered to 16 steps and now documents the
  real gate set (verify-unit-tests, test-console/verify-transcript,
  run, verify-bad-handoff, verify-marker, verify-host-console,
  verify-coordination) plus a no-VM/VM gate-set summary; VZ serial gate
  results row updated to "not passed, blocker isolated" with the claim
  0010 evidence files. **Observed:** `zig build context` regenerated
  `artifacts/context.md` (323 KiB, deterministic); no kernel/host/tools/
  build.zig/justfile/gate edits; `docs/status.md` and `docs/march-m15.md`
  untouched. Note: a parallel Freebuff docs-tightening branch
  (`freebuff/can-you-look-through-the-documentation-…`) also edits
  README/roadmap/architecture and is not on `origin/main` — merges may
  need reconciliation; the context snapshot gets one final regen at
  close-out per the prompt. ✅

## Milestone close-out checklist (for the final integrator)

What remains before M1.5 can be tagged as closed (per `docs/status.md`
hard gates + `docs/march-m15.md` step 20) — the milestone-close prose
itself is the integrator's job, not this claim's:

1. **Serial gate / device discovery** — find the VZ virtio-console
   register file or a documented console fallback; the probe runs to
   completion but selects no usable MMIO serial device (`M2_SERIA`,
   claims 0009/0010). Hard gate: `zig build run` reaching `dipshit>`.
2. **RX path** — wire kernel `readByte` to a real device register and
   prove host keystrokes reach the guest end to end (hard gate: "Host
   keystrokes reach the kernel"). Until then the transcript gate stays
   mock-level and the kernel's `readByte` is a no-RX stub.
3. **Hard gate 5 (fs commands)** — re-scoped decision: deferred to a
   storage-driver milestone (march step 15); `ls`/`cat`/`write` are out
   of scope and hard gate 5 stays open by design.
4. **Hard gate 6 (real VM reboot/shutdown)** — a real EFI Runtime
   Services `ResetSystem` mechanism shipped **after this branch was cut**
   (claim 0011, `kernel/src/machine.zig`: reboot→cold, shutdown→shutdown,
   `M2_RST!` NVRAM stage, WFE park; unit-proven arg construction). The
   gate stays open only because the live reset is unobserved — the kernel
   halts at `M2_SERIA` (claim 0002) before the monitor runs. Live gate
   flips on an observed VZ reset.
5. **Live `vm-serial.log` half of step 19** — assert the transcript bytes
   in a live serial log once a console transport exists (mock half is
   gated and passing).
6. **Final `docs/status.md` milestone-close prose** — flip M1.5 position
   row to done, close hard gates (note claim 0011 for gate 6), and note
   the milestone in the changelog; `docs/march-m15.md` step 20 row to ✅;
   final `zig build context` regen after all merges settle;
   `bash tools/verify-coordination.sh` green.

> **Note added during rebase onto `origin/main` (2026-08-07):** the
> parallel docs-tightening branch merged (Apple-VZ identity, claim-0010
> wording) and claim 0011 (real `ResetSystem` machine controls) landed
> after this branch was cut; conflicts reconciled by keeping both sides'
> substance. This log's earlier "not implemented" machine-controls wording
> is superseded by the claim-0011 note above.
