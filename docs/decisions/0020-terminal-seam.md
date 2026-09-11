# ADR 0020: The terminal (vt) seam — a userland-ownable console

Status: **ACCEPTED** · Date: 2026-09-10 · Milestone: M44 (next focus) ·
Issue **#1072** · Claims **#1073** (object + ABI) and **#1075** (pump + pilot)

> The object (`kernel/src/terminal.zig`), the `/dev/tty` device-fd routing
> (`kernel/src/file_table.zig`), the serial front-end pump, and the EL0 pilot
> (`TTYECHO.BIN`, class-B `live-ttyecho`) all landed under #1073/#1075. Boot
> default is unchanged: nothing attaches until a process calls
> `sys_tty_attach`.

## Context

The only terminal in the system today is the **kernel console** (the virtio
serial device): `kernel/src/shell.zig` reads it and writes to it, and the
kernel monitor drives ~90 diagnostic commands over it. EL0 has no way to own a
terminal — `sys_write(fd 1)` emits bytes to the console and input arrives as
raw key events, but a process cannot *be* the thing on the other end of a
console.

That blocks three planned directions at once:

- **#1065 — a userland shell.** The shell can't run on the raw console or live
  in a desktop window without owning a terminal.
- **`TERM.BIN` — a desktop terminal app.** It needs a session buffer to render
  and feed.
- **#1066 — remote/SSH.** A TCP/SSH session is just another thing feeding
  keys into, and draining output from, a shell's terminal.

## The claw-back traps we are refusing

1. **A "run a kernel monitor command" syscall.** It would freeze kernel
   internals (`mem`, `pages`, `pci`, `syscalls`, `uaccess`, `strace`, `sym`, …)
   into a permanent EL0 ABI. Kernel-internal diagnostics stay in the kernel
   monitor; userland gets structured data through real syscalls — `sys_procs`
   (slot 7) is the model.
2. **Kernel-shell-over-TCP.** Remote must attach a front-end to a terminal
   object like every other consumer, not tunnel the kernel shell.

## Decision

### D1. A terminal OBJECT is a session buffer, not a device
`kernel/src/terminal.zig` defines a bounded, hardware-free session:

- **output ring** — the owner process appends bytes (`write`); a front-end
  drains them (`read_out`). Full ⇒ drop the OLDEST byte and count it
  (`out_dropped`), so output always flows.
- **input queue** — a front-end appends keys (`push_input`); the owner drains
  them (`read_input`). Full ⇒ drop the NEWEST byte and count it
  (`in_dropped`) — a key burst must never evict older keys.
- **attach state** — at most one front-end (`none`/`serial`/`window`/`net`)
  plus an optional owner pid. `attach`/`detach` are explicit.
- **no line discipline** in the object (v1): it is a byte pipe; the shell owns
  line editing/history exactly as the kernel shell does today. Adding
  raw/cooked modes later is additive.

The object is pure (fixed arrays, no hardware, no allocation) and fully
host-tested; the device/front-end wiring lives outside it.

### D2. Front-ends own a terminal one at a time
A front-end is whatever renders output and supplies input: the raw serial
console, a TABWM terminal window, a TCP session, later an SSH channel. Attach
is exclusive; detach leaves the terminal usable (buffered) but unattached.

### D3. ABI: the terminal is a DEVICE FILE, not a new syscall family
A process opens `/dev/tty` through the **existing** `sys_file_open` (slot 23)
and reads/writes it through **existing** `sys_file_read`/`sys_file_write`
(slots 24/25). `kernel/src/file_table.zig` gains a virtual terminal device
kind routed to the terminal object — **no new syscall slot** for terminal I/O.

Rationale: the fd shape is the least-clawback one. Every future channel
(remote session, SSH channel, extra shells) is another fd, not another
syscall; and the frozen ADR 0007 ABI is reused rather than extended.

**Update (claim #1075):** front-end attach/detach landed as **ADR 0007 slot 67
`sys_tty_attach(front_end)`** (`0` = detach, `1` = serial console; window/net
reserved `ENOSYS`) rather than boot policy — the decision was deferred to the
wiring tranche and a single explicit slot proved cleaner and testable than a
boot setting, while terminal I/O still consumes no slot. Boot policy can still
drive the attach from a startup file later; the slot is the mechanism.

### D4. Boot default is unchanged
The kernel monitor keeps the raw serial console. A terminal attaches the
serial front-end only when explicitly handed over (boot setting, then a
syscall). Every existing live gate keeps running against the monitor exactly
as today — zero regression.

### D5. Kernel-internal diagnostics stay in the kernel monitor
The userland shell exposes user-facing commands (files, apps, network) through
syscalls; `mem`/`pages`/`pci`/`syscalls`/… remain monitor commands. If a
diagnostic is genuinely needed in the desktop, add a **structured syscall**
returning data (the `sys_procs` model), never a command passthrough.

## Consequences

- `SH.BIN`, `TERM.BIN`, remote, and SSH become **owners/front-ends**, not
  separate hacks; the shell is written once against the seam.
- The kernel grows one bounded pure module plus a device kind in the fd table;
  no new syscall slot is consumed.
- Overflow behavior is explicit and observable (`out_dropped`/`in_dropped`)
  rather than silent.
- The kernel monitor survives as the boot/recovery/diagnostic console (the
  UEFI-shell/BIOS-setup role) — a healthy split, not a migration to delete.

## Open issues (left to later)

- ~~Whether boot policy alone can hand the console over, or a `sys_tty_*` attach
  slot is needed.~~ — **resolved by claim #1075**: slot 67 `sys_tty_attach`.
- ~~The EL0 serial-attached pilot + its class-B gate.~~ — **landed by claim
  #1075**: `TTYECHO.BIN` + `live-ttyecho.spec` (opens `/dev/tty`, attaches the
  serial console, echoes a scripted line into the serial log).
- Multi-terminal allocation (`/dev/ttyN`), ownership transfer, and cleanup
  policy when multiple processes want a terminal.
- Raw/cooked mode and kernel-side echo (only if a front-end wants them).
- The window (TERM.BIN) and net (remote/SSH) front-end implementations (the
  attach selectors are reserved and return `ENOSYS`).
