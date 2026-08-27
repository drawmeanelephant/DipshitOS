#!/usr/bin/env python3
"""Generate freestanding dynamic ELF binaries (LD.SO, LIBUI.SO, LIBFONT.SO, DYNAPP.ELF).

Milestone 30: Freestanding Runtime Linker & Shared Libraries (Claim 7921).
"""

import os
import struct
import sys

TEXT_BASE = 0x00400000
EM_AARCH64 = 0xB7

PT_LOAD = 1
PT_DYNAMIC = 2
PT_INTERP = 3

PF_X = 1
PF_W = 2
PF_R = 4

DT_NULL = 0
DT_NEEDED = 1
DT_PLTRELSZ = 2
DT_PLTGOT = 3
DT_HASH = 4
DT_STRTAB = 5
DT_SYMTAB = 6
DT_RELA = 7
DT_RELASZ = 8
DT_RELAENT = 9
DT_STRSZ = 10
DT_SYMENT = 11
DT_JMPREL = 23

R_AARCH64_NONE = 0
R_AARCH64_ABS64 = 257
R_AARCH64_GLOB_DAT = 1025
R_AARCH64_JUMP_SLOT = 1026
R_AARCH64_RELATIVE = 1027


def build_libui_so():
    """Build LIBUI.SO shared library exporting UI and windowing syscall routines."""
    # Machine code for exported functions:
    # ui_write (offset 0):
    #   mov x8, #1; svc #0; ret
    # ui_exit (offset 12):
    #   mov x8, #3; svc #0; ret
    # ui_win_open (offset 24):
    #   mov x8, #12; svc #0; ret
    # ui_win_fill (offset 36):
    #   mov x8, #13; svc #0; ret
    # ui_win_present (offset 48):
    #   mov x8, #14; svc #0; ret
    # ui_win_close (offset 60):
    #   mov x8, #15; svc #0; ret
    # ui_poll_event (offset 72):
    #   mov x8, #21; svc #0; ret
    code = [
        # ui_write @0
        0xD2800028,  # mov x8, #1
        0xD4000001,  # svc #0
        0xD65F03C0,  # ret
        # ui_exit @12
        0xD2800068,  # mov x8, #3
        0xD4000001,  # svc #0
        0xD65F03C0,  # ret
        # ui_win_open @24
        0xD2800188,  # mov x8, #12
        0xD4000001,  # svc #0
        0xD65F03C0,  # ret
        # ui_win_fill @36
        0xD28001A8,  # mov x8, #13
        0xD4000001,  # svc #0
        0xD65F03C0,  # ret
        # ui_win_present @48
        0xD28001C8,  # mov x8, #14
        0xD4000001,  # svc #0
        0xD65F03C0,  # ret
        # ui_win_close @60
        0xD28001E8,  # mov x8, #15
        0xD4000001,  # svc #0
        0xD65F03C0,  # ret
        # ui_poll_event @72
        0xD28002A8,  # mov x8, #21
        0xD4000001,  # svc #0
        0xD65F03C0,  # ret
    ]
    code_bytes = b"".join(struct.pack("<I", w) for w in code)

    # String table
    # 0: ""
    # 1: "ui_write"
    # 10: "ui_exit"
    # 18: "ui_win_open"
    # 30: "ui_win_fill"
    # 42: "ui_win_present"
    # 57: "ui_win_close"
    # 70: "ui_poll_event"
    strtab = (
        b"\x00"
        b"ui_write\x00"
        b"ui_exit\x00"
        b"ui_win_open\x00"
        b"ui_win_fill\x00"
        b"ui_win_present\x00"
        b"ui_win_close\x00"
        b"ui_poll_event\x00"
    )

    ehdr_size = 64
    phdr_size = 56
    phnum = 2  # PT_LOAD (R+X), PT_DYNAMIC (RW)
    phoff = ehdr_size

    code_off = (ehdr_size + phnum * phdr_size + 15) & ~15

    # Symbol table: Elf64Sym (24 bytes each)
    # st_name (u32), st_info (u8), st_other (u8), st_shndx (u16), st_value (u64), st_size (u64)
    symtab = bytearray()
    # 0: NULL symbol
    symtab += struct.pack("<IBBHQQ", 0, 0, 0, 0, 0, 0)
    # 1: ui_write @0
    symtab += struct.pack("<IBBHQQ", 1, 0x12, 0, 1, code_off + 0, 12)
    # 2: ui_exit @12
    symtab += struct.pack("<IBBHQQ", 10, 0x12, 0, 1, code_off + 12, 12)
    # 3: ui_win_open @24
    symtab += struct.pack("<IBBHQQ", 18, 0x12, 0, 1, code_off + 24, 12)
    # 4: ui_win_fill @36
    symtab += struct.pack("<IBBHQQ", 30, 0x12, 0, 1, code_off + 36, 12)
    # 5: ui_win_present @48
    symtab += struct.pack("<IBBHQQ", 42, 0x12, 0, 1, code_off + 48, 12)
    # 6: ui_win_close @60
    symtab += struct.pack("<IBBHQQ", 57, 0x12, 0, 1, code_off + 60, 12)
    # 7: ui_poll_event @72
    symtab += struct.pack("<IBBHQQ", 70, 0x12, 0, 1, code_off + 72, 12)

    strtab_off = code_off + len(code_bytes)
    symtab_off = (strtab_off + len(strtab) + 7) & ~7
    dyn_off = (symtab_off + len(symtab) + 7) & ~7

    # Dynamic tags
    dynamic = bytearray()
    dynamic += struct.pack("<QQ", DT_STRTAB, strtab_off)
    dynamic += struct.pack("<QQ", DT_STRSZ, len(strtab))
    dynamic += struct.pack("<QQ", DT_SYMTAB, symtab_off)
    dynamic += struct.pack("<QQ", DT_SYMENT, 24)
    dynamic += struct.pack("<QQ", DT_NULL, 0)

    total_size = dyn_off + len(dynamic)

    # ELF header (ELF64, little-endian, ET_DYN, EM_AARCH64)
    ehdr = struct.pack(
        "<4s5B7xHHIQQQIHHHHHH",
        b"\x7fELF",
        2,  # ELF64
        1,  # little endian
        1,  # version
        0,  # OSABI SysV
        0,  # ABIVERSION
        3,  # e_type = ET_DYN (shared object)
        EM_AARCH64,
        1,
        0,  # e_entry
        phoff,  # e_phoff
        0,  # e_shoff
        0,  # e_flags
        ehdr_size,
        phdr_size,
        phnum,
        0,
        0,
        0,
    )

    # Program headers:
    # 0: PT_LOAD R+X (covering code + tables)
    phdr0 = struct.pack(
        "<IIQQQQQQ",
        PT_LOAD,
        PF_R | PF_X,
        0,  # p_offset
        0,  # p_vaddr
        0,  # p_paddr
        total_size,  # p_filesz
        total_size,  # p_memsz
        0x1000,  # align
    )

    # 1: PT_DYNAMIC RW
    phdr1 = struct.pack(
        "<IIQQQQQQ",
        PT_DYNAMIC,
        PF_R | PF_W,
        dyn_off,  # p_offset
        dyn_off,  # p_vaddr
        dyn_off,  # p_paddr
        len(dynamic),  # p_filesz
        len(dynamic),  # p_memsz
        8,  # align
    )

    image = bytearray(total_size)
    image[0:ehdr_size] = ehdr
    image[phoff : phoff + phdr_size] = phdr0
    image[phoff + phdr_size : phoff + 2 * phdr_size] = phdr1
    image[code_off : code_off + len(code_bytes)] = code_bytes
    image[strtab_off : strtab_off + len(strtab)] = strtab
    image[symtab_off : symtab_off + len(symtab)] = symtab
    image[dyn_off : dyn_off + len(dynamic)] = dynamic

    return bytes(image)


def build_libfont_so():
    """Build LIBFONT.SO shared library exporting font_measure_8x8."""
    # font_measure_8x8 (x0 = str):
    #   mov x1, x0
    # loop:
    #   ldrb w2, [x1], #1
    #   cbnz w2, loop
    #   sub x0, x1, x0
    #   sub x0, x0, #1
    #   lsl x0, x0, #3  // * 8
    #   ret
    code = [
        0xAA0003E1,  # mov x1, x0
        0x38401422,  # ldrb w2, [x1], #1
        0x35FFFFE2,  # cbnz w2, loop
        0xCB000020,  # sub x0, x1, x0
        0xD1000400,  # sub x0, x0, #1
        0xD37DF000,  # lsl x0, x0, #3
        0xD65F03C0,  # ret
    ]
    code_bytes = b"".join(struct.pack("<I", w) for w in code)

    strtab = b"\x00font_measure_8x8\x00"

    ehdr_size = 64
    phdr_size = 56
    phnum = 2
    phoff = ehdr_size

    code_off = (ehdr_size + phnum * phdr_size + 15) & ~15

    symtab = bytearray()
    symtab += struct.pack("<IBBHQQ", 0, 0, 0, 0, 0, 0)
    symtab += struct.pack("<IBBHQQ", 1, 0x12, 0, 1, code_off + 0, len(code_bytes))
    strtab_off = code_off + len(code_bytes)
    symtab_off = (strtab_off + len(strtab) + 7) & ~7
    dyn_off = (symtab_off + len(symtab) + 7) & ~7

    dynamic = bytearray()
    dynamic += struct.pack("<QQ", DT_STRTAB, strtab_off)
    dynamic += struct.pack("<QQ", DT_STRSZ, len(strtab))
    dynamic += struct.pack("<QQ", DT_SYMTAB, symtab_off)
    dynamic += struct.pack("<QQ", DT_SYMENT, 24)
    dynamic += struct.pack("<QQ", DT_NULL, 0)

    total_size = dyn_off + len(dynamic)

    ehdr = struct.pack(
        "<4s5B7xHHIQQQIHHHHHH",
        b"\x7fELF",
        2,
        1,
        1,
        0,
        0,
        3,  # ET_DYN
        EM_AARCH64,
        1,
        0,
        phoff,
        0,
        0,
        ehdr_size,
        phdr_size,
        phnum,
        0,
        0,
        0,
    )

    phdr0 = struct.pack(
        "<IIQQQQQQ",
        PT_LOAD,
        PF_R | PF_X,
        0,
        0,
        0,
        total_size,
        total_size,
        0x1000,
    )
    phdr1 = struct.pack(
        "<IIQQQQQQ",
        PT_DYNAMIC,
        PF_R | PF_W,
        dyn_off,
        dyn_off,
        dyn_off,
        len(dynamic),
        len(dynamic),
        8,
    )

    image = bytearray(total_size)
    image[0:ehdr_size] = ehdr
    image[phoff : phoff + phdr_size] = phdr0
    image[phoff + phdr_size : phoff + 2 * phdr_size] = phdr1
    image[code_off : code_off + len(code_bytes)] = code_bytes
    image[strtab_off : strtab_off + len(strtab)] = strtab
    image[symtab_off : symtab_off + len(symtab)] = symtab
    image[dyn_off : dyn_off + len(dynamic)] = dynamic

    return bytes(image)


def build_dynapp_elf():
    """Build DYNAPP.ELF dynamic executable requiring LIBUI.SO and LIBFONT.SO with PT_INTERP LD.SO."""
    msg = b"dynapp: hello from dynamic executable (Milestone 30)!\n"

    # GOT table will have slots:
    # 0: ui_write
    # 1: ui_win_open
    # 2: ui_win_fill
    # 3: ui_win_present
    # 4: ui_win_close
    # 5: ui_exit

    # Code:
    #   _start:
    #     // 1. ui_write(1, msg, len)
    #     mov x0, #1
    #     adr x1, msg
    #     mov x2, #len
    #     ldr x9, =got_ui_write
    #     ldr x9, [x9]
    #     blr x9
    #
    #     // 2. ui_win_open("DynApp", 100, 100, 300, 200, 0)
    #     adr x0, title
    #     mov x1, #100
    #     mov x2, #100
    #     mov x3, #300
    #     mov x4, #200
    #     mov x5, #0
    #     ldr x9, =got_ui_win_open
    #     ldr x9, [x9]
    #     blr x9
    #     mov x19, x0 // wid
    #
    #     // 3. ui_win_fill(wid, 0, 0, 300, 200, 0xff202020)
    #     mov x0, x19
    #     mov x1, #0
    #     mov x2, #0
    #     mov x3, #300
    #     mov x4, #200
    #     movz x5, #0x2020
    #     movk x5, #0xFF20, lsl #16
    #     ldr x9, =got_ui_win_fill
    #     ldr x9, [x9]
    #     blr x9
    #
    #     // 4. ui_win_present(wid)
    #     mov x0, x19
    #     ldr x9, =got_ui_win_present
    #     ldr x9, [x9]
    #     blr x9
    #
    #     // 5. ui_win_close(wid)
    #     mov x0, x19
    #     ldr x9, =got_ui_win_close
    #     ldr x9, [x9]
    #     blr x9
    #
    #     // 6. ui_exit(0)
    #     mov x0, #0
    #     ldr x9, =got_ui_exit
    #     ldr x9, [x9]
    #     blr x9

    ehdr_size = 64
    phdr_size = 56
    phnum = 4  # PT_INTERP, PT_LOAD (text), PT_LOAD (data/got), PT_DYNAMIC

    interp_str = b"LD.SO\x00"
    interp_off = ehdr_size + phnum * phdr_size
    interp_len = len(interp_str)

    code_start_off = (interp_off + interp_len + 15) & ~15
    entry_vaddr = TEXT_BASE + code_start_off

    # We will build text and data
    # Data segment starts at page boundary
    text_size = 0x1000  # 4 KiB
    data_vaddr = TEXT_BASE + text_size
    data_off = text_size
    # String table for dynamic section:
    # 0: ""
    # 1: "LIBUI.SO"
    # 10: "LIBFONT.SO"
    # 21: "ui_write"
    # 30: "ui_win_open"
    # 42: "ui_win_fill"
    # 54: "ui_win_present"
    # 69: "ui_win_close"
    # 82: "ui_exit"
    strtab = (
        b"\x00"
        b"LIBUI.SO\x00"
        b"LIBFONT.SO\x00"
        b"ui_write\x00"
        b"ui_win_open\x00"
        b"ui_win_fill\x00"
        b"ui_win_present\x00"
        b"ui_win_close\x00"
        b"ui_exit\x00"
    )

    # Symbol table: Elf64Sym entries
    symtab = bytearray()
    symtab += struct.pack("<IBBHQQ", 0, 0, 0, 0, 0, 0)
    symtab += struct.pack("<IBBHQQ", 21, 0x12, 0, 0, 0, 0)  # ui_write
    symtab += struct.pack("<IBBHQQ", 30, 0x12, 0, 0, 0, 0)  # ui_win_open
    symtab += struct.pack("<IBBHQQ", 42, 0x12, 0, 0, 0, 0)  # ui_win_fill
    symtab += struct.pack("<IBBHQQ", 54, 0x12, 0, 0, 0, 0)  # ui_win_present
    symtab += struct.pack("<IBBHQQ", 69, 0x12, 0, 0, 0, 0)  # ui_win_close
    symtab += struct.pack("<IBBHQQ", 82, 0x12, 0, 0, 0, 0)  # ui_exit

    # Layout of data segment:
    # data_vaddr: dynamic section (13 DT tags * 16 = 208 bytes)
    # strtab_vaddr: strtab
    # symtab_vaddr: symtab (aligned to 8)
    # rela_vaddr: rela (aligned to 8)
    # got_vaddr: got (aligned to 16)
    dyn_vaddr = data_vaddr
    dyn_tags_count = 13
    dyn_size = dyn_tags_count * 16
    strtab_vaddr = dyn_vaddr + dyn_size
    symtab_vaddr = (strtab_vaddr + len(strtab) + 7) & ~7
    rela_vaddr = (symtab_vaddr + len(symtab) + 7) & ~7
    # 6 rela entries of 24 bytes = 144 bytes
    got_vaddr = (rela_vaddr + 6 * 24 + 15) & ~15

    # Relocations (Elf64Rela: r_offset, r_info, r_addend)
    rela = bytearray()
    for s_idx in range(1, 7):
        r_offset = got_vaddr + (s_idx - 1) * 8
        r_info = (s_idx << 32) | R_AARCH64_GLOB_DAT
        r_addend = 0
        rela += struct.pack("<QQq", r_offset, r_info, r_addend)

    # Dynamic section
    dynamic = bytearray()
    dynamic += struct.pack("<QQ", DT_NEEDED, 1)  # "LIBUI.SO"
    dynamic += struct.pack("<QQ", DT_NEEDED, 10)  # "LIBFONT.SO"
    dynamic += struct.pack("<QQ", DT_STRTAB, strtab_vaddr)
    dynamic += struct.pack("<QQ", DT_STRSZ, len(strtab))
    dynamic += struct.pack("<QQ", DT_SYMTAB, symtab_vaddr)
    dynamic += struct.pack("<QQ", DT_SYMENT, 24)
    dynamic += struct.pack("<QQ", DT_RELA, rela_vaddr)
    dynamic += struct.pack("<QQ", DT_RELASZ, len(rela))
    dynamic += struct.pack("<QQ", DT_RELAENT, 24)
    dynamic += struct.pack("<QQ", DT_PLTGOT, got_vaddr)
    dynamic += struct.pack("<QQ", DT_JMPREL, rela_vaddr)
    dynamic += struct.pack("<QQ", DT_PLTRELSZ, len(rela))
    dynamic += struct.pack("<QQ", DT_NULL, 0)

    # Assembly instructions for dynamic app
    code = [
        # Prologue (0, 1, 2)
        0xA9BF7BFD,  # stp x29, x30, [sp, #-16]!
        0x910003FD,  # mov x29, sp
        0xA9BF4FF3,  # stp x19, x20, [sp, #-16]!
        # ui_write(1, msg, len)
        0xD2800020,  # mov x0, #1 (idx 3)
        0x10000001,  # adr x1, msg (idx 4, patched)
        0xD2800002 | (len(msg) << 5),  # mov x2, len (idx 5)
        0x58000009,  # ldr x9, got_ui_write_ptr (idx 6, patched)
        0xF9400129,  # ldr x9, [x9] (idx 7)
        0xD63F0120,  # blr x9 (idx 8)
        # ui_win_open(64, 64, 256, 192)
        0xD2800800,  # mov x0, #64 (idx 9)
        0xD2800801,  # mov x1, #64 (idx 10)
        0xD2802002,  # mov x2, #256 (idx 11)
        0xD2801803,  # mov x3, #192 (idx 12)
        0x58000009,  # ldr x9, got_ui_win_open_ptr (idx 13, patched)
        0xF9400129,  # ldr x9, [x9] (idx 14)
        0xD63F0120,  # blr x9 (idx 15)
        0xAA0003F3,  # mov x19, x0 (wid) (idx 16)
        # ui_win_fill(wid, 0, 0, 256, 192, 0xff202020)
        0xAA1303E0,  # mov x0, x19 (idx 17)
        0xD2800001,  # mov x1, #0 (idx 18)
        0xD2800002,  # mov x2, #0 (idx 19)
        0xD2802003,  # mov x3, #256 (idx 20)
        0xD2801804,  # mov x4, #192 (idx 21)
        0xD2840405,  # movz x5, #0x2020 (idx 22)
        0xF2BFE405,  # movk x5, #0xFF20, lsl #16 (idx 23)
        0x58000009,  # ldr x9, got_ui_win_fill_ptr (idx 24, patched)
        0xF9400129,  # ldr x9, [x9] (idx 25)
        0xD63F0120,  # blr x9 (idx 26)
        # ui_win_present(wid)
        0xAA1303E0,  # mov x0, x19 (idx 27)
        0x58000009,  # ldr x9, got_ui_win_present_ptr (idx 28, patched)
        0xF9400129,  # ldr x9, [x9] (idx 29)
        0xD63F0120,  # blr x9 (idx 30)
        # ui_win_close(wid)
        0xAA1303E0,  # mov x0, x19 (idx 31)
        0x58000009,  # ldr x9, got_ui_win_close_ptr (idx 32, patched)
        0xF9400129,  # ldr x9, [x9] (idx 33)
        0xD63F0120,  # blr x9 (idx 34)
        # ui_exit(0)
        0xD2800000,  # mov x0, #0 (idx 35)
        0x58000009,  # ldr x9, got_ui_exit_ptr (idx 36, patched)
        0xF9400129,  # ldr x9, [x9] (idx 37)
        0xD63F0120,  # blr x9 (idx 38)
        # Epilogue (idx 39, 40, 41)
        0xA8C14FF3,  # ldp x19, x20, [sp], #16
        0xA8C17BFD,  # ldp x29, x30, [sp], #16
        0xD65F03C0,  # ret
    ]

    code_len = len(code) * 4
    msg_off_in_code = code_len

    # Patch ADR instruction:
    # idx 4: adr x1, msg (instruction at index 4 -> pc = 16)
    rel_msg = msg_off_in_code - 16
    immlo = rel_msg & 3
    immhi = (rel_msg >> 2) & 0x7FFFF
    code[4] = 0x10000001 | (immlo << 29) | (immhi << 5)

    # Literal pool for GOT addresses (placed after msg)
    got_ptrs_off = (msg_off_in_code + len(msg) + 7) & ~7
    got_addrs = [
        got_vaddr + 0,
        got_vaddr + 8,
        got_vaddr + 16,
        got_vaddr + 24,
        got_vaddr + 32,
        got_vaddr + 40,
    ]

    # Patch LDR literal instructions:
    ldr_indices = [6, 13, 24, 28, 32, 36]
    for i, ldr_idx in enumerate(ldr_indices):
        pc = ldr_idx * 4
        target_off = got_ptrs_off + i * 8
        rel_words = (target_off - pc) // 4
        code[ldr_idx] = 0x58000009 | ((rel_words & 0x7FFFF) << 5)

    code_bytes = (
        b"".join(struct.pack("<I", w) for w in code)
        + msg
        + b"\x00" * (got_ptrs_off - (msg_off_in_code + len(msg)))
        + b"".join(struct.pack("<Q", a) for a in got_addrs)
    )

    data_bytes = bytearray(0x1000)  # 4 KiB data segment
    data_bytes[0 : len(dynamic)] = dynamic
    data_bytes[strtab_vaddr - data_vaddr : strtab_vaddr - data_vaddr + len(strtab)] = (
        strtab
    )
    data_bytes[symtab_vaddr - data_vaddr : symtab_vaddr - data_vaddr + len(symtab)] = (
        symtab
    )
    data_bytes[rela_vaddr - data_vaddr : rela_vaddr - data_vaddr + len(rela)] = (
        rela
    )
    # got initialized to zero (LD.SO will resolve it!)

    # Program headers
    phoff = ehdr_size
    # 0: PT_INTERP
    phdr_interp = struct.pack(
        "<IIQQQQQQ",
        PT_INTERP,
        PF_R,
        interp_off,
        TEXT_BASE + interp_off,
        TEXT_BASE + interp_off,
        interp_len,
        interp_len,
        1,
    )
    # 1: PT_LOAD (text)
    phdr_text = struct.pack(
        "<IIQQQQQQ",
        PT_LOAD,
        PF_R | PF_X,
        0,
        TEXT_BASE,
        TEXT_BASE,
        text_size,
        text_size,
        0x1000,
    )
    # 2: PT_LOAD (data)
    phdr_data = struct.pack(
        "<IIQQQQQQ",
        PT_LOAD,
        PF_R | PF_W,
        data_off,
        data_vaddr,
        data_vaddr,
        len(data_bytes),
        len(data_bytes),
        0x1000,
    )
    # 3: PT_DYNAMIC
    phdr_dyn = struct.pack(
        "<IIQQQQQQ",
        PT_DYNAMIC,
        PF_R | PF_W,
        data_off,
        dyn_vaddr,
        dyn_vaddr,
        len(dynamic),
        len(dynamic),
        8,
    )

    ehdr = struct.pack(
        "<4s5B7xHHIQQQIHHHHHH",
        b"\x7fELF",
        2,  # ELF64
        1,  # little-endian
        1,  # version
        0,
        0,
        2,  # ET_EXEC
        EM_AARCH64,
        1,
        entry_vaddr,
        phoff,
        0,
        0,
        ehdr_size,
        phdr_size,
        phnum,
        0,
        0,
        0,
    )

    total_file_size = text_size + len(data_bytes)
    file_bytes = bytearray(total_file_size)
    file_bytes[0:ehdr_size] = ehdr
    file_bytes[phoff : phoff + phdr_size] = phdr_interp
    file_bytes[phoff + phdr_size : phoff + 2 * phdr_size] = phdr_text
    file_bytes[phoff + 2 * phdr_size : phoff + 3 * phdr_size] = phdr_data
    file_bytes[phoff + 3 * phdr_size : phoff + 4 * phdr_size] = phdr_dyn
    file_bytes[interp_off : interp_off + interp_len] = interp_str
    file_bytes[code_start_off : code_start_off + len(code_bytes)] = code_bytes
    file_bytes[data_off : data_off + len(data_bytes)] = data_bytes

    return bytes(file_bytes)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin"
    os.makedirs(out_dir, exist_ok=True)

    libui_path = os.path.join(out_dir, "LIBUI.SO")
    libfont_path = os.path.join(out_dir, "LIBFONT.SO")
    dynapp_path = os.path.join(out_dir, "DYNAPP.ELF")

    with open(libui_path, "wb") as f:
        f.write(build_libui_so())
    print(f"Generated {libui_path} ({os.path.getsize(libui_path)} bytes)")

    with open(libfont_path, "wb") as f:
        f.write(build_libfont_so())
    print(f"Generated {libfont_path} ({os.path.getsize(libfont_path)} bytes)")

    with open(dynapp_path, "wb") as f:
        f.write(build_dynapp_elf())
    print(f"Generated {dynapp_path} ({os.path.getsize(dynapp_path)} bytes)")


if __name__ == "__main__":
    main()
