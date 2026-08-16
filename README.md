# DipshitOS

[![CI](https://github.com/drawmeanelephant/DipshitOS/actions/workflows/ci.yml/badge.svg)](https://github.com/drawmeanelephant/DipshitOS/actions/workflows/ci.yml)

A from-scratch AArch64 operating system. It boots under real UEFI firmware on
**Apple silicon**, hosted by Apple's **Virtualization.framework**
(**macOS 27 or newer**). It is **not Linux, not Unix, and not QEMU** — no
libc, no POSIX, no existing guest OS, no emulator in the boot path. The guest
is freestanding [Zig](https://ziglang.org/); the host launcher is Swift.

The name is a joke. The engineering is not: every subsystem is either verified
deterministically or **live-gated** on real hardware.

📚 **Documentation site: <https://drawmeanelephant.github.io/DipshitOS/>**
(compiled by [Boris](https://github.com/drawmeanelephant/boris) and published
to GitHub Pages).

## Status

Every milestone planned so far has landed: boot/kernel proper, the interactive
`dipshit>` monitor, userspace (allocator, scheduler, EL0 + syscalls), processes
(IPC, wait, kill), networking (virtio-net → ARP → IPv4/ICMP → UDP → DHCP →
TCP), graphics (framebuffer → Road Pops terminal → Driving Award window
manager), input (USB XHCI + HID), and — **milestone eleven (2026-08-16)** — a
full **desktop platform**: the ADR 0011 GUI contract, a zero-heap micro-widget
toolkit, and four real apps (`CALC.BIN`, `NOTEPAD.BIN`, `TOP.BIN`,
`DESKTOP.BIN`) with an EL0 `sys_exec`/`sys_kill` process-control seam so the
desktop launcher actually launches apps and the task manager can kill them.

**Now in progress (milestone twelve):** userland network applications — a TCP
syscall seam (`sys_tcp_connect/send/recv/close`, ADR 0007 slots 30–33), a
bounded DNS client, and the `FETCH.BIN` + `CHAT.BIN` capstone.

The canonical, always-current accounting is
[`docs/status.md`](docs/status.md); the readable summary is the
[documentation site](https://drawmeanelephant.github.io/DipshitOS/).

## Quick start

```bash
git clone https://github.com/drawmeanelephant/DipshitOS.git
cd DipshitOS
zig build            # compile the AArch64 UEFI application
zig build image      # build the GPT+FAT32 disk image
zig build run        # boot it with Swift + Virtualization.framework
```

`zig build run` boots the whole thing and writes the kernel's serial output to
`artifacts/vm-serial.log`. `zig build console` boots an interactive `dipshit>`
console; `zig build test-console` runs the deterministic transcript test.

**Requirements:** Apple silicon, macOS 27+, Zig 0.16.0, Swift + Xcode command
line tools, Python 3, bash. No root, no `mtools`, no Linux/QEMU path.

## Verification

The project separates two classes of evidence:

- **Class A** — deterministic (formatting, unit tests, a byte-identical console
  transcript, the build pipeline). Runs in CI on every push.
- **Class B** — **live-gated**: boots a real Virtualization.framework VM on
  Apple silicon and asserts on what the kernel reports. CI cannot run these.

```bash
just verify-portable   # class A, mirrors CI
just verify-vz         # class B, Apple silicon, boots real VMs
```

## Layout

- `boot/` — the AArch64 UEFI boot loader.
- `kernel/` — the freestanding kernel and every subsystem.
- `user/` — EL0 demo programs (`.BIN` images loaded by `exec`).
- `host/vm-runner/` — the Swift Virtualization.framework launcher.
- `site/` — the public documentation corpus (compiled by Boris).
- `docs/` — the engineering warehouse: claims, decisions (ADRs), status,
  hardware contract, gate inventory.

See `AGENTS.md` for the project rules, and the
[development guide](https://drawmeanelephant.github.io/DipshitOS/development.html)
for how the pieces fit.

## License

DipshitOS is **source-available, not open source** — the code is publicly
visible so it can be reviewed and learned from, but you may not use, modify,
redistribute, or incorporate it without written permission. Forks are not
freedom. The binding terms are [`LICENSE`](LICENSE); a plain-language summary
is on the [documentation site](https://drawmeanelephant.github.io/DipshitOS/license.html).
