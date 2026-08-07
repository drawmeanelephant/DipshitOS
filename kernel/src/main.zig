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
const ConfigurationTable = uefi.tables.ConfigurationTable;

// M1.5 console & shell core (agent B): the interactive `dipshit>` monitor
// runs on the polled TX console through these modules. The takeover path
// below is untouched; this is the seam's import surface.
const console = @import("console.zig");
const machine = @import("machine.zig");
const memmap = @import("memmap.zig");
const monitor = @import("monitor.zig");
const shell = @import("shell.zig");

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

// ADR 0004 D4 fixed-memory-marker fallback (gate work item 3): `takeover_marker`
// is a BSS word a host-side dump can read. It records the takeover stage so a
// silent post-exit death (no serial output) is discriminable: the stage present
// when the kernel halts names the failure window, and a missing later stage
// names the crash site. Values are 8-byte ASCII, little-endian in RAM.
const marker_entry: u64 = 0x4d325f454e545259; // "M2_ENTRY"
const marker_cmap: u64 = 0x4d325f434d415021; // "M2_CMAP!" — about to capture the EFI map
const marker_mapd: u64 = 0x4d325f4d41504421; // "M2_MAPD!" — identity map built, about to install it
const marker_prex: u64 = 0x4d325f5052455821; // "M2_PREX!" — about to call ExitBootServices
const marker_exit: u64 = 0x4d325f4558495421; // "M2_EXIT!"
const marker_mmu: u64 = 0x4d325f4d4d555021; // "M2_MMUP!"
const marker_table: u64 = 0x4d325f5441424c45; // "M2_TABLE"
const marker_seria: u64 = 0x4d325f5345524941; // "M2_SERIA"
const marker_ready: u64 = 0x4d325f5245414459; // "M2_READY" — console ready, banner next
const marker_raw: u64 = 0x4d325f52415721; // "M2_RAW!" — post-switch probe: declared-window base checks
const marker_txok: u64 = 0x4d325f54584f4b21; // "M2_TXOK!" — first serial TX completed (bytes may still be dropped; the log is the gate)
const marker_txst: u64 = 0x4d325f5458535421; // "M2_TXST!" — virtio flush entered (desc/avail posted)
const marker_txnt: u64 = 0x4d325f54584e5421; // "M2_TXNT!" — notify write issued
const marker_txpl: u64 = 0x4d325f5458504c21; // "M2_TXPL!" — used-ring poll finished
const marker_vpscan: u64 = 0x4d325f5650533031; // "M2_VPS01" — virtio-pci console dev scan done
const marker_vpbar: u64 = 0x4d325f5650533032; // "M2_VPS02" — BAR bases read
const marker_vpcap: u64 = 0x4d325f5650533033; // "M2_VPS03" — about to read the capability pointer (0x34)
const marker_vpcapr: u64 = 0x4d325f5650533034; // "M2_VPS04" — capability pointer read; walk about to start
const marker_vpwalk: u64 = 0x4d325f5650533035; // "M2_VPS05" — walk exited
const marker_vpdev: u64 = 0x4d325f5650444556; // "M2_VPDEV" — virtio-pci console device found, caps walked
const marker_vptx: u64 = 0x4d325f5650545821; // "M2_VPTX!" — transport programmed (features + queue)
const marker_vpok: u64 = 0x4d325f56504f4b21; // "M2_VPOK!" — DRIVER_OK, TX path armed

// Marker NVRAM channel: EFI Runtime Services `SetVariable` survives
// ExitBootServices (it is a *runtime* service, not a boot service — the same
// table M1.5's reboot/shutdown design cites via `ResetSystem`). Writing each
// stage as a non-volatile variable gives the host a post-exit-visible marker:
// artifacts/efi-vars.bin is host-readable after the run. This is the working
// form of the ADR 0004 D4 fallback on VZ — the memory-dump variant is
// impossible there (guest RAM is not mapped into the runner process, claim
// 0009).
const marker_variable_name = utf16z("DipshitM2");
const marker_vendor_guid = uefi.Guid{
    .time_low = 0x4d324d32, // "M2M2"
    .time_mid = 0x5f44, // "_D"
    .time_high_and_version = 0x4950, // "IP"
    .clock_seq_high_and_reserved = 0x53, // "S"
    .clock_seq_low = 0x48, // "H"
    .node = .{ 0x49, 0x54, 0x4f, 0x53, 0x2d, 0x4d }, // "ITOS-M"
};

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

/// Clean the D-cache over [start, start+len) to the point of coherence so a
/// subsequent translation walk (which may read memory directly, bypassing a
/// dirty cache) sees the real contents. 64-byte lines (Apple silicon
/// MMU_CLINE = 6); addresses are 64-byte aligned.
fn clean_dcache_range(start: u64, len: u64) void {
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
fn invalidate_dcache_range(start: u64, len: u64) void {
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

const ProbeRecord = extern struct {
    base: u64,
    magic: u32,
    version: u32,
    device: u32,
    layout: u32,
};
var probe_records: [96]ProbeRecord = undefined;
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

// Claim 0013 virtio-pci console (the VZ serial attachment): the runner's
// VZVirtioConsoleDeviceSerialPortConfiguration appears to the guest as a
// modern virtio-pci console (VID 0x1af4, DID 0x1043) on bus 0, found via
// the MCFG ECAM base — not the EFI MMIO windows (which the DSDT proves hold
// only PCI0 + the efivars store; the 0x20050000 PrimeCell UART is Apple's
// internal debug console, unconnected to the serial pipe). Discovery and
// transport setup run PRE-EXIT (config-space and BAR MMIO are
// firmware-identity-mapped and deterministic); post-exit only the notify
// MMIO + queue RAM are touched for TX, and every VA used sits below the
// 4 GiB blanket (mapped Device), so no post-switch fault is possible.
var pci_ecam: u64 = 0; // set from the MCFG table during dump_acpi
var vp_dev: u32 = 0; // console PCI device number
var vp_ready: bool = false; // transport initialized, TX path armed
var vp_common: u64 = 0; // common-config struct address (BAR + cap offset)
var vp_notify: u64 = 0; // notify region base (BAR + cap offset)
var vp_notify_mult: u32 = 0; // notify_off_multiplier
var vp_queue_notify_off: u16 = 0; // queue 1 notify offset
var vp_common_off: u32 = 0; // common cfg offset within the BAR
var vp_notify_off: u32 = 0; // notify cfg offset within the BAR
var vp_bar0: u64 = 0; // console BAR0 base (the SEL record)
var vp_tx_len: usize = 0; // bytes buffered in virtio_tx
var st_tx: ?*const SystemTable = null; // for post-exit flush stage markers

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

    // M1.5 machine controls: capture the EFI Runtime Services table
    // pre-exit. Runtime services (unlike boot services) survive
    // ExitBootServices, so `ResetSystem` remains callable after the
    // takeover — the same table whose SetVariable drives the marker
    // ladder below (observed working post-exit on VZ, claims 0009/0010).
    machine.init(st.runtime_services);

    print_pre_exit_error(st, "DipshitOS: kernel entered\r\n");
    set_marker(marker_entry);
    write_marker_var(st, marker_entry);
    // Second pre-exit write immediately after the first: if the persisted
    // variable still reads M2_ENTRY, a *repeated* SetVariable failed (the
    // marker ladder would be stuck); if it reads M2_CMAP!, the kernel died
    // inside capture_map below.
    write_marker_var(st, marker_cmap);

    const bs = st.boot_services orelse {
        print_pre_exit_error(st, "DipshitOS: no Boot Services\r\n");
        return map_failure;
    };

    var map_buffer = capture_map(bs) catch {
        print_pre_exit_error(st, "DipshitOS: GetMemoryMap failed\r\n");
        return map_failure;
    };

    // Claim 0013 diagnostic (PRE-EXIT, all firmware memory still readable):
    // record the declared MMIO windows, the EFI configuration table
    // (sniffing for the flattened device tree, magic 0xd00dfeed), and the
    // ACPI tables (SPCR names the console UART) into the probe-dump buffer.
    // Persist ONCE, immediately: big SetVariable writes are proven to work
    // pre-exit but hang post-exit on VZ (observed: the ladder stopped at
    // M2_RAW! with a 2.6 KB re-write pending), and a post-switch fault must
    // not lose this evidence. The post-exit probe appends only a small tail
    // (write_probe_tail).
    dump_mmio_descriptors(map_buffer.map);
    dump_config_table(st);
    dump_acpi(st);
    write_probe_var(st);

    // Claim 0013: the serial probe runs PRE-EXIT — post-exit reads of the
    // declared MMIO windows hang on VZ (observed every run). The selection
    // is remembered in the console_* globals and used post-exit for TX only.
    const pre = probe_serial_pre(map_buffer.map, st);
    console_kind = pre.kind;
    console_base = pre.base;
    dump_sel(pre.kind, pre.base);
    write_probe_var(st);

    // Pre-exit stage: proves the kernel passed valid_handoff + capture_map
    // and reached the exit call. The persisted NVRAM marker being M2_ENTRY
    // instead means the kernel died in that window.
    write_marker_var(st, marker_prex);

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
    set_marker(marker_exit);
    write_marker_var(st, marker_exit); // first post-exit runtime-services call

    // After successful exit, no longer allowed: AllocatePool/AllocatePages,
    // GetMemoryMap, SimpleTextOutput, Simple File System,
    // LoadImage/StartImage, SetTimer, any event services, any other Boot
    // Services call. The map buffer is now owned by this kernel and all
    // subsequent work is direct memory/register access only.
    const map_after_exit = map_buffer.map;
    if (!build_identity_map(map_after_exit, map_buffer.buffer, base, size, handoff)) {
        set_marker(marker_table);
        write_marker_var(st, marker_table);
        halt_forever();
    }
    // Pre-install write (still on the firmware identity map, reliable): if the
    // persisted ladder stops here, the kernel died between this write and the
    // post-install M2_MMUP! write — i.e. inside install_identity_map() or at
    // the first post-switch call (claim 0009: observed — every VZ run stops
    // at M2_MAPD!, so the MMU takeover window is the death site; the kernel
    // never reaches the serial probe).
    write_marker_var(st, marker_mapd);
    install_identity_map();
    set_marker(marker_mmu);
    write_marker_var(st, marker_mmu);

    const selected = probe_serial(map_after_exit, st);
    console_kind = selected.kind;
    console_base = selected.base;
    if (selected.kind == .none) {
        set_marker(marker_seria);
        write_marker_var(st, marker_seria);
        write_marker_fallback(base, size, map_after_exit);
        halt_forever();
    }
    set_marker(marker_ready);
    write_marker_var(st, marker_ready);

    st_tx = st; // for flush stage markers
    uart_puts("DipshitOS kernel has seized control.\n");
    // Claim 0013: after the first TX, record whether the TX path returned
    // (bytes may still be dropped by the device; the serial log is the gate,
    // but M2_TXOK! separates "TX hung" from "TX returned silently").
    write_marker_var(st, marker_txok);
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

    // ------------------------------------------------------------------
    // M1.5 console & shell core seam (agent B). The takeover path above
    // (exit, map, MMU, probe, uart_*) is byte-identical; this section only
    // wires the mock-proven shell loop onto the polled TX console. RX
    // reads are [inferred] and gated on the VZ serial gate (claim 0002,
    // unpassed): no device register is read, rx_wired() is false, so the
    // banner + prompt print and the kernel parks below — it never spins
    // hot. The loop's correctness is proven in kernel/src/shell.zig
    // against a scripted MockConsole (artifacts/m15-shell-core-loop.txt).
    // ------------------------------------------------------------------
    var m15 = M15Console{};
    const map_view = memmap.MapView.init(map_buffer.buffer, map_after_exit.info.descriptor_size, map_after_exit.info.len);
    const console_name = layout_name(console_kind);
    var mon = monitor.Monitor.init(
        m15.to_console(),
        .{
            .handoff = @bitCast(handoff.*),
            .map = map_view,
            .console_name = console_name[0 .. console_name.len - 1],
        },
        machine.control(),
    );
    shell.boot_and_park(&mon, m15.rx_wired());
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
    const blanket_end = 4 * 1024 * 1024 * 1024;
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

    // Claim 0013: the virtio-pci console transport window (firmware-assigned
    // at 0x100010000, ABOVE the blanket) must stay reachable post-exit for
    // TX. Map it Device (4 KiB pages; the low blanketed world is untouched).
    // Post-exit config writes cannot move the BAR on VZ (observed: a rebase
    // "completed" but the device never answered at the new base), so the
    // firmware's placement is mapped in place instead.
    if (vp_ready and vp_bar0 != 0 and vp_bar0 >= blanket_end) {
        if (!map_range(vp_bar0, vp_bar0 + 0x10000, Attr.device)) return false;
    }

    // All adopted fixed regions sit inside declared RAM below the blanket;
    // verify they resolve to Normal mappings as a consistency check.
    if (base > std.math.maxInt(u64) - size) return false;
    if (handoff.stack_base > std.math.maxInt(u64) - handoff.stack_size) return false;
    if (!mapped_normal(base)) return false;
    if (!mapped_normal(handoff.stack_base)) return false;
    if (!mapped_normal(@intFromPtr(handoff))) return false;
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

/// Walk VA through the built 4 KB-granule tables (T0SZ=25) and report whether
/// it resolves to a Normal mapping (MAIR AttrIndex = 0b01, descriptor bit 2).
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
    // Claim 0010 root cause: the freshly-built tables must be cleaned to
    // memory BEFORE the first walk can read them. The kernel writes them as
    // Normal WB stores (dirty in the D-cache only); the first post-switch
    // access walks them, and any D-cache line invalidation without a clean in
    // between (observed: the firmware runtime SetVariable call between the
    // switch and the TLBI drops the dirty lines) leaves stale RAM for the
    // post-TLBI re-walk to fault on. Clean the whole 512 KiB carve-out so the
    // walker always reads the real tables.
    clean_dcache_range(@intFromPtr(&table_storage), table_page_count * 4096);
    // T0SZ=25 selects the 2^39 VA space the map builder assumes (va_limit in
    // map_range). TG0 (the TTBR0 walker's granule) is left 0b00 = 4 KB in
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
    const tcr: u64 = 25 | (ips << 32);
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
    // Claim 0010: NO `tlbi vmalle1` at the switch. Bisect markers proved the
    // switch and the first post-switch runtime call succeed, but any re-walk
    // FORCED by a TLBI then faults on VZ (ladder ended at M2_TTBR!; claim
    // 0010). The stale firmware TLB entries are identity-compatible with our
    // map below the blanket boundary — the blanket maps every VA < 4 GiB with
    // the same VA==PA translations the firmware had (RAM Normal WB, MMIO
    // Device), so any stale entry still in the TLB resolves identically. The
    // safety argument stops at 4 GiB: above it only EFI-declared regions are
    // mapped, so this milestone must not touch VAs the firmware previously
    // translated above the blanket (none observed on VZ). Skipping the
    // invalidate is safe because the map never changes descriptors
    // post-switch; a later milestone that re-maps regions must revisit this
    // and characterise the VZ re-walk fault.
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb");
}

fn record_probe(base: u64, magic: u32, version: u32, device: u32, layout: u32) void {
    if (probe_count < probe_records.len) {
        probe_records[probe_count] = .{ .base = base, .magic = magic, .version = version, .device = device, .layout = layout };
        probe_count += 1;
    }
}

// ---------------------------------------------------------------------------
// Claim 0013 diagnostic: the probe's ground truth is persisted to the NVRAM
// channel (a second variable, `DipshitProbe`, same vendor GUID as the marker
// ladder) so the host can read exactly what each declared MMIO window
// contains even though the serial log is silent. The ladder (DipshitM2) is
// untouched. Lines are plain ASCII so `strings artifacts/efi-vars.bin` shows
// them.
// ---------------------------------------------------------------------------
const probe_variable_name = utf16z("DipshitProbe");
var probe_dump: [32768]u8 = undefined;
var probe_dump_len: usize = 0;

fn dump_str(text: []const u8) void {
    if (text.len > probe_dump.len - probe_dump_len) return;
    @memcpy(probe_dump[probe_dump_len .. probe_dump_len + text.len], text);
    probe_dump_len += text.len;
}

fn dump_hex(value: u64) void {
    var tmp: [18]u8 = undefined;
    tmp[0] = '0';
    tmp[1] = 'x';
    var index: usize = 2;
    var shift: u6 = 60;
    while (true) : (shift -= 4) {
        const digit: u8 = @intCast((value >> shift) & 0xf);
        tmp[index] = if (digit < 10) '0' + digit else 'a' + digit - 10;
        index += 1;
        if (shift == 0) break;
    }
    dump_str(tmp[0..index]);
}

fn dump_probe_line(off: u64, base: u64, magic: u32, version: u32, device: u32, vendor: u32) void {
    dump_str("VIRTIO O=");
    dump_hex(off);
    dump_str(" B=");
    dump_hex(base);
    dump_str(" M=");
    dump_hex(magic);
    dump_str(" V=");
    dump_hex(version);
    dump_str(" D=");
    dump_hex(device);
    dump_str(" R=");
    dump_hex(vendor);
    dump_str("\n");
}

fn dump_pl011_line(off: u64, addr: u64, pid0: u32, pid1: u32, pid2: u32, fr: u32) void {
    dump_str("UART PL011 O=");
    dump_hex(off);
    dump_str(" B=");
    dump_hex(addr);
    dump_str(" PID=");
    dump_hex(pid0 | (pid1 << 8) | (pid2 << 16));
    dump_str(" FR=");
    dump_hex(fr);
    dump_str("\n");
}

fn dump_16550_line(off: u64, addr: u64, ier: u32, iir: u32, lcr: u32, mcr: u32, lsr: u32, msr: u32, scratch: u32) void {
    dump_str("UART 16550 O=");
    dump_hex(off);
    dump_str(" B=");
    dump_hex(addr);
    dump_str(" IER=");
    dump_hex(ier);
    dump_str(" IIR=");
    dump_hex(iir);
    dump_str(" LCR=");
    dump_hex(lcr);
    dump_str(" MCR=");
    dump_hex(mcr);
    dump_str(" LSR=");
    dump_hex(lsr);
    dump_str(" MSR=");
    dump_hex(msr);
    dump_str(" SCR=");
    dump_hex(scratch);
    dump_str("\n");
}

fn dump_sel(kind: Kind, base: u64) void {
    dump_str("SEL=");
    switch (kind) {
        .pl011 => dump_str("PL011 "),
        .ns16550 => dump_str("16550 "),
        .virtio => dump_str("VIRTIO "),
        .none => dump_str("NONE "),
    }
    dump_str("base=");
    dump_hex(base);
    dump_str("\n");
}

/// Persist the probe dump to the NVRAM channel as a sequence of ≤ 2048-byte
/// chunks (variables `DipshitP0`, `DipshitP1`, ...). Chunked because a
/// single large SetVariable silently FAILS on VZ above ~4-5 KB (claim 0013:
/// a ~6 KB write vanished while a ~4.5 KB instance persisted). Best effort
/// per chunk; a failed call never changes control flow. Used PRE-EXIT only:
/// big SetVariable re-writes hang post-exit on VZ (claim 0013).
const probe_chunk_size: usize = 2048;
fn write_probe_var(st: *const SystemTable) void {
    if (probe_dump_len == 0) return;
    var pos: usize = 0;
    var chunk: usize = 0;
    while (pos < probe_dump_len) : (pos += probe_chunk_size) {
        const len = @min(probe_chunk_size, probe_dump_len - pos);
        var name: [16:0]u16 = undefined;
        const prefix = "DipshitP";
        var i: usize = 0;
        while (i < prefix.len) : (i += 1) name[i] = prefix[i];
        var digits: [4]u8 = undefined;
        var n = chunk;
        var nd: usize = 0;
        while (true) : (nd += 1) {
            digits[nd] = @intCast('0' + (n % 10));
            n /= 10;
            if (n == 0) break;
        }
        while (nd > 0) : (nd -= 1) {
            name[i] = digits[nd - 1];
            i += 1;
        }
        name[i] = 0;
        _ = st.runtime_services._setVariable(
            &name,
            &marker_vendor_guid,
            .{ .non_volatile = true, .bootservice_access = true, .runtime_access = true },
            len,
            probe_dump[pos .. pos + len].ptr,
        );
        chunk += 1;
    }
}

/// POST-EXIT variant: persist only the newest tail of the dump buffer (≤ 512
/// bytes) as a SEPARATE variable, so post-exit probe additions (candidate
/// hits, SEL) are observable without a large re-write of `DipshitProbe`
/// (which hangs post-exit on VZ). Best effort; a failure is ignored.
const probe_tail_variable_name = utf16z("DipshitP2");
fn write_probe_tail(st: *const SystemTable) void {
    if (probe_dump_len == 0) return;
    const start: usize = if (probe_dump_len > 512) probe_dump_len - 512 else 0;
    const len = probe_dump_len - start;
    _ = st.runtime_services._setVariable(
        &probe_tail_variable_name,
        &marker_vendor_guid,
        .{ .non_volatile = true, .bootservice_access = true, .runtime_access = true },
        len,
        probe_dump[start..].ptr,
    );
}

fn dump_raw(addr: u64, len: usize, tag: []const u8) void {
    dump_str(tag);
    dump_str(" @");
    dump_hex(addr);
    dump_str(": ");
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dump_hex(mmio_read8(addr + i));
        dump_str(" ");
    }
    dump_str("\n");
}

fn dump_guid_bytes(guid: *const uefi.Guid) void {
    const raw: [*]const u8 = @ptrCast(guid);
    var i: usize = 0;
    while (i < 16) : (i += 1) dump_hex(raw[i]);
}

/// Pre-exit dump of every EFI configuration-table entry: vendor GUID, table
/// pointer, and the first 32-bit word of the table (a flattened device tree
/// starts with the big-endian magic 0xd00dfeed — the authoritative VZ device
/// list). This runs before ExitBootServices so all firmware memory is
/// readable; the buffer is persisted post-exit by write_probe_var.
fn dump_config_table(st: *const SystemTable) void {
    const entries = st.number_of_table_entries;
    dump_str("CFG n=");
    dump_hex(entries);
    dump_str("\n");
    const table = st.configuration_table;
    var i: usize = 0;
    while (i < entries and i < 12) : (i += 1) {
        const entry = &table[i];
        dump_str("CFG ");
        dump_hex(i);
        dump_str(" G=");
        dump_guid_bytes(&entry.vendor_guid);
        dump_str(" P=");
        dump_hex(@intCast(@intFromPtr(entry.vendor_table)));
        const first = @as(*const volatile u32, @ptrFromInt(@intFromPtr(entry.vendor_table))).*;
        dump_str(" F=");
        dump_hex(first);
        dump_str("\n");
    }
}

fn dump_raw_sparse(addr: u64, len: usize, tag: []const u8) void {
    // Dump only the non-zero 16-byte groups of a window: a sparse register
    // file (claim 0013: 0x20050000 reads 0x23 0xd3 0x75 0x6a at +0, 0x01 at
    // +0x0c, and 0x31/0x10/0x04 in the +0xfe0 area) is shown completely
    // without paying 20 KB of ASCII for the zero pages.
    var pos: usize = 0;
    while (pos < len) : (pos += 16) {
        const group = @min(16, len - pos);
        var nonzero = false;
        var i: usize = 0;
        while (i < group) : (i += 1) {
            if (mmio_read8(addr + pos + i) != 0) {
                nonzero = true;
                break;
            }
        }
        if (!nonzero) continue;
        dump_str(tag);
        dump_str(" @");
        dump_hex(addr + pos);
        dump_str(": ");
        i = 0;
        while (i < group) : (i += 1) {
            dump_hex(mmio_read8(addr + pos + i));
            dump_str(" ");
        }
        dump_str("\n");
    }
}

/// Pre-exit dump of the FULL EFI map (every descriptor — no device window
/// or high region missed) plus the complete non-zero register bytes of each
/// declared MMIO window. PRE-EXIT only: post-exit reads of these windows
/// hang on VZ (claim 0013).
fn dump_mmio_descriptors(map: MemoryMapSlice) void {
    var count: usize = 0;
    var it = map.iterator();
    while (it.next()) |desc| : (count += 1) {
        if (count >= 64) break;
        if (desc.number_of_pages == 0 or desc.number_of_pages > std.math.maxInt(u64) / 4096) continue;
        dump_str("MAP T=");
        dump_hex(@intFromEnum(desc.type));
        dump_str(" B=");
        dump_hex(desc.physical_start);
        dump_str(" N=");
        dump_hex(desc.number_of_pages);
        dump_str(" A=");
        dump_hex(@bitCast(desc.attribute));
        dump_str("\n");
    }
    var it2 = map.iterator();
    while (it2.next()) |desc| {
        if (desc.type != .memory_mapped_io and desc.type != .memory_mapped_io_port_space) continue;
        if (desc.number_of_pages == 0 or desc.number_of_pages > std.math.maxInt(u64) / 4096) continue;
        const bytes = desc.number_of_pages * 4096;
        if (desc.physical_start > std.math.maxInt(u64) - bytes) continue;
        if (bytes <= 4096) {
            // Small window: dump every non-zero register byte in full.
            dump_raw_sparse(desc.physical_start, @intCast(bytes), "RAW");
        } else {
            // Big window (e.g. the efivars store): base string only.
            dump_raw(desc.physical_start, 64, "RAW");
        }
    }
}

/// Post-exit ACPI discovery (claim 0013): locate the RSDP via the ACPI 2.0
/// config-table GUID (observed present in run 2), walk the RSDT/XSDT, and
/// dump every table's signature + address plus the raw first 96 bytes of the
/// SPCR (Serial Port Console Redirection — names the console UART and its
/// exact base) and DBG2 (debug ports) tables. This is the authoritative VZ
/// device list; it supersedes heuristic MMIO scanning. Tables live in
/// firmware RAM below 4 GiB (covered by the blanket map); reads are volatile.
fn dump_acpi(st: *const SystemTable) void {
    // Runs PRE-EXIT (all firmware RAM readable; the full buffer is persisted
    // once by the caller). ACPI tables are plain RAM below 4 GiB, so no MMIO
    // reads here — this cannot hit the post-exit fivars-region stall.
    dump_str("ACPI start\n");
    var rsdp_addr: u64 = 0;
    const entries = st.number_of_table_entries;
    const cfg = st.configuration_table;
    var i: usize = 0;
    while (i < entries) : (i += 1) {
        if (std.mem.eql(u8, std.mem.asBytes(&cfg[i].vendor_guid), std.mem.asBytes(&ConfigurationTable.acpi_20_table_guid))) {
            rsdp_addr = @intFromPtr(cfg[i].vendor_table);
            break;
        }
    }
    if (rsdp_addr == 0) {
        dump_str("ACPI: no RSDP config-table entry\n");
        return;
    }
    dump_str("ACPI RSDP @");
    dump_hex(rsdp_addr);
    dump_str("\n");
    // Revision sits at offset 15 (after sig+checksum+OEM ID); offset 8 is an
    // OEM ID byte. ACPI 2.0+ carries the XSDT address at +24.
    const revision = mmio_read8(rsdp_addr + 15);
    dump_str("ACPI rev=");
    dump_hex(revision);
    dump_str("\n");
    const is_xsdt = revision >= 2;
    const root_addr: u64 = if (is_xsdt) mmio_read64(rsdp_addr + 24) else mmio_read32(rsdp_addr + 16);
    if (root_addr == 0) {
        dump_str("ACPI: no RSDT/XSDT\n");
        return;
    }
    const root_len = mmio_read32(root_addr + 4);
    dump_str("ACPI root @");
    dump_hex(root_addr);
    dump_str(" len=");
    dump_hex(root_len);
    dump_str("\n");
    const stride: u64 = if (is_xsdt) 8 else 4;
    var off: u64 = 36;
    var count: usize = 0;
    while (off + stride <= root_len and count < 24) : (off += stride) {
        const taddr: u64 = if (is_xsdt) mmio_read64(root_addr + off) else mmio_read32(root_addr + off);
        if (taddr == 0 or taddr > 4 * 1024 * 1024 * 1024) continue;
        const sig = mmio_read32(taddr);
        dump_str("ACPI T=");
        dump_hex(sig);
        dump_str(" @");
        dump_hex(taddr);
        dump_str("\n");
        if (sig == 0x52504353) { // "SPCR" (LE)
            dump_str("SPCR\n");
            dump_raw(taddr, 96, "  ");
        }
        if (sig == 0x32474244) { // "DBG2" (LE)
            dump_str("DBG2\n");
            dump_raw(taddr, 96, "  ");
        }
        if (sig == 0x50434146) { // "FACP" (LE) — FADT
            // DSDT pointer at offset 40: the AML device list (claims the
            // platform's serial devices with _HID/_CRS base addresses).
            const dsdt = mmio_read32(taddr + 40);
            dump_str("FACP DSDT @");
            dump_hex(dsdt);
            dump_str("\n");
            if (dsdt != 0 and dsdt < 4 * 1024 * 1024 * 1024) {
                const dsdt_len = mmio_read32(dsdt + 4);
                dump_str("DSDT len=");
                dump_hex(dsdt_len);
                dump_str("\n");
                dump_raw(dsdt, 96, "DSDT");
            }
        }
        if (sig == 0x4746434d) { // "MCFG" (LE) — PCI ECAM base
            const ecam = mmio_read64(taddr + 44);
            pci_ecam = ecam;
            dump_str("MCFG ECAM @");
            dump_hex(ecam);
            dump_str("\n");
            dump_pci(ecam);
        }
        count += 1;
    }
}

fn pci_read32(ecam: u64, bus: u32, dev: u32, func: u32, off: u32) u32 {
    const addr = ecam | (@as(u64, bus) << 20) | (@as(u64, dev) << 15) | (@as(u64, func) << 12) | off;
    return mmio_read32(addr);
}

fn pci_write32(ecam: u64, bus: u32, dev: u32, func: u32, off: u32, value: u32) void {
    const addr = ecam | (@as(u64, bus) << 20) | (@as(u64, dev) << 15) | (@as(u64, func) << 12) | off;
    mmio_write32(addr, value);
}

/// Byte-granular config-space read: the capability header fields sit at odd
/// offsets (c+1, c+3, c+4), and an unaligned 32-bit read on Device (nGnRnE)
/// memory is an alignment fault on ARMv8 — the cap walk MUST use byte reads
/// (claim 0013: every walk run faulted here, ladder M2_VPS04 → M2_VPS05 gap,
/// while the aligned/byte dumps in dump_pci survived).
fn pci_read8(ecam: u64, bus: u32, dev: u32, func: u32, off: u32) u8 {
    const addr = ecam | (@as(u64, bus) << 20) | (@as(u64, dev) << 15) | (@as(u64, func) << 12) | off;
    return mmio_read8(addr);
}

/// 32-bit config-space read assembled from four byte reads (safe at any
/// offset). Only for fields that may sit unaligned (capability header
/// payloads); the BAR/command fields at 0x10..0x24 stay aligned reads.
fn pci_read32_unaligned(ecam: u64, bus: u32, dev: u32, func: u32, off: u32) u32 {
    var result: u32 = 0;
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        result |= @as(u32, pci_read8(ecam, bus, dev, func, off + i)) << @as(u5, @intCast(i * 8));
    }
    return result;
}

/// Claim 0013 PCI discovery: the decoded DSDT declares a PCI0 root complex
/// (no UART, no MMIO virtio-console), so the VZ serial attachment is a
/// virtio-pci device found only through config space. Scan bus 0 for every
/// present device and dump VID/DID/class + all six BARs. PRE-EXIT only
/// (firmware maps the ECAM window; post-exit it is undeclared and the read
/// could fault/hang).
fn dump_pci(ecam: u64) void {
    if (ecam == 0 or ecam > 4 * 1024 * 1024 * 1024) {
        dump_str("PCI: no ECAM\n");
        return;
    }
    var found: usize = 0;
    var dev: u32 = 0;
    while (dev < 32 and found < 48) : (dev += 1) {
        var func: u32 = 0;
        var funcs: u32 = 1;
        while (func < funcs and found < 48) : (func += 1) {
            const id = pci_read32(ecam, 0, dev, func, 0);
            const vid = id & 0xffff;
            if (vid == 0xffff) continue;
            const hdr = pci_read32(ecam, 0, dev, func, 0x0c);
            const ht = (hdr >> 8) & 0xff;
            if (func == 0 and (ht & 0x80) != 0) funcs = 8;
            const did = id >> 16;
            dump_str("PCI D=");
            dump_hex(dev);
            dump_str(" F=");
            dump_hex(func);
            dump_str(" VID=");
            dump_hex(vid);
            dump_str(" DID=");
            dump_hex(did);
            dump_str(" CLS=");
            dump_hex((pci_read32(ecam, 0, dev, func, 8) >> 8) & 0xffffff);
            var b: u32 = 0;
            while (b < 6) : (b += 1) {
                dump_str(" B");
                dump_hex(b);
                dump_str("=");
                dump_hex(pci_read32(ecam, 0, dev, func, 0x10 + b * 4));
            }
            dump_str("\n");
            found += 1;
        }
    }
    dump_str("PCI found=");
    dump_hex(found);
    dump_str("\n");
    // Full aligned-u32 config-space dump of the virtio console (the
    // capability list at 0x34 is what the virtio-pci transport needs),
    // persisted pre-exit so the host sees the exact cap layout. ALIGNED u32
    // reads are the only coherent access on VZ (claim 0013: byte reads of
    // config space return shifted/garbage offset fields).
    var dev2: u32 = 0;
    while (dev2 < 32) : (dev2 += 1) {
        const id2 = pci_read32(ecam, 0, dev2, 0, 0);
        if ((id2 & 0xffff) == 0xffff) continue;
        const did2 = id2 >> 16;
        if (did2 != 0x1043 and did2 != 0x1003) continue;
        dump_str("CFGSPACE D=");
        dump_hex(dev2);
        dump_str("\n");
        var w: u32 = 0;
        while (w < 0x80) : (w += 4) {
            dump_str("W ");
            dump_hex(w);
            dump_str("=");
            dump_hex(pci_read32(ecam, 0, dev2, 0, w));
            dump_str("\n");
        }
        break;
    }
}

fn mmio_read32(address: u64) u32 {
    return @as(*volatile u32, @ptrFromInt(address)).*;
}

fn mmio_read64(address: u64) u64 {
    return @as(*volatile u64, @ptrFromInt(address)).*;
}

fn mmio_write64(address: u64, value: u64) void {
    @as(*volatile u64, @ptrFromInt(address)).* = value;
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

fn mmio_read16(address: u64) u16 {
    return @as(*volatile u16, @ptrFromInt(address)).*;
}

fn mmio_write16(address: u64, value: u16) void {
    @as(*volatile u16, @ptrFromInt(address)).* = value;
}

fn vp_read8(off: u32) u8 {
    return mmio_read8(vp_common + off);
}

fn vp_write8(off: u32, value: u8) void {
    mmio_write8(vp_common + off, value);
}

fn vp_read16(off: u32) u16 {
    return mmio_read16(vp_common + off);
}

fn vp_write16(off: u32, value: u16) void {
    mmio_write16(vp_common + off, value);
}

fn vp_read32(off: u32) u32 {
    return mmio_read32(vp_common + off);
}

fn vp_write32(off: u32, value: u32) void {
    mmio_write32(vp_common + off, value);
}

/// Claim 0013: initialize the modern virtio-pci console as the kernel
/// console. Walks the device's virtio capabilities (ID 0x09, cfg types
/// common/notify), programs the modern transport (features, queue 1 =
/// transmit), and arms TX. PRE-EXIT only; evidence is dumped to the probe
/// buffer so the host sees the state either way.
fn virtio_pci_init(st: *const SystemTable) bool {
    if (pci_ecam == 0) {
        dump_str("VP: no ECAM\n");
        return false;
    }

    // Locate the console: modern DID 0x1043, legacy 0x1003 (this milestone
    // drives the modern transport only). Bus 0, function 0.
    var console_dev: u32 = 32;
    var dev: u32 = 0;
    while (dev < 32) : (dev += 1) {
        const id = pci_read32(pci_ecam, 0, dev, 0, 0);
        if ((id & 0xffff) == 0xffff) continue;
        const did = id >> 16;
        if (did == 0x1043 or did == 0x1003) {
            console_dev = dev;
            break;
        }
    }
    if (console_dev == 32) {
        dump_str("VP: no virtio-console PCI device\n");
        return false;
    }
    vp_dev = console_dev;
    dump_str("VP dev=");
    dump_hex(console_dev);
    dump_str("\n");
    write_marker_var(st, marker_vpscan);

    // BAR bases (memory BARs; 64-bit pairs merged).
    var bar_base: [6]u64 = .{0} ** 6;
    var bi: usize = 0;
    while (bi < 6) : (bi += 1) {
        const low = pci_read32(pci_ecam, 0, console_dev, 0, 0x10 + @as(u32, @intCast(bi)) * 4);
        if ((low & 1) != 0) continue; // I/O space — ignored
        const base: u64 = low & ~@as(u32, 0xf);
        bar_base[bi] = base;
        if (((low >> 1) & 0x3) == 2 and bi + 1 < 6) { // 64-bit BAR
            const high = pci_read32(pci_ecam, 0, console_dev, 0, 0x10 + @as(u32, @intCast(bi + 1)) * 4);
            bar_base[bi] |= @as(u64, high) << 32;
            bi += 1;
        }
    }
    write_marker_var(st, marker_vpbar);

    // Walk the capability list for the virtio vendor-specific caps (ID 0x09):
    // each carries cfg_type + bar + offset; the notify cap adds a multiplier.
    write_marker_var(st, marker_vpcap);
    const cap_ptr = pci_read32(pci_ecam, 0, console_dev, 0, 0x34) & 0xff;
    write_marker_var(st, marker_vpcapr);
    var common_bar: u32 = 0;
    var common_off: u32 = 0;
    var notify_bar: u32 = 0;
    var notify_off: u32 = 0;
    var notify_mult: u32 = 0;
    var found_common = false;
    var found_notify = false;
    var c: u32 = cap_ptr;
    var caps: usize = 0;
    // The virtio_pci_cap header packs id/next/len/cfg_type into one aligned
    // u32; offset/length are the next two aligned u32s. Cap bases are 4-byte
    // aligned (0x40/0x50/0x60/0x74 on VZ), so every read below is aligned —
    // unaligned accesses fault on Device memory, and byte reads return
    // garbage on VZ (claim 0013); aligned u32 reads are the coherent view.
    while (c != 0 and c < 0x100 and (c & 3) == 0 and caps < 16) : (caps += 1) {
        const head = pci_read32(pci_ecam, 0, console_dev, 0, c);
        const id = head & 0xff;
        const next = (head >> 8) & 0xff;
        if (id == 0x09) {
            const cfg_type = (head >> 24) & 0xff;
            const bar = pci_read32(pci_ecam, 0, console_dev, 0, c + 4) & 0xff;
            const off = pci_read32(pci_ecam, 0, console_dev, 0, c + 8);
            switch (cfg_type) {
                1 => {
                    common_bar = bar;
                    common_off = off;
                    found_common = true;
                },
                2 => {
                    notify_bar = bar;
                    notify_off = off;
                    notify_mult = pci_read32(pci_ecam, 0, console_dev, 0, c + 16);
                    found_notify = true;
                },
                else => {},
            }
        }
        c = next;
    }
    write_marker_var(st, marker_vpwalk);

    // NOTE: no BAR rebase pre-exit — moving the window makes the device
    // unreachable pre-exit (observed: after rebasing to 0x10000, reads of
    // BOTH the old firmware base and 0x10000 hang — the firmware never maps
    // the low address). The firmware-assigned base is used for setup; a
    // post-exit rebase to below-the-blanket 0x10000 happens in
    // virtio_pci_rebase_post_exit (ECAM config writes survive post-exit,
    // and the blanket maps 0x10000 as Device).
    // Offset 0 is a legitimate common-cfg offset (VZ: common @ BAR0+0x00);
    // the caps must simply both be present.
    if (!found_common or !found_notify or common_bar >= 6 or notify_bar >= 6) {
        dump_str("VP: missing capability structs\n");
        return false;
    }
    vp_common = bar_base[common_bar] + common_off;
    vp_notify = bar_base[notify_bar] + notify_off;
    vp_notify_mult = notify_mult;
    vp_common_off = common_off;
    vp_notify_off = notify_off;
    vp_bar0 = bar_base[0];
    dump_str("VP common=");
    dump_hex(vp_common);
    dump_str(" notify=");
    dump_hex(vp_notify);
    dump_str(" mult=");
    dump_hex(notify_mult);
    dump_str("\n");
    // Stage marker: device found, BARs + capabilities resolved. If the ladder
    // stops here, a config-space read in the walk is the death site.
    write_marker_var(st, marker_vpdev);
    // Persist the walk results now: if a transport write below stalls, the
    // host still sees the resolved common/notify addresses.
    write_probe_var(st);

    // Modern transport init: reset, ACKNOWLEDGE|DRIVER, accept
    // VIRTIO_F_VERSION_1, FEATURES_OK.
    vp_write8(0x14, 0); // reset
    vp_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER
    const features_lo = vp_read32(0x04);
    // device_feature_select lives at 0x00 (0x08 is the DRIVER's select).
    vp_write32(0x00, 1);
    const features_hi = vp_read32(0x04);
    vp_write32(0x00, 0);
    dump_str("VP feats=");
    dump_hex(features_lo);
    dump_str("/");
    dump_hex(features_hi);
    dump_str("\n");
    if ((features_hi & 1) == 0) {
        dump_str("VP: no VIRTIO_F_VERSION_1\n");
        return false;
    }
    vp_write32(0x08, 1);
    vp_write32(0x0c, 1); // accept VIRTIO_F_VERSION_1
    vp_write32(0x08, 0);
    vp_write32(0x0c, 0);
    vp_write8(0x14, 1 | 2 | 8); // FEATURES_OK
    if ((vp_read8(0x14) & 8) == 0) {
        dump_str("VP: FEATURES_OK failed\n");
        return false;
    }

    // Queue 1 = console transmit. Size 1 (one descriptor, no chaining).
    vp_write16(0x16, 1); // queue_select
    const qsz = vp_read16(0x18);
    if (qsz == 0) {
        dump_str("VP: queue 1 absent\n");
        return false;
    }
    vp_write16(0x18, 1); // queue_size = 1
    virtio_desc[0] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    virtio_avail = .{ .flags = 0, .idx = 0, .ring = .{0} };
    virtio_used = .{ .flags = 0, .idx = 0, .ring = .{.{ .id = 0, .len = 0 }} };
    virtio_last_used = 0;
    vp_tx_len = 0;
    // Queue GPA registers are le64; VZ's common-cfg emulation accepts 32-bit
    // accesses (claim 0013: byte reads of config space return garbage — the
    // emulation has access-size quirks), so write each half as a 32-bit store
    // rather than a single 64-bit one that may be dropped.
    const qd = @intFromPtr(&virtio_desc);
    mmio_write32(vp_common + 0x20, @truncate(qd));
    mmio_write32(vp_common + 0x24, @truncate(qd >> 32));
    const qa = @intFromPtr(&virtio_avail);
    mmio_write32(vp_common + 0x28, @truncate(qa));
    mmio_write32(vp_common + 0x2c, @truncate(qa >> 32));
    const qu = @intFromPtr(&virtio_used);
    mmio_write32(vp_common + 0x30, @truncate(qu));
    mmio_write32(vp_common + 0x34, @truncate(qu >> 32));
    vp_write16(0x1c, 1); // queue_enable
    vp_queue_notify_off = vp_read16(0x1e);
    vp_write8(0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    if ((vp_read8(0x14) & 4) == 0) {
        dump_str("VP: DRIVER_OK failed\n");
        return false;
    }
    // Stage marker: transport armed. If the ladder stops here, a queue-setup
    // write (mmio_write64 at vp_common+0x20..0x30) is the death site.
    write_marker_var(st, marker_vptx);
    // Pre-exit readback of the queue setup: qsz/qen/qoff + the GPA halves
    // written above + device status. Verifies the 32-bit queue writes landed.
    dump_str("VP qsz=");
    dump_hex(vp_read16(0x18));
    dump_str(" qen=");
    dump_hex(vp_read16(0x1c));
    dump_str(" qoff=");
    dump_hex(vp_read16(0x1e));
    dump_str(" qd=");
    dump_hex(mmio_read32(vp_common + 0x20));
    dump_str(" qa=");
    dump_hex(mmio_read32(vp_common + 0x28));
    dump_str(" qu=");
    dump_hex(mmio_read32(vp_common + 0x30));
    dump_str(" st=");
    dump_hex(vp_read8(0x14));
    dump_str("\n");
    vp_ready = true;
    dump_str("VP ready qoff=");
    dump_hex(vp_queue_notify_off);
    dump_str("\n");
    write_marker_var(st, marker_vpok);
    return true;
}

/// Transmit the buffered TX bytes through queue 1: post the buffer in the
/// desc/avail rings, clean the D-cache (the device reads guest RAM
/// directly), kick via the notify region, and wait for the used ring.
/// Runs POST-EXIT on the pre-exit-captured VAs. A stuck device times out
/// and drops the line instead of hanging the kernel (TX remains honest: the
/// serial log is the gate, and M2_TXOK! records that the path returned).
fn virtio_pci_flush() void {
    if (!vp_ready or vp_tx_len == 0) return;
    virtio_desc[0] = .{ .addr = @intFromPtr(&virtio_tx), .len = @intCast(vp_tx_len), .flags = 0, .next = 0 };
    virtio_avail.ring[0] = 0; // descriptor index 0
    virtio_avail.idx +%= 1;
    clean_dcache_range(@intFromPtr(&virtio_desc), @sizeOf(VirtqDesc));
    clean_dcache_range(@intFromPtr(&virtio_avail), @sizeOf(VirtqAvail));
    clean_dcache_range(@intFromPtr(&virtio_tx), vp_tx_len);
    if (st_tx != null) write_marker_var(st_tx.?, marker_txst);
    // Post-exit probe of the transport before the notify: read device status
    // through the mapped window. Both this read and the notify write sit
    // between the M2_TXST!/M2_TXNT! markers, so a hang here or at the notify
    // both present as "TXST! without TXNT!" — the markers cannot fully
    // discriminate them; the honest invariant is "post-exit transport access
    // hangs".
    dump_str("VP pst=");
    dump_hex(vp_read8(0x14));
    dump_str("\n");
    if (st_tx != null) write_probe_tail(st_tx.?);
    // Notify via a 32-bit store (VZ common-cfg/notify emulation accepts
    // 32-bit accesses; a 16-bit store may be dropped — claim 0013).
    mmio_write32(vp_notify + @as(u64, vp_queue_notify_off) * vp_notify_mult, 1);
    if (st_tx != null) write_marker_var(st_tx.?, marker_txnt);
    var spins: usize = 0;
    while (spins < 2_000_000) : (spins += 1) {
        invalidate_dcache_range(@intFromPtr(&virtio_used), @sizeOf(VirtqUsed));
        if (virtio_used.idx != virtio_last_used) break;
    }
    virtio_last_used = virtio_used.idx;
    if (st_tx != null) write_marker_var(st_tx.?, marker_txpl);
    vp_tx_len = 0;
}

fn probe_serial(_: MemoryMapSlice, st: *const SystemTable) Candidate {
    // Selection happened PRE-EXIT in probe_serial_pre (post-exit reads of
    // the declared MMIO windows hang on VZ — claim 0013). This records the
    // stage marker and returns the pre-exit result so the banner/TX path
    // proceeds without any post-exit window read beyond TX itself.
    write_marker_var(st, marker_raw);
    return .{ .base = console_base, .kind = console_kind };
}

/// PRE-EXIT serial probe (claim 0013): scan the declared MMIO windows for a
/// PrimeCell UART. Run 5's raw dumps showed the 0x20050000 window carries
/// the standard PrimeCell CID block (0x0d/0xf0/0x05/0xb1 at +0xff0..0xffc)
/// with PL011-family PIDs (PID1=0x10, PID3=0x00, PID2 JEDEC nibble 0x4) but
/// PID0=0x31 instead of the textbook 0x11 — a VZ PL011-variant the old
/// probe's rigid `pid0 == 0x11` check rejected. Accept the CID+PID family
/// fingerprint instead. Pre-exit reads are deterministic (the pre-exit raw
/// dumps already read both windows safely); post-exit they hang.
fn probe_serial_pre(map: MemoryMapSlice, st: *const SystemTable) Candidate {
    probe_count = 0;
    // Claim 0013: the authoritative console is the virtio-pci device the
    // runner attaches (VZVirtioConsoleDeviceSerialPortConfiguration), found
    // via the MCFG ECAM base — not the EFI MMIO windows. It is preferred
    // whenever it initializes; the MMIO heuristics below remain as fallback
    // (the 0x20050000 PrimeCell UART is Apple's internal debug console, not
    // the serial attachment).
    if (virtio_pci_init(st)) {
        return .{ .base = vp_bar0, .kind = .virtio };
    }
    var it = map.iterator();
    while (it.next()) |desc| {
        if (desc.type != .memory_mapped_io and desc.type != .memory_mapped_io_port_space) continue;
        if (desc.number_of_pages == 0 or desc.number_of_pages > std.math.maxInt(u64) / 4096) continue;
        const bytes = desc.number_of_pages * 4096;
        if (desc.physical_start > std.math.maxInt(u64) - bytes) continue;
        const base = desc.physical_start;
        if (bytes < 0x1000) continue;

        const magic = mmio_read32(base);
        const version = mmio_read32(base + 4);
        const device = mmio_read32(base + 8);
        const vendor = mmio_read32(base + 12);
        if (magic == 0x74726976) { // "virt"
            record_probe(base, magic, version, device, vendor);
            dump_probe_line(0, base, magic, version, device, vendor);
            if ((version == 1 or version == 2) and device == 3 and vendor != 0) {
                dump_str("PRE: virtio-console candidate @");
                dump_hex(base);
                dump_str("\n");
                return .{ .base = base, .kind = .virtio };
            }
        }

        const cid0 = mmio_read32(base + 0xff0) & 0xff;
        const cid1 = mmio_read32(base + 0xff4) & 0xff;
        const cid2 = mmio_read32(base + 0xff8) & 0xff;
        const cid3 = mmio_read32(base + 0xffc) & 0xff;
        const pid0 = mmio_read32(base + 0xfe0) & 0xff;
        const pid1 = mmio_read32(base + 0xfe4) & 0xff;
        const pid2 = mmio_read32(base + 0xfe8) & 0xff;
        const pid3 = mmio_read32(base + 0xfec) & 0xff;
        const fr = mmio_read32(base + 0x18);
        if (cid0 != 0 or cid1 != 0 or cid2 != 0 or cid3 != 0 or pid0 != 0 or pid1 != 0 or pid2 != 0 or pid3 != 0 or fr != 0) {
            record_probe(base, pid0 | (pid1 << 8) | (pid2 << 16) | (pid3 << 24), fr, cid0 | (cid1 << 8) | (cid2 << 16) | (cid3 << 24), 0x504c3031); // PL01
            dump_pl011_line(0, base, pid0, pid1, pid2, fr);
        }
        if (cid0 == 0x0d and cid1 == 0xf0 and cid2 == 0x05 and cid3 == 0xb1 and pid1 == 0x10 and pid3 == 0x00 and (pid2 & 0x0f) == 0x04) {
            dump_str("PRE: PL011-family UART @");
            dump_hex(base);
            dump_str(" PID0=");
            dump_hex(pid0);
            dump_str("\n");
            return .{ .base = base, .kind = .pl011 };
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

/// PL011-family UART init (claim 0013): the VZ console at 0x20050000 is a
/// PrimeCell PL011-variant (CID 0x0d/0xf0/0x05/0xb1, PID1=0x10, PID2 JEDEC
/// 4, PID0=0x31) but boots DISABLED — writing DR without CR=UARTEN|TXE|RXE
/// produces no output (observed: M2_READY set, vm-serial.log empty). Program
/// the standard PL011 setup: disable, baud divisor, 8N1+FIFO, re-enable.
/// VZ likely ignores the baud divisor; the sequence is what matters.
var pl011_initialized: bool = false;
fn pl011_init() void {
    const base = console_base;
    mmio_write32(base + 0x30, 0); // CR = 0 (disable UART)
    mmio_write32(base + 0x24, 13); // IBRD: 115200 baud @ 24 MHz reference
    mmio_write32(base + 0x28, 1); // FBRD
    mmio_write32(base + 0x2c, 0x70); // LCR_H: 8 data, 1 stop, no parity, FIFO enable
    mmio_write32(base + 0x30, 0x301); // CR: UARTEN | TXE | RXE
}

fn uart_putc(byte: u8) void {
    switch (console_kind) {
        .pl011 => {
            if (!pl011_initialized) {
                pl011_init();
                pl011_initialized = true;
            }
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
            // Claim 0013: the VZ serial attachment is a modern virtio-pci
            // console (BAR0 transport, queue 1 TX). Bytes are line-buffered
            // and flushed as one descriptor — one kick per line instead of
            // one per byte.
            virtio_tx[vp_tx_len] = byte;
            vp_tx_len += 1;
            if (byte == '\n' or vp_tx_len >= virtio_tx.len) virtio_pci_flush();
        },
        .none => {},
    }
}

fn uart_puts(text: []const u8) void {
    for (text) |byte| uart_putc(byte);
    // Claim 0013: a virtio-console line without a trailing newline (e.g. the
    // shell's prompt) must still reach the host — flush any buffered bytes.
    if (console_kind == .virtio and vp_tx_len > 0) virtio_pci_flush();
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

/// Volatile marker write: a bare dead store to BSS could be elided under
/// ReleaseSmall (nothing in the guest reads `takeover_marker` back), which
/// would silently rob the host dump of its discriminator.
fn set_marker(value: u64) void {
    @as(*volatile u64, &takeover_marker).* = value;
}

/// Write the current marker stage as an EFI non-volatile variable. Best
/// effort: a failed runtime call never changes control flow (on VZ the
/// firmware may not keep runtime services resident — then this is a no-op and
/// the BSS marker remains the only record). The first write (pre-exit)
/// creates the variable; later writes update it in place.
fn write_marker_var(st: *const SystemTable, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    _ = st.runtime_services._setVariable(
        &marker_variable_name,
        &marker_vendor_guid,
        .{ .non_volatile = true, .bootservice_access = true, .runtime_access = true },
        bytes.len,
        &bytes,
    );
}

fn write_marker_fallback(base: u64, size: u64, map: MemoryMapSlice) void {
    // Fixed BSS evidence remains available to a host-side debugger if the
    // serial probe is blocked. It is not reported as serial success. The
    // discriminating marker word was already set to M2_SERIA by the caller;
    // the M2M! breadcrumb lives in the virtio scratch region only, so the
    // halt reason is never clobbered.
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

// ===========================================================================
// M1.5 console & shell core (agent B) — prompt-loop seam support.
// Additive section; the takeover path above is byte-identical.
// ===========================================================================

/// Console adapter over the polled TX uart. `readByte`/`rx_wired` are
/// [inferred] stubs: live RX reads are gated on the VZ serial gate
/// (claim 0002, unpassed) and are NOT implemented in this slice — no
/// device register is touched by the input path. The shell loop's
/// correctness is proven against a scripted MockConsole in
/// `kernel/src/shell.zig` instead.
const M15Console = struct {
    const Self = @This();

    pub const vtable = console.Console.VTable{
        .write = writeFn,
        .flush = flushFn,
        .readByte = readByteFn,
    };

    fn writeFn(_: *anyopaque, bytes: []const u8) void {
        uart_puts(bytes);
    }

    fn flushFn(_: *anyopaque) void {}

    fn readByteFn(_: *anyopaque) ?u8 {
        // [inferred] No RX path yet: reading the real device registers is
        // gated on claim 0002. The shell sees no input and parks.
        return null;
    }

    fn to_console(self: *Self) console.Console {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// [inferred] No RX source is wired until the VZ serial gate passes,
    /// so the shell prints banner + prompt and the kernel parks in WFE.
    fn rx_wired(self: *Self) bool {
        _ = self;
        return false;
    }
};
