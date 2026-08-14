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

They are built by the same pipeline as the kernel: Zig → ELF → flat `DSK1`
image, embedded on the ESP by the image builder.

<Aside kind="note">

**PLANNED.** These are seam-proving demos, not applications. A real desktop
with clickable windows is the next milestone's work — see [[roadmap]].

</Aside>
