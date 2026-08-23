//! DipshitOS AArch64 ELF loader (M22 D1, issue #324, claim 9815).
//!
//! Pure parse + validate for statically linked AArch64 ELF32/ELF64
//! executables. The consumer is `exec.exec_file` (magic sniff: a file whose
//! first four bytes are `\x7fELF` takes this path instead of the DSK1/DSK3
//! flat paths) — no new syscall slot; `sys_exec` (28) and the monitor's
//! `exec` command both reach it through the same loader.
//!
//! Loader contract (documented, host-tested):
//!   * Only PT_LOAD program headers matter; every other type is skipped.
//!   * At most 2 PT_LOAD segments (max 2): segment 0 is TEXT (must NOT be
//!     writable — W^X), an optional segment 1 is DATA (must be writable).
//!   * Segment 0's p_vaddr MUST equal `text_base` (0x0040_0000), the fixed
//!     EL0 text aperture (`userspace.text_va`). The kernel maps it there,
//!     so absolute addresses in a normally linked image stay valid — no
//!     relocation is performed.
//!   * An optional data segment must start EXACTLY at text_base +
//!     p_memsz[0] (directly after the text memory image); the kernel maps
//!     it as the writable data aperture right there, matching the
//!     claim-3805 DSK3 shape.
//!   * e_entry must land inside segment 0's INITIALIZED bytes (file range);
//!     it is reported relative to segment 0's p_vaddr because the staging
//!     strip re-bases the content at the aperture base.
//!   * Bounded: p_memsz >= p_filesz per segment, file ranges inside the
//!     read buffer, non-overlapping file ranges (the staging copy is
//!     forward-only), and total load size <= `load_max` (256 KiB — the
//!     shared `exec.exec_program_max` staging buffer bound).
//!
//! No dynamic linking, no sections, no relocations, no libc/POSIX.

const std = @import("std");
/// The `\x7fELF` magic.
pub const magic = [4]u8{ 0x7f, 'E', 'L', 'F' };
/// EM_AARCH64.
pub const em_aarch64: u16 = 0xB7;
/// PT_LOAD.
const pt_load: u32 = 1;
/// PF_W — writable segment flag.
const pf_w: u32 = 2;

/// The required p_vaddr of the first PT_LOAD segment — the kernel's fixed
/// EL0 text aperture (`userspace.text_va`). Kept as a local constant so
/// this module stays dependency-free for host tests; exec.zig asserts the
/// two agree.
pub const text_base: u64 = 0x0040_0000;
/// Page size used for the text/data aperture boundary check.
/// Total load bound — mirrors `exec.exec_program_max` (the shared staging
/// buffer). A program whose PT_LOAD memory exceeds this is rejected.
pub const load_max: usize = 256 * 1024;
/// At most two PT_LOAD segments (text + optional data).
pub const max_segments: usize = 2;

pub const Error = error{
    /// Not an ELF file (bad magic or absurdly short buffer).
    not_elf,
    /// EI_CLASS is neither 1 (ELF32) nor 2 (ELF64).
    unsupported_class,
    /// EI_DATA is not 1 (little-endian).
    unsupported_endian,
    /// e_machine is not EM_AARCH64.
    unsupported_machine,
    /// The header, program-header table, or a segment record extends past
    /// the buffer end.
    truncated,
    /// e_phentsize does not match the class's expected record size.
    bad_phdr,
    /// No PT_LOAD segments at all.
    no_load_segments,
    /// More than `max_segments` PT_LOAD segments.
    too_many_segments,
    /// A segment's file range escapes the buffer, p_memsz < p_filesz, or
    /// the total load exceeds `load_max`.
    segment_too_large,
    /// Two segments' FILE ranges overlap (the staging copy is forward-only
    /// and requires ordered, disjoint source ranges).
    overlapping_segments,
    /// The first PT_LOAD carries PF_W (the kernel maps text read-only).
    writable_text,
    /// A second PT_LOAD lacks PF_W (the kernel maps data read-write).
    readable_data,
    /// The first segment's p_vaddr is not `text_base`.
    bad_text_base,
    /// The second segment does not start exactly at the text segment's
    /// memory end (text_base + p_memsz[0]).
    bad_data_base,
    /// e_entry falls outside segment 0's initialized bytes.
    bad_entry,
};

/// One collected PT_LOAD segment, re-based to staging coordinates by the
/// caller (the parser reports raw file offsets + sizes).
pub const Segment = struct {
    /// Byte offset of the segment's initialized bytes in the FILE buffer.
    file_offset: usize,
    /// Initialized byte count copied from the file (p_filesz).
    file_size: usize,
    /// In-memory byte count including the zero-filled BSS tail (p_memsz).
    mem_size: usize,
};

pub const Image = struct {
    /// Entry-point offset RELATIVE to segment 0's p_vaddr (== its offset
    /// within the staged text region after the strip).
    entry_rel: u64,
    segments: [max_segments]Segment,
    segment_count: usize,
};

/// Quick magic sniff for the exec dispatch: true when the buffer starts
/// with the ELF magic (and is long enough to hold one).
pub fn is_elf(buf: []const u8) bool {
    return buf.len >= magic.len and std.mem.eql(u8, buf[0..magic.len], &magic);
}

// ---------------------------------------------------------------------------
// Symbol collection (M22 D3, issue #326): walk section headers, find the
// SHT_SYMTAB (+ its linked strtab), and emit function/object symbols with
// non-local binding. Names are slices INTO `buf` — the caller must copy
// them before dropping the buffer.
// ---------------------------------------------------------------------------

const sh_type_symtab: u32 = 2;
const stt_func: u8 = 2;
const stt_object: u8 = 1;
const stb_local: u8 = 0;

pub const SymInfo = struct {
    name: []const u8,
    addr: u64,
    size: u64,
};

/// Collect up to `out.len` symbols from `buf`. Returns how many were
/// written. Malformed/absent symbol tables yield 0 — never an error (a
/// stripped image simply has no names).
pub fn collect_symbols(buf: []const u8, out: []SymInfo) usize {
    if (!is_elf(buf)) return 0;
    const ei_class = buf[4];
    if (ei_class != 1 and ei_class != 2) return 0;

    var shoff: u64 = 0;
    var shentsize: usize = 0;
    var shnum: usize = 0;
    if (ei_class == 1) {
        if (buf.len < 52) return 0;
        shoff = read_u32(buf, 32);
        shentsize = read_u16(buf, 46);
        shnum = read_u16(buf, 48);
        if (shentsize != 40) return 0;
    } else {
        if (buf.len < 64) return 0;
        shoff = read_u64(buf, 40);
        shentsize = read_u16(buf, 58);
        shnum = read_u16(buf, 60);
        if (shentsize != 64) return 0;
    }
    if (shnum == 0 or shoff == 0) return 0;
    const table_bytes = @as(u64, shnum) * @as(u64, shentsize);
    if (shoff > buf.len or table_bytes > buf.len - shoff) return 0;

    // Locate SHT_SYMTAB; remember its linked strtab index.
    var symtab_off: u64 = 0;
    var symtab_size: u64 = 0;
    var symtab_entsize: u64 = 0;
    var strtab_idx: usize = 0;
    var found = false;
    var i: usize = 0;
    while (i < shnum) : (i += 1) {
        const rec = shoff + @as(u64, i) * @as(u64, shentsize);
        const sh_type = read_u32(buf, @intCast(rec + 4));
        if (sh_type != sh_type_symtab) continue;
        const sh_offset = if (ei_class == 1) read_u32(buf, @intCast(rec + 16)) else read_u64(buf, @intCast(rec + 24));
        const sh_size = if (ei_class == 1) read_u32(buf, @intCast(rec + 20)) else read_u64(buf, @intCast(rec + 32));
        strtab_idx = if (ei_class == 1) read_u32(buf, @intCast(rec + 24)) else read_u32(buf, @intCast(rec + 40));
        symtab_off = sh_offset;
        symtab_size = sh_size;
        symtab_entsize = if (ei_class == 1) read_u32(buf, @intCast(rec + 36)) else read_u64(buf, @intCast(rec + 56));
        found = true;
        break;
    }
    if (!found) return 0;

    // Resolve the strtab section record.
    if (strtab_idx >= shnum) return 0;
    const srec = shoff + @as(u64, strtab_idx) * @as(u64, shentsize);
    const str_off = if (ei_class == 1) read_u32(buf, @intCast(srec + 16)) else read_u64(buf, @intCast(srec + 24));
    const str_size = if (ei_class == 1) read_u32(buf, @intCast(srec + 20)) else read_u64(buf, @intCast(srec + 32));
    if (str_off > buf.len or str_size > buf.len - str_off) return 0;
    const strtab = buf[@intCast(str_off)..][0..@intCast(str_size)];

    // Expected entry sizes per class.
    const want_entsize: u64 = if (ei_class == 1) 16 else 24;
    if (symtab_entsize != want_entsize) return 0;
    if (symtab_off > buf.len or symtab_size > buf.len - symtab_off) return 0;

    var written: usize = 0;
    const entries = symtab_size / symtab_entsize;
    var e: usize = 0;
    while (e < entries) : (e += 1) {
        if (written == out.len) break;
        const rec = symtab_off + e * symtab_entsize;
        var st_name: u32 = 0;
        var st_info: u8 = 0;
        var st_value: u64 = 0;
        var st_size: u64 = 0;
        if (ei_class == 1) {
            st_name = read_u32(buf, @intCast(rec));
            st_info = buf[rec + 12];
            st_value = read_u32(buf, @intCast(rec + 4));
            st_size = read_u32(buf, @intCast(rec + 8));
        } else {
            st_name = read_u32(buf, @intCast(rec));
            st_info = buf[rec + 4];
            st_value = read_u64(buf, @intCast(rec + 8));
            st_size = read_u64(buf, @intCast(rec + 16));
        }
        // Keep GLOBAL(1)/WEAK(2) FUNC/OBJECT; skip locals and specials.
        const binding = st_info >> 4;
        const kind = st_info & 0xf;
        if (binding == stb_local) continue;
        if (kind != stt_func and kind != stt_object) continue;
        if (st_name >= strtab.len) continue;
        const name_slice = std.mem.sliceTo(strtab[st_name..], 0);
        if (name_slice.len == 0) continue;
        out[written] = .{ .name = name_slice, .addr = st_value, .size = st_size };
        written += 1;
    }
    return written;
}

fn read_u16(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off..][0..2], .little);
}

fn read_u32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}

fn read_u64(buf: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, buf[off..][0..8], .little);
}

const RawSegment = struct {
    offset: u64,
    vaddr: u64,
    filesz: u64,
    memsz: u64,
    flags: u32,
};

/// Parse + validate an ELF executable image. `buf` holds the whole file as
/// read from the volume. On success returns the bounded load plan.
pub fn parse(buf: []const u8) Error!Image {
    // e_ident needs 16 bytes; the shortest header table (ELF32) ends at
    // byte 44 with phentsize/phnum at 42/44 — checked below per class.
    if (!is_elf(buf)) return error.not_elf;
    const ei_class = buf[4];
    const ei_data = buf[5];
    if (ei_class != 1 and ei_class != 2) return error.unsupported_class;
    if (ei_data != 1) return error.unsupported_endian;

    var entry: u64 = 0;
    var phoff: u64 = 0;
    var phnum: usize = 0;
    var phentsize_expected: usize = 0;
    var header_min: usize = 0;
    if (ei_class == 1) {
        header_min = 52; // through e_phnum @44..46 (+ slack)
        if (buf.len < header_min) return error.truncated;
        entry = read_u32(buf, 24);
        phoff = read_u32(buf, 28);
        phnum = read_u16(buf, 44);
        phentsize_expected = 32;
    } else {
        header_min = 64; // through e_shstrndx @62..64
        if (buf.len < header_min) return error.truncated;
        entry = read_u64(buf, 24);
        phoff = read_u64(buf, 32);
        phnum = read_u16(buf, 56);
        phentsize_expected = 56;
    }
    const machine = read_u16(buf, 18);
    if (machine != em_aarch64) return error.unsupported_machine;

    // Program-header table bounds.
    if (phnum == 0) return error.no_load_segments;
    const phentsize = if (ei_class == 1) read_u16(buf, 42) else read_u16(buf, 54);
    if (phentsize != phentsize_expected) return error.bad_phdr;
    const table_bytes = @as(u64, phnum) * @as(u64, phentsize);
    if (phoff > buf.len or table_bytes > buf.len - phoff) return error.truncated;

    // Walk once, collecting PT_LOAD records (skip every other type).
    var raws: [max_segments]RawSegment = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const rec = phoff + @as(u64, i) * @as(u64, phentsize);
        const r: RawSegment = switch (ei_class) {
            1 => .{
                .offset = read_u32(buf, @intCast(rec + 4)),
                .vaddr = read_u32(buf, @intCast(rec + 8)),
                .filesz = read_u32(buf, @intCast(rec + 16)),
                .memsz = read_u32(buf, @intCast(rec + 20)),
                .flags = read_u32(buf, @intCast(rec + 24)),
            },
            else => .{
                .flags = read_u32(buf, @intCast(rec + 4)),
                .offset = read_u64(buf, @intCast(rec + 8)),
                .vaddr = read_u64(buf, @intCast(rec + 16)),
                .filesz = read_u64(buf, @intCast(rec + 32)),
                .memsz = read_u64(buf, @intCast(rec + 40)),
            },
        };
        if (read_u32(buf, @intCast(rec)) != pt_load) continue;
        if (count == max_segments) return error.too_many_segments;
        raws[count] = r;
        count += 1;
    }
    if (count == 0) return error.no_load_segments;

    // Per-segment bounds + flags.
    var total_mem: u64 = 0;
    for (raws[0..count]) |r| {
        if (r.memsz < r.filesz) return error.segment_too_large;
        if (r.offset > buf.len or r.filesz > buf.len - r.offset) return error.segment_too_large;
        total_mem += r.memsz;
        if (total_mem > load_max) return error.segment_too_large;
    }
    if (raws[0].flags & pf_w != 0) return error.writable_text;
    if (count == 2 and raws[1].flags & pf_w == 0) return error.readable_data;

    // File ranges must be disjoint AND ordered (forward-only staging copy:
    // destination offsets only ever shrink below source offsets when the
    // sources do not overlap).
    if (count == 2) {
        const a_end = raws[0].offset + raws[0].filesz;
        const b_start = raws[1].offset;
        if (a_end > b_start) return error.overlapping_segments;
    }

    // Placement contract: text at the fixed EL0 aperture; optional data
    // DIRECTLY after the text segment's memory image (the kernel maps the
    // data aperture at text_base + text_memsz, so absolute data references
    // stay valid only under exact adjacency).
    if (raws[0].vaddr != text_base) return error.bad_text_base;
    if (count == 2) {
        if (raws[1].vaddr != raws[0].vaddr + raws[0].memsz) return error.bad_data_base;
    }

    // Entry must land in segment 0's INITIALIZED bytes (executing the
    // zero-filled tail would fault immediately anyway — reject it here
    // with an honest message instead of a tombstone).
    if (entry < raws[0].vaddr or entry >= raws[0].vaddr + raws[0].filesz) return error.bad_entry;

    var segments: [max_segments]Segment = undefined;
    segments[0] = .{
        .file_offset = @intCast(raws[0].offset),
        .file_size = @intCast(raws[0].filesz),
        .mem_size = @intCast(raws[0].memsz),
    };
    if (count == 2) {
        segments[1] = .{
            .file_offset = @intCast(raws[1].offset),
            .file_size = @intCast(raws[1].filesz),
            .mem_size = @intCast(raws[1].memsz),
        };
    }
    return .{ .entry_rel = entry - raws[0].vaddr, .segments = segments, .segment_count = count };
}

// ---------------------------------------------------------------------------
// Tests (host-side, pure): hand-crafted minimal images pin every contract.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build a minimal ELF32 image: ELF header (52 B) + one phdr (32 B) +
/// `code`. Returns the image and its total size.
fn elf32_one(code: []const u8, vaddr: u32, filesz_extra: usize, memsz_extra: usize, flags: u32) [128]u8 {
    var img = [_]u8{0} ** 128;
    // e_ident
    @memcpy(img[0..4], &magic);
    img[4] = 1; // ELF32
    img[5] = 1; // little-endian
    img[6] = 1; // EV_CURRENT
    // e_type=2 (EXEC) @16, e_machine @18
    std.mem.writeInt(u16, img[16..18], 2, .little);
    std.mem.writeInt(u16, img[18..20], em_aarch64, .little);
    std.mem.writeInt(u32, img[20..24], 1, .little); // e_version
    std.mem.writeInt(u32, img[24..28], vaddr, .little); // e_entry (at code start)
    std.mem.writeInt(u32, img[28..32], 52, .little); // e_phoff
    std.mem.writeInt(u16, img[40..42], 52, .little); // e_ehsize
    std.mem.writeInt(u16, img[42..44], 32, .little); // e_phentsize
    std.mem.writeInt(u16, img[44..46], 1, .little); // e_phnum
    // phdr @52: PT_LOAD, R+X
    std.mem.writeInt(u32, img[52..56], pt_load, .little);
    std.mem.writeInt(u32, img[56..60], 84, .little); // p_offset
    std.mem.writeInt(u32, img[60..64], vaddr, .little); // p_vaddr
    std.mem.writeInt(u32, img[68..72], @intCast(code.len + filesz_extra), .little); // p_filesz
    std.mem.writeInt(u32, img[72..76], @intCast(code.len + filesz_extra + memsz_extra), .little); // p_memsz
    std.mem.writeInt(u32, img[76..80], flags, .little);
    @memcpy(img[84..][0..code.len], code);
    return img;
}

test "elf: minimal valid ELF32 parses with correct entry" {
    const code = [_]u8{ 0x01, 0x00, 0x80, 0xd2 }; // mov x0, #1
    const img = elf32_one(&code, 0x400000, 0, 0, 5); // R+X
    const image = try parse(&img);
    try testing.expectEqual(@as(usize, 1), image.segment_count);
    try testing.expectEqual(@as(u64, 0), image.entry_rel);
    try testing.expectEqual(@as(usize, 84), image.segments[0].file_offset);
    try testing.expectEqual(code.len, image.segments[0].file_size);
}

test "elf: rejects bad magic, classes, endianness, and machine" {
    var img = elf32_one(&[_]u8{0} ** 4, 0x400000, 0, 0, 5);

    // Bad magic.
    var bad_magic = img;
    bad_magic[0] = 'D';
    try testing.expectError(error.not_elf, parse(&bad_magic));
    try testing.expectError(error.not_elf, parse(img[0..3]));

    // Bad class (3 is reserved).
    var bad_class = img;
    bad_class[4] = 3;
    try testing.expectError(error.unsupported_class, parse(&bad_class));

    // Big-endian.
    var bad_endian = img;
    bad_endian[5] = 2;
    try testing.expectError(error.unsupported_endian, parse(&bad_endian));

    // x86_64 machine (0x3E) — "unsupported architecture".
    var x86 = img;
    std.mem.writeInt(u16, x86[18..20], 0x3E, .little);
    try testing.expectError(error.unsupported_machine, parse(&x86));
}

test "elf: rejects truncated headers and tables" {
    const code = [_]u8{0} ** 4;
    const img = elf32_one(&code, 0x400000, 0, 0, 5);
    // Header cut short of the ELF32 minimum.
    try testing.expectError(error.truncated, parse(img[0..48]));
    // Program-header table extends past the buffer (claim phnum=9 but ship 1).
    var bad_table = img;
    std.mem.writeInt(u16, bad_table[44..46], 9, .little);
    try testing.expectError(error.truncated, parse(&bad_table));
    // Wrong phentsize.
    var bad_entsize = img;
    std.mem.writeInt(u16, bad_entsize[42..44], 56, .little);
    try testing.expectError(error.bad_phdr, parse(&bad_entsize));
    // phnum == 0 → no PT_LOAD.
    var no_phdr = img;
    std.mem.writeInt(u16, no_phdr[44..46], 0, .little);
    try testing.expectError(error.no_load_segments, parse(&no_phdr));
}

test "elf: rejects out-of-range and oversized segments" {
    // p_filesz pointing past the buffer.
    var oob = elf32_one(&[_]u8{0} ** 4, 0x400000, 0, 0, 5);
    std.mem.writeInt(u32, oob[68..72], 9999, .little);
    std.mem.writeInt(u32, oob[72..76], 9999, .little);
    try testing.expectError(error.segment_too_large, parse(&oob));

    // memsz < filesz (BSS smaller than the initialized part).
    var neg_bss = elf32_one(&[_]u8{0} ** 4, 0x400000, 0, 0, 5);
    std.mem.writeInt(u32, neg_bss[72..76], 2, .little); // memsz < filesz (4)
    try testing.expectError(error.segment_too_large, parse(&neg_bss));

    // Total load above load_max.
    var huge = elf32_one(&[_]u8{0} ** 4, 0x400000, 0, 0, 5);
    std.mem.writeInt(u32, huge[72..76], load_max + 1, .little);
    try testing.expectError(error.segment_too_large, parse(&huge));
}

test "elf: enforces W^X segment flags and placement contract" {
    const code = [_]u8{0} ** 4;
    // Writable first segment (RWX) → refused.
    const wtxt = elf32_one(&code, 0x400000, 0, 0, 7);
    try testing.expectError(error.writable_text, parse(&wtxt));

    // Wrong text base (linked at 0x1000) → refused honestly.
    const wrong_base = elf32_one(&code, 0x1000, 0, 0, 5);
    try testing.expectError(error.bad_text_base, parse(&wrong_base));

    // Entry outside the initialized range → bad entry.
    var bad_entry_img = elf32_one(&code, 0x400000, 8, 0, 5); // filesz 12 > code 4? no: extra widens range
    _ = &bad_entry_img;
    // Simpler: point e_entry past the segment.
    var far_entry = elf32_one(&code, 0x400000, 0, 0, 5);
    std.mem.writeInt(u32, far_entry[24..28], 0x400000 + 4096, .little);
    try testing.expectError(error.bad_entry, parse(&far_entry));
}

test "elf: ELF64 parses and reports entry_rel correctly" {
    var img = [_]u8{0} ** 160;
    @memcpy(img[0..4], &magic);
    img[4] = 2; // ELF64
    img[5] = 1;
    img[6] = 1;
    std.mem.writeInt(u16, img[16..18], 2, .little); // EXEC
    std.mem.writeInt(u16, img[18..20], em_aarch64, .little);
    std.mem.writeInt(u32, img[20..24], 1, .little); // version
    std.mem.writeInt(u64, img[24..32], 0x400010, .little); // e_entry
    std.mem.writeInt(u64, img[32..40], 64, .little); // e_phoff
    std.mem.writeInt(u16, img[52..54], 64, .little); // e_ehsize
    std.mem.writeInt(u16, img[54..56], 56, .little); // e_phentsize
    std.mem.writeInt(u16, img[56..58], 1, .little); // e_phnum
    // phdr @64: PT_LOAD R+X, offset 120, vaddr 0x400000
    std.mem.writeInt(u32, img[64..68], pt_load, .little);
    std.mem.writeInt(u32, img[68..72], 5, .little); // R+X
    std.mem.writeInt(u64, img[72..80], 120, .little); // p_offset
    std.mem.writeInt(u64, img[80..88], 0x400000, .little); // p_vaddr
    std.mem.writeInt(u64, img[96..104], 32, .little); // p_filesz
    std.mem.writeInt(u64, img[104..112], 32, .little); // p_memsz
    const image = try parse(&img);
    try testing.expectEqual(@as(usize, 1), image.segment_count);
    try testing.expectEqual(@as(u64, 0x10), image.entry_rel);
    try testing.expectEqual(@as(usize, 120), image.segments[0].file_offset);
}

test "elf: two-segment layout validates the data-base contract" {
    // Text: vaddr 0x400000, memsz 0x1000 → data must sit at 0x401000.
    var img = [_]u8{0} ** 512;
    @memcpy(img[0..4], &magic);
    img[4] = 1;
    img[5] = 1;
    img[6] = 1;
    std.mem.writeInt(u16, img[18..20], em_aarch64, .little);
    std.mem.writeInt(u32, img[20..24], 1, .little);
    std.mem.writeInt(u32, img[24..28], 0x400000, .little); // entry
    std.mem.writeInt(u32, img[28..32], 52, .little); // e_phoff
    std.mem.writeInt(u16, img[42..44], 32, .little);
    std.mem.writeInt(u16, img[44..46], 2, .little); // two phdrs
    // phdr 0 @52: text, R+X, offset 116, filesz 8, memsz 0x1000
    std.mem.writeInt(u32, img[52..56], pt_load, .little);
    std.mem.writeInt(u32, img[56..60], 116, .little);
    std.mem.writeInt(u32, img[60..64], 0x400000, .little);
    std.mem.writeInt(u32, img[68..72], 8, .little);
    std.mem.writeInt(u32, img[72..76], 0x1000, .little);
    std.mem.writeInt(u32, img[76..80], 5, .little);
    // phdr 1 @84: data, RW, offset 124, vaddr 0x401000, filesz/memsz 4
    std.mem.writeInt(u32, img[84..88], pt_load, .little);
    std.mem.writeInt(u32, img[88..92], 124, .little);
    std.mem.writeInt(u32, img[92..96], 0x401000, .little);
    std.mem.writeInt(u32, img[100..104], 4, .little);
    std.mem.writeInt(u32, img[104..108], 4, .little);
    std.mem.writeInt(u32, img[108..112], 6, .little); // RW
    const image = try parse(&img);
    try testing.expectEqual(@as(usize, 2), image.segment_count);
    try testing.expectEqual(@as(usize, 124), image.segments[1].file_offset);
    try testing.expectEqual(@as(usize, 4), image.segments[1].mem_size);

    // Data NOT on the following page boundary → refused.
    var misaligned = img;
    std.mem.writeInt(u32, misaligned[92..96], 0x401800, .little);
    try testing.expectError(error.bad_data_base, parse(&misaligned));

    // Overlapping FILE ranges → refused (staging copy safety).
    var overlap = img;
    std.mem.writeInt(u32, overlap[88..92], 118, .little); // data file starts inside text file range
    try testing.expectError(error.overlapping_segments, parse(&overlap));
}

test "elf: collect_symbols reads a hand-built symtab" {
    // Build an ELF32 with two sections: symtab + strtab, three symbols
    // (global func "crasher", local skipped, global object "msg").
    var img = [_]u8{0} ** 512;
    @memcpy(img[0..4], &magic);
    img[4] = 1;
    img[5] = 1;
    std.mem.writeInt(u16, img[18..20], em_aarch64, .little);
    const shoff: u32 = 52;
    std.mem.writeInt(u32, img[32..36], shoff, .little); // e_shoff
    std.mem.writeInt(u16, img[46..48], 40, .little); // e_shentsize
    std.mem.writeInt(u16, img[48..50], 2, .little); // e_shnum: symtab+strtab

    // Section 0 @52: SHT_SYMTAB, offset 132, size 48 (3 entries), link=1.
    std.mem.writeInt(u32, img[shoff..][0..4], 0, .little); // sh_name
    std.mem.writeInt(u32, img[shoff + 4 ..][0..4], 2, .little); // SHT_SYMTAB
    std.mem.writeInt(u32, img[shoff + 16 ..][0..4], 132, .little); // sh_offset
    std.mem.writeInt(u32, img[shoff + 20 ..][0..4], 48, .little); // sh_size
    std.mem.writeInt(u32, img[shoff + 24 ..][0..4], 1, .little); // sh_link -> strtab
    std.mem.writeInt(u32, img[shoff + 36 ..][0..4], 16, .little); // sh_entsize

    // Section 1 @92: SHT_STRTAB, offset 180, size 40.
    const s1 = shoff + 40;
    std.mem.writeInt(u32, img[s1 + 4 ..][0..4], 3, .little); // STRTAB
    std.mem.writeInt(u32, img[s1 + 16 ..][0..4], 180, .little);
    std.mem.writeInt(u32, img[s1 + 20 ..][0..4], 40, .little);

    // Strtab: [0]=NUL, "crasher\0", "msg\0"
    @memcpy(img[181..189], "crasher\x00");
    @memcpy(img[189..193], "msg\x00");

    // Symtab entries at 132: entry 0 is the reserved null symbol.
    // Entry 1: GLOBAL FUNC crasher @0x400010 size 20; st_name=1.
    var e1 = shoff;
    _ = &e1;
    const sym_base: u32 = 132;
    std.mem.writeInt(u32, img[sym_base + 16 ..][0..4], 1, .little); // st_name
    img[sym_base + 16 + 12] = (1 << 4) | 2; // GLOBAL FUNC
    std.mem.writeInt(u32, img[sym_base + 16 + 4 ..][0..4], 0x400010, .little); // st_value
    std.mem.writeInt(u32, img[sym_base + 16 + 8 ..][0..4], 20, .little); // st_size
    // Entry 2: LOCAL func (skipped).
    std.mem.writeInt(u32, img[sym_base + 32 ..][0..4], 9, .little);
    img[sym_base + 32 + 12] = (0 << 4) | 2;

    var out: [8]SymInfo = undefined;
    const n = collect_symbols(&img, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("crasher", out[0].name);
    try testing.expectEqual(@as(u64, 0x400010), out[0].addr);
    try testing.expectEqual(@as(u64, 20), out[0].size);

    // Stripped image (no sections) yields zero without error.
    var bare = elf32_one(&[_]u8{0} ** 4, 0x400000, 0, 0, 5);
    _ = &bare;
    try testing.expectEqual(@as(usize, 0), collect_symbols(&bare, &out));
}
