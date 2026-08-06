# AGENTS.md — rules for working in this repository

These rules bind any AI agent or human contributor working in this project.

## Project identity

- This is a from-scratch AArch64 operating system project.
- It is not Linux-based.
- It must not depend on libc, POSIX, or an existing guest operating system.
- The guest implementation language is Zig; the host launcher is Swift.

## Milestone scope rules

- Do not implement work from later milestones.
- Do not introduce libc or POSIX.
- Do not add a kernel during milestone zero.
- Do not add graphics, networking, SMP, processes, or filesystems.
- Host-side observation devices (serial console, a framebuffer used only to
  screenshot the guest, the BOOTED.TXT evidence file) are permitted and are
  not "graphics" or "filesystem" milestones; guest-side graphics, network,
  or storage stacks remain out of scope.
- Milestone zero ends at: a Zig-compiled AArch64 UEFI application boots
  from `EFI/BOOT/BOOTAA64.EFI` on a FAT image and prints its message.

## Evidence rules

- State what was directly observed versus inferred. Never present a guess
  as a result.
- Run available verification before claiming success. Save command output
  and logs under `artifacts/`.
- Do not fabricate successful command output. If a dependency or platform
  capability is unavailable, complete everything else and report the
  precise blocked step.

## Documentation rules

- Record hardware assumptions in `docs/hardware-contract.md`.
- Record important design choices as architecture decision records under
  `docs/decisions/`.
- Keep `docs/status.md` current: it is the canonical "where we are" answer,
  updated whenever a gate passes, fails, or a milestone completes. Other
  docs link to it instead of duplicating status prose.
- Keep `README.md` and `docs/testing.md` honest about what was observed.
