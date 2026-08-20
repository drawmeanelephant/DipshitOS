#!/usr/bin/env python3
"""Convert a Zig aarch64-freestanding ELF into DipshitOS DSK2 multi-segment image.

DSK2 format (m16 C1, wishlist 15):

  offset 0:  u32 magic        = 0x324B5344 ("DSK2")
  offset 4:  u32 flags        = 0
  offset 8:  u64 entry_offset (file offset of entry point)
  offset 16: u64 segment_count (N)
  offset 24: u64 image_size    (total file size including header+table+data)

  offset 32: N * segment descriptors (32 bytes each):
    0:  u64 vaddr_offset  (vaddr - lowest PT_LOAD vaddr, i.e. offset from text_va 0x00400000)
    8:  u64 filesz        (bytes stored in file for this segment)
    16: u64 memsz         (bytes in memory, >= filesz, tail zero = bss)
    24: u32 flags         (PF_X=1 PF_W=2 PF_R=4)
    28: u32 reserved      (0)

  offset 32+N*32: segment data concatenated in descriptor order (each filesz bytes)

Segments are derived from ELF PT_LOADs (type 1) with non-zero memsz,
excluding GNU_STACK (type 0x6474e551). The lowest vaddr becomes base
(0x00400000 in normal user builds). vaddr_offset preserves the linker's
relative layout. The entry_offset is file-relative: header+table + sum of
previous filesz + (e_entry - seg_vaddr). At least one segment must be
executable (PF_X) and contain the entry.

Usage:
  elf2bin-dsk2.py INPUT.elf OUTPUT.bin
  elf2bin-dsk2.py --info FILE.bin
"""

import struct
import sys

PT_LOAD = 1
PT_GNU_STACK = 0x6474E551
EM_AARCH64 = 183
MAGIC_DSK2 = 0x324B5344
HEADER_SIZE = 32
SEG_DESC_SIZE = 32
BASE_VA = 0x00400000  # expected, but we derive from ELF

def read_header(data):
    magic, flags, entry_offset, seg_count, image_size = struct.unpack_from("<IIQQQ", data, 0)
    # note: our header is 4+4+8+8+8 =32, struct is "<IIQQQ" = 4+4+8+8+8
    return {"magic": magic, "flags": flags, "entry_offset": entry_offset, "segment_count": seg_count, "image_size": image_size}

def build(input_path, output_path):
    with open(input_path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF":
        print(f"elf2bin-dsk2: {input_path} is not ELF", file=sys.stderr)
        return 1
    if data[4] != 2 or data[5] != 1:
        print("elf2bin-dsk2: only ELF64 LE supported", file=sys.stderr)
        return 1
    e_machine = struct.unpack_from("<H", data, 18)[0]
    if e_machine != EM_AARCH64:
        print(f"elf2bin-dsk2: not AArch64 (machine {e_machine})", file=sys.stderr)
        return 1
    e_entry = struct.unpack_from("<Q", data, 24)[0]
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize = struct.unpack_from("<H", data, 54)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]

    loads = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = struct.unpack_from("<IIQQQQQQ", data, off)
        if p_type != PT_LOAD:
            continue
        if p_type == PT_GNU_STACK:
            continue
        # ignore zero-size GNU_STACK already filtered; keep all PT_LOAD with memsz>0
        if p_memsz == 0:
            continue
        loads.append((p_vaddr, p_offset, p_filesz, p_memsz, p_flags))
    if not loads:
        print(f"elf2bin-dsk2: {input_path} has no PT_LOAD", file=sys.stderr)
        return 1
    # Sort by vaddr
    loads.sort(key=lambda x: x[0])
    base = min(v for v, _, _, _, _ in loads)
    # For user builds base should be 0x400000, but we preserve whatever
    segs = []
    for vaddr, p_offset, filesz, memsz, flags in loads:
        vaddr_off = vaddr - base
        segs.append((vaddr_off, filesz, memsz, flags, p_offset))

    # Find entry segment
    entry_found = False
    entry_file_off = None
    # compute file offset for entry
    header_and_table = HEADER_SIZE + len(segs) * SEG_DESC_SIZE
    # cumulative filesz
    cum = 0
    # we need to map entry to segment
    for idx, (voff, filesz, memsz, flags, p_offset) in enumerate(segs):
        # segment's vaddr range
        seg_vaddr = base + voff
        if seg_vaddr <= e_entry < seg_vaddr + memsz:
            if not (flags & 1):
                print(f"elf2bin-dsk2: entry {e_entry:#x} in non-executable segment {idx}", file=sys.stderr)
                return 1
            entry_file_off = header_and_table + cum + (e_entry - seg_vaddr)
            entry_found = True
            break
        cum += filesz
    if not entry_found:
        print(f"elf2bin-dsk2: entry {e_entry:#x} not in any PT_LOAD", file=sys.stderr)
        return 1

    image_size = header_and_table + sum(filesz for _, filesz, _, _, _ in segs)
    # Build header
    header = struct.pack("<IIQQQ", MAGIC_DSK2, 0, entry_file_off, len(segs), image_size)
    # Build segment descriptors
    descs = b""
    for voff, filesz, memsz, flags, _ in segs:
        descs += struct.pack("<QQQI I", voff, filesz, memsz, flags, 0)
        # Actually need <QQQ I I : voff, filesz, memsz, flags, reserved
        # struct.pack "<QQQI I" is not correct; use "<QQQII"
    # redo correctly
    descs = b""
    for voff, filesz, memsz, flags, _ in segs:
        descs += struct.pack("<QQQII", voff, filesz, memsz, flags, 0)

    with open(output_path, "wb") as out:
        out.write(header)
        out.write(descs)
        for voff, filesz, memsz, flags, p_offset in segs:
            if filesz > 0:
                out.write(data[p_offset:p_offset+filesz])

    print(f"elf2bin-dsk2: {input_path} -> {output_path}: entry_offset=0x{entry_file_off:x} image_size={image_size} segments={len(segs)} (from {len(loads)} PT_LOAD)")
    for i, (voff, filesz, memsz, flags, _) in enumerate(segs):
        print(f"  seg{i}: voff=0x{voff:x} filesz={filesz} memsz={memsz} flags={flags:#x} ({'R' if flags & 4 else ''}{'W' if flags & 2 else ''}{'X' if flags & 1 else ''})")
    return 0

def info(path):
    with open(path, "rb") as f:
        d = f.read()
    if len(d) < HEADER_SIZE:
        print(f"{path} too small", file=sys.stderr)
        return 1
    h = read_header(d)
    print(f"DSK2 {path}: magic=0x{h['magic']:08x} flags={h['flags']} entry_offset=0x{h['entry_offset']:x} seg_count={h['segment_count']} image_size={h['image_size']}")
    if h['magic'] != MAGIC_DSK2:
        print(" WARNING: magic mismatch", file=sys.stderr)
        return 1
    if len(d) < HEADER_SIZE + h['segment_count']*SEG_DESC_SIZE:
        print(" truncated table", file=sys.stderr)
        return 1
    for i in range(h['segment_count']):
        off = HEADER_SIZE + i*SEG_DESC_SIZE
        voff, filesz, memsz, flags, reserved = struct.unpack_from("<QQQII", d, off)
        print(f"  seg{i}: voff=0x{voff:x} filesz={filesz} memsz={memsz} flags={flags:#x} reserved={reserved}")
    return 0

def main(argv):
    if len(argv)==2 and argv[0]=="--info":
        return info(argv[1])
    if len(argv)!=2:
        print("usage: elf2bin-dsk2.py INPUT.elf OUTPUT.bin | elf2bin-dsk2.py --info FILE.bin", file=sys.stderr)
        return 2
    return build(argv[0], argv[1])

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
