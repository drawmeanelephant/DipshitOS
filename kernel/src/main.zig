//! DipshitOS milestone-two kernel proper.
//!
//! The boot stub passes the v2 contract in x3. The kernel validates it, moves
//! to the stub-allocated stack, captures the EFI map, calls ExitBootServices,
//! installs an identity-map TTBR0_EL1, probes a bounded set of MMIO serial
//! candidates, prints the takeover evidence, and never returns after a
//! successful exit. No libc, POSIX, allocator, interrupts, timers, RX, DMA,
//! filesystem, or firmware service is used after the exit boundary.

const std = @import("std");
const uefi = std.os.uefi;
const SystemTable = uefi.tables.SystemTable;
const BootServices = uefi.tables.BootServices;
const MemoryMapSlice = uefi.tables.MemoryMapSlice;
const MemoryType = uefi.tables.MemoryType;

const HandoffV2 = extern struct {
    magic: u32,
    version: u32,
    kernel_base: u64,
    kernel_size: u64,
    system_table: u64,
    image_handle: u64,
    stack_base: u64,
    stack_size: u64,
    flags: u64,
};

const handoff_magic: u32 = 0x324B5344; // "DSK2"
const handoff_version: u32 = 2;
const bad_handoff: u64 = 2;
const map_failure: u64 = 3;
const exit_failure: u64 = 4;
const table_failure: u64 = 5;
const serial_failure: u64 = 6;

fn utf16z(comptime text: []const u8) [text.len + 1:0]u16 {
    var result: [text.len + 1:0]u16 = undefined;
    for (text, 0..) |byte, index| result[index] = byte;
    result[text.len] = 0;
    return result;
}

const table_page_count = 128; // 512 KiB fixed BSS carve-out, no allocator.
var table_storage: [table_page_count][512]u64 align(4096) = undefined;
var table_count: usize = 0;
var takeover_marker: u64 = 0;

const ProbeRecord = extern struct {
    base: u64,
    magic: u32,
    version: u32,
    device: u32,
    layout: u32,
};
var probe_records: [32]ProbeRecord = undefined;
var probe_count: usize = 0;

const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
    ring: [1]u16,
};
const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};
const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [1]VirtqUsedElem,
};
var virtio_desc: [1]VirtqDesc align(16) = undefined;
var virtio_avail: VirtqAvail align(2) = undefined;
var virtio_used: VirtqUsed align(4) = undefined;
var virtio_tx: [128]u8 align(16) = undefined;
var virtio_last_used: u16 = 0;

const Candidate = struct {
    base: u64,
    kind: Kind,
};
const Kind = enum { none, pl011, ns16550, virtio };
var console_kind: Kind = .none;
var console_base: u64 = 0;

// Candidate addresses are not hard-coded into the probe. The EFI map's
// declared MMIO descriptors are the only windows it may inspect.

/// The naked shim is the only code that runs on the loader stack. It copies
/// the four ABI arguments into caller-saved temporaries, installs the exact
/// 16 KiB stack from HandoffV2, restores x0..x3, and calls the normal Zig
/// takeover function. It returns only for a pre-exit failure.
///
/// The `bl` below overwrites the link register with this shim's own return
/// address, so the loader's x30 is stashed in x20 first. x20 is callee-saved
/// under AAPCS64: kernel_main (callconv(.c)) must preserve x19..x28, so the
/// value survives the call. Restoring x30 before the final `ret` is what
/// lets a pre-exit failure actually reach the loader (which then writes
/// RC.TXT); without it the `ret` loops forever on the `bl`'s return address
/// and the kernel never gets back (the observed bad-handoff gate failure).
export fn _start(
    _: u64,
    _: u64,
    _: *const SystemTable,
    _: *HandoffV2,
) callconv(.naked) u64 {
    asm volatile ("mov x9, x0\n" ++
            "mov x10, x1\n" ++
            "mov x11, x2\n" ++
            "mov x12, x3\n" ++
            "mov x19, sp\n" ++
            "mov x20, x30\n" ++
            "ldr x4, [x12, #40]\n" ++
            "ldr x5, [x12, #48]\n" ++
            "add sp, x4, x5\n" ++
            "mov x0, x9\n" ++
            "mov x1, x10\n" ++
            "mov x2, x11\n" ++
            "mov x3, x12\n" ++
            "bl %[takeover]\n" ++
            "mov sp, x19\n" ++
            "mov x30, x20\n" ++
            "ret"
        :
        : [takeover] "X" (&kernel_main),
    );
}

fn kernel_main(base: u64, size: u64, st: *const SystemTable, handoff: *HandoffV2) callconv(.c) u64 {
    if (!valid_handoff(base, size, st, handoff)) {
        print_pre_exit_error(st, "DipshitOS: invalid handoff\r\n");
        return bad_handoff;
    }

    print_pre_exit_error(st, "DipshitOS: kernel entered\r\n");

    const bs = st.boot_services orelse {
        print_pre_exit_error(st, "DipshitOS: no Boot Services\r\n");
        return map_failure;
    };

    var map_buffer = capture_map(bs) catch {
        print_pre_exit_error(st, "DipshitOS: GetMemoryMap failed\r\n");
        return map_failure;
    };

    var exited = false;
    var attempt: usize = 0;
    while (attempt < 8) : (attempt += 1) {
        // The map buffer is already allocated. Re-reading it is the only
        // permitted operation between an INVALID_PARAMETER retry.
        if (bs.exitBootServices(@ptrFromInt(handoff.image_handle), map_buffer.map.info.key)) |_| {
            exited = true;
            break;
        } else |err| switch (err) {
            error.InvalidParameter => {
                const refreshed = bs.getMemoryMap(map_buffer.buffer) catch {
                    print_pre_exit_error(st, "DipshitOS: map refresh failed\r\n");
                    return map_failure;
                };
                map_buffer.map = refreshed;
            },
            else => {
                print_pre_exit_error(st, "DipshitOS: ExitBootServices failed\r\n");
                return exit_failure;
            },
        }
    }
    if (!exited) {
        print_pre_exit_error(st, "DipshitOS: ExitBootServices failed after 8 attempts\r\n");
        halt_forever();
    }

    // After successful exit, no longer allowed: AllocatePool/AllocatePages,
    // GetMemoryMap, SimpleTextOutput, Simple File System,
    // LoadImage/StartImage, SetTimer, any event services, any other Boot
    // Services call. The map buffer is now owned by this kernel and all
    // subsequent work is direct memory/register access only.
    const map_after_exit = map_buffer.map;
    if (!build_identity_map(map_after_exit, map_buffer.buffer, base, size, handoff)) {
        takeover_marker = 0x4d325f5441424c45; // M2_TABLE
        halt_forever();
    }
    install_identity_map();

    const selected = probe_serial(map_after_exit);
    if (selected.kind == .none) {
        takeover_marker = 0x4d325f5345524941; // M2_SERIA
        write_marker_fallback(base, size, map_after_exit);
        halt_forever();
    }
    console_kind = selected.kind;
    console_base = selected.base;

    uart_puts("DipshitOS kernel has seized control.\n");
    uart_puts("memory-map descriptors=");
    uart_hex(@intCast(map_after_exit.info.len));
    uart_puts(" descriptor_size=");
    uart_hex(@intCast(map_after_exit.info.descriptor_size));
    uart_puts(" version=");
    uart_hex(@intCast(map_after_exit.info.descriptor_version));
    uart_puts(" key=");
    uart_hex(@intFromEnum(map_after_exit.info.key));
    uart_puts("\n");

    var it = map_after_exit.iterator();
    while (it.next()) |desc| {
        uart_puts("map type=");
        uart_hex(@intFromEnum(desc.type));
        uart_puts(" base=");
        uart_hex(desc.physical_start);
        uart_puts(" pages=");
        uart_hex(desc.number_of_pages);
        uart_puts(" attr=");
        uart_hex(@bitCast(desc.attribute));
        uart_puts("\n");
    }

    uart_puts("probe base=");
    uart_hex(console_base);
    uart_puts(" layout=");
    uart_puts(layout_name(console_kind));
    uart_puts(" records=");
    uart_hex(@intCast(probe_count));
    uart_puts("\n");
    for (probe_records[0..probe_count]) |record| {
        uart_puts("probe candidate=");
        uart_hex(record.base);
        uart_puts(" magic=");
        uart_hex(record.magic);
        uart_puts(" version=");
        uart_hex(record.version);
        uart_puts(" device=");
        uart_hex(record.device);
        uart_puts(" layout=");
        uart_hex(record.layout);
        uart_puts("\n");
    }

    uart_puts("kernel terminal state\n");
    // No return after takeover. WFE is a terminal state, not a firmware call.
    halt_forever();
}

const CapturedMap = struct {
    buffer: []align(8) u8,
    map: MemoryMapSlice,
};

fn capture_map(bs: *BootServices) !CapturedMap {
    const info = try bs.getMemoryMapInfo();
    if (info.descriptor_size == 0 or info.len > std.math.maxInt(usize) / info.descriptor_size) return error.OutOfResources;
    const map_bytes = info.len * info.descriptor_size;
    if (info.descriptor_size > std.math.maxInt(usize) / 64 or map_bytes > std.math.maxInt(usize) - 64 * info.descriptor_size) return error.OutOfResources;
    const extra = 64 * info.descriptor_size;
    const bytes = map_bytes + extra;
    const buffer = try bs.allocatePool(.loader_data, bytes);
    const map = try bs.getMemoryMap(buffer);
    return .{ .buffer = buffer, .map = map };
}

fn valid_handoff(base: u64, size: u64, st: *const SystemTable, handoff: *const HandoffV2) bool {
    if (@intFromPtr(st) != handoff.system_table) return false;
    if (handoff.magic != handoff_magic or handoff.version != handoff_version) return false;
    if (handoff.kernel_base != base or handoff.kernel_size != size) return false;
    if (size == 0 or base > std.math.maxInt(u64) - size) return false;
    if (handoff.image_handle == 0 or handoff.stack_base == 0) return false;
    if (handoff.stack_size != 16 * 1024 or handoff.flags != 0) return false;
    if ((base & 0xfff) != 0 or (handoff.stack_base & 0xfff) != 0) return false;
    if (handoff.stack_base + handoff.stack_size < handoff.stack_base) return false;
    return true;
}

fn build_identity_map(map: MemoryMapSlice, map_buffer: []align(8) u8, base: u64, size: u64, handoff: *const HandoffV2) bool {
    table_count = 0;
    _ = new_table() orelse return false; // root table at index zero

    var it = map.iterator();
    while (it.next()) |desc| {
        if (desc.number_of_pages == 0 or desc.number_of_pages > std.math.maxInt(u64) / 4096) return false;
        const bytes = desc.number_of_pages * 4096;
        if (desc.physical_start > std.math.maxInt(u64) - bytes) return false;
        if (is_ram(desc.type)) {
            if (!map_range(desc.physical_start, desc.physical_start + bytes, Attr.normal)) return false;
        } else if (desc.type == .memory_mapped_io or desc.type == .memory_mapped_io_port_space) {
            if (!map_range(desc.physical_start, desc.physical_start + bytes, Attr.device)) return false;
        }
    }

    // Ensure all adopted fixed regions are present even if a firmware map has
    // unusual descriptor granularity.
    if (base > std.math.maxInt(u64) - size) return false;
    if (handoff.stack_base > std.math.maxInt(u64) - handoff.stack_size) return false;
    if (@intFromPtr(handoff) > std.math.maxInt(u64) - 4096) return false;
    if (@intFromPtr(map_buffer.ptr) > std.math.maxInt(u64) - map_buffer.len) return false;
    if (!map_range(base, base + size, Attr.normal)) return false;
    if (!map_range(handoff.stack_base, handoff.stack_base + handoff.stack_size, Attr.normal)) return false;
    if (!map_range(@intFromPtr(handoff), @intFromPtr(handoff) + 4096, Attr.normal)) return false;
    if (!map_range(@intFromPtr(map_buffer.ptr), @intFromPtr(map_buffer.ptr) + map_buffer.len, Attr.normal)) return false;
    if (!map_range(@intFromPtr(&table_storage), @intFromPtr(&table_storage) + table_page_count * 4096, Attr.normal)) return false;

    // Only EFI-declared MMIO descriptors are mapped and probed. We never
    // sweep arbitrary physical addresses: an absent VZ device must not turn
    // the probe into a synchronous abort.
    var mmio_it = map.iterator();
    while (mmio_it.next()) |desc| {
        if (desc.type == .memory_mapped_io or desc.type == .memory_mapped_io_port_space) {
            if (desc.number_of_pages == 0 or desc.number_of_pages > std.math.maxInt(u64) / 4096) return false;
            const bytes = desc.number_of_pages * 4096;
            if (desc.physical_start > std.math.maxInt(u64) - bytes) return false;
            const end = desc.physical_start + bytes;
            if (!map_range(desc.physical_start, end, Attr.device)) return false;
        }
    }
    return true;
}

const Attr = enum { normal, device };
const page_size: u64 = 4096;
const block_size: u64 = 2 * 1024 * 1024;

fn is_ram(kind: MemoryType) bool {
    return switch (kind) {
        .loader_code, .loader_data, .boot_services_code, .boot_services_data, .conventional_memory, .persistent_memory => true,
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

fn read_mmfr0() u64 {
    var value: u64 = undefined;
    asm volatile ("mrs %[value], id_aa64mmfr0_el1"
        : [value] "=r" (value),
    );
    return value;
}

fn install_identity_map() void {
    const mmfr0 = read_mmfr0();
    var ips: u64 = mmfr0 & 0xf;
    if (ips > 5) ips = 5;
    const tcr: u64 = 25 | (1 << 8) | (1 << 10) | (3 << 12) | (ips << 32);
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
    asm volatile ("tlbi vmalle1" ::: .{ .memory = true });
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb");
}

fn record_probe(base: u64, magic: u32, version: u32, device: u32, layout: u32) void {
    if (probe_count < probe_records.len) {
        probe_records[probe_count] = .{ .base = base, .magic = magic, .version = version, .device = device, .layout = layout };
        probe_count += 1;
    }
}

fn mmio_read32(address: u64) u32 {
    return @as(*volatile u32, @ptrFromInt(address)).*;
}

fn mmio_write32(address: u64, value: u32) void {
    @as(*volatile u32, @ptrFromInt(address)).* = value;
}

fn mmio_read8(address: u64) u8 {
    return @as(*volatile u8, @ptrFromInt(address)).*;
}

fn mmio_write8(address: u64, value: u8) void {
    @as(*volatile u8, @ptrFromInt(address)).* = value;
}

fn probe_serial(map: MemoryMapSlice) Candidate {
    probe_count = 0;
    var it = map.iterator();
    while (it.next()) |desc| {
        if (desc.type != .memory_mapped_io and desc.type != .memory_mapped_io_port_space) continue;
        if (desc.number_of_pages == 0 or desc.number_of_pages > std.math.maxInt(u64) / 4096) continue;
        const bytes = desc.number_of_pages * 4096;
        if (desc.physical_start > std.math.maxInt(u64) - bytes) continue;
        const end = desc.physical_start + bytes;
        const base = desc.physical_start;
        if (base > std.math.maxInt(u64) - 4096 or base + 4096 > end or probe_count >= probe_records.len) continue;
        const magic = mmio_read32(base);
        const version = mmio_read32(base + 4);
        const device = mmio_read32(base + 8);
        const vendor = mmio_read32(base + 12);
        record_probe(base, magic, version, device, vendor);
        if (magic == 0x74726976 and (version == 1 or version == 2) and device == 3 and vendor != 0) {
            if (virtio_init(base)) return .{ .base = base, .kind = .virtio };
        }
        if (bytes >= 0x1000) {
            const pid0 = mmio_read32(base + 0xfe0) & 0xff;
            const pid1 = mmio_read32(base + 0xfe4) & 0xff;
            const pid2 = mmio_read32(base + 0xfe8) & 0xff;
            const fr = mmio_read32(base + 0x18);
            record_probe(base, pid0 | (pid1 << 8), pid2, fr, 0x504c3031); // PL01
            if (pid0 == 0x11 and pid1 == 0x10 and pid2 == 0x14 and (fr & 0x80) == 0) {
                return .{ .base = base, .kind = .pl011 };
            }
        }

        // 16550 registers are byte-wide. This read-only signature avoids
        // writing arbitrary device registers during discovery; a scratch
        // round-trip is deliberately not used on an un-described window.
        if (bytes >= 8) {
            const ier = mmio_read8(base + 1);
            const iir = mmio_read8(base + 2);
            const lcr = mmio_read8(base + 3);
            const mcr = mmio_read8(base + 4);
            const lsr = mmio_read8(base + 5);
            const msr = mmio_read8(base + 6);
            const scratch = mmio_read8(base + 7);
            record_probe(base, (@as(u32, lsr) << 24) | (@as(u32, iir) << 16) | (@as(u32, lcr) << 8) | mcr, ier, msr, 0x31363535); // 1655
            if ((iir & 0xc0) == 0xc0 and lcr == 0x03 and (mcr & 0xe0) == 0 and (lsr & 0x60) == 0x60 and (lsr & 0x80) == 0 and scratch != 0xff) {
                return .{ .base = base, .kind = .ns16550 };
            }
        }
    }
    return .{ .base = 0, .kind = .none };
}

fn virtio_init(base: u64) bool {
    // This implementation uses only the modern virtio-mmio register path.
    // A version-1 (legacy) device is not selected because its PFN queue
    // layout would require a separate setup path.
    if (mmio_read32(base + 0x04) != 2) return false;
    mmio_write32(base + 0x14, 0);
    const device_features_low = mmio_read32(base + 0x10);
    mmio_write32(base + 0x14, 1);
    const device_features_high = mmio_read32(base + 0x10);
    if ((device_features_high & 1) == 0) return false; // VIRTIO_F_VERSION_1 (bit 32)

    mmio_write32(base + 0x70, 0);
    mmio_write32(base + 0x70, 1 | 2); // ACKNOWLEDGE | DRIVER
    mmio_write32(base + 0x24, 0);
    mmio_write32(base + 0x20, 0); // no optional low-word features
    mmio_write32(base + 0x24, 1);
    mmio_write32(base + 0x20, 1); // negotiate VIRTIO_F_VERSION_1
    _ = device_features_low;
    mmio_write32(base + 0x70, 1 | 2 | 8); // FEATURES_OK
    if ((mmio_read32(base + 0x70) & 8) == 0) return false;

    virtio_desc[0] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    virtio_avail = .{ .flags = 0, .idx = 0, .ring = .{0} };
    virtio_used = .{ .flags = 0, .idx = 0, .ring = .{.{ .id = 0, .len = 0 }} };
    virtio_last_used = 0;
    mmio_write32(base + 0x30, 1); // queue 1: console transmit queue
    const max = mmio_read32(base + 0x34);
    if (max == 0) return false;
    mmio_write32(base + 0x38, 1);
    mmio_write32(base + 0x80, @truncate(@intFromPtr(&virtio_desc)));
    mmio_write32(base + 0x84, @truncate(@intFromPtr(&virtio_desc) >> 32));
    mmio_write32(base + 0x90, @truncate(@intFromPtr(&virtio_avail)));
    mmio_write32(base + 0x94, @truncate(@intFromPtr(&virtio_avail) >> 32));
    mmio_write32(base + 0xa0, @truncate(@intFromPtr(&virtio_used)));
    mmio_write32(base + 0xa4, @truncate(@intFromPtr(&virtio_used) >> 32));
    mmio_write32(base + 0x44, 1);
    mmio_write32(base + 0x70, 1 | 2 | 8 | 4); // DRIVER_OK
    return (mmio_read32(base + 0x70) & 4) != 0;
}

fn uart_putc(byte: u8) void {
    switch (console_kind) {
        .pl011 => {
            var timeout: usize = 0;
            while ((mmio_read32(console_base + 0x18) & (1 << 5)) != 0 and timeout < 1_000_000) : (timeout += 1) {}
            if (timeout < 1_000_000) mmio_write32(console_base, byte);
        },
        .ns16550 => {
            var timeout: usize = 0;
            while ((mmio_read8(console_base + 5) & (1 << 5)) == 0 and timeout < 1_000_000) : (timeout += 1) {}
            if (timeout < 1_000_000) mmio_write8(console_base, byte);
        },
        .virtio => {
            virtio_tx[0] = byte;
            virtio_desc[0] = .{ .addr = @intFromPtr(&virtio_tx), .len = 1, .flags = 0, .next = 0 };
            const next = virtio_avail.idx + 1;
            virtio_avail.ring[0] = virtio_avail.idx;
            virtio_avail.idx = next;
            asm volatile ("dmb ish" ::: .{ .memory = true });
            mmio_write32(console_base + 0x50, 1);
            var timeout: usize = 0;
            while (virtio_used.idx == virtio_last_used and timeout < 1_000_000) : (timeout += 1) {}
            virtio_last_used = virtio_used.idx;
        },
        .none => {},
    }
}

fn uart_puts(text: []const u8) void {
    for (text) |byte| uart_putc(byte);
}

fn uart_hex(value: u64) void {
    uart_puts("0x");
    var shift: u6 = 60;
    while (true) : (shift -= 4) {
        const digit: u8 = @intCast((value >> shift) & 0xf);
        uart_putc(if (digit < 10) '0' + digit else 'a' + digit - 10);
        if (shift == 0) break;
    }
}

fn layout_name(kind: Kind) []const u8 {
    return switch (kind) {
        .pl011 => "PL011\n",
        .ns16550 => "16550\n",
        .virtio => "virtio-console\n",
        .none => "none\n",
    };
}

fn write_marker_fallback(base: u64, size: u64, map: MemoryMapSlice) void {
    // Fixed BSS evidence remains available to a host-side debugger if the
    // serial probe is blocked. It is not reported as serial success.
    takeover_marker = 0x4d324d21; // M2M!
    virtio_tx[0] = 'M';
    virtio_tx[1] = '2';
    virtio_tx[2] = '!';
    virtio_tx[3] = 0;
    _ = base;
    _ = size;
    _ = map;
}

fn halt_forever() noreturn {
    while (true) asm volatile ("wfe");
}

fn print_pre_exit_error(st: *const SystemTable, msg: []const u8) void {
    if (st.con_out) |out| {
        var wide: [128:0]u16 = undefined;
        for (msg, 0..) |byte, index| wide[index] = byte;
        wide[msg.len] = 0;
        _ = out.outputString(&wide) catch {};
    }
}
