#!/usr/bin/env python3
"""Z4b (issue #761): check an ELF against the VirelaiOS static-loader contract.

Replicates the checks in kernel/src/elf.zig `parse()` (the loader itself is
class-agnostic — ELF32 or ELF64 — and the *layout* is the contract):

  * e_ident class 1 or 2, little-endian, EM_AARCH64, correct phentsize;
  * only PT_LOAD segments are collected (others skipped); at most 2;
  * segment 0 is not writable (W^X) and p_vaddr == 0x0040_0000
    (elf.zig `text_base`);
  * an optional segment 1 is writable and p_vaddr == text_base +
    p_memsz[0] EXACTLY (data directly after the text memory image);
  * file ranges ordered + disjoint, p_memsz >= p_filesz, ranges inside
    the file;
  * total p_memsz <= 256 KiB (`load_max` / `exec_program_max`);
  * e_entry lands inside segment 0's INITIALIZED (file) bytes.

Exit 0 with "CONTRACT OK" when every check passes; prints each PT_LOAD and
exits 1 otherwise. This is the machine half of the host link contract —
tools/build-zc-host.sh runs it on every emitted image.

Usage: check-zc-host-contract.py <elf-file>
"""

import struct
import sys

TEXT_BASE = 0x00400000
LOAD_MAX = 256 * 1024
EM_AARCH64 = 0xB7
PT_LOAD = 1


def fail(msg: str) -> None:
    print(f"CONTRACT FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    path = sys.argv[1] if len(sys.argv) > 1 else "a.out"
    buf = open(path, "rb").read()
    if buf[:4] != b"\x7fELF":
        fail("not an ELF")
    cls = buf[4]
    if cls not in (1, 2):
        fail("unsupported class")
    if buf[5] != 1:
        fail("unsupported endian (need little)")
    if struct.unpack("<H", buf[18:20])[0] != EM_AARCH64:
        fail("unsupported machine (need EM_AARCH64)")
    if cls == 1:
        entry, phoff = struct.unpack("<II", buf[24:32])
        phnum = struct.unpack("<H", buf[44:46])[0]
        if struct.unpack("<H", buf[42:44])[0] != 32:
            fail("bad phentsize (ELF32 needs 32)")
    else:
        entry, phoff = struct.unpack("<QQ", buf[24:40])
        phnum = struct.unpack("<H", buf[56:58])[0]
        if struct.unpack("<H", buf[54:56])[0] != 56:
            fail("bad phentsize (ELF64 needs 56)")

    segs = []
    for i in range(phnum):
        rec = phoff + i * (32 if cls == 1 else 56)
        p_type = struct.unpack("<I", buf[rec : rec + 4])[0]
        if p_type != PT_LOAD:
            continue
        if cls == 1:
            fl, off, va, _pa, fs, ms, _al = struct.unpack("<I6I", buf[rec + 4 : rec + 32])
        else:
            fl, off, va, _pa, fs, ms, _al = struct.unpack("<I6Q", buf[rec + 4 : rec + 56])
        segs.append((fl, off, va, fs, ms))
        print(
            f"PT_LOAD off={off:#x} va={va:#x} filesz={fs:#x} memsz={ms:#x} "
            f"flags={fl:#x}"
        )
    print(f"entry={entry:#x} phnum={phnum} file={len(buf)} B")

    if not segs:
        fail("no PT_LOAD segments")
    if len(segs) > 2:
        fail("more than 2 PT_LOAD segments")
    s0 = segs[0]
    if s0[0] & 2:
        fail("segment 0 is writable (W^X)")
    total_mem = 0
    for s in segs:
        if s[3] > s[4]:
            fail("p_memsz < p_filesz")
        if s[1] + s[3] > len(buf):
            fail("segment file range escapes the file")
        total_mem += s[4]
    if total_mem > LOAD_MAX:
        fail(f"total load {total_mem} > {LOAD_MAX}")
    if s0[2] != TEXT_BASE:
        fail(f"text base {s0[2]:#x} != {TEXT_BASE:#x}")
    if len(segs) == 2:
        s1 = segs[1]
        if not (s1[0] & 2):
            fail("segment 1 is not writable")
        want = s0[2] + s0[4]
        if s1[2] != want:
            fail(f"data base {s1[2]:#x} != text_base + p_memsz[0] ({want:#x})")
        if s0[1] + s0[3] > s1[1]:
            fail("overlapping file ranges")
    if not (s0[2] <= entry < s0[2] + s0[3]):
        fail("e_entry outside segment 0 initialized bytes")
    print("CONTRACT OK")


if __name__ == "__main__":
    main()
