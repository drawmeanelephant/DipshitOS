# ADR 0007: EL0 syscall ABI and runtime dispatch table

Status: **accepted** · Date: 2026-08-10 · Milestone: three (claim 3594)

## Context

Claim 8215 / PR #60 proved the smallest real EL0 boundary: a statically
linked EL0t task executes from a page-isolated user-text aperture, uses a
separate EL0 stack, enters EL1 with `svc #0`, and returns through the shared
exception-vector frame while the tick scheduler preserves `SP_EL0`. That card
deliberately exposed only one proof operation.

This card freezes the numbered contract before uaccess, per-task address
spaces, task lifecycle expansion, or executable loading build on accidental
register choices. The merged and VZ-proven claim-8215 convention is x8 as the
operation selector and x0 as argument/result. Docs-only commit `6b1b8cd`
later described both number and result as x0; that transcription cannot encode
`ping(value) -> value` and contradicts `userspace.zig`, claim 8215, its branch
log, and its live evidence. This ADR records the implemented boundary.

The kernel is a relocation-free flat image linked at zero and loaded at a
runtime-selected base. ADR 0005 therefore forbids const data tables containing
function or slice pointers: their link-time absolute addresses are wrong after
the load.

## Decisions

### D1. Register and exception convention

- x8 contains the syscall number.
- x0–x5 contain up to six arguments; x0 receives the return value.
- The instruction is `svc #0`. ESR_EL1's SVC immediate remains zero and is
  reserved; it does not carry a syscall number.
- The result is written to x0 in the saved claim-9746 vector frame before
  exception return restores the registers.
- SVC dispatch is EL0-only. `is_svc64_from_el0` accepts AArch64 SVC from EL0t;
  an SVC from EL1t or EL1h stays on the exception report-and-park path because
  kernel code calls functions directly.
- Claim 8215 continues to own vector entry, EL0 routing, `SP_EL0`, and return
  plumbing. The syscall module registers through its existing
  `set_svc_dispatcher` seam.

### D2. Fixed number space and table

The namespace is 0–63. The dispatch table has exactly 64 slots and is built at
runtime in module-level BSS. It is never a const function-pointer table.

| # | Name | Signature | Behavior |
|---|------|-----------|----------|
| 0 | `sys_ping` | `ping(value) -> value` | Preserves claim 8215's two-call EL0 return proof. |
| 1 | `sys_write` | `write(fd, buf, len) -> i64` | Writes at most 256 bytes to console fd 1 through the registered writer. |
| 2 | `sys_yield` | `yield() -> i64` | Cooperatively stages the next runnable task and returns 0 when the caller runs again. |
| 3 | `sys_exit` | `exit(status) -> noreturn` | Removes the caller from the runnable ring, stages its successor, and defers a shell report. |
| 4–63 | reserved | — | Returns `-ENOSYS`; later additions occupy one frozen row without renumbering. |

Every in-range slot has a monotonic call counter. `syscalls` reports the four
implemented rows and counters deterministically.

### D3. Return errors

Negative signed values are returned as their two's-complement x0 bit pattern:

| Value | Name | Meaning |
|-------|------|---------|
| 0 | success | The operation succeeded. |
| -1 | `EINVAL` | Argument arithmetic or the bounded write cap is invalid. |
| -2 | `EBADF` | The write fd is not 1. |
| -3 | `EFAULT` | Reserved for the follow-on uaccess card; not returned yet. |
| -4 | `ENOSYS` | The syscall number is unknown or reserved. |

`sys_write` currently checks the fd, 256-byte cap, addition overflow, the MMU
builder's guaranteed low 4 GiB identity blanket, and containment within one of
the two kernel-known EL0 apertures (user text or user stack) before
dereferencing. Privileged RAM and Device mappings inside the blanket are
therefore not readable through this syscall. This is bounded arithmetic over
already-known identity mappings, not fault-safe user-pointer access. The later
uaccess card owns mapping/permission checks, fault recovery, and EFAULT.

### D4. Scheduling effects stay within the fixed task model

Yield and exit reuse the claim-5275 fixed scheduler pool. Yield saves the SVC
frame and stages the next runnable task. Exit marks the EL0 caller terminated,
removes it from round-robin selection, stages another existing task, and never
returns to the terminated frame. The exception seam returns the scheduler's
selected frame just as its IRQ path already does. No dynamic task creation,
process object, allocation, or expanded loader is introduced.

The demo EL0 payload waits on a one-word witness in its existing user-BSS
aperture before calling `sys_yield`. Only the timer-switch wrapper updates that
witness; cooperative switches cannot. This preserves claim 8215's prerequisite
observation—a real timer IRQ preempts EL0 and returns to the shell—before the
new cooperative path runs.

SVC handlers execute in synchronous exception context, not IRQ context, so the
write writer may emit a short bounded line. Timer/scheduler IRQ paths remain
console-free; exit reporting is deferred to the shell idle loop.

## What this is not

- It is not POSIX, libc, `errno`, or a compatibility ABI.
- It is not uaccess, PAN, fault recovery, or safe arbitrary user-pointer
  access.
- It is not per-task address spaces, processes, dynamic task creation, or a
  user lifecycle subsystem.
- It is not an ELF loader or ESP executable path.
- It does not change the kernel takeover path, MMU ownership, or hardware
  contract.

Those later milestone-three cards build on this frozen numbering and register
contract rather than widening this card.

## Consequences

- Adding a syscall is one runtime table row, one bounded handler, and tests;
  existing numbers and errors do not move.
- The claim-8215 ping transcript remains a regression proof while the new live
  SVC gate proves dispatch-table write/yield/exit behavior and shell recovery.
- Host tests cover table shape, marshalling, errors, counters, writer output,
  scheduling hooks, and deterministic reporting; VZ evidence remains required
  for the real EL0 exception round trip.

## Amendment (2026-08-10, claim 6120 — the uaccess card)

D3's `-3`/`EFAULT` row is no longer reserved: the uaccess card implements it.
`sys_write` now copies user bytes through the uaccess layer
(`kernel/src/uaccess.zig`, `uaccess.copy_in`) instead of validating ranges
inline, so a bad user pointer returns `-3` rather than `-1`:

- `EFAULT` (`-3`) — the user pointer is bad: `buf + len` wraps, the range is
  not fully inside one of the two kernel-known EL0 apertures (user text
  read-only, user stack read-write), the range targets an unmapped address
  (above the identity blanket), or the operation lacks permission (e.g.
  `copy_out` into the read-only text aperture). Rejected before any memory
  access; a data abort taken while a copy is running is recovered into
  `EFAULT` instead of crashing EL1 (a masked uaccess window + the
  claim-9746 synchronous path advancing ELR past the faulting instruction).
- `EINVAL` (`-1`) — the bounded write cap is exceeded (`len > 256`);
  pointer-arithmetic and range errors are `EFAULT` now.
- `EBADF` (`-2`) — unchanged (fd is not 1).

The pointer-taking syscall (`sys_write`) is migrated; the EFAULT contract is
proven end to end by the EL0 payload (a bad-pointer write returns `-3` and
EL0 survives) and by the `uaccess` monitor diagnostic (a real data abort at
EL1 recovered into EFAULT on VZ), gated by `tools/verify-live-uaccess.sh`.
The ABI itself — x8 number, x0–x5 arguments, x0 result, slots 0–3,
reserved 4–63 — is unchanged.

## Amendment (2026-08-10, claim 5804 — the per-task address-space card)

The user pointer's translation now comes from the EL0 task's OWN TTBR0 root
instead of the shared identity map, and the design landed on the VZ fallback
(measured — see `kernel/src/mmu.zig`'s module doc):

- **TTBR1 is NOT used.** The original design put the kernel at a TTBR1 KVA
  shadow (`KVA_BASE + phys`) so TTBR0 could be swapped freely per task.
  Live VZ measurement proved TTBR1 translation incompatible with this
  kernel's tables: with 4 KiB-aligned tables the TTBR1 walker faults at the
  FIRST descent level in every configuration (shared L0 root, dedicated
  48-bit L0 root, dedicated 39-bit L1-rooted mirror with T1SZ=25) despite
  provably-valid descriptor chains — the signature of a walker masking
  table addresses to 64 KiB. With 64 KiB-aligned tables the walk resolves
  (block and page leaves) but a Normal-WB data access through TTBR1 then
  aborts (TLB conflict abort, then synchronous external abort DFSC=0x21
  after extra invalidations) while Device leaves were readable — so a
  kernel executing from a KVA shadow cannot work on VZ.
- **Fallback: per-task TTBR0 with an EL1-only kernel overlay.** The kernel
  stays identity-mapped in TTBR0 (T0SZ=16, TTBR1=0). Every task's TTBR0
  root carries the kernel identity map as EL1-only leaves (AP=0b00); the
  EL0 task's root (`build_user_root`) is a clone of the identity tree with
  its text+stack leaves overlaid at the user VAs. The kernel is therefore
  reachable under EVERY root, so the scheduler can switch TTBR0 per task.
- **EL0 reach is exactly the text+stack leaves.** Every other leaf — kernel
  RAM, firmware, MMIO Device windows — is EL1-only, so an EL0 access takes
  a permission fault, never a device access. UXN/PXN are enforced on every
  user leaf (W^X). MMIO is excluded from EL0 by the same EL1-only AP bits:
  the user root's Device leaves are EL1-only (`el0_device = 0` measured on
  VZ).
- The `addrspaces` monitor diagnostic reports TTBR1=0, T0SZ=16, each task's
  TTBR0 root, and the user root's leaf inventory (`el0`, `el0_device`),
  gated by `tools/verify-live-addrspaces.sh`.

The syscall ABI (x8 number, x0–x5 args, x0 result) and the EFAULT contract
are unchanged by the address-space move; the EL0 payload + uaccess recovery
prove the boundary under the user root.

## Amendment (2026-08-10, claim 3200 — the blocking syscalls card)

Slot 4 (`sys_sleep`) is frozen in the dispatch table:

| 4 | `sys_sleep` | `sleep(ticks) -> i64` | Blocks the calling task for at least `ticks` scheduler ticks (1 tick ≈ 1 s timer period on VZ). Returns 0 on wake; `EINVAL` for a zero-ticks deadline clamp or overflow. The scheduler's `blocked` state + per-task `wakeup_tick` deadline + timer-driven `wake_expired` on every tick move the sleeper back to `ready`; the round-robin ring resumes it from its saved SVC frame, exactly like `sys_yield`. |

`implemented_count` is now 5; the `syscalls` report prints rows 0–4.
`scheduler.sleep_current` clamps `ticks=0` to 1 (minimum sleep is one tick).
The `blocked` task is counted as live by `user_root_in_use` (the exec gate),
so a sleeping user program still owns the user root until it exits.

The ABI — x8 number, x0–x5 arguments, x0 result, reserved 5–63, error
codes — is unchanged.

## Amendment (2026-08-10, claim 5965 — the IPC mailbox card)

Follow-on 3 card 3f freezes slots 5 and 6 in the dispatch table (the ONE
ABI change in the follow-on 3 card set; everything else stays frozen):

| 5 | `sys_ipc_send` | `ipc_send(target, buf, len) -> i64` | Copy `len` bytes (≤ 64; longer is truncated to the slot bound) from the caller's region through uaccess into process `target`'s bounded per-process mailbox (`kernel/src/mailbox.zig`: 8 × 64 B BSS ring per process id, FIFO — the capacity is a DATA-PATH CONSTANT, raised 4 → 8 by claim 3179 on card 4b; NOT a syscall number, this ABI row is unchanged). Returns the sent length; `EINVAL` for an out-of-range/free/exited target, `EFAULT` for a bad user pointer, `ENOSPC` when the target's ring is full (checked before any bytes are copied). |
| 6 | `sys_ipc_recv` | `ipc_recv(buf, max) -> i64` | Copy the caller's OWN oldest message out through uaccess (`max` > 64 clamps to it; `max` shorter than the message truncates the copy — both documented), consuming it. Returns the copied length; 0 when the mailbox is empty; `EINVAL` when the calling task is not a process; `EFAULT` leaves the message queued (peek → copy_out → drop). |

`ENOSPC` (`-5`) joins the D3 error table: the target process's bounded
mailbox is full — the send is refused, never unbounded and never silently
dropped.

`implemented_count` is now 7; the `syscalls` report prints rows 0–6.
Every byte crosses the claim-6120 uaccess window in both directions, and a
process can only reach its own mailbox (recv) and a live target's (send) —
cross-process isolation at the mailbox level, with the ring reset whenever a
process id is created/recycled (exec path + boot-payload registration).

No POSIX pipes/fds/signals, no unbounded mailboxes, no scheduler/lifecycle
changes: this is the ONLY ABI amendment in the follow-on 3 card set.

## Data-path note (2026-08-11, claim 3179 — the IPC-depth card)

Follow-on 4 card 4b raises the mailbox capacity `mailbox.max_messages`
4 → 8 (the per-process ring grows 256 → 512 B of fixed BSS — still no
allocation) as a DATA-PATH CONSTANT, NOT a syscall number: the ABI stays
frozen (the follow-on-4 set's ABI amendments are ONLY slots 7/8, on cards
4a/4c). The truncation contract is unchanged: a message longer than 64 B
still truncates at the slot bound, a full ring still refuses with the
same `ENOSPC` (-5) — now at the 9th send — the same empty → 0 recv
result, the same drain invariant `sent − recv == pending ≤ capacity`,
and the same cross-process isolation (a process reaches only its own
mailbox and a live target's).

## Amendment (2026-08-11, claim 5799 — the process-observability card)

Follow-on 4 card 4a freezes slot 7 in the dispatch table (the ONE ABI
change in the first card of the follow-on 4 set; everything else stays
frozen):

| 7 | `sys_procs` | `procs(buf, max) -> i64` | Copy a bounded snapshot of the process table OUT into the caller's region through uaccess — a read-only view (no write path). One fixed 40-byte row per NON-FREE descriptor, in id order: `u64 pid` (LE), `u64` state code (the `process.State` enum: 1=created, 2=running, 3=exited), `u64 exit_status` (0 unless exited — the status survives the reap), `name[16]` NUL-padded. `max` truncates to WHOLE rows (`floor(max / 40)` — a partial row is never copied); `max == 0` → 0 rows. Returns the row count written; `EFAULT` for a bad buffer. |

`implemented_count` is now 8; the `syscalls` report prints rows 0–7.
The snapshot is marshaled into a fixed BSS scratch (`max_processes` × 40 =
320 B, no allocation) then copy_out'd through the claim-6120 uaccess
window; no caller-identity requirement (any EL0 task may read the table).
The EL0 proof rides PEER.BIN: it polls `sys_procs` once per quantum until
the snapshot shows a running peer, prints `peer: sees <pid> <name>
<state>` per row, then enters its recv loop — a process-level view of the
process table reachable from EL0, distinct from the EL1h monitor's own
`procs` read.

The ABI — x8 number, x0–x5 arguments, x0 result, reserved 8–63, error
codes — is unchanged.

## Amendment (2026-08-11, claim 9946 — the exit-status-propagation card)

Follow-on 4 card 4c freezes slot 8 in the dispatch table (the SECOND ABI
change in the follow-on 4 set — the set's explicit slots 7/8 amendment,
following the `sys_sleep` slot-4 and ipc slots-5/6 precedents; every
existing syscall number 0–7 stays frozen):

| 8 | `sys_wait` | `wait(target) -> i64` | Block the calling process until the process with id `target` exits, then return its exit status. NOT POSIX wait: no zombies, no fds, no children — the caller may wait on ANY registered process (the exit status is a plain kernel-recorded number, kept in the process registry after the executor reap). Errors are `EINVAL`: the caller is not a process (an EL1h task), the target is out of range or free, the target is `created` (loaded but not yet running — it may never run, and the kernel refuses a waiter that could never wake), or the caller waits on ITSELF (it would never exit while blocked — the deadlock is refused). An ALREADY-EXITED target returns its stored status immediately (no block); a RUNNING target parks the caller (`scheduler.wait_current` — the claim-0635 sleep seam: the caller's SVC frame stays on its kernel stack, and the exit path's `wake_waiters` flips it back to `ready` and patches the status into the saved frame's x0, so the syscall return lands when the ring resumes it). |

`implemented_count` is now 9; the `syscalls` report prints rows 0–8.
The block is event-driven, not time-driven: `wake_expired` (the tick
clock) never touches a task whose `wait_pid` is set, and the wake happens
in `exit_current` right after the registry records the exit — pure TCB +
saved-frame writes, safe in the exception context. Multiple waiters on
one pid all wake with the same status; a waiter can never outlive its
target (a process is only reaped AFTER it exits, which wakes the waiter
first). The EL0 proof rides COUNTER.BIN (exec'd with the wait target in
its argv): it prints `ipc: waiting pid=<n>`, blocks, and prints `ipc: saw
pid=<n> status=<s>` when the target (STATUS43.BIN, exiting 43) wakes it.

As with slot 7, this is the follow-on-4 set's final ABI change; the ABI —
x8 number, x0–x5 arguments, x0 result, reserved 9–63, error codes — is
otherwise unchanged.

## Amendment (2026-08-12, claim 1384 — the UDP syscall seam card)

Milestone-five card N6 freezes slots 9/10/11 in the dispatch table (the
card's ONE ABI change, following the `sys_sleep` slot-4, ipc slots-5/6,
and wait slot-8 precedents; every existing syscall number 0–8 stays
frozen):

| 9 | `sys_udp_listen` | `udp_listen(port) -> i64` | Bind the bounded kernel listen table (`udp.zig`'s 4-slot table — the SAME table the monitor's `net udp listen` uses) to `port`. Kernel-global: any EL0 task may bind any port (no per-process ownership — the honest bound). Returns 0; `EINVAL` for port 0/> 65535 or a duplicate/full table. |
| 10 | `sys_udp_send` | `udp_send(ip, port, buf, len) -> i64` | Send ONE UDP datagram to `ip:port` from the FIXED source port 7000 (`udp.default_src_port`). `ip` is the 4 octets in network byte order in x0's low 32 bits (extracted byte-explicitly — AArch64 is little-endian, never a bitcast). `len` (≤ `udp.payload_max` 64, truncated honestly) is copied through uaccess into fixed BSS staging, then `net_udp_send` runs the N5 path: an own-IP send takes the LOOPBACK path (no device round trip); a peer send needs its MAC in the ARP table (`EINVAL` — `.no_peer`/`.not_ready`/`.timeout`; the seam does NOT resolve ARP — the caller resolves via the monitor's `net arp` and may retry). Returns the payload length; `EFAULT` for a bad `buf`; 0 for a zero-length no-op. |
| 11 | `sys_udp_recv` | `udp_recv(port, buf, max) -> i64` | Copy the oldest datagram for the listener on `port` OUT through uaccess — the full 8-byte UDP header + payload (the caller parses the header; the src IP is not kept — honest bound). Returns the copied length (max clamps to `udp.datagram_max` 72; shorter truncates and CONSUMES); 0 when the ring is empty; `EINVAL` when not listening on `port`. The datagram is PEEKED, copied out, and only then popped — a bad recv buffer (`EFAULT`) leaves it queued (the claim-5965 contract). The device is DRAINED FIRST (`virtio_net.net_rx_drain`, the claim-6076 polled-drain contract — the used-buffer IRQ is unobserved): a recv pulls any waiting frame device → ring synchronously, so an EL0 polling loop is self-sufficient without the shell idle loop (observed live: without the drain the answer sat in the device queue until a `net` command drained it). |

`implemented_count` is now 12; the `syscalls` report prints rows 0–11.
The EL0 proof rides UDP.BIN (a new `user/src/udp.zig` program, loaded by
`exec`): it binds 7000, loopback-sends to its own IP, polls `sys_udp_recv`
for the host's `--net-udp-respond 10.0.0.2:9999` answer (the cooperative
`sys_yield` between polls — the ring must return to the program, so the
live gate keys its observation phase on the program's OWN `udp: got ping`
marker and its exit on the reap line; an early expect would kill the VM
before the round trip and the gate would fail on a healthy kernel),
observes the `EINVAL` mapping from EL0 (unbound-port recv, unresolved-
peer send), and exits 17.

As with slots 7/8, this is the milestone-five set's ABI amendment; the
ABI — x8 number, x0–x5 arguments, x0 result, reserved 12–63, error
codes — is otherwise unchanged. The UDP protocol layer itself stays in
the N5 card (`kernel/src/udp.zig`); these handlers only marshal args,
copy bytes through the claim-6120 uaccess window, and call through.

## Amendment (2026-08-13, claim 0487 — the draw/window syscall seam card)

Milestone-six card G6 freezes slots 12/13/14 in the dispatch table (the
card's ONE ABI change, following the `sys_sleep` slot-4, ipc slots-5/6,
slots-7/8, and udp slots-9/10/11 precedents; every existing syscall
number 0–11 stays frozen):

| 12 | `sys_win_open` | `win_open(x, y, w, h) -> i64` | Open a user window in the G5 window manager (`driving_award.zig`): a bounded registry slot (id 2..3, TWO user windows) with a fixed BSS back-buffer (≤ 256×192 B8G8R8X8), OWNED by the calling process (the syscall layer records the caller's pid via `process.find_by_task(scheduler.current_id())`). Returns the window id; `EINVAL` for geometry outside the back-buffer/scanout bounds, an unarmed manager (no gpu), or a non-process caller; `ENOSPC` (-5) when both user slots are already open. No uaccess — plain numbers. |
| 13 | `sys_win_fill` | `win_fill(id, x, y, w, h, rgb) -> i64` | Fill a rect (window-local coordinates) in the CALLER'S window's back-buffer with a 24-bit `0xRRGGBB` color, marking it dirty. Returns 0; `EINVAL` for an unknown id, a window the caller does NOT own (per-process ownership), an out-of-range word, or a rect outside the window bounds. No uaccess — the kernel owns the buffer; the program never touches it directly. |
| 14 | `sys_win_present` | `win_present(id) -> i64` | Mark the CALLER'S window dirty so the compositor blits its back-buffer on the next idle-loop pass (the deferred-present discipline — the syscall never touches the gpu directly; the shell idle loop's `driving_award.drain` composites). Returns 0; `EINVAL` for an unknown id or a window the caller does NOT own. |
| 15 | `sys_win_close` | `win_close(id) -> i64` | (Follow-on to claim 0487 — the teardown half of the seam.) Release a user window OWNED BY THE CALLER so it can be re-opened. Returns 0; `EINVAL` for an unknown id, a non-user window (the terminal + clock are fixed), or a window the caller does NOT own. The monitor's `win close <n>` is the EL1h PRIVILEGED equivalent (closes any user window); both call `driving_award.user_close`. |
| 16 | `sys_win_move` | `win_move(id, x, y) -> i64` | (Follow-on to claim 0487 — the move half of the seam.) Reposition the CALLER'S user window's top-left corner to (x, y), CLAMPED so the whole window stays inside the scanout (`driving_award.user_move` — a window never moves off-screen). Returns 0; `EINVAL` for an unknown id, a window the caller does NOT own, an out-of-range word, or an unarmed manager. No uaccess — plain numbers. |
| 17 | `sys_win_raise` | `win_raise(id) -> i64` | (Follow-on to claim 0487 — the restack half of the seam.) Raise the CALLER'S user window to the top of the z-order (focus unchanged — tracked by id). Returns 0; `EINVAL` for an unknown id or a window the caller does NOT own. The monitor's `win move <n> <x> <y>` / `win raise <n>` are the EL1h equivalents. |
| 18 | `sys_win_get` | `win_get(id, buf) -> i64` | (Follow-on to claim 0487 — the read-back half of the seam.) Copy the CALLER'S user window's geometry (x, y, w, h as four u32 LE words — 16 bytes) OUT through uaccess, so an EL0 program can read its window's rect back after a CLAMPED move (`sys_win_move` clamps silently; this is the read-back seam). Returns 0; `EINVAL` for an unknown id, a non-user window (the terminal + clock are fixed), or a window the caller does NOT own; `EFAULT` for a bad `buf`. The first pointer-taking win slot (the claim-6120 contract). |
| 19 | `sys_win_query` | `win_query(id, buf) -> i64` | (Follow-on to claim 0487 — the full-state introspection half of the seam.) Copy the CALLER'S user window's FULL state (x, y, w, h, z, focused, visible, dirty as eight u32 LE words — 32 bytes) OUT through uaccess, so an EL0 program can introspect its window end to end: the z-order rank (`z` = the registry index, 0 = bottom — the SAME number the monitor's `win` report prints), plus the focus/visible/dirty flags. Returns 0; `EINVAL` for an unknown id, a non-user window, or a window the caller does NOT own; `EFAULT` for a bad `buf`. The second pointer-taking win slot. |
| 20 | `sys_win_set_visible` | `win_set_visible(id, visible) -> i64` | (Follow-on to claim 0487 — the visibility half of the seam.) HIDE (`visible` 0) or SHOW (`visible` 1) the CALLER'S user window (`driving_award.user_set_visible`, owner-restricted like fill/present/close). Hiding marks the terminal dirty so the next composite repaints over the hidden window; showing marks the window dirty so it reappears. Returns 0; `EINVAL` for an unknown id, a non-user window (the terminal + clock are fixed), a window the caller does NOT own, or a `visible` flag that is not 0/1. Plain numbers, no uaccess. |

`implemented_count` is now 21; the `syscalls` report prints rows 0–20.
The EL0 proof rides WIN.BIN (a new `user/src/win.zig` program, loaded by
`exec`): it opens window 2, fills a dark-blue background + three 48×48
blocks (red/cyan/white), presents it, and exits 87 — the first EL0
graphics. No uaccess (the seam is plain numbers + kernel-owned buffers),
no allocation (fixed BSS back-buffers).

**Per-process ownership (the follow-on that supersedes the original
"kernel-global" bound):** a window is OWNED by the process that opened it
and AUTO-CLOSES when that process exits — the scheduler's `exit_current`
calls `driving_award.close_owner(pid)`, so no window leaks until reboot.
`sys_win_fill`/`sys_win_present`/`sys_win_close` are owner-restricted (a
process can only render into and close its own window; the EL1h monitor's
`win close` stays privileged). The open → fill → present → exit
auto-close and the open → fill → present → close → re-open cycles are
host-tested end to end (`kernel/src/syscall.zig`, `kernel/src/driving_award.zig`).

The close follow-on (slot 15) makes the seam releasable: `sys_win_close`
and the monitor's `win close <n>` both call `driving_award.user_close`,
which frees the id (2..3) for re-open and un-presents the window. The
open → fill → present → close → re-open cycle is host-tested end to end
(`kernel/src/syscall.zig`, `kernel/src/driving_award.zig`), and the
EL0 release proof rides a SEVENTH image WINCLOSE.BIN
(`user/src/winclose.zig`): it opens window 2, fills it, presents it,
CLOSES it through slot 15, and exits 88 — the class-B gate
`tools/verify-live-win-close.sh` shows the window gone from the registry
(`win: windows=2`) and a re-exec re-opening id 2 (the freed slot reused,
never id 3). The auto-close-on-exit proof rides WIN.BIN (open → exit, NO
close): the class-B gate `tools/verify-live-win-close.sh`'s sibling
`tools/verify-live-win-syscall.sh` shows `win: windows=2` with
`sys_win_close calls=0` after WIN.BIN exits — the window was released by
the exit path, not a syscall. Because WIN.BIN's window now vanishes
before a host capture, an EIGHTH image WINLOOP.BIN
(`user/src/winloop.zig`) opens the same window and yield-loops forever,
keeping it on the scanout for the gate's decoded-capture phase.

The move/raise follow-on (slots 16/17) makes the seam able to reposition
and restack: `sys_win_move` clamps the window on-scanout
(`driving_award.user_move`), `sys_win_raise` reorders the z-order
(`driving_award.user_raise`), and both are owner-restricted like
fill/present/close. The EL0 proof rides a NINTH image WINMOVE.BIN
(`user/src/winmove.zig`): open → fill → present → move → move (the second
move clamps to the scanout corner) → raise → yield-forever; the class-B
gate `tools/verify-live-win-move.sh` shows the window's final clamped
rect (`win[2]: user user rect=1024,528,256,192`), the counters
(open=1/fill=4/present=3/move=2/raise=1/close=0), and the decoded
capture with the window's colors at the NEW position and the terminal
where it USED to be.

The get follow-on (slot 18) makes the clamp observable from EL0:
`sys_win_get(id, buf)` copies the caller's window rect (four u32 LE
words — the first pointer-taking win slot, through the claim-6120 uaccess
window) so a program can read its clamped position back instead of
inferring it from the `win` report. WINMOVE.BIN now reads the rect back
after its clamped move and prints `winmove: get 1024,528,256,192` — the
gate's `tools/verify-live-win-move.sh` assertion (get=1), alongside the
counters (move=2/raise=1/get=1/close=0).

The query follow-on (slot 19) makes the FULL state introspectable from
EL0: `sys_win_query(id, buf)` copies the caller's window rect PLUS the
z-order rank (`z` = the registry index), focus, visible, and dirty flags
(eight u32 LE words — the second pointer-taking win slot) so a program
sees its window the same way the EL1h `win` report does. WINMOVE.BIN
prints `winmove: query 1024,528,256,192 z=2 focused=1 visible=1 dirty=1`
after its clamped move — the gate's `tools/verify-live-win-move.sh`
assertion (query=1), alongside the counters (move=2/raise=1/get=1/query=1/close=0).

The set_visible follow-on (slot 20) makes the window HIDEABLE/SHOWABLE
from EL0: `sys_win_set_visible(id, visible)` toggles the caller's
window's `visible` flag (owner-restricted; the fixed terminal + clock are
refused). Hiding marks the terminal dirty so the next composite repaints
over the hidden window's pixels; showing marks the window dirty so it
reappears — the window's back-buffer and z-order rank are untouched
(only the flag flips). WINMOVE.BIN now hides its window, sleeps 2 ticks
(holding it hidden while the gate captures the GONE frame), shows it
again, and prints `winmove: hide ok` / `winmove: show ok`. The class-B
gate `tools/verify-live-win-move.sh` gained a marker-driven capture
(`--screenshot-after "winmove: hide ok"`, a new VMRunner flag) that
proves the PIXEL DISAPPEARS (no red/cyan/white blocks at the clamped
spot) while the LATEST fixed capture proves it RETURNS — alongside the
counters (move=2/raise=1/get=1/query=1/set_visible=2/close=0).

As with slots 9/10/11, this is the milestone-six set's ABI amendment; the
ABI — x8 number, x0–x5 arguments, x0 result, reserved 21–63, error
codes — is otherwise unchanged. The window registry + compositor stay in
the G5 card (`kernel/src/driving_award.zig`); these handlers only marshal
args and call through to it.

## Amendment (2026-08-15, claim 6359 — the EL0 exec seam card)

Milestone 11's A5 tracker claim called DESKTOP.BIN a "clickable application
menu to launch EL0 programs" — but the code only selected apps; `exec` was
an EL1h monitor command only. This card freezes slot 28 in the dispatch
table (the card's ONE ABI change, following the file slots-23/27 precedent;
every existing syscall number 0–27 stays frozen):

| 28 | `sys_exec` | `exec(path_ptr, path_len) -> i64` | Copy the `.BIN` name through uaccess, then run the EL1h loader (`exec.exec_file`) to load the program from the ESP into a FRESH process slot and spawn it at EL0. Returns the new process's pid on success (surfaced via `exec.last_exec_pid` — an EL0 launcher can hand it to `sys_wait` or a future `sys_kill`); `EINVAL` for a non-process caller (an EL1h task), an empty/over-long path, or a loader refusal (`.no_disk`, `.bad_magic`, `.bad_entry`, `.too_large`, `.no_args_room`, `.too_many_args`); `EFAULT` for a bad path pointer; `ENOENT` when the file is absent from the volume; `ENOSPC` for a capacity refusal (scheduler pool full, page allocator exhausted, page-table carve-out full, process registry full). No args in this row — a future amendment may add an argv block (the card-3e monitor form). |

`implemented_count` is now 29; the `syscalls` report prints rows 0–28.
The path crosses the claim-6120 uaccess window exactly like slot 23; the
loader itself is unchanged (the EL0 caller gets the SAME `exec_file` path
as the monitor command, so any program the EL1h shell can run, an EL0
program can run). A caller may exec a second program while its own window
stays up — the spawned process owns its own window slot (the G5
`user_windows_max` 4 covers up to four concurrent GUI apps).

The EL0 proof rides DESKTOP.BIN: its quick-launch buttons and Enter-on-
selection call `ui.exec_program(name)` (slot 28), and the class-B gate
`tools/verify-live-desktop.sh` types Enter after `desktop: menu ready` and
asserts `desktop: launch CALC.BIN`, the launched `calc: ready`, and
`28 sys_exec calls=1` in the `syscalls` report — the launcher is real.

As with slots 23–27, this is the Milestone 11/12 boundary's ABI amendment;
the ABI — x8 number, x0–x5 arguments, x0 result, reserved 29–63, error
codes — is otherwise unchanged. The loader stays in the milestone-three
card (`kernel/src/exec.zig`); this handler only marshals the path through
uaccess and calls through to it.

**Slot-allocation note:** Milestone 12's TCP seam (issue #148) originally
planned slots 28–31; slot 28 is now `sys_exec`, so the TCP plan moves to
slots 29–32 (the issue body is updated to match).

## Amendment (2026-08-15, claim 7604 — the EL0 termination seam card)

M11's A4 tracker claim called TOP.BIN a "click-to-kill process termination"
tool — but its Kill button only logged `top: kill requested` under a
"Future kill syscall" comment (the kernel's `kill` was an EL1h monitor
command only, claim 7786). This card freezes slot 29 in the dispatch table
(the card's ONE ABI change, following the `sys_exec` slot-28 precedent;
every existing syscall number 0–28 stays frozen):

| 29 | `sys_kill` | `kill(target_pid) -> i64` | Arm the target process's executor for termination from EL0 (the claim-7786 kill seam: `scheduler.request_kill` is a pure TCB write — the ring converts the target's NEXT selection into the existing exit path with the reserved status 137, flowing through the real exit → zombie → idle-reap → page-return lifecycle; the OS, not the program, owns process lifetime). Returns 0 once armed; `EINVAL` for a non-process caller (an EL1h task), an out-of-range / free / exited / no-executor target, or a scheduler-owned refusal (the shell or idle). Self-kill is allowed (the monitor's `kill` is equally general); a permanently blocked target keeps the EL1h kill's documented bound — the arm applies at the target's next selection, so a task blocked forever in `sys_wait_event`/`sys_wait` stays until woken. |

`implemented_count` is now 30; the `syscalls` report prints rows 0–29.
The handler validates the target through the process registry (the
`sys_wait` precedent for numeric targets) and calls through to the
claim-7786 seam — no new lifecycle machinery, no ABI change beyond the
frozen row.

The EL0 proof rides TOP.BIN: the process table auto-selects the first
RUNNING process, and the Kill button or `k`/`K` call `ui.kill_process(pid)`
(slot 29), printing `top: kill pid=<n>`. The class-B gate
`tools/verify-live-sys-kill.sh` execs COUNTER.BIN + TOP.BIN, types `k`
after `top: ready`, and asserts `top: kill pid=1`, NO `counter: alive`
after the kill, `tasks user-exec exited status=137` +
`procs COUNTER.BIN exited status=137` (the real lifecycle), and
`29 sys_kill calls=1` in the `syscalls` report — the EL0 kill, live.

As with slot 28, this is the Milestone 11/12 boundary's ABI amendment;
the ABI — x8 number, x0–x5 arguments, x0 result, reserved 30–63, error
codes — is otherwise unchanged. **The M12 TCP plan (issue #148) now runs
at slots 30–33** (28 `sys_exec`, 29 `sys_kill`, then TCP; the issue body
is updated to match).

## Amendment (2026-08-15, ADR 0012 — userland TCP socket seam)

Milestone 12 exposes the kernel's Milestone 5 TCP client to EL0 applications
through the ADR 0007 syscall seam (slots 30–33, following slot 28 `sys_exec` and slot 29 `sys_kill`):

| Slot | Name | Signature | Description |
|:---|:---|:---|:---|
| 30 | `sys_tcp_connect` | `connect(ip: u32, port: u16) -> i64` | Resolves peer MAC via ARP, initiates 3-way handshake to target IPv4:port, and blocks the caller on the scheduler sleep/event seam until `ESTABLISHED` or timeout (30 s). Returns `0` on success, or negative error code (`ECONNREFUSED` -6, `ETIMEDOUT` -7, `EINVAL` -1, `ENOTREADY` -5). |
| 31 | `sys_tcp_send` | `send(buf_ptr: [*]const u8, len: usize) -> i64` | Marshals payload (up to 64 bytes) via `uaccess.copy_in`, constructs TCP segment, and transmits. Returns bytes sent, or negative error code (`ENOTCONN` -5, `EFAULT` -3, `EINVAL` -1). |
| 32 | `sys_tcp_recv` | `recv(buf_ptr: [*]u8, max_len: usize) -> i64` | Drains the RX buffer via `uaccess.copy_out` (peek $\to$ copy $\to$ pop). Drains virtio-net device first (the N6 drain contract). Returns bytes received (0 if none pending / non-blocking EOF), or negative error code (`ENOTCONN` -5, `EFAULT` -3). |
| 33 | `sys_tcp_close` | `close() -> i64` | Initiates graceful FIN teardown (FIN $\to$ FIN-ACK $\to$ ACK) and returns connection to `closed`/`idle`. Returns 0 on success, or negative error code (`ENOTCONN` -5). |

`implemented_count` is 34; reserved slots become 34–63.
These handlers marshal arguments and user buffers through the claim-6120 `uaccess` window and invoke `kernel/src/tcp.zig`.
Proof program: `TCP.BIN` (`user/src/tcp_client.zig`, Issue #148).

## Amendment (2026-08-16, claim 5801 — the mutating filesystem seam)

Milestone 13 card B1 turns the read-only M10 file ABI mutating — slots
34–37, following slot 33 `sys_tcp_close`:

| Slot | Name | Signature | Description |
|:---|:---|:---|:---|
| 34 | `sys_file_delete` | `delete(path_ptr, path_len) -> i64` | Delete the file at `path` (DATA by default; `/esp/` routes to the ESP). Frees the FAT cluster chain and marks the directory slot deleted. Returns 0; `EINVAL` bad path or a directory, `ENOENT` absent, `EFAULT` bad pointer. |
| 35 | `sys_file_rename` | `rename(old_ptr, old_len, new_ptr, new_len) -> i64` | Rename a file in place (same directory — cross-directory moves and cross-volume renames are refused). Returns 0; `EINVAL` bad path / target-exists (no EEXIST row — documented) / cross-directory, `ENAMETOOLONG` bad 8.3 name, `ENOENT` absent, `EFAULT` bad pointer. |
| 36 | `sys_file_truncate` | `truncate(handle, size) -> i64` | Resize the OPEN handle to `size` bytes (shrink truncates, grow zero-fills, ≤ 2048). Returns 0; `EBADF` bad/closed handle, `EACCES` not open for write, `ENOSPC` over-large, `ENOENT` absent. |
| 37 | `sys_file_free` | `free(volume) -> i64` | Free bytes on a volume (0 = DATA, 1 = ESP). Returns the byte count; `EINVAL` bad volume, `ENOENT` unmounted. |

`implemented_count` is 38; reserved slots become 38–63.
The handlers marshal paths through the claim-6120 `uaccess` window and
invoke `kernel/src/file_table.zig`'s new mutating ops, which sit on
`kernel/src/fat.zig`'s `delete_file`/`rename_file`/`truncate_file`/`free_space`.
Proof program: `FSTEST.BIN` (`user/src/fstest.zig`, issue #161); live gate
`tools/verify-live-fs-mutation.sh`. `FILE.BIN` grows Delete/Rename buttons
over slots 34/35.
