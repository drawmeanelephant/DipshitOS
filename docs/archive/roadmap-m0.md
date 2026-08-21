# Roadmap archive — Milestone zero — boot pipeline proof

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).

---

## Milestone zero (implemented) — boot pipeline proof

A tiny AArch64 UEFI application, written in Zig, is built, placed at
`EFI/BOOT/BOOTAA64.EFI` on a FAT32 ESP inside a GPT image, and booted under
UEFI by the Swift Virtualization.framework launcher (Apple silicon running
macOS 27 or newer only; there is no QEMU path in this project). The application prints

```
DIPSHITOS BOOTLOADER
firmware has agreed to cooperate
```

and returns control to the firmware.

Deliverables: `boot/`, `host/vm-runner/`, `image/`, `tools/`, `docs/`,
`build.zig`, `build.zig.zon`, `AGENTS.md`, `README.md`.

**No kernel, loader, allocator, scheduler, filesystem, graphics, networking,
SMP, or userspace existed at the end of milestone zero** *(historical
statement of the M0 end state)*.
