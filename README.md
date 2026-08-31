# VirelaiOS

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

Every milestone through **thirty-one** has landed and closed — the boot
pipeline, the interactive `virelai>` monitor, userspace (allocator,
scheduler, EL0 + syscalls), processes (IPC, wait, kill), networking
(virtio-net → ARP → IPv4/ICMP → UDP → DHCP → TCP), graphics (framebuffer →
Road Pops terminal → Driving Award window manager), input (USB XHCI + HID),
usability, app events, the userland filesystem, the desktop platform
(`CALC.BIN`, `NOTEPAD.BIN`, `TOP.BIN`, `FILE.BIN`, `DESKTOP.BIN`), network
apps, shared services (clipboard + app timers), audio, kernel consolidation,
desktop completeness and the post-M17 arcs, and the M18–M27 experience layer
(terminal & shell depth, shell programming, text rendering & Unicode, window
management depth, developer tools, the text editor, CALC, file manager depth,
network experience, desktop polish).

The 2026-08-27 hardware-depth trio rounded it out:

- **M28 — SMP:** a second CPU core online via PSCI, per-core schedulers,
  spinlocks, and GICv3 IPIs — `smp: cores=2 online=2` live-gated on real VZ.
- **M29 — VM depth:** demand paging, copy-on-write, and anonymous
  `sys_mmap`/`sys_munmap` (ADR 0007 slots 63/64).
- **M30 — dynamic linking:** a freestanding runtime linker (`LD.SO`) plus
  `LIBUI.SO`/`LIBFONT.SO` shared libraries, zero libc, W^X multi-aperture
  isolation, live-gated.
- **M31 — dynamic linking ecosystem:** the desktop apps migrated to dynamic
  executables (`CALC.ELF`, `NOTEPAD.ELF`, `FILE.ELF`, `DESKTOP.ELF`) with
  runtime `dlopen`/`dlsym` plugin loading.

Also landed: an in-guest HTTP/1.1 web server (`HTTPD.BIN`, TCP passive open,
claim 0750), offline preflight for the M26 network apps (N13/N14), and a
wall-clock bounding fix for `sys_tcp_connect` (#613).

**Right now:** every GitHub milestone is closed and the issue tracker is at
**zero open issues** — the repo sits between milestones, with no M32 defined
yet. The canonical, always-current accounting is
[`docs/status.md`](docs/status.md); the readable summary is the
[documentation site](https://drawmeanelephant.github.io/DipshitOS/).

## Quick start

```bash
git clone https://github.com/drawmeanelephant/DipshitOS.git
cd VirelaiOS
zig build            # compile the AArch64 UEFI application
zig build image      # build the GPT+FAT32 disk image
zig build run        # boot it with Swift + Virtualization.framework
```

`zig build run` boots the whole thing and writes the kernel's serial output to
`artifacts/vm-serial.log`. `zig build console` boots an interactive `virelai>`
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
- `user/` — EL0 programs: flat `.BIN` images, dynamic `.ELF` executables,
  and the `LD.SO`/`LIBUI.SO`/`LIBFONT.SO` shared libraries.
- `host/vm-runner/` — the Swift Virtualization.framework launcher.
- `site/` — the public documentation corpus (compiled by Boris).
- `docs/` — the engineering warehouse: claims, decisions (ADRs), status,
  hardware contract, gate inventory, and the [memorial to `calm-lavoisier`](docs/calm-lavoisier-memorial.md).

See `AGENTS.md` for the project rules, and the
[development guide](https://drawmeanelephant.github.io/DipshitOS/development.html)
for how the pieces fit.

## License

VirelaiOS is **source-available, not open source** — the code is publicly
visible so it can be reviewed and learned from, but you may not use, modify,
redistribute, or incorporate it without written permission. Forks are not
freedom. The binding terms are [`LICENSE`](LICENSE); a plain-language summary
is on the [documentation site](https://drawmeanelephant.github.io/DipshitOS/license.html).
