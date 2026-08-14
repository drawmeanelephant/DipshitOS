---
title: Userspace & syscalls
parent: architecture
status: published
tags: [architecture, syscalls, el0]
---

# Userspace & syscalls

Real EL0 user programs run under DipshitOS, loaded from the disk by `exec` and
scheduled as processes. The syscall boundary is a frozen, numbered ABI.

## The ABI (ADR 0007)

The syscall ABI is frozen in `docs/decisions/0007-syscall-abi.md`: the syscall
number goes in x8, arguments in x0–x5, the result in x0, dispatched through a
runtime-built 64-slot table. Twenty-one slots (0–20) are implemented; the rest
return `ENOSYS`.

| Slot | Name | What it does |
|-----:|------|--------------|
| 0 | `ping` | round-trip identity check |
| 1 | `write` | bounded console write from an EL0 aperture |
| 2 | `yield` | cooperative yield |
| 3 | `exit` | terminate with a status |
| 4 | `sleep` | block for N scheduler ticks |
| 5/6 | `ipc_send` / `ipc_recv` | bounded per-process mailbox |
| 7 | `procs` | read-only process-table snapshot |
| 8 | `wait` | block until a peer exits, return its status |
| 9/10/11 | `udp_listen` / `udp_send` / `udp_recv` | UDP from EL0 |
| 12–20 | `win_*` | open/fill/present/close/move/raise/get/query/set_visible |

## Fault-safe uaccess

Pointer-taking syscalls copy through a `uaccess` layer that enforces the EL0
apertures (text read-only, stack read-write) and returns `EFAULT` (`-3`)
rather than faulting the kernel. A masked recovery window latches a real EL1
data abort, advances ELR past the faulting instruction, and converts it into a
clean `EFAULT`. The `uaccess` command proves the recovery live.

## Exec and processes

`exec <file> [args...]` reads a flat `DSK1` image through the FAT path, strips
its header, rebuilds the EL0 user root around its page, packs a bounded argv
block into the text page, and spawns it. Programs are real processes with a
lifecycle: `running → exited → zombie → reaped`, with exit status preserved
past the reap.

## Inter-process communication

- **Mailbox** — `sys_ipc_send`/`sys_ipc_recv` move bytes between two live
  processes through bounded per-process rings.
- **Wait** — `sys_wait(target)` blocks the caller until the target exits and
  returns its status (event-driven, not POSIX wait).
- **Kill** — the monitor's `kill <pid|name>` ends a never-exiting program with
  the reserved status 137; the kernel owns lifetime, not the program.

## What EL0 cannot do

EL0 reaches only its own text and stack leaves. It cannot touch kernel RAM,
firmware, or MMIO, and its windows and sockets are kernel-owned — the
owner-restricted [[capabilities|window and UDP]] syscalls refuse
cross-process access.

<Aside kind="info">

**LIVE-GATED.** Concurrent programs, exit-status propagation, the IPC round
trip, and the UDP syscall seam are each proven by a dedicated class B gate —
`verify-live-concurrent`, `verify-live-wait`, `verify-live-ipc`, and
`verify-live-net-udp-syscall`.

</Aside>
