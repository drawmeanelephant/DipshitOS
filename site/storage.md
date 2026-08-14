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

## Loading programs

`exec <file> [args...]` reads a flat `DSK1` image through the same FAT path,
strips its 24-byte header, rebuilds the user root around its page, and spawns
it at EL0. The program images are embedded on the ESP by the image builder.

<Aside kind="info">

**VERIFIED.** `verify-live-fs` (ESP file window) and `verify-live-gfs` (the
DATA partition, written and persisted across reboot) gate the storage path;
`verify-live-exec` gates program loading.

</Aside>

<Aside kind="warning">

**LIMITATION.** FAT32 only, no directories-with-subdirectories write
semantics beyond what the path resolver exposes, no journaling, no block
cache, and no general file-descriptor layer. It is a storage *driver*, not a
filesystem API.

</Aside>
