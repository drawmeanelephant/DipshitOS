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

// M1.5 console & shell core (agent B): the interactive `dipshit>` monitor
// runs on the polled TX console through these modules. The takeover path
// below is untouched; this is the seam's import surface.
const console = @import("console.zig");
const machine = @import("machine.zig");
const memmap = @import("memmap.zig");
const monitor = @import("monitor.zig");
const shell = @import("shell.zig");

// Claim 0023: the handoff-v2 contract, the identity-map MMU, and the
// evidence channel (takeover markers + probe dumps) live in their own
// modules. This file keeps local aliases so the orchestration below reads
// like the original; the marker names and values are evidence.zig's.
const handoff = @import("handoff.zig");
const mmu = @import("mmu.zig");
const mmio = @import("mmio.zig");
const pci = @import("pci.zig");
const evidence = @import("evidence.zig");
const virtio_console = @import("virtio_console.zig");
const walkprobe = @import("walkprobe.zig"); // claim 7896 diagnostic (linker-eliminated from default builds)
const HandoffV2 = handoff.HandoffV2;

// Claim 0020 phase selectors live with the transport (the exact-one-phase
// comptime check is virtio_console.zig's); the orchestration reads them.
const tx_transition_a = virtio_console.tx_transition_a; // pre-ExitBootServices
const tx_transition_b = virtio_console.tx_transition_b; // post-EBS, firmware translation still active
const tx_transition_c = virtio_console.tx_transition_c; // post identity-map install, before unrelated work
const tx_transition_d = virtio_console.tx_transition_d; // normal final location (banner site)

// Only the markers the orchestration itself writes are aliased here; the
// virtio/transition markers are internal to virtio_console.zig.
const marker_entry = evidence.marker_entry;
const marker_cmap = evidence.marker_cmap;
const marker_prex = evidence.marker_prex;
const marker_exit = evidence.marker_exit;
const marker_table = evidence.marker_table;
const marker_mapd = evidence.marker_mapd;
const marker_mmu = evidence.marker_mmu;
const marker_seria = evidence.marker_seria;
const marker_ready = evidence.marker_ready;
const marker_raw = evidence.marker_raw;
const marker_txok = evidence.marker_txok;
const marker_seam = evidence.marker_seam;

// Claim 0015: NVRAM console channel (build-gated by `-Dnvram-console`).
// Post-exit access to the virtio-pci transport hangs on VZ (claim 0013), so
// in nvram-console builds console bytes ride the proven post-exit-safe
// runtime-SetVariable channel instead of the MMIO transport. The option
// comes from build.zig (kernel module options); a default build has it
// false and the virtio TX path is byte-identical.
const build_options = @import("build_options");
const nvram_console = @import("nvram_console.zig");

// Claim 0021: firmware MMU-state capture (default off; the default build is
// byte-identical). Records the firmware's live MMU registers and a bounded
// walk of its TTBR0 tables for the virtio BAR0 window + a RAM control
// address, plus the kernel's planned values, persisted pre-exit.
const fw_mmu_capture = build_options.fw_mmu_capture;

const bad_handoff: u64 = 2;
const map_failure: u64 = 3;
const exit_failure: u64 = 4;
const table_failure: u64 = 5;
const serial_failure: u64 = 6;

const ProbeRecord = extern struct {
    base: u64,
    magic: u32,
    version: u32,
    device: u32,
    layout: u32,
};
var probe_records: [96]ProbeRecord = undefined;
var probe_count: usize = 0;

const Candidate = struct {
    base: u64,
    kind: Kind,
};
const Kind = evidence.Kind;
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

fn kernel_main(base: u64, size: u64, st: *const SystemTable, handoff_rec: *HandoffV2) callconv(.c) u64 {
    if (!valid_handoff(base, size, st, handoff_rec)) {
        print_pre_exit_error(st, "DipshitOS: invalid handoff\r\n");
        return bad_handoff;
    }

    // M1.5 machine controls: capture the EFI Runtime Services table
    // pre-exit. Runtime services (unlike boot services) survive
    // ExitBootServices, so `ResetSystem` remains callable after the
    // takeover — the same table whose SetVariable drives the marker
    // ladder below (observed working post-exit on VZ, claims 0009/0010).
    machine.init(st.runtime_services);

    // Claim 0015: capture the same table for the NVRAM console channel.
    // Active only in `-Dnvram-console` builds; otherwise the module's
    // writes are never called.
    nvram_console.init(st.runtime_services);

    print_pre_exit_error(st, "DipshitOS: kernel entered\r\n");
    evidence.set_marker(marker_entry);
    evidence.write_marker_var(st, marker_entry);
    // Second pre-exit write immediately after the first: if the persisted
    // variable still reads M2_ENTRY, a *repeated* SetVariable failed (the
    // marker ladder would be stuck); if it reads M2_CMAP!, the kernel died
    // inside capture_map below.
    evidence.write_marker_var(st, marker_cmap);

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
    evidence.dump_mmio_descriptors(map_buffer.map);
    evidence.dump_config_table(st);
    pci.dump_acpi(st);
    // Claim 0015: in nvram-console builds the console stream itself carries
    // the map/probe evidence through the NVRAM channel, so persisting the
    // separate ~40 KB DipshitProbe variable is redundant AND starves the
    // chunk channel (the store is only ~61 KB writable on VZ, observed:
    // both gate runs died at 0xf061 with the session cut off mid-help).
    if (comptime !build_options.nvram_console) evidence.write_probe_var(st);

    // Claim 0013: the serial probe runs PRE-EXIT — post-exit reads of the
    // declared MMIO windows hang on VZ (observed every run). The selection
    // is remembered in the console_* globals and used post-exit for TX only.
    const pre = probe_serial_pre(map_buffer.map, st);
    console_kind = pre.kind;
    console_base = pre.base;
    evidence.dump_sel(pre.kind, pre.base);
    if (comptime !build_options.nvram_console) evidence.write_probe_var(st);

    // Claim 0017 diagnostic (build-gated `-Dpreexit-tx`): transmit a fixed
    // line through the SAME virtio-pci transport the post-exit path uses
    // while Boot Services and the firmware address space are still active.
    // Runs after the probe evidence is persisted (a hang must not lose it)
    // and immediately before the pre-exit marker / ExitBootServices. The
    // marker ladder brackets the flush (M2_PEXT! ... M2_TXST!/M2_TXNT!/
    // M2_TXPL! ... M2_PEXD!); vm-serial.log is the "bytes reached the host"
    // gate (tools/verify-preexit-tx.sh). Diagnostic only — the post-exit
    // banner TX is untouched.
    if (comptime build_options.preexit_tx) virtio_console.preexit_tx_experiment(st);
    // Claim 0020 phase A: the same fixed line through the same transport,
    // still pre-ExitBootServices. Runs immediately before the pre-exit
    // marker so a hang cannot lose the persisted probe evidence.
    if (comptime tx_transition_a) virtio_console.transition_tx_experiment(st, .a);
    // Claim 0021 diagnostic (build-gated `-Dfw-mmu-capture`): while the
    // firmware translation is still live, record the firmware's MMU
    // registers + a bounded walk of its TTBR0 tables for the virtio BAR0
    // window (the claim-0020 post-switch hang target) and a RAM control
    // address, plus the kernel's planned values. Persisted as its own small
    // ASCII variable, immediately before the pre-exit marker/exit so a hang
    // cannot lose it.
    if (comptime fw_mmu_capture) evidence.fw_mmu_capture_diag(st, handoff_rec, virtio_console.vp_ready, virtio_console.vp_bar0);

    // Pre-exit stage: proves the kernel passed valid_handoff + capture_map
    // and reached the exit call. The persisted NVRAM marker being M2_ENTRY
    // instead means the kernel died in that window.
    evidence.write_marker_var(st, marker_prex);

    var exited = false;
    var attempt: usize = 0;
    while (attempt < 8) : (attempt += 1) {
        // The map buffer is already allocated. Re-reading it is the only
        // permitted operation between an INVALID_PARAMETER retry.
        if (bs.exitBootServices(@ptrFromInt(handoff_rec.image_handle), map_buffer.map.info.key)) |_| {
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
    evidence.set_marker(marker_exit);
    evidence.write_marker_var(st, marker_exit); // first post-exit runtime-services call
    // Claim 0020 phase B: the FIRST post-exit TX attempt, immediately after
    // a successful ExitBootServices while the firmware's translation regime
    // is still active (DipshitOS page tables are not yet built). This is
    // the controlled test of whether ExitBootServices itself destroys
    // access to the transport window.
    if (comptime tx_transition_b) virtio_console.transition_tx_experiment(st, .b);

    // After successful exit, no longer allowed: AllocatePool/AllocatePages,
    // GetMemoryMap, SimpleTextOutput, Simple File System,
    // LoadImage/StartImage, SetTimer, any event services, any other Boot
    // Services call. The map buffer is now owned by this kernel and all
    // subsequent work is direct memory/register access only.
    const map_after_exit = map_buffer.map;
    // Claim 0023: the virtio BAR window (discovered pre-exit) is handed to
    // mmu.build_identity_map as the optional extra Device window above the
    // blanket; mmu.zig stays transport-agnostic.
    const extra_window: ?mmu.DeviceWindow = if (virtio_console.vp_ready and virtio_console.vp_bar0 != 0)
        .{ .base = virtio_console.vp_bar0, .len = 0x10000 }
    else
        null;
    if (!mmu.build_identity_map(map_after_exit, map_buffer.buffer, base, size, handoff_rec, extra_window)) {
        evidence.set_marker(marker_table);
        evidence.write_marker_var(st, marker_table);
        halt_forever();
    }
    // Pre-install write (still on the firmware identity map, reliable): if the
    // persisted ladder stops here, the kernel died between this write and the
    // post-install M2_MMUP! write — i.e. inside install_identity_map() or at
    // the first post-switch call (claim 0009: observed — every VZ run stops
    // at M2_MAPD!, so the MMU takeover window is the death site; the kernel
    // never reaches the serial probe).
    evidence.write_marker_var(st, marker_mapd);
    mmu.install_identity_map();
    evidence.set_marker(marker_mmu);
    evidence.write_marker_var(st, marker_mmu);
    // Claim 1517: the TLBI is now executed inside install_identity_map()
    // (corrected start level T0SZ=16 + full invalidation at the switch —
    // the ADR-0006 no-TLBI debt is paid). With -Dwalk-probe (class D,
    // default off), run the cold-address probe battery so the ladder names
    // the first address that does not resolve.
    if (comptime build_options.walk_probe) walkprobe.run(st);
    // Claim 0020 phase C: the FIRST MMIO access to the transport after the
    // identity-map switch, before the post-switch probe (M2_RAW!) or any
    // other runtime-service/diagnostic work. Tests whether installing the
    // DipshitOS page tables destroys access (the claim-0013/0018
    // hypothesis), with the marker write above being the only prior
    // post-switch call.
    if (comptime tx_transition_c) virtio_console.transition_tx_experiment(st, .c);

    const selected = probe_serial(map_after_exit, st);
    console_kind = selected.kind;
    console_base = selected.base;
    if (selected.kind == .none) {
        evidence.set_marker(marker_seria);
        evidence.write_marker_var(st, marker_seria);
        evidence.write_marker_fallback(&virtio_console.virtio_tx, base, size, map_after_exit);
        halt_forever();
    }
    evidence.set_marker(marker_ready);
    evidence.write_marker_var(st, marker_ready);

    virtio_console.st_tx = st; // for flush stage markers
    // Claim 0020 phase D: TX at the normal final location — the same site
    // where the production banner transmits. Same payload as phases A/B/C.
    if (comptime tx_transition_d) virtio_console.transition_tx_experiment(st, .d);
    uart_puts("DipshitOS kernel has seized control.\n");
    // Claim 0013: after the first TX, record whether the TX path returned
    // (bytes may still be dropped by the device; the serial log is the gate,
    // but M2_TXOK! separates "TX hung" from "TX returned silently").
    evidence.write_marker_var(st, marker_txok);
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
            // Claim 0023: the shared handoff.zig type is used directly.
            .handoff = handoff_rec.*,
            .map = map_view,
            .console_name = console_name[0 .. console_name.len - 1],
        },
        machine.control(),
    );
    // Claim 0015 diagnostic: mark the seam entry so a missing shell banner
    // is attributable to the seam setup vs. the shell write path.
    if (comptime build_options.nvram_console) {
        evidence.write_marker_var(st, marker_seam);
        // Stack + console-pointer probe: the banner write path crashed
        // without entering M15Console.writeFn, so record the state at the
        // seam (sp, vtable/ctx addresses, and a direct vtable dispatch).
        var sp: u64 = undefined;
        asm volatile ("mov %[sp], sp"
            : [sp] "=r" (sp),
        );
        uart_puts("[seam] sp=");
        uart_hex(sp);
        uart_puts(" base=");
        uart_hex(handoff_rec.stack_base);
        uart_puts(" ctx=");
        uart_hex(@intFromPtr(mon.console.ctx));
        uart_puts(" vt=");
        uart_hex(@intFromPtr(mon.console.vtable));
        uart_puts("\n");
        const probe_con = m15.to_console();
        probe_con.print_line("[seam] direct dispatch");
    }
    shell.boot_and_park(&mon, m15.rx_wired());
    // No return after takeover. WFE is a terminal state, not a firmware call.
    // Note: with RX wired (nvram builds) boot_and_park loops forever, so
    // this flush is unreachable there — the trailing prompt is flushed by
    // readByteFn when the scripted session ends. Kept as a safety net for
    // the no-RX path, where boot_and_park returns after the prompt.
    if (comptime build_options.nvram_console) nvram_console.flush();
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

fn valid_handoff(base: u64, size: u64, st: *const SystemTable, handoff_rec: *const HandoffV2) bool {
    // Entry-time mirror checks (the struct against the x0/x2 register
    // arguments) + the struct-internal validation from handoff.zig
    // (magic/version/flags/stack-size/alignment/bounds). Same semantics as
    // the previous inline checks; the canonical rules live in handoff.zig.
    if (@intFromPtr(st) != handoff_rec.system_table) return false;
    if (handoff_rec.kernel_base != base or handoff_rec.kernel_size != size) return false;
    return handoff.validate(handoff_rec) == .none;
}

fn record_probe(base: u64, magic: u32, version: u32, device: u32, layout: u32) void {
    if (probe_count < probe_records.len) {
        probe_records[probe_count] = .{ .base = base, .magic = magic, .version = version, .device = device, .layout = layout };
        probe_count += 1;
    }
}

fn probe_serial(_: MemoryMapSlice, st: *const SystemTable) Candidate {
    // Selection happened PRE-EXIT in probe_serial_pre (post-exit reads of
    // the declared MMIO windows hang on VZ — claim 0013). This records the
    // stage marker and returns the pre-exit result so the banner/TX path
    // proceeds without any post-exit window read beyond TX itself.
    evidence.write_marker_var(st, marker_raw);
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
    if (virtio_console.virtio_pci_init(st)) {
        return .{ .base = virtio_console.vp_bar0, .kind = .virtio };
    }
    var it = map.iterator();
    while (it.next()) |desc| {
        if (desc.type != .memory_mapped_io and desc.type != .memory_mapped_io_port_space) continue;
        if (desc.number_of_pages == 0 or desc.number_of_pages > std.math.maxInt(u64) / 4096) continue;
        const bytes = desc.number_of_pages * 4096;
        if (desc.physical_start > std.math.maxInt(u64) - bytes) continue;
        const base = desc.physical_start;
        if (bytes < 0x1000) continue;

        const magic = mmio.mmio_read32(base);
        const version = mmio.mmio_read32(base + 4);
        const device = mmio.mmio_read32(base + 8);
        const vendor = mmio.mmio_read32(base + 12);
        if (magic == 0x74726976) { // "virt"
            record_probe(base, magic, version, device, vendor);
            evidence.dump_probe_line(0, base, magic, version, device, vendor);
            if ((version == 1 or version == 2) and device == 3 and vendor != 0) {
                evidence.dump_str("PRE: virtio-console candidate @");
                evidence.dump_hex(base);
                evidence.dump_str("\n");
                return .{ .base = base, .kind = .virtio };
            }
        }

        const cid0 = mmio.mmio_read32(base + 0xff0) & 0xff;
        const cid1 = mmio.mmio_read32(base + 0xff4) & 0xff;
        const cid2 = mmio.mmio_read32(base + 0xff8) & 0xff;
        const cid3 = mmio.mmio_read32(base + 0xffc) & 0xff;
        const pid0 = mmio.mmio_read32(base + 0xfe0) & 0xff;
        const pid1 = mmio.mmio_read32(base + 0xfe4) & 0xff;
        const pid2 = mmio.mmio_read32(base + 0xfe8) & 0xff;
        const pid3 = mmio.mmio_read32(base + 0xfec) & 0xff;
        const fr = mmio.mmio_read32(base + 0x18);
        if (cid0 != 0 or cid1 != 0 or cid2 != 0 or cid3 != 0 or pid0 != 0 or pid1 != 0 or pid2 != 0 or pid3 != 0 or fr != 0) {
            record_probe(base, pid0 | (pid1 << 8) | (pid2 << 16) | (pid3 << 24), fr, cid0 | (cid1 << 8) | (cid2 << 16) | (cid3 << 24), 0x504c3031); // PL01
            evidence.dump_pl011_line(0, base, pid0, pid1, pid2, fr);
        }
        if (cid0 == 0x0d and cid1 == 0xf0 and cid2 == 0x05 and cid3 == 0xb1 and pid1 == 0x10 and pid3 == 0x00 and (pid2 & 0x0f) == 0x04) {
            evidence.dump_str("PRE: PL011-family UART @");
            evidence.dump_hex(base);
            evidence.dump_str(" PID0=");
            evidence.dump_hex(pid0);
            evidence.dump_str("\n");
            return .{ .base = base, .kind = .pl011 };
        }
    }
    return .{ .base = 0, .kind = .none };
}

var pl011_initialized: bool = false;
fn pl011_init() void {
    const base = console_base;
    mmio.mmio_write32(base + 0x30, 0); // CR = 0 (disable UART)
    mmio.mmio_write32(base + 0x24, 13); // IBRD: 115200 baud @ 24 MHz reference
    mmio.mmio_write32(base + 0x28, 1); // FBRD
    mmio.mmio_write32(base + 0x2c, 0x70); // LCR_H: 8 data, 1 stop, no parity, FIFO enable
    mmio.mmio_write32(base + 0x30, 0x301); // CR: UARTEN | TXE | RXE
}

fn uart_putc(byte: u8) void {
    // Claim 0015: in nvram-console builds every console byte rides the
    // NVRAM channel instead of the MMIO transport (which hangs post-exit
    // on VZ). Comptime-gated, so a default build is byte-identical.
    if (comptime build_options.nvram_console) {
        nvram_console.putc(byte);
        return;
    }
    switch (console_kind) {
        .pl011 => {
            if (!pl011_initialized) {
                pl011_init();
                pl011_initialized = true;
            }
            var timeout: usize = 0;
            while ((mmio.mmio_read32(console_base + 0x18) & (1 << 5)) != 0 and timeout < 1_000_000) : (timeout += 1) {}
            if (timeout < 1_000_000) mmio.mmio_write32(console_base, byte);
        },
        .ns16550 => {
            var timeout: usize = 0;
            while ((mmio.mmio_read8(console_base + 5) & (1 << 5)) == 0 and timeout < 1_000_000) : (timeout += 1) {}
            if (timeout < 1_000_000) mmio.mmio_write8(console_base, byte);
        },
        .virtio => {
            // Claim 0013: the VZ serial attachment is a modern virtio-pci
            // console (BAR0 transport, queue 1 TX). Bytes are line-buffered
            // and flushed as one descriptor — one kick per line instead of
            // one per byte.
            virtio_console.virtio_tx[virtio_console.vp_tx_len] = byte;
            virtio_console.vp_tx_len += 1;
            if (byte == '\n' or virtio_console.vp_tx_len >= virtio_console.virtio_tx.len) virtio_console.virtio_pci_flush();
        },
        .none => {},
    }
}

fn uart_puts(text: []const u8) void {
    for (text) |byte| uart_putc(byte);
    // Claim 0013: a virtio-console line without a trailing newline (e.g. the
    // shell's prompt) must still reach the host — flush any buffered bytes.
    // In nvram-console builds the virtio transport is never touched; the
    // NVRAM sink does its own newline/buffer-flush batching.
    if (comptime !build_options.nvram_console) {
        if (console_kind == .virtio and virtio_console.vp_tx_len > 0) virtio_console.virtio_pci_flush();
    }
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

/// Console adapter over the polled TX uart. `readByte`/`rx_wired` dispatch
/// to the live virtio receive queue when the console is the virtio device
/// (claim 6684; the shell loop's correctness is also proven against a
/// scripted MockConsole in `kernel/src/shell.zig`). For the PL011/16550
/// fallback consoles RX stays an unimplemented null stub — no device
/// register is read on that path.
const M15Console = struct {
    const Self = @This();

    // Claim 0015 root cause: the vtable is built at runtime into BSS, NOT
    // as a const in .rodata. The kernel ELF is linked at address 0 with no
    // relocation sections and the flat loader copies the image to a
    // runtime-chosen base (observed 0x7e4d1000), so a const vtable would
    // hold link-time absolute function addresses (observed: write=0x44c4,
    // should be base+0x44c4) and the first dispatch would jump into the
    // weeds — the claim-0015 seam crash (chunk 30 persisted, the first
    // vtable write never did; writeFn was never entered). Building the
    // table in RAM makes every `&fn` resolve PC-relatively (ADRP), which is
    // correct at any load base. Host tests never caught this because macOS
    // relocates test binaries; the flat kernel loader does not.
    var vtable_storage: console.Console.VTable = undefined;
    var vtable_ready = false;

    fn ensure_vtable() *const console.Console.VTable {
        if (!vtable_ready) {
            vtable_storage = .{
                .write = writeFn,
                .flush = flushFn,
                .readByte = readByteFn,
            };
            vtable_ready = true;
        }
        return &vtable_storage;
    }

    // Claim 0015: in nvram-console builds the shell loop runs a scripted
    // session. The input is a STATIC kernel-side byte buffer (the same
    // technique the mock transcript uses), NOT host keystrokes — host RX
    // stays unclaimed. It proves the real command loop executes post-exit
    // on VZ and its output is observable through the NVRAM channel. The
    // script is compile-time elided in default builds.
    script_pos: usize = 0,

    fn writeFn(_: *anyopaque, bytes: []const u8) void {
        uart_puts(bytes);
    }

    fn flushFn(_: *anyopaque) void {
        if (comptime build_options.nvram_console) nvram_console.flush();
    }

    fn readByteFn(ctx: *anyopaque) ?u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (comptime build_options.nvram_console) {
            if (self.script_pos < nvram_script.len) {
                const byte = nvram_script[self.script_pos];
                self.script_pos += 1;
                return byte;
            }
            // Script exhausted: persist any buffered output (the trailing
            // prompt has no newline) on the first idle poll, then stay idle.
            nvram_console.flush();
            return null;
        }
        // Claim 6684: live RX through the polled virtio receive queue
        // (queue 0). Runs whenever the console is the virtio device — post-MMU
        // the transport is reachable (claim 1517). Never blocks.
        if (console_kind == .virtio) return virtio_console.virtio_read_byte();
        return null;
    }

    fn to_console(self: *Self) console.Console {
        return .{ .ctx = self, .vtable = ensure_vtable() };
    }

    /// True when an input source is wired so the shell loop runs instead
    /// of parking. Nvram-console builds run the scripted session; default
    /// builds run the live loop when the virtio receive queue is armed
    /// (claim 6684). Otherwise the shell prints banner + prompt and the
    /// kernel parks.
    fn rx_wired(self: *Self) bool {
        _ = self;
        if (comptime build_options.nvram_console) return true;
        return console_kind == .virtio and virtio_console.rx_armed();
    }
};

/// Claim 0015: the scripted session served by `M15Console.readByte` in
/// nvram-console builds — the same shape of input the mock transcript test
/// feeds (help/version/mem/echo), proving real command execution post-exit.
const nvram_script = if (build_options.nvram_console)
    "version\nmem\necho nvram-console-ok\nhelp\n"
else
    "";
