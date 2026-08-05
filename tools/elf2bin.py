#!/usr/bin/env python3
"""Convert a Zig aarch64-freestanding ELF executable into the DipshitOS flat
kernel image (KERNEL.BIN). Pure Python 3 standard library only.

Format v1 (see docs/decisions/0002-kernel-handoff.md):

  offset 0:  u32 magic        = 0x314B5344 ("DSK1")
  offset 4:  u32 flags        = 0
  offset 8:  u64 entry_offset  (bytes from the START OF THE FILE -- i.e.
             including this 24-byte header -- to the entry point; the loader
             jumps to base + entry_offset)
  offset 16: u64 image_size    (total file size, including this 24-byte header)
  offset 24: loadable content  (PT_LOAD segments placed at their vaddr
             relative to the lowest segment vaddr, preserving the linker's
             exact relative layout so PC-relative addressing (adr/adrp)
             stays valid when the loader places the image at any 4K-aligned
             base; memsz > filesz regions are zero-filled for BSS)

The input ELF must be statically linked with no dynamic relocations: every
internal reference is PC-relative within the image (verified by
disassembling the kernel before each release).

Usage:
  elf2bin.py INPUT.elf OUTPUT.bin     # build the flat kernel image
  elf2bin.py --info FILE.bin          # print the header fields
"""

import struct
import sys

PT_LOAD = 1
EM_AARCH64 = 183
MAGIC = 0x314B5344  # "DSK1"
HEADER_SIZE = 24


def read_header(data):
    magic, flags, entry_offset, image_size = struct.unpack_from("<IIQQ", data, 0)
    return {"magic": magic, "flags": flags,
            "entry_offset": entry_offset, "image_size": image_size}


def build(input_path, output_path):
    with open(input_path, "rb") as f:
        data = f.read()

    if data[:4] != b"\x7fELF":
        print("elf2bin: %s is not an ELF file" % input_path, file=sys.stderr)
        return 1
    if data[4] != 2 or data[5] != 1:
        print("elf2bin: only ELF64 little-endian is supported", file=sys.stderr)
        return 1
    e_machine = struct.unpack_from("<H", data, 18)[0]
    if e_machine != EM_AARCH64:
        print("elf2bin: %s is not AArch64 (machine %d)" % (input_path, e_machine),
              file=sys.stderr)
        return 1

    e_entry = struct.unpack_from("<Q", data, 24)[0]
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize = struct.unpack_from("<H", data, 54)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]

    loads = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if struct.unpack_from("<I", data, off)[0] != PT_LOAD:
            continue
        p_vaddr = struct.unpack_from("<Q", data, off + 16)[0]
        p_offset = struct.unpack_from("<Q", data, off + 8)[0]
        p_filesz, p_memsz = struct.unpack_from("<QQ", data, off + 32)
        loads.append((p_vaddr, p_offset, p_filesz, p_memsz))
    if not loads:
        print("elf2bin: %s has no PT_LOAD segments" % input_path, file=sys.stderr)
        return 1

    # Lay the segments out relative to the lowest vaddr, preserving the
    # linker's relative layout exactly (gaps stay zero-filled).
    base = min(v for v, _, _, _ in loads)
    end = max(v + m for v, _, _, m in loads)
    blob = bytearray(end - base)
    for vaddr, poff, fsz, memsz in loads:
        rel = vaddr - base
        blob[rel:rel + fsz] = data[poff:poff + fsz]
        # (memsz > fsz tail stays zero: BSS)

    # entry_offset is file-relative (the loader jumps to base + entry_offset,
    # and the loadable content starts after the 24-byte header).
    entry_offset = HEADER_SIZE + e_entry - base
    if entry_offset < HEADER_SIZE or entry_offset >= HEADER_SIZE + len(blob):
        print("elf2bin: entry offset %#x outside loadable content" % entry_offset,
              file=sys.stderr)
        return 1

    header = struct.pack("<IIQQ", MAGIC, 0, entry_offset, HEADER_SIZE + len(blob))
    with open(output_path, "wb") as f:
        f.write(header)
        f.write(bytes(blob))

    print("elf2bin: %s -> %s: entry_offset=0x%x image_size=%d "
          "(content %d bytes from %d PT_LOAD segment(s))"
          % (input_path, output_path, entry_offset, HEADER_SIZE + len(blob),
             len(blob), len(loads)))
    return 0


def main(argv):
    # argv is sys.argv[1:] (script name already removed).
    if len(argv) == 2 and argv[0] == "--info":
        with open(argv[1], "rb") as f:
            data = f.read()
        if len(data) < HEADER_SIZE:
            print("elf2bin: %s too small to be a kernel image" % argv[1],
                  file=sys.stderr)
            return 1
        h = read_header(data)
        print("kernel image %s: magic=0x%08x flags=%d entry_offset=0x%x "
              "image_size=%d" % (argv[1], h["magic"], h["flags"],
                                 h["entry_offset"], h["image_size"]))
        if h["magic"] != MAGIC:
            print("elf2bin: WARNING: magic mismatch (not a DipshitOS kernel "
                  "image?)", file=sys.stderr)
            return 1
        return 0

    if len(argv) != 2:
        print("usage: elf2bin.py INPUT.elf OUTPUT.bin | elf2bin.py --info FILE.bin",
              file=sys.stderr)
        return 2
    return build(argv[0], argv[1])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
