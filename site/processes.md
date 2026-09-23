---
title: Processes & IPC
parent: capabilities
status: published
tags: [capabilities, processes, ipc]
---

# Processes & IPC

A process is a bounded registry entry owning an image, an address space, a
lifecycle state, and an exit status. Several processes run concurrently and
exchange bytes through kernel mailboxes.

## Lifecycle

`running → exited → zombie → reaped`. The scheduler's idle task reaps one
zombie per iteration, the exited descriptor stays visible in `procs` with its
status kept, and the allocator pages return at the reap.

- `exec <file> [args...]` loads and spawns; capacity is bounded (16-slot
  pool: shell + worker + thirteen EL0 slots + idle).
- `kill <pid|name>` force-terminates with status 137 — the kernel owns
  lifetime, not the program.
- `procs` prints the table; `tasks` prints scheduler slots and states.

## IPC

- **Mailbox** — `sys_ipc_send` copies the caller's bytes into the target's
  ring (full → `ENOSPC`); `sys_ipc_recv` copies the caller's own ring out
  (peek → copy → drop, so a bad buffer never loses a message).
- **Wait** — `sys_wait(target)` blocks the caller until the target exits and
  returns its status; event-driven, not POSIX.
- **Observability** — `sys_procs` gives EL0 a read-only snapshot of the
  process table.

## What's proven live

- **Concurrency** — `live-concurrent` shows two live processes.
- **Long-lived peers** — `live-long-lived` keeps one program running
  across another's exit, reap, and re-exec.
- **IPC round trip** — `live-ipc` interleaves `ipc: ping N` sends with
  byte-exact `peer: got ping N` echoes.
- **Wait** — `live-wait` shows two blocked tasks while the target is
  still `running`, then the status propagates.
- **Scale** — `live-scale` runs ten user programs at once inside
  the 16-slot pool (thirteen EL0 user slots after M65d / #1442).

<Aside kind="info">

**LIVE-GATED.** Each bullet above is a named class B gate spec in
`tools/gate/specs/` (run with `just gate <id>`); the [[evidence]] page explains how they are
classified and run.

</Aside>
