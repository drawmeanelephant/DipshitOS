# Critique prompt: DipshitOS milestone zero

You are reviewing the milestone-zero deliverables of DipshitOS, a from-scratch
AArch64 operating system. Milestone zero must prove only that a Zig-compiled
AArch64 UEFI application boots and prints a fixed message. There is no kernel,
no loader, no libc, no POSIX, no graphics, no networking, no filesystem code,
no SMP, no userspace.

Read the full project context (artifacts/context.md), including every source
file, build file, documentation file, inspection output and runtime log.

## What to prioritize

Focus your review on, in this order:

1. **Incorrect UEFI assumptions** -- wrong protocol usage, wrong entry-point
   convention for the pinned Zig release, bad assumptions about firmware
   behavior, misuse of the EFI System Table.
2. **Target or ABI mistakes** -- anything that is not genuinely AArch64, any
   libc/POSIX leakage into guest code, wrong calling conventions, wrong data
   model.
3. **Invalid PE/COFF generation** -- anything that would stop the firmware
   from loading the application (bad section layout, wrong subsystem, wrong
   entry point, broken relocation expectations).
4. **Unsafe pointer or lifetime assumptions** -- in the Zig guest code and in
   the Swift host launcher.
5. **Apple Virtualization configuration errors** -- invalid or missing
   devices, wrong boot loader setup, EFI variable store misuse, configuration
   that cannot validate.
6. **Build steps that are not reproducible** -- non-deterministic behavior,
   steps that silently do nothing, hidden tool dependencies, anything that
   would fail on a clean checkout.
7. **Claims not supported by logs or commands** -- the project distinguishes
   *observed* behavior from *inferred* behavior; flag any claim that asserts
   observation without a log file or command output in evidence.
8. **Unnecessary expansion beyond milestone zero** -- any code or design that
   implements a kernel, loader, allocator, scheduler, filesystem, graphics
   stack, networking stack, or userspace.

## Required output format

Do **not** spend output praising ordinary code. Organize your review into
exactly these five sections:

### Proven bugs
Things that are definitely wrong, with the specific file, line, and reason.
A claim counts as a proven bug only if you can point at concrete evidence
(spec violation, API misuse, a log showing failure).

### Likely bugs
Things that are probably wrong but where you lack a confirming observation.
State what evidence would confirm or refute each one.

### Architectural risks
Design-level concerns that will cost the project later (e.g. hardware
assumptions that will not survive into the kernel milestone).

### Missing evidence
Observations the milestone claims or implies but that are not backed by a
log file or command output in artifacts/.

### Suggested tests
Concrete, minimal verification steps (commands, in order) that a reviewer
could run to confirm the milestone's claims on a clean machine.
