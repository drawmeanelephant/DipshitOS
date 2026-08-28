---
title: User programs & demos
parent: capabilities
status: published
tags: [capabilities, userspace, demos]
---

# User programs & demos

The `user/` tree builds flat `.BIN` images that `exec` loads from the ESP and
runs at EL0. Each one is a small proof of a seam. Forty-seven flat images ship on the ESP at the current tree (plus the
dynamic executables and shared libraries listed below):

| Image | Source | Proves |
|-------|--------|--------|
| `USER.BIN` | `user/src/main.zig` | the basic EL0 path: `sys_write`, pings, exit status |
| `COUNTER.BIN` | `user/src/counter.zig` | a never-exiting program that sends IPC and optionally waits |
| `PEER.BIN` | `user/src/peer.zig` | IPC receive: echoes `peer: got ping N` |
| `STATUS43.BIN` | `user/src/status43.zig` | `sys_wait`'s target: sleeps, then exits 43 |
| `UDP.BIN` | `user/src/udp.zig` | the UDP syscall seam: listen, loopback, peer datagram, exit 17 |
| `WIN.BIN` | `user/src/win.zig` | `sys_win_open`/`fill`/`present` — EL0 graphics |
| `WINCLOSE.BIN` | `user/src/winclose.zig` | `sys_win_close` and slot reuse |
| `WINLOOP.BIN` | `user/src/winloop.zig` | a window kept alive across the pixel proof |
| `WINMOVE.BIN` | `user/src/winmove.zig` | move/raise/get/query/set_visible — the full window seam |
| `KEYTEST.BIN` | `user/src/keytest.zig` | the interactive event loop: `sys_poll_event`/`sys_wait_event` |
| `SAVETEXT.BIN` | `user/src/savetext.zig` | `sys_file_write` — persist text to the DATA partition |
| `TYPE.BIN` | `user/src/type.zig` | `sys_file_open`/`read`/`close` — dump a file |
| `DIR.BIN` | `user/src/dir.zig` | `sys_dir_list` — list a directory |
| `CALC.BIN` | `user/src/calc.zig` | the graphical calculator (checked arithmetic, repeat, memory) |
| `NOTEPAD.BIN` | `user/src/notepad.zig` | the graphical editor, load/save `/data/notes.txt`, scrollable viewport |
| `TOP.BIN` | `user/src/top.zig` | the graphical process monitor with click-to-kill (`sys_kill`) |
| `DESKTOP.BIN` | `user/src/desktop.zig` | the launcher: manifests the app catalog (`APPS.TXT`) and `sys_exec`s apps |
| `TCP.BIN` | `user/src/tcp_client.zig` | the TCP syscall seam: connect, send, receive echo, close, exit 18 |
| `FETCH.BIN` | `user/src/fetch.zig` | an HTTP/1.0 client over TCP: request, parse response, exit 42 |
| `CHAT.BIN` | `user/src/chat.zig` | graphical UDP chat: windows + events + `sys_udp_*` |
| `FILE.BIN` | `user/src/file_browser.zig` | the graphical DATA-partition file browser (list, read, delete, rename) |
| `FSTEST.BIN` | `user/src/fstest.zig` | the mutating filesystem seam: create/write → truncate → rename → free → delete |
| `TIMER.BIN` | `user/src/timertest.zig` | the app-timer seam: arm → block on `TIMER` event → cancel |
| `VICTIM.BIN` | `user/src/hardening_victim.zig` | the hostile-EL0 proof's victim: owns a window and yield-loops forever |
| `HARDEN.BIN` | `user/src/harden.zig` | the hostile-EL0 proof's attacker: refused EINVAL on every cross-process window call |
| `JINGLE.BIN` | `user/src/jingle.zig` | the EL0 audio seam: learns the negotiated PCM state, plays Twinkle Twinkle Little Star |
| `CHIME.BIN` | `user/src/chime.zig` | event-triggered sound: arms an app timer, blips 880 Hz on every `TIMER` event |
| `GLOBALS.BIN` | `user/src/globals.zig` | M16 C1: the first segmented DSK3 image — writable globals past the old 16 KiB bound |
| `GUARD.BIN` | `user/src/guard.zig` | M16 C2: steps into its guard page and is reaped 139 |
| `ASM.BIN` | `user/src/asm.zig` | M22 D2: the assembler |
| `DISAS.BIN` | `user/src/disas.zig` | M22 D4: the disassembler |
| `PS.BIN` | `user/src/ps.zig` | M22 D6: the process list |
| `RESMON.BIN` | `user/src/resmon.zig` | M22 D10: the resource monitor |
| `DEVCONS.BIN` | `user/src/devcons.zig` | M22 D14: the developer console |
| `EDIT.BIN` | `user/src/edit.zig` | M23: the text editor (E1–E25: undo/redo, goto, tabs, syntax, console split) |
| `SETTINGS.BIN` | `user/src/settings_panel.zig` | the persistent settings panel |
| `M21DEMO.BIN` | `user/src/m21demo.zig` | M21 W1/W2 tiling + master-detail gate payload |
| `SPIN.BIN` | `user/src/spin.zig` | Arc5 #246: the hostile-consumer (CPU) test |
| `SYSMON.BIN` | `user/src/sysmon.zig` | M27 G6: the system monitor dashboard |
| `PING.BIN` | `user/src/ping.zig` | M26 N1: the ICMP ping seam (`sys_ping_send`/`sys_ping_poll`) |
| `NETSTAT.BIN` | `user/src/netstat.zig` | M26 N2: the network dashboard (`sys_net_stats`) |
| `DNS.BIN` | `user/src/dns.zig` | M26 N5: DNS lookup tool |
| `TRACEROUTE.BIN` | `user/src/traceroute.zig` | M26 N7: traceroute / tracehost CLI |
| `DOWNLOAD.BIN` | `user/src/download.zig` | M26 N11: HTTP download manager |
| `NETPROF.BIN` | `user/src/netprof.zig` | M26 N12: network profile manager |
| `VMTEST.BIN` | `user/src/vmtest.zig` | M29: demand-fault, COW, mmap/munmap, zero-leak teardown |
| `HTTPD.BIN` | `user/src/httpd.zig` | the in-guest HTTP/1.1 web server (TCP passive open, claim 0750) |

**Dynamic executables and shared libraries (M30/M31):**

| Image | Source | Proves |
|-------|--------|--------|
| `LD.SO` | `user/src/ld.zig` | M30: the freestanding runtime linker (PT_DYNAMIC, GOT relocations, AuxV) |
| `LIBUI.SO` / `LIBFONT.SO` | `user/src/libui_so.zig` / `user/src/libfont_so.zig` | M30: position-independent UI + font shared libraries |
| `DYNAPP.ELF` | `user/src/dynapp.zig` | M30 D4: the dynamic-executable proof — links both libraries, opens a window, exits 0 |
| `CALC.ELF` / `NOTEPAD.ELF` / `FILE.ELF` / `DESKTOP.ELF` | migrated M31 apps | M31 E1–E4: the desktop apps rebuilt as dynamic executables |
| `PLUGIN.SO` | loaded via `dlopen`/`dlsym` | M31 E5: runtime-loadable plugin modules |

They are built by the same pipeline as the kernel: Zig → ELF → a flat `DSK1`
image (or a dynamic ELF, for the `.ELF` apps), embedded on the ESP by the
image builder.

<Aside kind="note">

**MIX.** The early images are seam-proving demos; the milestone-eleven and
later images are real applications — a calculator, an editor, a process
monitor, a desktop launcher, a file browser, a text editor, developer tools,
and network apps — built on the zero-heap `ui.zig` widget toolkit and
launched from the desktop. Since M30 the same apps also ship as dynamic
`.ELF` executables linked at runtime by `LD.SO`.

</Aside>
