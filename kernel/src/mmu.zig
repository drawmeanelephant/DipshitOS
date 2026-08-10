//! DipshitOS identity-map MMU (extracted verbatim from the former
//! kernel/src/main.zig junk drawer; claim 0023 mechanical split — no
//! behavior change).
//!
//! Page-table construction, attributes, table allocation, D-cache
//! maintenance for the walk, and the identity-map install
//! (`install_identity_map`). The builder maps the low physical space one
//! pass: declared RAM as Normal Write-Back (2 MiB blocks where aligned,
//! 4 KiB pages at region edges), declared MMIO windows and every
//! *undeclared* region as Device nGnRnE, so no post-switch access can
//! fault on an unmapped address and device semantics are preserved. Claim
//! 8215 then overlays EL0 permissions on two dedicated page-aligned ranges:
//! read/execute user text and read/write/non-executable user stack. All
//! neighboring kernel RAM and all Device mappings remain EL1-only. The
//! virtio-pci console transport window above the blanket is passed in by
//! the caller (`extra_device`), so this module does not depend on the
//! virtio transport module.
//!
//! No libc, no POSIX, allocator, or firmware service is used after the
//! exit boundary. The table storage is a fixed BSS carve-out.

const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const MemoryMapSlice = uefi.tables.MemoryMapSlice;
const MemoryType = uefi.tables.MemoryType;
const handoff = @import("handoff.zig");
const build_options = if (builtin.is_test) struct {
    pub const t0sz25 = false;
} else @import("build_options");

const table_page_count = 128; // 512 KiB fixed BSS carve-out, no allocator.
var table_storage: [table_page_count][512]u64 align(4096) = undefined;
var table_count: usize = 0;

/// Physical address of the root translation table (BSS). Exposed for the
/// claim-0021 firmware-MMU-capture diagnostic (evidence.zig), which prints
/// the kernel's planned TTBR0 value for the host-side diff.
pub fn table_root() u64 {
    return @intFromPtr(&table_storage[0]);
}

/// TCR_EL1.T0SZ that install_identity_map() programs: 16 in production
/// (W=48, the 4 KiB stage-1 walk starts at level 0 — matching the built
/// L0-rooted hierarchy, claim 1517). The legacy 25 (W=39, walk starts at
/// level 1 — the claim-6460/7896 start-level mismatch) is selectable with
/// the class-D option -Dt0sz25 for A/B regression. The kernel-plan capture
/// (evidence.zig) prints this same value so a -Dfw-mmu-capture build
/// reports the true planned TCR.
pub const plan_t0sz: u64 = if (build_options.t0sz25) 25 else 16;
/// The builder always maps this low physical range identity. Higher mappings
/// are explicit device/user windows and are not a general syscall aperture.
pub const identity_blanket_end: u64 = 4 * 1024 * 1024 * 1024;

/// Clean the D-cache over [start, start+len) to the point of coherence so a
/// subsequent translation walk (which may read memory directly, bypassing a
/// dirty cache) sees the real contents. 64-byte lines (Apple silicon
/// MMU_CLINE = 6); addresses are 64-byte aligned.
pub fn clean_dcache_range(start: u64, len: u64) void {
    var addr = start & ~@as(u64, 63);
    const end = start + len;
    while (addr < end) : (addr += 64) {
        asm volatile ("dc cvac, %[addr]"
            :
            : [addr] "r" (addr),
        );
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
}

/// Invalidate the D-cache over [start, start+len) so the CPU re-reads RAM
/// the device just wrote (the virtio used ring). Pairs with
/// clean_dcache_range for device-visible DMA buffers.
pub fn invalidate_dcache_range(start: u64, len: u64) void {
    var addr = start & ~@as(u64, 63);
    const end = start + len;
    while (addr < end) : (addr += 64) {
        asm volatile ("dc ivac, %[addr]"
            :
            : [addr] "r" (addr),
        );
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
}

/// Optional extra Device windows the identity map must cover above the
/// blanket (the virtio-pci console BAR, discovered pre-exit by
/// virtio_console.zig, and the virtio-pci block BAR, discovered by
/// virtio_blk.zig — claim 6420). The caller passes the windows it needs.
pub const DeviceWindow = struct {
    base: u64,
    len: u64,
};

/// A page-isolated Normal-RAM range that EL0 may access. Executable regions
/// are user-read-only and PXN; writable regions are UXN+PXN. There is no
/// representation for user-accessible Device memory.
pub const UserRegion = struct {
    base: u64,
    len: u64,
    writable: bool,
    executable: bool,
};

pub fn build_identity_map(
    map: MemoryMapSlice,
    map_buffer: []align(8) u8,
    base: u64,
    size: u64,
    handoff_rec: *const handoff.HandoffV2,
    extra_device: []const DeviceWindow,
    user_regions: []const UserRegion,
) bool {
    table_count = 0;
    _ = new_table() orelse return false; // root table at index zero

    // One-pass identity map of the low physical space. Declared RAM maps
    // Normal Write-Back (2 MiB blocks where aligned, 4 KiB pages at region
    // edges); declared MMIO windows and every *undeclared* region map Device
    // nGnRnE, so no post-switch access can fault on an unmapped address and
    // device semantics are preserved. The firmware's runtime SetVariable
    // (the marker ladder's channel) touches its NVRAM controller, which the
    // EFI map does not declare; the firmware's own map covers it as Device —
    // mapping it Normal (a previous iteration) lets a cacheable access to an
    // emulated device hang forever, and leaving it unmapped faults — both
    // present as the observed claim-0009 ladder (M2_MAPD! then nothing).
    // Bounded: 4 GiB at 2 MiB = 2048 blocks = 4 L2 tables + L1 + root
    // (~24 KiB of the 512 KiB carve-out).
    const blanket_end = identity_blanket_end;
    if (!map_low_identity(blanket_end, map)) return false;

    // Regions above the blanket (none observed on VZ) still get mapped.
    var it = map.iterator();
    while (it.next()) |desc| {
        if (desc.number_of_pages == 0 or desc.number_of_pages > std.math.maxInt(u64) / 4096) return false;
        const bytes = desc.number_of_pages * 4096;
        if (desc.physical_start > std.math.maxInt(u64) - bytes) return false;
        if (desc.physical_start + bytes <= blanket_end) continue; // covered by the blanket
        if (is_ram(desc.type)) {
            if (!map_range(desc.physical_start, desc.physical_start + bytes, Attr.normal)) return false;
        } else if (desc.type == .memory_mapped_io or desc.type == .memory_mapped_io_port_space) {
            if (!map_range(desc.physical_start, desc.physical_start + bytes, Attr.device)) return false;
        }
    }

    // Claim 0013 (+ claim 6420): the virtio-pci console and block transport
    // windows (firmware-assigned ABOVE the blanket) must stay reachable
    // post-exit. Map each Device (4 KiB pages; the low blanketed world is
    // untouched). Post-exit config writes cannot move the BARs on VZ
    // (observed: a rebase "completed" but the device never answered at the
    // new base), so the firmware's placement is mapped in place instead.
    // The windows come from the caller, who owns the virtio discovery.
    for (extra_device) |window| {
        if (window.base >= blanket_end) {
            if (!map_range(window.base, window.base + window.len, Attr.device)) return false;
        }
    }

    // Claim 8215: apply narrow EL0 permissions only after the complete
    // identity map exists. A 2 MiB Normal block is split when necessary;
    // only the requested 4 KiB leaves change. This happens before TTBR0 is
    // installed, so the existing post-install no-remap/TLBI contract holds.
    for (user_regions) |region| {
        if (!apply_user_region(region)) return false;
    }

    // All adopted fixed regions sit inside declared RAM below the blanket;
    // verify they resolve to Normal mappings as a consistency check.
    if (base > std.math.maxInt(u64) - size) return false;
    if (handoff_rec.stack_base > std.math.maxInt(u64) - handoff_rec.stack_size) return false;
    if (!mapped_normal(base)) return false;
    if (!mapped_normal(handoff_rec.stack_base)) return false;
    if (!mapped_normal(@intFromPtr(handoff_rec))) return false;
    if (!mapped_normal(@intFromPtr(map_buffer.ptr))) return false;
    if (!mapped_normal(@intFromPtr(&table_storage))) return false;
    return true;
}

const Attr = enum { normal, device };
const page_size: u64 = 4096;
const block_size: u64 = 2 * 1024 * 1024;

const RegionKind = enum { ram, mmio };

/// True if any descriptor of the given kind overlaps [start, end).
fn region_overlap(start: u64, end: u64, map: MemoryMapSlice, kind: RegionKind) bool {
    var it = map.iterator();
    while (it.next()) |desc| {
        if (desc.number_of_pages == 0 or desc.number_of_pages > std.math.maxInt(u64) / 4096) continue;
        const bytes = desc.number_of_pages * 4096;
        if (desc.physical_start > std.math.maxInt(u64) - bytes) continue;
        const matches = switch (kind) {
            .ram => is_ram(desc.type),
            .mmio => desc.type == .memory_mapped_io or desc.type == .memory_mapped_io_port_space,
        };
        if (!matches) continue;
        if (start < desc.physical_start + bytes and end > desc.physical_start) return true;
    }
    return false;
}

/// True if a single RAM descriptor fully covers [start, start + block_size).
fn block_covered_by_ram(start: u64, map: MemoryMapSlice) bool {
    const end = start + block_size;
    var it = map.iterator();
    while (it.next()) |desc| {
        if (!is_ram(desc.type)) continue;
        if (desc.number_of_pages == 0) continue;
        const bytes = desc.number_of_pages * 4096;
        if (desc.physical_start <= start and desc.physical_start + bytes >= end) return true;
    }
    return false;
}

/// Identity-map [0, end): 2 MiB blocks of Device nGnRnE by default; blocks
/// fully covered by a RAM descriptor map Normal; blocks with any MMIO or
/// partial RAM coverage are mapped at 4 KiB granularity (RAM pages Normal,
/// everything else Device). No post-switch access can then fault, and nothing
/// the firmware reaches with device semantics is ever cacheable.
fn map_low_identity(end: u64, map: MemoryMapSlice) bool {
    const root = &table_storage[0];
    const l1 = ensure_table(&root[0]) orelse return false;
    var va: u64 = 0;
    while (va < end) : (va += block_size) {
        const ix = indices(va);
        const l2 = ensure_table(&l1[ix.l1]) orelse return false;
        const has_ram = region_overlap(va, va + block_size, map, .ram);
        const has_mmio = region_overlap(va, va + block_size, map, .mmio);
        if (!has_ram and !has_mmio) {
            l2[ix.l2] = va | attr_bits(.device, false);
        } else if (has_ram and !has_mmio and block_covered_by_ram(va, map)) {
            l2[ix.l2] = va | attr_bits(.normal, false);
        } else {
            const pages = new_table() orelse return false;
            l2[ix.l2] = @intFromPtr(pages) | 3;
            var page: u64 = 0;
            while (page < block_size) : (page += page_size) {
                const pa = va + page;
                const attr: Attr = if (region_overlap(pa, pa + page_size, map, .ram)) .normal else .device;
                pages[page >> 12] = pa | attr_bits(attr, true);
            }
        }
    }
    return true;
}

/// Walk VA through the built 4 KB-granule tables (T0SZ=16, L0-rooted) and
/// report whether it resolves to a Normal mapping (MAIR AttrIndex = 0b01,
/// descriptor bit 2).
fn mapped_normal(va: u64) bool {
    const ix = indices(va);
    const root = &table_storage[0];
    const l1 = table_entry(&root[ix.l0]) orelse return false;
    var l2e = l1[ix.l1];
    if ((l2e & 3) == 1) return (l2e & 0x4) != 0;
    if ((l2e & 3) != 3) return false;
    const l2 = table_entry(&l2e) orelse return false;
    var l3e = l2[ix.l2];
    if ((l3e & 3) == 1) return (l3e & 0x4) != 0;
    if ((l3e & 3) != 3) return false;
    const l3 = table_entry(&l3e) orelse return false;
    const e = l3[ix.l3];
    if ((e & 3) == 0) return false;
    return (e & 0x4) != 0;
}

fn is_ram(kind: MemoryType) bool {
    return switch (kind) {
        .loader_code, .loader_data, .boot_services_code, .boot_services_data, .conventional_memory, .persistent_memory => true,
        // EFI runtime services code/data stay mapped (Normal WB, executable
        // this milestone) so SetVariable/ResetSystem remain callable after
        // ExitBootServices — the marker NVRAM channel and the M1.5 machine
        // controls both need them. They are RAM; they are never used as
        // general-purpose memory.
        .runtime_services_code, .runtime_services_data => true,
        else => false,
    };
}

fn attr_bits(attr: Attr, page: bool) u64 {
    const base: u64 = if (page) 0x3 else 0x1;
    const mem_attr: u64 = if (attr == .normal) 1 << 2 else 0;
    const share: u64 = if (attr == .normal) 3 << 8 else 0;
    return base | (1 << 10) | share | mem_attr;
}

fn new_table() ?*align(4096) [512]u64 {
    if (table_count >= table_page_count) return null;
    const table: *align(4096) [512]u64 = @ptrCast(&table_storage[table_count]);
    table_count += 1;
    @memset(table, 0);
    return table;
}

fn table_entry(entry: *u64) ?*align(4096) [512]u64 {
    if ((entry.* & 3) != 3) return null;
    return @ptrFromInt(entry.* & ~@as(u64, 0xfff));
}

fn ensure_table(entry: *u64) ?*align(4096) [512]u64 {
    if (entry.* == 0) {
        const table = new_table() orelse return null;
        entry.* = @intFromPtr(table) | 3;
        return table;
    }
    return table_entry(entry);
}

fn map_range(start: u64, end: u64, attr: Attr) bool {
    const va_limit: u64 = 1 << 39;
    if (end <= start) return true;
    if (start >= va_limit or end > va_limit) return false;
    if (end > std.math.maxInt(u64) - 4095) return false;
    var pos = start & ~@as(u64, 0xfff);
    const limit = (end + 4095) & ~@as(u64, 0xfff);
    while (pos < limit) {
        if ((pos & (block_size - 1)) == 0 and limit - pos >= block_size) {
            if (!map_block(pos, attr)) return false;
            pos += block_size;
        } else {
            if (!map_page(pos, attr)) return false;
            pos += page_size;
        }
    }
    return true;
}

fn indices(va: u64) struct { l0: usize, l1: usize, l2: usize, l3: usize } {
    return .{
        .l0 = @intCast((va >> 39) & 0x1ff),
        .l1 = @intCast((va >> 30) & 0x1ff),
        .l2 = @intCast((va >> 21) & 0x1ff),
        .l3 = @intCast((va >> 12) & 0x1ff),
    };
}

fn map_block(va: u64, attr: Attr) bool {
    const ix = indices(va);
    const root = &table_storage[0];
    const l1 = ensure_table(&root[ix.l0]) orelse return false;
    const l2 = ensure_table(&l1[ix.l1]) orelse return false;
    const want = (va & ~@as(u64, block_size - 1)) | attr_bits(attr, false);
    if (l2[ix.l2] == 0) {
        l2[ix.l2] = want;
        return true;
    }
    return l2[ix.l2] == want;
}

fn split_block(entry: *u64) bool {
    if ((entry.* & 3) != 1) return false;
    const old = entry.*;
    const base = old & ~@as(u64, block_size - 1);
    const attr = old & 0xfff;
    const pages = new_table() orelse return false;
    var i: usize = 0;
    while (i < 512) : (i += 1) pages[i] = (base + i * page_size) | attr | 3;
    entry.* = @intFromPtr(pages) | 3;
    return true;
}

fn map_page(va: u64, attr: Attr) bool {
    const ix = indices(va);
    const root = &table_storage[0];
    const l1 = ensure_table(&root[ix.l0]) orelse return false;
    const l2 = ensure_table(&l1[ix.l1]) orelse return false;
    if (l2[ix.l2] != 0 and (l2[ix.l2] & 3) == 1 and !split_block(&l2[ix.l2])) return false;
    const l3 = ensure_table(&l2[ix.l2]) orelse return false;
    const want = (va & ~@as(u64, 0xfff)) | attr_bits(attr, true);
    if (l3[ix.l3] == 0 or l3[ix.l3] == want) {
        l3[ix.l3] = want;
        return true;
    }
    return false;
}

fn apply_user_region(region: UserRegion) bool {
    if (region.len == 0 or region.base % page_size != 0 or region.len % page_size != 0) return false;
    if (region.writable and region.executable) return false;
    if (region.base > std.math.maxInt(u64) - region.len) return false;
    var va = region.base;
    const end = region.base + region.len;
    while (va < end) : (va += page_size) {
        if (!apply_user_page(va, region.writable, region.executable)) return false;
    }
    return true;
}

fn apply_user_page(va: u64, writable: bool, executable: bool) bool {
    const ix = indices(va);
    const root = &table_storage[0];
    const l1 = table_entry(&root[ix.l0]) orelse return false;
    const l2 = table_entry(&l1[ix.l1]) orelse return false;
    if ((l2[ix.l2] & 3) == 1 and !split_block(&l2[ix.l2])) return false;
    const l3 = table_entry(&l2[ix.l2]) orelse return false;
    const entry = user_leaf(l3[ix.l3], writable, executable) orelse return false;
    l3[ix.l3] = entry;
    return true;
}

/// Pure permission transform pinned by host tests. Existing leaf, AttrIndex
/// 1 (Normal WB) only: Device pages can never be promoted into the user
/// aperture by a bad caller.
fn user_leaf(original: u64, writable: bool, executable: bool) ?u64 {
    if (writable and executable) return null;
    if ((original & 3) != 3 or ((original >> 2) & 7) != 1) return null;
    var entry = original;
    const ap_mask: u64 = 3 << 6;
    const pxn: u64 = 1 << 53;
    const uxn: u64 = 1 << 54;
    entry &= ~(ap_mask | pxn | uxn);
    entry |= if (writable) @as(u64, 1 << 6) else @as(u64, 3 << 6);
    if (executable) {
        entry |= pxn; // EL0 executable, EL1 execute-never.
    } else {
        entry |= pxn | uxn;
    }
    return entry;
}

test "mmu: user leaves are page-local W^X and reject Device mappings" {
    const pa: u64 = 0x1234_5000;
    const normal = pa | attr_bits(.normal, true);
    const text = user_leaf(normal, false, true).?;
    try std.testing.expectEqual(@as(u64, 3), (text >> 6) & 3); // EL0 RO
    try std.testing.expectEqual(@as(u64, 1), (text >> 53) & 1); // PXN
    try std.testing.expectEqual(@as(u64, 0), (text >> 54) & 1); // EL0 executable
    try std.testing.expectEqual(pa, text & 0x0000_ffff_ffff_f000);

    const stack = user_leaf(normal, true, false).?;
    try std.testing.expectEqual(@as(u64, 1), (stack >> 6) & 3); // EL0 RW
    try std.testing.expectEqual(@as(u64, 1), (stack >> 53) & 1); // PXN
    try std.testing.expectEqual(@as(u64, 1), (stack >> 54) & 1); // UXN
    try std.testing.expectEqual(pa, stack & 0x0000_ffff_ffff_f000);

    const device = pa | attr_bits(.device, true);
    try std.testing.expect(user_leaf(device, false, true) == null);
    try std.testing.expect(user_leaf(normal, true, true) == null);
}

pub fn read_mmfr0() u64 {
    var value: u64 = undefined;
    asm volatile ("mrs %[value], id_aa64mmfr0_el1"
        : [value] "=r" (value),
    );
    return value;
}

/// Install the built identity map: program MAIR/TCR/TTBR0 and switch. See
/// the no-TLBI safety argument below (ADR 0006 / claim 0010).
pub fn install_identity_map() void {
    const mmfr0 = read_mmfr0();
    var ips: u64 = mmfr0 & 0xf;
    if (ips > 5) ips = 5;
    // Claim 0010 root cause: the freshly-built tables must be cleaned to
    // memory BEFORE the first walk can read them. The kernel writes them as
    // Normal WB stores (dirty in the D-cache only); the first post-switch
    // access walks them, and any D-cache line invalidation without a clean in
    // between (observed: the firmware runtime SetVariable call between the
    // switch and the TLBI drops the dirty lines) leaves stale RAM for the
    // post-TLBI re-walk to fault on. Clean the whole 512 KiB carve-out so the
    // walker always reads the real tables.
    clean_dcache_range(@intFromPtr(&table_storage), table_page_count * 4096);
    // T0SZ selects the TTBR0 VA space size and therefore the initial lookup
    // level of the walk. Production T0SZ=16 (W=48, 2^48 space) starts the 4
    // KiB stage-1 walk at LEVEL 0 — the level the built L0-rooted hierarchy
    // (root -> L1 -> L2 -> optional L3) actually targets, so every fresh
    // walk resolves (claim 1517). The legacy 25 (W=39) starts the walk at
    // LEVEL 1 over the same L0-rooted tables — the claim-6460/7896
    // start-level mismatch: a fresh walk misparses below 1 GiB and faults
    // at ROOT[1..3]=0 for VAs >= 1 GiB (-Dt0sz25 reproduces it). The map
    // builder's va_limit (1 << 39) still bounds every mapped VA (blanket +
    // extra device window sit far below it) under either T0SZ. TG0 (the TTBR0
    // walker's granule) is left 0b00 = 4 KB in
    // BOTH architectural field positions: ARMv8.0 puts TG0 at bits [9:8]
    // (0b01 = 64 KB), ARMv8.1+ with 16 KB granule support puts it at bits
    // [15:14] with IRGN0/ORGN0/SH0 at [9:8]/[11:10]/[13:12]. The tables are
    // 4 KB-granule, so the walker MUST be programmed for 4 KB under whichever
    // revision the CPU implements. (Claim 0010 measured the firmware's own
    // TCR_EL1 on VZ: TG0 at [15:14] = 0b00 — the guest is the ARMv8.1+
    // layout, and the prior `1 << 8` was IRGN0, not TG0; the death persisted
    // with a 4K-correct value, so the granule is defensive rather than the
    // root cause.) IPS is bits [34:32] in both layouts and is taken from
    // ID_AA64MMFR0_EL1 per ADR 0004 D3.
    const tcr: u64 = plan_t0sz | (ips << 32);
    const mair: u64 = 0x000000000000ff00; // Attr0 Device-nGnRnE, Attr1 Normal WB.
    const root = @intFromPtr(&table_storage[0]);
    asm volatile ("dsb ishst" ::: .{ .memory = true });
    asm volatile ("msr mair_el1, %[value]"
        :
        : [value] "r" (mair),
    );
    asm volatile ("msr tcr_el1, %[value]"
        :
        : [value] "r" (tcr),
    );
    asm volatile ("msr ttbr0_el1, %[value]"
        :
        : [value] "r" (root),
    );
    asm volatile ("isb");
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb");
    // Claim 1517 (pays the ADR-0006 debt): execute a FULL TLB invalidation
    // at the switch. The old no-TLBI crutch (claim 0010, ADR 0006) survived
    // only by riding stale firmware TLB entries that were identity-compatible
    // below the blanket — but the first post-MMU read of the virtio-pci BAR
    // window (above the blanket, claim 0013) hit an evicted entry, re-walked
    // the L0-rooted tables under the claim-6460 start-level mismatch
    // (T0SZ=25) and faulted (claims 0018/0020). Claims 6460/7896 proved on
    // real VZ hardware that with the corrected start level (T0SZ=16) a
    // forced re-walk RESOLVES and an empty TLB makes the first post-switch
    // access deterministic (cell B: 9/9 boots complete the whole console
    // path vs ~1/3 with the stale entries). The tables are D-cache-cleaned
    // before the switch and the map never changes descriptors post-switch,
    // so the walk after this invalidation is stable; a later milestone that
    // re-maps regions must revisit the ADR-0006 invalidation list.
    asm volatile ("tlbi vmalle1" ::: .{ .memory = true });
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb");
}
