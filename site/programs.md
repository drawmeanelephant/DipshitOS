---
title: User programs & demos
parent: capabilities
status: published
tags: [capabilities, userspace, demos]
---

# User programs & demos

The `user/` tree builds flat `.BIN` images that `exec` loads from the ESP and
runs at EL0. Each one is a small proof of a seam.

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
| `FILE.BIN` | `user/src/file_browser.zig` | the graphical DATA-partition file browser (`sys_dir_list` + read-only open) |

They are built by the same pipeline as the kernel: Zig → ELF → flat `DSK1`
image, embedded on the ESP by the image builder.

<Aside kind="note">

**MIX.** The early images are seam-proving demos; the milestone-eleven and
later images are real applications — a calculator, an editor, a process
monitor, a desktop launcher, and a file browser — built on the zero-heap
`ui.zig` widget toolkit and launched from the desktop.

</Aside>
