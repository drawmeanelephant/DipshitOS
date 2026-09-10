#!/usr/bin/env python3
"""Convert a Zig aarch64-freestanding ELF executable into the VirelaiOS flat
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

Format v2 ("KRN2", the kernel only; issue #1042) adds a relocation table so
the loader can place the image at any base even when the compiler emitted
absolute (base-0) references that PC-relative addressing cannot fix — LLVM
jump tables and outlined-function pointer tables are the observed cases:

  offset 0:  u32 magic        = 0x324E524B ("KRN2")
  offset 4:  u32 flags        = 0
  offset 8:  u64 entry_offset  (file-relative; includes the 40-byte header)
  offset 16: u64 image_size    (total file size, header + content + relocs)
  offset 24: u64 reloc_offset  (file offset of the relocation table)
  offset 32: u64 reloc_count   (number of 24-byte entries)
  offset 40: loadable content
  after content: reloc_count × { u64 offset, u64 value, u32 width, u32 _ }
             the loader writes (value + kernel_base) at content offset
             `offset`, as `width` (8 or 4) bytes.

The relocation records come from an ELF linked with lld `--emit-relocs`; the
input must keep its symbol/reloc sections (build.zig sets
`link_emit_relocs` and clears `strip`). Every absolute relocation
(R_AARCH64_ABS64/ABS32) whose target lies in a PT_LOAD segment is captured;
an unexpected absolute type in loadable content is a hard build failure, so
an unrelocated pointer table can never silently ship again.

The still-valid v1 contract: any reference the linker resolves PC-relatively
(adr/adrp) needs no relocation table entry — the loader places content at
base+0 preserving the linker's exact relative layout.

Usage:
  elf2bin.py INPUT.elf OUTPUT.bin     # build the flat kernel image
  elf2bin.py --relocs INPUT.elf OUT   # kernel image + absolute-reloc table
  elf2bin.py --info FILE.bin          # print the header fields
"""

import struct
import sys

PT_LOAD = 1
EM_AARCH64 = 183
MAGIC = 0x314B5344  # "DSK1"
MAGIC_SEGMENTS = 0x334B5344  # "DSK3" — segmented user image (milestone 16 C1)
MAGIC_RELOC = 0x324E524B  # "KRN2" — kernel image with absolute-reloc table
HEADER_SIZE = 24
HEADER_SIZE_SEGMENTS = 48
HEADER_SIZE_RELOC = 40
RELOC_ENTRY_SIZE = 24

SHT_RELA = 4
SHT_NOBITS = 8
SHF_ALLOC = 0x2
R_AARCH64_ABS64 = 257
R_AARCH64_ABS32 = 258

PF_X = 1
PF_W = 2


def read_header(data):
    magic, flags, entry_offset, image_size = struct.unpack_from("<IIQQ", data, 0)
    h = {"magic": magic, "flags": flags,
         "entry_offset": entry_offset, "image_size": image_size,
         "reloc_offset": None, "reloc_count": 0}
    if magic == MAGIC_RELOC and len(data) >= HEADER_SIZE_RELOC:
        h["reloc_offset"], h["reloc_count"] = struct.unpack_from("<QQ", data, 24)
    return h


def _parse_loads(data):
    """Return the list of (vaddr, p_offset, filesz, memsz, p_flags) PT_LOAD
    segments in the ELF, or None on a malformed header."""
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize = struct.unpack_from("<H", data, 54)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]
    loads = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if struct.unpack_from("<I", data, off)[0] != PT_LOAD:
            continue
        p_flags = struct.unpack_from("<I", data, off + 4)[0]
        p_offset = struct.unpack_from("<Q", data, off + 8)[0]
        p_vaddr = struct.unpack_from("<Q", data, off + 16)[0]
        p_filesz, p_memsz = struct.unpack_from("<QQ", data, off + 32)
        loads.append((p_vaddr, p_offset, p_filesz, p_memsz, p_flags))
    return loads


def _parse_sections(data):
    """Return the ELF section headers as dicts (empty list if stripped)."""
    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize, e_shnum = struct.unpack_from("<HH", data, 58)
    secs = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        (name, typ, flags, addr, soff, size, link, info,
         align, entsize) = struct.unpack_from("<IIQQQQIIQQ", data, off)
        secs.append({"name": name, "typ": typ, "flags": flags, "addr": addr,
                     "off": soff, "size": size, "link": link, "info": info,
                     "align": align, "entsize": entsize})
    return secs


def _collect_abs_relocs(data, base, loads):
    """Return [(blob_offset, value, width)] for every absolute relocation
    (R_AARCH64_ABS64/ABS32) whose target sits in a PT_LOAD segment. The
    linked bytes at each site already hold the final base-0 absolute value
    (lld resolves symbol+addend in place), so the loader adds `base` to the
    value verbatim. An unexpected absolute type in loadable content is a
    hard error: it would need relocating but has no table entry."""
    spans = [(v, v + m) for v, _, _, m, _ in loads]
    secs = _parse_sections(data)

    def loaded(vaddr):
        return any(lo <= vaddr < hi for lo, hi in spans)

    out = []
    for s in secs:
        if s["typ"] != SHT_RELA or s["info"] >= len(secs):
            continue
        tgt = secs[s["info"]]
        if not (tgt["flags"] & SHF_ALLOC) or tgt["typ"] == SHT_NOBITS:
            continue
        if not loaded(tgt["addr"]):
            continue
        entsize = s["entsize"] or 24
        for k in range(s["size"] // entsize):
            o = s["off"] + k * entsize
            r_offset, r_info, _r_addend = struct.unpack_from("<QQq", data, o)
            r_type = r_info & 0xFFFFFFFF
            if r_type not in (R_AARCH64_ABS64, R_AARCH64_ABS32):
                if 257 <= r_type <= 260:
                    raise ValueError(
                        "unhandled absolute relocation type %d in %s@0x%x "
                        "(no loader support)" % (r_type, "loaded section",
                                                 tgt["addr"] + r_offset))
                continue  # PC-relative / instruction fixup, already applied
            width = 8 if r_type == R_AARCH64_ABS64 else 4
            vaddr = tgt["addr"] + r_offset
            if not loaded(vaddr):
                continue
            loc = tgt["off"] + r_offset
            value = struct.unpack_from("<Q" if width == 8 else "<I", data, loc)[0]
            out.append((vaddr - base, value, width))
    out.sort()
    return out


def _build_flat_reloc(input_path, output_path, e_entry, base, blob, loads, data):
    """Emit the "KRN2" kernel image: v1 flat content plus the absolute-reloc
    table the loader applies before the cache flush (issue #1042)."""
    relocs = _collect_abs_relocs(data, base, loads)
    entry_offset = HEADER_SIZE_RELOC + e_entry - base
    if entry_offset < HEADER_SIZE_RELOC or entry_offset >= HEADER_SIZE_RELOC + len(blob):
        print("elf2bin: entry offset %#x outside loadable content" % entry_offset,
              file=sys.stderr)
        return 1
    reloc_offset = HEADER_SIZE_RELOC + len(blob)
    image_size = reloc_offset + len(relocs) * RELOC_ENTRY_SIZE
    header = struct.pack("<IIQQQQ", MAGIC_RELOC, 0, entry_offset, image_size,
                         reloc_offset, len(relocs))
    with open(output_path, "wb") as f:
        f.write(header)
        f.write(bytes(blob))
        for off, value, width in relocs:
            f.write(struct.pack("<QQII", off, value, width, 0))
    print("elf2bin: %s -> %s: entry_offset=0x%x image_size=%d "
          "(%d PT_LOAD segment(s), %d absolute reloc(s))"
          % (input_path, output_path, entry_offset, image_size,
             len(loads), len(relocs)))
    return 0


def build(input_path, output_path, segments=False, allow_writable=False,
          relocs=False):
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
    loads = _parse_loads(data)
    if not loads:
        print("elf2bin: %s has no PT_LOAD segments" % input_path, file=sys.stderr)
        return 1

    # Lay the segments out relative to the lowest vaddr, preserving the
    # linker's relative layout exactly (gaps stay zero-filled).
    base = min(v for v, _, _, _, _ in loads)
    end = max(v + m for v, _, _, m, _ in loads)
    blob = bytearray(end - base)
    for vaddr, poff, fsz, memsz, _pflags in loads:
        rel = vaddr - base
        blob[rel:rel + fsz] = data[poff:poff + fsz]
        # (memsz > fsz tail stays zero: BSS)

    if relocs:
        if segments:
            print("elf2bin: --relocs and --segments are mutually exclusive",
                  file=sys.stderr)
            return 2
        return _build_flat_reloc(input_path, output_path, e_entry, base, blob,
                                 loads, data)
    if segments:
        return _build_segmented(input_path, output_path, data, e_entry,
                                loads, base, blob)
    # A flat (DSK1) image is mapped read-only by the kernel `exec` path, so
    # any writable .data/.bss content would fault on the FIRST store — the
    # exact failure VICTIM.BIN hit (data abort at 0x400a50, its .bss tail
    # inside the read-only text region) and NOTEPAD before its DSK3
    # conversion. Refuse unless the caller exempts the image with
    # --allow-writable (ONLY for a flat image whose loader maps RW itself,
    # i.e. the kernel — never for an exec'd user program).
    if not allow_writable:
        writable = [load for load in loads if load[4] & PF_W and load[3] > 0]
        if writable:
            print(
                "elf2bin: %s: writable PT_LOAD segment(s) in a flat image "
                "(no --segments). DSK1 maps the whole file read-only under "
                "kernel `exec`, so the first store to .data/.bss would fault. "
                "Build it segmented instead: user/linker-segmented.ld + "
                "elf2bin.py --segments." % input_path,
                file=sys.stderr,
            )
            for vaddr, _poff, fsz, memsz, fl in writable:
                print("  writable PT_LOAD: vaddr=0x%x filesz=%d memsz=%d "
                      "flags=0x%x" % (vaddr, fsz, memsz, fl), file=sys.stderr)
            return 2
    return _build_flat(input_path, output_path, e_entry, base, blob, loads)


def _build_flat(input_path, output_path, e_entry, base, blob, loads):
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


def _build_segmented(input_path, output_path, data, e_entry, loads, base, blob):
    """Emit the segmented DSK3 user image (milestone 16 C1): a 48-byte header
    carrying the RX text size, the initialized RW data size, and the total RW
    (data + zeroed BSS) size, followed by [text+rodata][data] (the BSS tail is
    implicit zero-fill, never stored). The loader maps text EL0-RO+PXN and the
    data region EL0-RW+UXN+PXN."""
    # The first writable segment's vaddr is the text/data boundary (the
    # linker script page-aligns .data, so `text_size` is page-aligned).
    data_start = end_of = base
    for v, _, _, m, _ in loads:
        end_of = max(end_of, v + m)
    writable_starts = [v for v, _, _, _, fl in loads if fl & PF_W]
    if writable_starts:
        data_start = min(writable_starts)
    else:
        data_start = end_of

    text_size = data_start - base
    data_file_size = 0
    data_mem_size = 0
    for vaddr, poff, fsz, memsz, fl in loads:
        if not (fl & PF_W):
            continue
        rel = vaddr - base
        # data content is stored in the blob right after the text region.
        if rel < text_size:
            print("elf2bin: %s writable segment overlaps the RX region"
                  % input_path, file=sys.stderr)
            return 1
        data_file_size += fsz
        data_mem_size += memsz

    if text_size == 0 or text_size % 4096 != 0:
        print("elf2bin: %s text_size %#x is not page-aligned "
              "(align .data to 4096 in the linker script)"
              % (input_path, text_size), file=sys.stderr)
        return 1

    entry_offset = HEADER_SIZE_SEGMENTS + e_entry - base
    if entry_offset < HEADER_SIZE_SEGMENTS or entry_offset >= HEADER_SIZE_SEGMENTS + text_size:
        print("elf2bin: entry offset %#x outside the RX region" % entry_offset,
              file=sys.stderr)
        return 1

    image_size = HEADER_SIZE_SEGMENTS + text_size + data_file_size
    header = struct.pack("<IIQQQQQ", MAGIC_SEGMENTS, 0, entry_offset, image_size,
                         text_size, data_file_size, data_mem_size)
    content = bytes(blob[:text_size + data_file_size])
    with open(output_path, "wb") as f:
        f.write(header)
        f.write(content)

    print("elf2bin: %s -> %s: entry_offset=0x%x image_size=%d "
          "text=%d data=%d (bss tail %d) from %d PT_LOAD segment(s)"
          % (input_path, output_path, entry_offset, image_size,
             text_size, data_file_size, data_mem_size - data_file_size,
             len(loads)))
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
        extra = ""
        if h["reloc_offset"] is not None:
            extra = " reloc_offset=0x%x reloc_count=%d" % (
                h["reloc_offset"], h["reloc_count"])
        print("kernel image %s: magic=0x%08x flags=%d entry_offset=0x%x "
              "image_size=%d%s" % (argv[1], h["magic"], h["flags"],
                                   h["entry_offset"], h["image_size"], extra))
        if h["magic"] not in (MAGIC, MAGIC_SEGMENTS, MAGIC_RELOC):
            print("elf2bin: WARNING: magic mismatch (not a VirelaiOS kernel "
                  "image?)", file=sys.stderr)
            return 1
        return 0

    segments = False
    allow_writable = False
    relocs = False
    while argv and argv[0] in ("--segments", "--allow-writable", "--relocs"):
        if argv[0] == "--segments":
            segments = True
        elif argv[0] == "--allow-writable":
            allow_writable = True
        else:
            relocs = True
        argv = argv[1:]
    if len(argv) != 2:
        print("usage: elf2bin.py [--segments] [--allow-writable] [--relocs] "
              "INPUT.elf OUTPUT.bin | elf2bin.py --info FILE.bin",
              file=sys.stderr)
        return 2
    return build(argv[0], argv[1], segments=segments,
                 allow_writable=allow_writable, relocs=relocs)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
