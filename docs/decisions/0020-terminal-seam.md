# ADR 0020: The terminal (vt) seam — a userland-ownable console

Status: **ACCEPTED** · Date: 2026-09-10 · amended 2026-09-11 (Amendment A,
the window front-end — M45 card SH6, #1082; Amendment B, the net/remote
front-end — M45 card SH7, #1083) · Milestone: M44 (next focus) ·
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
- ~~The window (TERM.BIN) front-end implementation.~~ — **design resolved by
  Amendment A** (below); implementation is M45 card SH6 (#1082).
- The net (remote/SSH) front-end implementation (selector `3` stays reserved
  and returns `ENOSYS`). — **design resolved by Amendment B** (below);
  implementation is M45 card SH7 (#1083).

---

# Amendment A — the window front-end (`TERM.BIN`, selector 2)

Status: **ACCEPTED** (design) · Date: 2026-09-11 · Card **SH6** (#1082) ·
Implementation tracked by #1082. The D1–D5 decisions above are unchanged;
this amendment only fixes the window front-end the original D3/Open-issues
left reserved.

## Context

The seam ships the serial front-end only. M45 card SH6 asks for `TERM.BIN`, a
TABWM terminal window that renders a shell's terminal and feeds its keys
(selector `2`, today `ENOSYS`). Four questions were open: **who owns the
binding**, **who drains the output ring**, **who pushes input**, and
**close/detach policy**. This amendment settles them against the existing
kernel seams (`kernel/src/terminal.zig`, the `/dev/tty` routing in
`kernel/src/file_table.zig`, `handle_tty_attach`, `input.zig`'s
`focused_owner`/`hid_to_bytes`, and `driving_award.zig`'s per-process window
ownership). No code lands here.

## Decisions

### A1. The window front-end is kernel-pumped, exactly like serial
The terminal object stays a pure byte session (D1). A front-end binding names
a **window**; the kernel moves bytes between the terminal rings and the window,
symmetric with `pumpRuntimeInput`/`pumpRuntimeOutput` for the serial console.
**No terminal-I/O syscall is added** (D3 holds): the owner keeps reading and
writing `/dev/tty`.

### A2. The owner attaches its own window
`sys_tty_attach` selector `2` gains a second argument, `window_id`. The caller
must **own** the `.user` window (the `sys_win_fill` ownership rule) and must
already have opened `/dev/tty` (its controlling terminal). The binding is
exclusive per terminal (D2) and mutually exclusive with the serial front-end;
selector `0` detaches and frees both. Selector `3` (net) stays `ENOSYS`.

Rationale: a window front-end needs **no cross-process access**. The process
that owns the terminal also owns the window and is the single writer of both,
so ADR 0020's per-process terminal invariant (`controlling_terminal(pid)`) is
preserved and no new capability appears (no reading another process's
terminal, no drawing into another's window).

### A3. `TERM.BIN` hosts the shell in-process
`TERM.BIN` is the owner: it opens a `.user` window, opens `/dev/tty`, calls
`sys_tty_attach(2, id)`, and runs the shared shell core
(`user/src/lib/shell.zig` + `user/src/lib/tty.zig`) over the terminal fd — the
same core as `SH.BIN`, a different presentation. The kernel renders; `TERM.BIN`
draws no pixels itself. `SH.BIN` remains the serial/raw-console shell
(ADR 0021 D1); the desktop presentation is `TERM.BIN`. A future split into a
separate shell process plus a front-end capability is deferred to its own
amendment.

### A4. Rendering is kernel-side, into the bound window
On the owner's `/dev/tty` write, after appending to the output ring, the kernel
drains the ring into a bounded per-terminal character grid + scrollback (sized
like `text.zig`), marks the bound window damaged, and lets the existing
compositor present it on its cadence (the deferred-present discipline, the
`sys_win_present` shape). The glyph raster is the kernel's. Terminal output
stays a byte pipe (D1); the grid is presentation state, not part of the
terminal object.

### A5. Window keys feed the terminal input queue
`input.zig` already routes key events to the focused user window's owner
(`focused_owner`). For a window bound as a terminal front-end, key events are
encoded with the existing `hid_to_bytes` encoder and pushed into the bound
terminal's input queue — the same byte encoding the serial console path uses,
so the shell's line editor stays byte-driven and front-end-agnostic. Non-key
events (`WIN_CLOSE`, `WIN_RESIZE`, `WIN_FOCUS`/`WIN_BLUR`) are still delivered
to the owner, so the host observes close/resize. The binding does **not** steal
focus: when the window is not focused, keys go where focus says.

### A6. Close and detach
Closing the bound window (owner `sys_win_close`, owner exit, or the WM close
path) auto-detaches the terminal; the terminal survives, buffered, unattached
(D2), and the serial console is **not** reclaimed automatically (boot default
unchanged, D4). `sys_tty_attach(0)` is the explicit detach. A terminal has at
most one window binding, and a window at most one terminal.

## Rejected alternatives

- **Cross-process front-end fd** (a `TERM.BIN` child attaches to `SH.BIN`'s
  terminal and drains/pushes via inverted `/dev/tty` read/write): preserves
  crash isolation but invents a cross-process terminal capability and inverts
  the fd direction — a bigger ABI/security decision than SH6 needs. Deferred.
- **Userland-rendered GUI terminal** (a normal app that reads keys from events
  and draws with `lib/ui.zig`, bypassing the seam): simplest, but it does not
  exercise the terminal seam, so remote/SSH could not reuse the path. Rejected
  for this card.

## Open issues left by this amendment

- Kernel grid bounds/scrollback and `WIN_RESIZE` reflow.
- The separate-shell-process split (would need its own amendment).
- The net front-end (`3`) keeps its own amendment.

---

# Amendment B — the net (remote TCP) front-end (selector 3)

Status: **ACCEPTED** (design) · Date: 2026-09-11 · Card **SH7** (#1083) ·
Implemented 2026-09-11 (claim #1102): the kernel net front-end + pump,
`SH.BIN net [port]`, the host-client runner seam (`--net-tcp-connect`), and
the class-B `live-remote` gate (**PASS**). The D1–D5 decisions and Amendment A
are unchanged; this amendment only fixes the net front-end the original
D3/Open-issues left reserved.

## Context

The seam ships the serial front-end (ADR 0020) and the window front-end
(Amendment A). M45 card SH7 asks for a **remote TCP session** that drives a
shell's terminal: a client connects over the network, types into the shell,
and sees its output — "remote in" without SSH first (#1066 Stage 1). Selector
`3` (`.net`) is reserved and returns `ENOSYS` today.

The kernel already has a bounded TCP seam (`kernel/src/tcp.zig` + slots
30–33) and a listener consumer (`HTTPD.BIN`): `sys_tcp_connect(0, port)`
passive-opens a listener; an incoming SYN completes a server handshake with a
**fixed server ISN**; `sys_tcp_send`/`sys_tcp_recv`/`sys_tcp_close` move
bytes. The stack is a **single** bounded connection at a time, has **no TCP
loopback** (an own-IP connect is refused `.no_peer`), no reassembly, a fixed
4096 window, and a `payload_max` TX/RX bound. Four questions were open: **who
listens**, **who pumps the bytes**, **what the trust posture is**, and
**how disconnect is handled**. This amendment settles them against those
seams. No code lands here.

## Decisions

### B1. The net front-end is kernel-pumped, exactly like serial and window
The terminal object stays a pure byte session (D1). A front-end binding names
a **TCP listener port**; the kernel moves bytes between the terminal rings and
the kernel TCP connection, symmetric with `pumpRuntimeInput`/
`pumpRuntimeOutput` for the serial console and the Amendment-A window pump.
**No terminal-I/O syscall is added** (D3 holds): the owner keeps reading and
writing `/dev/tty`. Bytes are raw — no line discipline, no echo, no crypto.

### B2. The owner attaches its own listener
`sys_tty_attach` selector `3` gains an argument, `args[1] = listen port`. The
caller must already have opened `/dev/tty` (its controlling terminal). The
kernel enters LISTEN on that port through the same path as
`sys_tcp_connect(0, port)` (reusing the `tcp.zig` passive-open state
machine), records the caller as the connection owner (`tcp.owner_pid`), and
binds the terminal `.net`. The binding is exclusive per terminal (D2) and
**mutually exclusive with the serial and window front-ends**; `sys_tty_attach(0)`
detaches and closes the listener. Because the TCP seam is a **single
connection at a time**, at most one terminal may hold the net front-end: a
second `sys_tty_attach(3, …)` while a session is listening/connected is
`EACCES`, and a port already owned by another process is `EACCES` too.

Rationale: a net front-end needs **no cross-process access**. The process
that owns the terminal also opens the listener and is the single writer of
both, preserving ADR 0020's per-process terminal invariant
(`controlling_terminal(pid)`) and adding no capability (no reading another
process's terminal, no steering another process's socket). This is the same
reasoning as A2.

### B3. The pump moves bytes between the terminal rings and the connection
On the owner's `/dev/tty` write, after appending to the output ring, the
kernel drains the ring into TCP data segments (chunked to the stack's
`payload_max`, the honest bound — overflow is the stack's documented
behavior, never silent), and a received TCP payload is pushed into the
terminal's input queue. The pump is driven from the kernel idle loop and
flushed from the terminal write path, symmetric with the serial pump (D2/A1).
The shell's line editor stays byte-driven and front-end-agnostic (A5's
principle): `SH.BIN` and `TERM.BIN` run unchanged over a net-attached
terminal.

### B4. Disconnect, detach, and lifecycle
A client disconnect (FIN/RST), a `sys_tcp_close` on the session,
`sys_tty_attach(0)`, or owner exit auto-detaches the terminal; the terminal
survives, buffered, unattached (D2), and the serial console is **not**
reclaimed automatically (boot default unchanged, D4). The listener is closed
on detach so no port lingers. The net front-end is a **session** front-end:
a disconnect ends the session, and the owner may re-attach (re-listen) to
accept again. A terminal has at most one net binding; a net session has at
most one terminal.

### B5. Trust posture — plaintext, trusted-network only
v1 adds **no authentication, encryption, or source-IP filtering**. The
listener binds the guest's own IP and the requested port; anyone who can
reach it obtains a shell at the owner's privilege. This is an explicit,
documented posture (ADR, `docs/status.md`, help), not an accident: the
machine is expected to be on a trusted network / behind the VZ NAT boundary.
SSH/TLS is #1066 Stage 2/3 and rides this same seam as another front-end; a
bounded shared-secret or source-IP allowlist is a follow-up, not SH7.

### B6. Remote is a front-end of the shell, not a separate shell
`SH.BIN` and `TERM.BIN` can each open a listener and attach selector `3`; the
shared shell core (`lib/shell.zig` + `lib/tty.zig`) is unchanged. No dedicated
`REMOTED.BIN` is required, and a cross-process front-end is rejected for the
same reason as A's cross-process fd. The remote presentation is the shell
seen through a fourth front-end.

## Class-B gate topology (host → guest inbound)

`kernel/src/tcp.zig` has **no loopback** (own-IP connect refused `.no_peer`)
and the guest is behind VZ NAT, so the gate cannot use an in-guest client and
the host cannot reach in without a forward. The live gate therefore adds a
**host-side TCP client seam** to `host/vm-runner`
(`--net-tcp-connect <guest-ip>:<port>[:<payload-file>]`): it initiates the
SYN toward the guest's listener, completes the handshake (the guest's server
ISN is fixed; the runner's ISN is deterministic), sends the payload, captures
the guest's reply, then closes. The gate: the guest shell attaches selector
`3` on a port, the host connects and sends `echo remote-ok\n`, the serial log
shows the shell output, and the client FIN detaches the terminal
(`attached` → `detached`, session closed). This runner + spec work lands in
the implementation tranche (#1083), alongside class-A terminal
net-binding/pump tests.

## Rejected alternatives

- **Cross-process front-end process** (`REMOTED.BIN` accepting and feeding a
  *different* process's terminal): invents a cross-process terminal
  capability. Rejected for the same reason as Amendment A's cross-process fd.
- **In-guest loopback client:** impossible today — the TCP seam refuses
  own-IP connects and has no loopback. The gate connects from the host.
- **SSH-first / crypto:** out of scope. #1066 Stage 2 builds the primitives
  first; SSH is Stage 3 and reuses this seam.
- **A userland app that shells out over TCP** (bypassing the seam): does not
  exercise the terminal seam, so remote/SSH could not reuse the path.

## Open issues left by this amendment

- Authentication (shared secret / source-IP allowlist) and TLS/SSH over the
  same seam (#1066 Stage 2/3).
- Multiple concurrent remote sessions — needs a multi-connection TCP stack;
  today the seam is a single connection at a time.
- Listener bind-address/port policy and a `settings` key (deferred to SH8).
- The host-client runner seam's exact deterministic ISN/pacing contract.
