//! DipshitOS Freestanding Runtime Linker (LD.SO, Milestone 30 Dynamic Linking).
//!
//! Zero libc/POSIX, zero external runtime. Maps and relocates ELF dynamic
//! executables and shared libraries (LIBUI.SO, LIBFONT.SO) on Apple Silicon AArch64.

const std = @import("std");

// Syscall numbers (ADR 0007 / ADR 0010)
const sys_write_num: u64 = 1;
const sys_exit_num: u64 = 3;
const sys_file_open_num: u64 = 23;
const sys_file_read_num: u64 = 24;
const sys_file_close_num: u64 = 26;
const mode_read: u32 = 1;

// Program header types (PT_*)
pub const pt_null: u32 = 0;
pub const pt_load: u32 = 1;
pub const pt_dynamic: u32 = 2;
pub const pt_interp: u32 = 3;
pub const pt_note: u32 = 4;
pub const pt_shlib: u32 = 5;
pub const pt_phdr: u32 = 6;
pub const pt_tls: u32 = 7;

// Dynamic section tags (DT_*)
pub const dt_null: u64 = 0;
pub const dt_needed: u64 = 1;
pub const dt_pltrelsz: u64 = 2;
pub const dt_pltgot: u64 = 3;
pub const dt_hash: u64 = 4;
pub const dt_strtab: u64 = 5;
pub const dt_symtab: u64 = 6;
pub const dt_rela: u64 = 7;
pub const dt_relasz: u64 = 8;
pub const dt_relaent: u64 = 9;
pub const dt_strsz: u64 = 10;
pub const dt_syment: u64 = 11;
pub const dt_jmprel: u64 = 23;

// AArch64 relocations
pub const r_aarch64_none: u32 = 0;
pub const r_aarch64_abs64: u32 = 257;
pub const r_aarch64_glob_dat: u32 = 1025;
pub const r_aarch64_jump_slot: u32 = 1026;
pub const r_aarch64_relative: u32 = 1027;

// Auxiliary vector types (AT_*)
pub const at_null: u64 = 0;
pub const at_phdr: u64 = 3;
pub const at_phent: u64 = 4;
pub const at_phnum: u64 = 5;
pub const at_pagesz: u64 = 6;
pub const at_base: u64 = 7;
pub const at_entry: u64 = 9;

pub const Auxv = struct {
    phdr: u64 = 0,
    phent: u64 = 56,
    phnum: u64 = 0,
    entry: u64 = 0,
    base: u64 = 0,
    pagesz: u64 = 4096,
};

pub const Elf64Dyn = extern struct {
    d_tag: u64,
    d_val: u64,
};

pub const Elf64Rela = extern struct {
    r_offset: u64,
    r_info: u64,
    r_addend: i64,

    pub inline fn sym(self: Elf64Rela) u32 {
        return @intCast(self.r_info >> 32);
    }

    pub inline fn r_type(self: Elf64Rela) u32 {
        return @intCast(self.r_info & 0xffffffff);
    }
};

pub const Elf64Sym = extern struct {
    st_name: u32,
    st_info: u8,
    st_other: u8,
    st_shndx: u16,
    st_value: u64,
    st_size: u64,
};

pub const Elf64Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

pub const LoadedLib = struct {
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    base_va: u64 = 0,
    strtab: ?[*]const u8 = null,
    symtab: ?[*]const Elf64Sym = null,
    sym_count: usize = 0,
};

pub const max_loaded_libs = 8;
var loaded_libs: [max_loaded_libs]LoadedLib = [_]LoadedLib{.{}} ** max_loaded_libs;
var loaded_lib_count: usize = 0;

// Shared library placement heap
var next_lib_va: u64 = 0x0100_0000;

// ---------------------------------------------------------------------------
// Syscall helpers
// ---------------------------------------------------------------------------

fn sys_write(fd: u64, msg: []const u8) void {
    if (msg.len == 0) return;
    _ = asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 1)),
          [arg0] "{x0}" (fd),
          [arg1] "{x1}" (@as(u64, @intFromPtr(msg.ptr))),
          [arg2] "{x2}" (@as(u64, msg.len)),
    );
}

fn sys_file_open(path: []const u8, mode: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 23)),
          [arg0] "{x0}" (@as(u64, @intFromPtr(path.ptr))),
          [arg1] "{x1}" (@as(u64, path.len)),
          [arg2] "{x2}" (@as(u64, mode)),
    );
}

fn sys_file_read(fd: u64, buf: [*]u8, len: usize) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 24)),
          [arg0] "{x0}" (fd),
          [arg1] "{x1}" (@as(u64, @intFromPtr(buf))),
          [arg2] "{x2}" (@as(u64, len)),
    );
}

fn sys_file_close(fd: u64) void {
    _ = asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 26)),
          [arg0] "{x0}" (fd),
    );
}

fn sys_exit(code: u64) noreturn {
    asm volatile ("svc #0"
        :
        : [num] "{x8}" (@as(u64, 3)),
          [arg0] "{x0}" (code),
    );
    unreachable;
}

// ---------------------------------------------------------------------------
// Linker Logic
// ---------------------------------------------------------------------------

pub fn parse_auxv(auxv_ptr: [*]const u64) Auxv {
    var av = Auxv{};
    var i: usize = 0;
    while (true) : (i += 2) {
        const a_type = auxv_ptr[i];
        const a_val = auxv_ptr[i + 1];
        if (a_type == at_null) break;
        switch (a_type) {
            at_phdr => av.phdr = a_val,
            at_phent => av.phent = a_val,
            at_phnum => av.phnum = a_val,
            at_entry => av.entry = a_val,
            at_base => av.base = a_val,
            at_pagesz => av.pagesz = a_val,
            else => {},
        }
    }
    return av;
}

pub fn find_phdr_dynamic(phdr_base: u64, phent: usize, phnum: usize) ?*const Elf64Phdr {
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const phdr: *const Elf64Phdr = @ptrFromInt(phdr_base + i * phent);
        if (phdr.p_type == pt_dynamic) return phdr;
    }
    return null;
}

pub fn lookup_symbol_in_libs(sym_name: []const u8) ?u64 {
    for (loaded_libs[0..loaded_lib_count]) |lib| {
        if (lib.strtab == null or lib.symtab == null) continue;
        var i: usize = 0;
        while (i < lib.sym_count) : (i += 1) {
            const sym = lib.symtab.?[i];
            const name_ptr = lib.strtab.? + sym.st_name;
            const name_slice = std.mem.sliceTo(name_ptr, 0);
            if (std.mem.eql(u8, name_slice, sym_name)) {
                return lib.base_va + sym.st_value;
            }
        }
    }
    return null;
}

pub fn load_shared_library(name: []const u8) ?*LoadedLib {
    // Check if already loaded
    for (loaded_libs[0..loaded_lib_count]) |*lib| {
        if (std.mem.eql(u8, lib.name[0..lib.name_len], name)) return lib;
    }
    if (loaded_lib_count >= max_loaded_libs) return null;

    sys_write(1, "ld.so: loading shared library: ");
    sys_write(1, name);
    sys_write(1, "\n");

    const lib_dest_va = next_lib_va;
    const lib_buf: [*]const u8 = @ptrFromInt(lib_dest_va);
    var valid = false;

    if (lib_buf[0] == 0x7f and lib_buf[1] == 'E' and lib_buf[2] == 'L' and lib_buf[3] == 'F') {
        valid = true;
    } else {
        const fd = sys_file_open(name, mode_read);
        if (fd >= 0) {
            defer sys_file_close(@intCast(fd));
            const max_lib_bytes: usize = 64 * 1024;
            const mut_lib_buf: [*]u8 = @ptrFromInt(lib_dest_va);
            const read_bytes = sys_file_read(@intCast(fd), mut_lib_buf, max_lib_bytes);
            if (read_bytes > 64) {
                valid = true;
            }
        }
    }

    if (!valid) {
        sys_write(1, "ld.so: file not found: ");
        sys_write(1, name);
        sys_write(1, "\n");
        return null;
    }

    // Advance heap for next library (aligned to 64 KiB)
    next_lib_va += 0x10000;

    const lib_slot = &loaded_libs[loaded_lib_count];
    @memcpy(lib_slot.name[0..name.len], name);
    lib_slot.name_len = name.len;
    lib_slot.base_va = lib_dest_va;

    // Parse ELF header & program headers of .SO
    const e_phoff = std.mem.readInt(u64, lib_buf[32..40], .little);
    const e_phentsize = std.mem.readInt(u16, lib_buf[54..56], .little);
    const e_phnum = std.mem.readInt(u16, lib_buf[56..58], .little);

    // Look for PT_DYNAMIC in .SO
    var dyn_phdr: ?Elf64Phdr = null;
    var p: usize = 0;
    while (p < e_phnum) : (p += 1) {
        const ph_off = e_phoff + p * e_phentsize;
        const p_type = std.mem.readInt(u32, lib_buf[ph_off..][0..4], .little);
        if (p_type == pt_dynamic) {
            dyn_phdr = Elf64Phdr{
                .p_type = p_type,
                .p_flags = std.mem.readInt(u32, lib_buf[ph_off + 4 ..][0..4], .little),
                .p_offset = std.mem.readInt(u64, lib_buf[ph_off + 8 ..][0..8], .little),
                .p_vaddr = std.mem.readInt(u64, lib_buf[ph_off + 16 ..][0..8], .little),
                .p_paddr = std.mem.readInt(u64, lib_buf[ph_off + 24 ..][0..8], .little),
                .p_filesz = std.mem.readInt(u64, lib_buf[ph_off + 32 ..][0..8], .little),
                .p_memsz = std.mem.readInt(u64, lib_buf[ph_off + 40 ..][0..8], .little),
                .p_align = std.mem.readInt(u64, lib_buf[ph_off + 48 ..][0..8], .little),
            };
            break;
        }
    }

    if (dyn_phdr) |dph| {
        const dyn_ptr: [*]const Elf64Dyn = @ptrFromInt(lib_dest_va + dph.p_offset);
        var strtab: ?[*]const u8 = null;
        var symtab: ?[*]const Elf64Sym = null;
        var sym_count: usize = 0;
        var strsz: usize = 0;

        var d: usize = 0;
        while (dyn_ptr[d].d_tag != dt_null) : (d += 1) {
            const tag = dyn_ptr[d].d_tag;
            const val = dyn_ptr[d].d_val;
            switch (tag) {
                dt_strtab => strtab = @ptrFromInt(lib_dest_va + val),
                dt_symtab => symtab = @ptrFromInt(lib_dest_va + val),
                dt_strsz => strsz = @intCast(val),
                else => {},
            }
        }

        if (symtab != null and strtab != null) {
            // Count symbols
            var sc: usize = 1;
            while (sc < 1024) : (sc += 1) {
                const s = symtab.?[sc];
                if (s.st_name >= strsz) break;
                if (s.st_name == 0 and s.st_value == 0 and s.st_size == 0) break;
            }
            sym_count = sc;
        }

        lib_slot.strtab = strtab;
        lib_slot.symtab = symtab;
        lib_slot.sym_count = sym_count;
    }

    loaded_lib_count += 1;
    return lib_slot;
}

pub fn relocate_main(dyn_phdr: *const Elf64Phdr, base_va: u64) void {
    const dyn_ptr: [*]const Elf64Dyn = @ptrFromInt(dyn_phdr.p_vaddr);

    var strtab: ?[*]const u8 = null;
    var symtab: ?[*]const Elf64Sym = null;
    var rela_ptr: ?[*]const Elf64Rela = null;
    var rela_sz: usize = 0;
    var jmprel_ptr: ?[*]const Elf64Rela = null;
    var jmprel_sz: usize = 0;

    // Collect dynamic info
    var d: usize = 0;
    while (dyn_ptr[d].d_tag != dt_null) : (d += 1) {
        const tag = dyn_ptr[d].d_tag;
        const val = dyn_ptr[d].d_val;
        switch (tag) {
            dt_needed => {
                // val is offset in strtab, but strtab might be discovered later
            },
            dt_strtab => strtab = @ptrFromInt(val),
            dt_symtab => symtab = @ptrFromInt(val),
            dt_rela => rela_ptr = @ptrFromInt(val),
            dt_relasz => rela_sz = @intCast(val),
            dt_jmprel => jmprel_ptr = @ptrFromInt(val),
            dt_pltrelsz => jmprel_sz = @intCast(val),
            else => {},
        }
    }

    // Now load all DT_NEEDED libraries
    if (strtab) |st| {
        d = 0;
        while (dyn_ptr[d].d_tag != dt_null) : (d += 1) {
            if (dyn_ptr[d].d_tag == dt_needed) {
                const lib_name = std.mem.sliceTo(st + dyn_ptr[d].d_val, 0);
                _ = load_shared_library(lib_name);
            }
        }
    }

    // Process DT_RELA relocations
    if (rela_ptr) |relas| {
        const count = rela_sz / @sizeOf(Elf64Rela);
        for (relas[0..count]) |rel| {
            apply_relocation(rel, base_va, strtab, symtab);
        }
    }

    // Process DT_JMPREL (PLT) relocations
    if (jmprel_ptr) |jmprels| {
        const count = jmprel_sz / @sizeOf(Elf64Rela);
        for (jmprels[0..count]) |rel| {
            apply_relocation(rel, base_va, strtab, symtab);
        }
    }
}

fn apply_relocation(rel: Elf64Rela, base_va: u64, strtab: ?[*]const u8, symtab: ?[*]const Elf64Sym) void {
    const rtype = rel.r_type();
    const r_sym = rel.sym();
    const target: *u64 = @ptrFromInt(rel.r_offset);

    switch (rtype) {
        r_aarch64_relative => {
            target.* = @as(u64, @bitCast(@as(i64, @intCast(base_va)) +% rel.r_addend));
        },
        r_aarch64_glob_dat, r_aarch64_jump_slot, r_aarch64_abs64 => {
            if (symtab != null and strtab != null) {
                const sym = symtab.?[r_sym];
                const sym_name = std.mem.sliceTo(strtab.? + sym.st_name, 0);
                if (lookup_symbol_in_libs(sym_name)) |sym_addr| {
                    target.* = @as(u64, @bitCast(@as(i64, @intCast(sym_addr)) +% rel.r_addend));
                } else {
                    sys_write(1, "ld.so: warning unresolved symbol: ");
                    sys_write(1, sym_name);
                    sys_write(1, "\n");
                }
            }
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Entry Point (_start)
// ---------------------------------------------------------------------------

comptime {
    if (@import("builtin").os.tag == .freestanding) {
        @export(&_start, .{ .name = "_start", .linkage = .strong });
    }
}

fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// x0 = argc, x1 = argv_va, x2 = auxv_va
        \\mov x19, x0 // preserve argc
        \\mov x20, x1 // preserve argv_va
        \\mov x21, x2 // preserve auxv_va
        \\
        \\// If x2 (auxv_va) is not passed, find auxv on stack
        \\cbnz x21, 1f
        \\mov x21, sp
        \\add x21, x21, #24 // skip argc, argv NULL, envp NULL
        \\1:
        \\sub sp, sp, #32
        \\stp x29, x30, [sp, #16]
        \\mov x29, sp
        \\
        \\mov x0, x21
        \\bl ld_main
        \\
        \\mov x9, x0
        \\ldp x29, x30, [sp, #16]
        \\add sp, sp, #32
        \\
        \\mov x0, x19 // restore argc
        \\mov x1, x20 // restore argv_va
        \\br x9      // jump to executable entry point
    );
}

export fn ld_main(auxv_ptr: [*]const u64) u64 {
    sys_write(1, "ld.so: freestanding dynamic runtime linker active\n");

    const av = parse_auxv(auxv_ptr);
    if (av.phdr == 0 or av.entry == 0) {
        sys_write(1, "ld.so: error bad auxv\n");
        sys_exit(1);
    }

    if (find_phdr_dynamic(av.phdr, @intCast(av.phent), @intCast(av.phnum))) |dyn_phdr| {
        relocate_main(dyn_phdr, 0x0040_0000);
    }

    sys_write(1, "ld.so: relocations resolved successfully, entering main application\n");
    return av.entry;
}

// ---------------------------------------------------------------------------
// Host Unit Tests
// ---------------------------------------------------------------------------

test "ld: parse_auxv extracts standard AT_* vectors" {
    const testing = std.testing;
    const raw_auxv = [_]u64{
        at_phdr,   0x400040,
        at_phent,  56,
        at_phnum,  4,
        at_entry,  0x401000,
        at_base,   0x800000,
        at_pagesz, 4096,
        at_null,   0,
    };
    const av = parse_auxv(&raw_auxv);
    try testing.expectEqual(@as(u64, 0x400040), av.phdr);
    try testing.expectEqual(@as(u64, 56), av.phent);
    try testing.expectEqual(@as(u64, 4), av.phnum);
    try testing.expectEqual(@as(u64, 0x401000), av.entry);
    try testing.expectEqual(@as(u64, 0x800000), av.base);
    try testing.expectEqual(@as(u64, 4096), av.pagesz);
}

test "ld: symbol lookup across loaded libraries" {
    const testing = std.testing;
    loaded_lib_count = 0;

    const sym_names = "\x00ui_win_open\x00ui_win_fill\x00";
    const syms = [_]Elf64Sym{
        .{ .st_name = 0, .st_info = 0, .st_other = 0, .st_shndx = 0, .st_value = 0, .st_size = 0 },
        .{ .st_name = 1, .st_info = 0x12, .st_other = 0, .st_shndx = 1, .st_value = 0x100, .st_size = 32 },
        .{ .st_name = 13, .st_info = 0x12, .st_other = 0, .st_shndx = 1, .st_value = 0x200, .st_size = 32 },
    };

    var lib = &loaded_libs[0];
    const name = "LIBUI.SO";
    @memcpy(lib.name[0..name.len], name);
    lib.name_len = name.len;
    lib.base_va = 0x0100_0000;
    lib.strtab = sym_names.ptr;
    lib.symtab = &syms;
    lib.sym_count = 3;
    loaded_lib_count = 1;

    try testing.expectEqual(@as(?u64, 0x0100_0100), lookup_symbol_in_libs("ui_win_open"));
    try testing.expectEqual(@as(?u64, 0x0100_0200), lookup_symbol_in_libs("ui_win_fill"));
    try testing.expectEqual(@as(?u64, null), lookup_symbol_in_libs("nonexistent"));
}
