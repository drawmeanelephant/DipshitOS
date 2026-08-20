---
title: Storage & filesystem
parent: capabilities
status: published
tags: [capabilities, storage, fat]
---

# Storage & filesystem

Files live on the disk itself, in a FAT32 volume read and written through a
virtio-blk transport — not in NVRAM variables or a host-side snapshot.

## The stack

- **`virtio_blk.zig`** — a modern virtio-blk transport (DID 0x1042), re-armed
  after `ExitBootServices` (the device resets there — observed).
- **`fat.zig`** — GPT + FAT32 mount, list, read, and write over injected
  sector I/O, with directory cluster chains and `/`-path resolution.
- **Commands** — `ls [<dir>]`, `cat <file|path>`, `write <file> <bytes>`,
  `mount <esp|data>`.

## Two volumes

The disk image carries:

- the **ESP** (`EFI/BOOT/BOOTAA64.EFI` + `KERNEL.BIN` + the user `.BIN`
  programs), and
- a second **DATA** FAT32 partition (36 MiB, Linux-FS type GUID) mounted by
  `mount data`.

A file written to the DATA volume persists across a real reboot on the disk
itself — that is the live gate `verify-live-gfs`.

## The userland file ABI

Milestone ten opened storage to EL0: a per-process file-handle table
(`kernel/src/file_table.zig`, 8 static handles, reset at process lifecycle)
behind the `sys_file_open`/`read`/`write`/`close` and `sys_dir_list` syscalls
(slots 23–27), with path canonicalization routing `/esp/...` and `/data/...`
to the right volume. `SAVETEXT.BIN`, `TYPE.BIN`, and `DIR.BIN` prove the
seam; `NOTEPAD.BIN` and `FILE.BIN` use it for real work. Milestone thirteen's
B1 card extended the seam with `sys_file_delete`/`rename`/`truncate`/`free`
(slots 34–37) — proven live by `FSTEST.BIN` and exposed through `FILE.BIN`'s
Delete/Rename buttons.

## Loading programs

`exec <file> [args...]` reads a flat `DSK1` image through the same FAT path,
strips its 24-byte header, rebuilds the user root around its page, and spawns
it at EL0. The program images are embedded on the ESP by the image builder.

<Aside kind="info">

**VERIFIED.** `verify-live-fs` (ESP file window) and `verify-live-gfs` (the
DATA partition, written and persisted across reboot) gate the storage path;
`verify-live-exec` gates program loading, and `verify-live-user-fs` gates the
userland file syscall ABI end to end.

</Aside>

<Aside kind="warning">

**LIMITATION.** FAT32 only, no directories-with-subdirectories write
semantics beyond what the path resolver exposes, no journaling, and no block
cache. The ABI covers delete, rename, truncate, and free (slots 34–37,
milestone thirteen's B1 card), but it is a storage *driver* with a bounded
file API, not a POSIX filesystem.

</Aside>
