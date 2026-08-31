# VirelaiOS teams & file ownership

> Rule: **don't touch another team's files — file a GitHub issue against them.**
> This isn't enforced by tooling; it's a convention that lets 3–5 agents
> work in parallel without merge-conflicting each other.

## Teams

### Core — boot, memory, interrupts, EL state

| File | Lines | Role |
|------|-------|------|
| `kernel/src/main.zig` | 1,692 | boot sequence, init order |
| `kernel/src/alloc.zig` | — | physical page allocator |
| `kernel/src/memmap.zig` | — | EFI memory map |
| `kernel/src/mmu.zig` | — | EL1 page tables, TTBR0/TTBR1 |
| `kernel/src/exceptions.zig` | — | VBAR_EL1, sync/IRQ vectors |
| `kernel/src/userspace.zig` | — | EL0 entry contract |
| `kernel/src/uaccess.zig` | — | copy_in/copy_out + fault recovery |
| `kernel/src/console.zig` | — | serial mock + real console |
| `kernel/src/gic.zig` | — | GIC distributor + redistributor |
| `kernel/src/timer.zig` | — | CNTP timer |
| `kernel/src/machine.zig` | — | EFI runtime services, reboot |
| `kernel/src/evidence.zig` | — | NVRAM markers |
| `kernel/src/handoff.zig` | — | loader → kernel handoff |
| `kernel/src/mmio.zig` | — | MMIO accessors |
| `kernel/src/pci.zig` | — | PCI config space |
| `kernel/src/virtio_console.zig` | — | virtio serial console |
| `kernel/src/virtio_custom.zig` | — | custom virtio device (diag) |
| `kernel/src/walkprobe.zig` | — | diagnostic walk probe |
| `kernel/src/nvram_console.zig` | — | NVRAM console fallback |
| `build.zig` | — | Zig build system |
| `.github/` | — | CI workflows |
| `justfile` | — | developer quick-ref |

**Owns:** Boot pipeline, memory model, interrupt dispatch, exception levels,
platform init. Everything from UEFI exit to the first shell prompt.

### Desktop — compositor, rendering, input, windows

| File | Lines | Role |
|------|-------|------|
| `kernel/src/driving_award.zig` | 3,617 | window manager + compositor |
| `kernel/src/text.zig` | — | framebuffer text renderer |
| `kernel/src/font8x8.zig` | — | 8×8 glyph table |
| `kernel/src/road_pops.zig` | — | Road Pops tee (boot terminal) |
| `kernel/src/input.zig` | — | HID → keycode decode |
| `kernel/src/xhci.zig` | — | XHCI USB host controller |
| `kernel/src/clipboard.zig` | — | kernel clipboard |
| `user/src/lib/ui.zig` | — | UI widget toolkit |
| `user/src/desktop.zig` | — | desktop launcher |
| `user/src/calc/` | — | calculator app |
| `user/src/notepad.zig` | — | notepad app |
| `user/src/top.zig` | — | task manager app |
| `user/src/file_browser.zig` | — | file browser app |

**Owns:** Screen, windows, mouse/keyboard input, UI toolkit, desktop apps.

### Net — network stack, TCP, DNS, DHCP

| File | Lines | Role |
|------|-------|------|
| `kernel/src/virtio_net.zig` | 1,972 | virtio-net driver |
| `kernel/src/arp.zig` | — | ARP table + requests |
| `kernel/src/ipv4.zig` | — | IPv4 dispatch, ICMP echo |
| `kernel/src/udp.zig` | — | UDP listener table |
| `kernel/src/tcp.zig` | — | TCP state machine |
| `kernel/src/dhcp.zig` | — | DHCP client lifecycle |
| `kernel/src/dns.zig` | — | DNS resolver |
| `kernel/src/csprng.zig` | — | ChaCha20 CSPRNG |
| `kernel/src/virtio_entropy.zig` | — | virtio entropy driver |
| `user/src/fetch.zig` | — | HTTP fetch app |
| `user/src/chat.zig` | — | chat app |
| `user/src/tcp.zig` | — | TCP test app |

**Owns:** All network I/O from the virtio queue to the application socket.

### Shell/Process — shell, process model, IPC, app lifecycle

| File | Lines | Role |
|------|-------|------|
| `kernel/src/shell.zig` | 2,759 | interactive shell |
| `kernel/src/monitor.zig` | 6,997 | monitor commands |
| `kernel/src/process.zig` | — | process registry |
| `kernel/src/exec.zig` | — | ELF/flat image loader |
| `kernel/src/elf.zig` | — | ELF parser |
| `kernel/src/scheduler.zig` | 1,962 | task scheduler |
| `kernel/src/mailbox.zig` | — | inter-process mailbox |
| `kernel/src/pipe.zig` | — | shell pipe buffer |
| `kernel/src/events.zig` | — | per-process event queues |
| `kernel/src/app_timers.zig` | — | per-app timers |
| `kernel/src/settings.zig` | — | persistent settings |
| `kernel/src/lineedit.zig` | — | line editor |
| `kernel/src/tokenizer.zig` | — | command tokenizer |
| `kernel/src/scrollback.zig` | — | terminal scrollback |
| `kernel/src/tombstone.zig` | — | crash tombstones |
| `kernel/src/serial_ring.zig` | — | serial event ring |
| `user/src/` | all non-Desktop non-Net apps | user programs |

**Owns:** Shell, commands, process lifecycle, IPC, event system, all
non-Desktop/non-Net user programs.

### Storage/Files — filesystem, FAT, ESP, disk image

| File | Lines | Role |
|------|-------|------|
| `kernel/src/fat.zig` | — | FAT32 driver |
| `kernel/src/esp.zig` | — | ESP mount + files |
| `kernel/src/file_table.zig` | — | per-process file handles |
| `kernel/src/virtio_blk.zig` | — | virtio-blk driver |
| `image/mkfat32.py` | — | FAT image builder |
| `image/make-image.sh` | — | disk image assembly |
| `image/apps.txt` | — | application manifest |

**Owns:** Everything from the virtio-blk queue to the file descriptor table.

### VZ/Host — host runner, CI, gate scripts, tools

| File | Role |
|------|------|
| `host/vm-runner/Sources/*.swift` | VZ host launcher |
| `tools/verify-live.sh` | unified gate runner |
| `tools/gates/*.sh` | per-gate definitions |
| `tools/lib/verify-live-common.sh` | shared gate boilerplate |
| `tools/verify-unit-tests.sh` | unit test gate |
| `tools/verify-bss-budget.sh` | BSS budget gate |
| `tools/verify-glyph-raster.sh` | glyph raster gate |
| `tools/verify-mutations.sh` | mutation gate |
| `tools/verify-mmu-debt.sh` | MMU debt gate |
| `tools/elf2bin.py` | ELF → flat image converter |
| `tools/mkhello-elf.py` | example ELF generator |
| `tools/decode-screen-glyphs.py` | glyph screenshot decoder |
| `tools/ragshit/` | context engine (dev tooling) |
| `docs/status.md` | living status |
| `docs/testing.md` | testing policy |
| `docs/gate-inventory.md` | gate classification |
| `docs/roadmap.md` | milestone plan |
| `docs/agent-concurrency-plan.md` | lane assignments |
| `docs/TEAMS.md` | this file |
| `docs/CLAIMS.md` | active work table |

**Owns:** Host tooling, CI, gate infrastructure, docs (except ADRs owned
by the relevant team).

## Shared files: the syscall table

`kernel/src/syscall.zig` (3,353 lines) is touched by every team that adds
a new service. Convention:

1. **File a GitHub issue** before you need a slot. Issue title: "Reserve
   syscall slot N for `<purpose>`". Tag the Core team.
2. **Core owns the dispatch table structure** — they add the slot number,
   the handler stub, and bump `implemented_count`.
3. **Your team implements the handler function** (in a file you own) and
   Core plumbs it into the dispatch.
4. **Event kinds** follow the same pattern: file an issue, Core reserves
   the kind number in `events.zig`, your team uses it.

## Cross-team dependency rule

When you need something from another team's zone, you file a **real
GitHub issue** on the project repository. The issue body should state:

- What you need (precisely)
- What depends on it (so they can prioritize)
- What the interface is (function signature, syscall slot, event kind)

Do not just edit another team's file and hope they notice. The issue
is the coordination surface.

## Active work tracking

See [`docs/CLAIMS.md`](CLAIMS.md) for the single-table active-work tracker.
No claim IDs, no index regeneration, no coordination verification scripts.
Just a table. Update it when you start and when you finish.