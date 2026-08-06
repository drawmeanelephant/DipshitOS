# Milestone 1.5 — commands & personality (agent C): registry, identity, memory, utilities, controls, and the elephant

Planning-first agent prompt for DipshitOS. Feed this file to the
implementing agent. It must produce a written plan **before** changing any
code. **Build against a mock console first** — this slice must not depend
on agent A's input proof or on the VZ serial gate outcome.

- Branch: `agent/.../m15-commands` (claim first via a claim file in
  `docs/claims/` + a log entry in `docs/logs/`; merge per ADR 0003)
- Date: 2026-08-06
- Inputs (read first; they are binding): `AGENTS.md`, `docs/status.md`,
  `docs/march-m15.md` (M1.5 steps 12–18, the "Best agent split" C row),
  the coordination rules + changelog (`docs/logs/`, `docs/claims/`),
  `docs/testing.md`, `docs/hardware-contract.md`,
  `docs/decisions/0002-kernel-handoff.md`,
  `docs/decisions/0004-kernel-proper.md`,
  `docs/m2-kernel-proper-design.md`, `kernel/src/main.zig`

---

You are working on DipshitOS, a from-scratch AArch64 operating system
(freestanding Zig guest, Swift + Virtualization.framework host, no QEMU
path). Milestone 1.5 makes the milestone-two kernel's terminal WFE loop
serve an interactive monitor (`dipshit>`). The monitor is the loop's
payload; the command layer must be portable and unit-testable **independent
of which MMIO console is real** (the serial gate outcome is unknown until it
runs — see `docs/m2-vz-serial-gate-prompt.md`).

All your code goes in **new kernel files** (e.g. `kernel/src/console.zig`
for the write/putc abstraction plus a test double, `kernel/src/monitor.zig`
for the registry and commands) so it cannot collide with agent A/B's edits
to `kernel/src/main.zig` and can be exercised with `zig test` on the host.

## Scope (steps 12–18 of `docs/march-m15.md`)

1. **Step 12 — command registry.** Name, help text, and function pointer per
   command; `help` generated from the registry. Adding commands must be
   mechanical.
2. **Step 13 — identity commands.** `help`, `about`, `version`, `uname`,
   `handoff` — the latter prints the handoff v2 struct the kernel received
   (kernel base/size, system table, image handle, stack bounds, flags).
3. **Step 14 — memory inspection.** `mem` from the **captured EFI map** (the
   kernel captured it before `ExitBootServices`; no `GetMemoryMap`
   post-exit): total conventional RAM, reserved regions, descriptor count,
   kernel bounds. Derive "256 MiB detected" from the map, not a constant.
4. **Step 15 — filesystem decision.** Do **not** implement ESP file access
   post-exit (the ESP root died with Boot Services; x3 carries handoff v2,
   not the root). Decide and record: a **pre-exit file window** vs. deferring
   fs commands to a storage-driver milestone. Fs commands are output-only at
   most. Record the decision in `docs/status.md` (hard gate 5 depends on it).
5. **Step 16 — shell utilities.** `echo`, `clear`, `hex`, `repeat`.
6. **Step 17 — machine controls.** `reboot`/`shutdown`/`halt` via the
   Runtime Services table captured pre-exit (`st.runtime_services →
   ResetSystem` survives `ExitBootServices`) or a documented fallback (WFE
   loop / VM teardown). Never claim power-off happened without evidence.
7. **Step 18 — personality.** `elephant` (operational mascot diagnostics),
   a rotating boot message, and one deeply stupid command (`beans`). 🐘
8. The `dipshit>` prompt rendering and banner.

## Do not

- Modify `kernel/src/main.zig`'s takeover path (ExitBootServices, MMU,
  probe, `uart_*`). The wiring of the monitor into the terminal loop
  happens later through the integration branch. New files only in this
  slice.
- Add an allocator, interrupts, timers, or storage drivers (milestone
  rules; no libc/POSIX).
- Claim any observed hardware behavior — everything here is built and tested
  against the mock console; hardware claims stay `[inferred]`.

## Process (hard gate)

1. **Claim before you start.** Create `docs/claims/<NNN>-m15-commands.md`
   from the TEMPLATE (owner/branch, 🔄) and append a log entry in
   `docs/logs/agent-...-m15-commands.md` *before* writing code.
2. Read the binding inputs; restate in your plan the exact evidence you
   expect from each command's unit test.
3. Implement.
4. Verify per the gates below; save output under
   `artifacts/m15-commands-*.txt`.

## Verification gates

1. `zig fmt --check` and `zig build` pass (guest builds with the new files).
2. `zig test` passes for the registry + commands against the mock console
   (deterministic `echo`/`hex`/`mem`/`help` output; unknown command handled).
3. `git diff` on `kernel/` shows **additions in new files only** — zero
   changes to `kernel/src/main.zig`.
4. `docs/march-m15.md` updated: steps 12–18 flipped with evidence; the
   step-15 fs decision recorded in `docs/status.md` (hard gate 5); branch
   log appended, claim closed.

## Definition of done

- A testable command layer with the identity, memory, utility, and control
  commands above (≥ the M1.5 "ten commands" bar), unit-tested against a
  mock console, with zero collisions on `kernel/src/main.zig`.
- The step-15 filesystem decision is recorded in `docs/status.md` (hard
  gate 5).
- No hardware claim was made without a log; nothing from the serial gate or
  host-plumbing slices snuck in.
