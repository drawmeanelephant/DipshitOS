---
title: Roadmap & status
status: published
tags: [roadmap, status]
---

# Roadmap & status

This page summarizes the milestone plan. The repository's
[`docs/status.md`](https://github.com/drawmeanelephant/DipshitOS/blob/main/docs/status.md)
is the canonical, always-current source; this is the readable summary.

## Shipped

| Milestone | What landed |
|-----------|-------------|
| 0–2 | Boot pipeline, kernel handoff, `ExitBootServices`, identity-map MMU, polled serial console |
| 1.5 | The interactive `dipshit>` monitor: shell, filesystem, reboot/shutdown |
| 3 | Allocator, GIC + timer, scheduler, EL0 + syscalls, uaccess, address spaces, exec |
| 4 | Entropy/ChaCha20 + ASLR, general filesystem, process registry, IPC, wait, kill, scale |
| 5 | Networking N1–N11: net TX/RX, ARP, IPv4/ICMP, UDP, the UDP syscall seam, NAT, DHCP, DHCP renew, TCP, TCP retransmission |
| 6 | Graphics G1–G6: framebuffer, text, Road Pops, Driving Award, the draw/window syscall seam |
| 7 | Input I1–I3: XHCI transport, USB enumeration + HID, the event FIFO + keycode decode |
| 8 | Usability U0–U8: ADR 0008 HIG, grouped `help`, line editing + history, the one error contract, window chrome (focus rings + title bars), `welcome`/`about`/`motd`, `sysinfo`, persistent settings on the DATA partition |
| 9 | Events E0–E6: per-process event queues, keyboard/pointer/window events to focused EL0 apps, `sys_poll_event`/`sys_wait_event` (slots 21/22), `KEYTEST.BIN` |
| 10 | Files & storage F0–F4: ADR 0010, per-process file table, `/esp/` + `/data/` routing, file syscalls (slots 23–27), `SAVETEXT.BIN`/`TYPE.BIN`/`DIR.BIN` |
| 11 | Desktop platform A0–A5: ADR 0011, the zero-heap `ui.zig` toolkit, `CALC.BIN`/`NOTEPAD.BIN`/`TOP.BIN`, the `DESKTOP.BIN` launcher, `sys_exec`/`sys_kill` (slots 28/29) |
| 12 | Network apps N0–N3: TCP syscall seam (slots 30–33), RFC 1035 DNS, `TCP.BIN`/`FETCH.BIN`/`CHAT.BIN` |
| 13 | Files & applications B1–B4: mutating filesystem seam (B1, slots 34–37), `APPS.TXT` identity manifest (B2), the `FILE.BIN` graphical data browser (B3), and manifest-driven desktop composition (B4) |
| 14 | Shared user services S1–S4: the clipboard (slots 38–39), app timers (slots 40–41), the NOTEPAD composition capstone, and security/isolation hardening (the TCP owner fix + the hostile-EL0 gate) |
| 15 | Audio A1–A4: virtio-snd transport, PCM playback + `beep`, the EL0 audio seam (slots 42–45), `JINGLE.BIN`, the boot chime, and `CHIME.BIN` |
| 16 | Kernel consolidation C1–C4: multi-segment user images, guard pages + per-segment permissions, measured pools, one-session composition |
| 17 | Desktop completeness C1–C10 + Arc1–5: widget depth, window management, app upgrades, rich interactions, system polish |
| 18 | Terminal & shell depth: scrollback, selection, search, persistent history, colors, scripting mode |
| 19 | Shell as a programming environment: pipes (slots 56/57), redirection, env vars, functions + args, substitution, arithmetic, conditionals |
| 20 | Text rendering & Unicode: font sizes, Unicode glyphs, search, chrome, tabs |
| 21 | Window management depth: tiling, master-detail, minimize, alt-tab, notification center, maximize, focus rings |
| 22 | Developer tools: ELF loader, assembler, symbols, disassembler, strace |
| 23 | The text editor: `EDIT.BIN` with undo/redo, goto, tabs, syntax, console split |
| 24 | CALC grows up: programmer mode, memory, units, constants, history persist |
| 25 | File manager depth: du, sort, overwrite/conflict, path copy |
| 26 | Network experience: ping, netstat, traceroute, HTTP fetch display, offline preflight |
| 27 | Desktop polish & completeness G1–G30 (issues #444–#473): splash, wizard, about, previews, sounds, sysmon, tooltips, audits, dogfood |
| 28 | SMP: a second CPU core via PSCI, per-core schedulers, spinlocks, GICv3 IPIs |
| 29 | VM depth: demand paging, copy-on-write, anonymous `sys_mmap`/`sys_munmap` (slots 63/64) |
| 30 | Dynamic linking: freestanding `LD.SO`, `LIBUI.SO`/`LIBFONT.SO`, W^X multi-aperture isolation |
| 31 | Dynamic linking ecosystem: `CALC.ELF`/`NOTEPAD.ELF`/`FILE.ELF`/`DESKTOP.ELF`, `dlopen`/`dlsym` |

Every milestone through **thirty-one** is **done** and live-gated. Post-milestone
landings include the `HTTPD.BIN` in-guest HTTP/1.1 web server (TCP passive
open, claim 0750), the M26 offline-preflight cards N13/N14 (claim 8852), and
the `sys_tcp_connect` wall-clock fix (issue #613, claim 2572).

## Current

**There is no active milestone.** Every GitHub milestone is closed, the issue
tracker is at **zero open issues** (2026-08-28), and no claim is active on a
branch — the project sits between milestones, with no M32 defined yet. The
canonical answer to "what's next" lives in the repository's
`docs/status.md`.

Honest-bound edges that remain planned regardless of milestone:

- **The balloon device** — the last unattached virtio surface (low priority;
  the guest is a fixed 256 MiB, and demand paging now exists but does not
  make memory reclaimable).
- **Routing beyond the NAT gateway** and any IPv6 stack; TCP RTO stays fixed
  (no adaptive estimation), and the TCP client is single-connection.
- **Deeper filesystem semantics** — M13's B1 shipped delete/rename/
  truncate/free and no app has produced new pressure.
- **Multi-display and accelerated/3D graphics** — the guest stays
  single-display, 2D-blit-only.

Both former "open thread" caveats are resolved and shipped: the M8 U4
pointer-focus proof is now class-B-headless via custom-virtio pointer
injection (claim 9367), and the synthesized-keyboard `events=0` report is
fixed by the headless virtio input channel (claims 9588/0680).

<Aside kind="note">

**PLANNED.** Nothing on this page is shipped until it has a gate; the march
trackers (`docs/march-m*.md`) are the live per-card status, and this page
reports only what has actually landed.

</Aside>

## How to read the status

- **Shipped** = landed, merged, and gated.
- **In progress** = claimed on a branch, not yet merged.
- **Planned** = sketched, with no gate yet.

The repository distinguishes these strictly: claims are only flipped to
observed when the matching live gate passes, and the [[evidence]] page
explains the classification.

<Aside kind="warning">

**LIMITATION.** Do not read the repository's `docs/` planning prompts as
shipped features. The planning tree is an engineering warehouse; this site is
the public index of what actually landed.

</Aside>
