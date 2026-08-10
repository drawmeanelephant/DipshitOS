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
const alloc = @import("alloc.zig");
const memmap = @import("memmap.zig");
const monitor = @import("monitor.zig");
const shell = @import("shell.zig");
// Claim 3475: ESP file window. Claim 6420: now FAT-backed (live ESP via
// the virtio-blk transport), replacing the NVRAM persistence medium.
const esp = @import("esp.zig");
const virtio_blk = @import("virtio_blk.zig");
// Milestone four (claim 2665): virtio entropy driver + ChaCha20 CSPRNG.
// The entropy device (DID 0x1044) seeds the CSPRNG post-MMU; `random` and
// the exec-path ASLR consumer live off that seed.
const virtio_entropy = @import("virtio_entropy.zig");
const csprng = @import("csprng.zig");

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
const exceptions = @import("exceptions.zig"); // claim 9746: VBAR_EL1 vector table + basic sync/IRQ handlers
const gic = @import("gic.zig"); // claim 7948: GIC distributor + CPU interface
const timer = @import("timer.zig"); // claim 7948: ARM generic timer (CNTP)
const scheduler = @import("scheduler.zig"); // claim 5275: tick-driven round-robin tasks
const userspace = @import("userspace.zig"); // claim 8215: first EL0t task + SVC boundary
const syscall = @import("syscall.zig"); // claim 3594: fixed syscall ABI + runtime dispatch table
const exec = @import("exec.zig"); // milestone-three card 6: ESP exec — owns the shared rebuild_user_root (claims 2665/3693)
const virtio_custom = @import("virtio_custom.zig"); // claim 0828: custom-virtio spike driver (DID 0x1082)
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
    // Claim 3475: the probe dump is persisted ONCE, after the serial
    // selection is known, and only in `-Dprobe-var` diagnostic builds. The
    // serial log carries the probe records (base/layout/records below), and
    // VZ's append-per-write variable store fills up fast: the ~32 KiB
    // persist per boot (16 chunks × 2 KiB) left ~64 B free by the time the
    // shell ran, so the ESP file window's `write` always failed with
    // EFI_OUT_OF_RESOURCES (observed, claim 3475). Claim 0015 already
    // gated the persist off in nvram-console builds for the same
    // starvation; `-Dprobe-var` restores it for diagnostics.
    const pre = probe_serial_pre(map_buffer.map, st);
    console_kind = pre.kind;
    console_base = pre.base;
    evidence.dump_sel(pre.kind, pre.base);
    if (comptime build_options.probe_var) evidence.write_probe_var(st);

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

    // Claim 6420: the virtio-pci block transport (the runner's disk is a
    // VZVirtioBlockDeviceConfiguration — modern virtio-blk, DID 0x1041).
    // Armed PRE-EXIT like the console (config-space + BAR reads hang
    // post-exit on VZ, claim 0013); its BAR0 window is handed to the
    // identity map below so post-MMU sector I/O reaches the device
    // (claim 1517's transport reliability applies).
    const blk_ready = virtio_blk.virtio_blk_init();

    // Milestone four (claim 2665): the virtio-pci entropy transport
    // (DID 0x1044 — the runner's VZVirtioEntropyDeviceConfiguration, seen
    // on the bus since the claim-5844-era `pci` listing). Armed PRE-EXIT
    // like the console/blk devices (config-space + BAR reads must stay
    // pre-exit, claim 0013); its BAR0 window is handed to the identity map
    // below, and the transport is RE-ARMED post-MMU (the claim-6420 lesson:
    // VZ resets virtio devices at ExitBootServices) right before the seed.
    const entropy_ready = virtio_entropy.virtio_entropy_init();

    // Claim 0828: the custom-virtio spike device (DID 0x1082) — PRE-EXIT
    // discovery only (config-space reads, the claim-0013 discipline). VZ's
    // firmware BAR assignment moves between boots (0x50001000 in the claim-
    // 5844 run; ABOVE the 4 GiB blanket on a later boot), so the transport
    // BAR is handed to the identity map below like the console/blk windows.
    const cv_probed = virtio_custom.probe();

    // Claim 6420: the ESP file window. The FAT32 volume on the ESP is
    // mounted through the virtio-blk transport and the root directory
    // snapshotted into the window (names/sizes/content for small files) —
    // replacing claim 3475's pre-exit Simple File System snapshot AND its
    // NVRAM persistence medium: `write` now writes the live FAT volume, so
    // files survive reboot on the disk itself. Best effort; a failed mount
    // leaves the window empty and the monitor reports it honestly.
    if (blk_ready) _ = esp.set_disk(virtio_blk.disk_ops());

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
    // Claim 0023 (+ 6420): the virtio console + block BAR windows
    // (discovered pre-exit) are handed to mmu.build_identity_map as the
    // extra Device windows above the blanket; mmu.zig stays
    // transport-agnostic.
    var extra_windows: [4]mmu.DeviceWindow = undefined;
    var extra_count: usize = 0;
    if (virtio_console.vp_ready and virtio_console.vp_bar0 != 0) {
        extra_windows[extra_count] = .{ .base = virtio_console.vp_bar0, .len = 0x10000 };
        extra_count += 1;
    }
    if (virtio_blk.blk_ready and virtio_blk.blk_bar0 != 0) {
        extra_windows[extra_count] = .{ .base = virtio_blk.blk_bar0, .len = 0x10000 };
        extra_count += 1;
    }
    // Claim 0828: the custom-virtio transport BAR (pre-exit resolved).
    // mmu.zig maps windows above the blanket; below it the 4 GiB blanket
    // already covers the BAR, so the entry is a harmless no-op there.
    if (cv_probed and virtio_custom.cv_bar != 0) {
        extra_windows[extra_count] = virtio_custom.device_window();
        extra_count += 1;
    }
    // Milestone four (claim 2665): the entropy transport BAR (pre-exit
    // resolved) — same Device-window treatment as the console/blk/custom
    // transports so post-MMU common-config reads reach the device.
    if (entropy_ready and virtio_entropy.ent_bar0 != 0) {
        extra_windows[extra_count] = .{ .base = virtio_entropy.ent_bar0, .len = 0x10000 };
        extra_count += 1;
    }
    const user_text = userspace.text_region(base);
    const user_stack = userspace.stack_region(base);
    const user_regions = [_]mmu.UserRegion{
        .{ .base = user_text.base, .len = user_text.len, .writable = false, .executable = true },
        .{ .base = user_stack.base, .len = user_stack.len, .writable = true, .executable = false },
    };
    if (!mmu.build_identity_map(map_after_exit, map_buffer.buffer, base, size, handoff_rec, extra_windows[0..extra_count], &user_regions)) {
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
    exceptions.init(exception_report_writer);
    exceptions.install();
    mmu.install_identity_map();
    // Claim 9746 (roadmap item 5, first half): install the VBAR_EL1
    // exception vectors + basic synchronous/IRQ handlers NOW — after
    // ExitBootServices and the identity-map switch, when the kernel owns
    // EL1 and no pre-exit firmware Boot Services are still active. Writing
    // VBAR_EL1 earlier (pre-ExitBootServices) is catastrophic on VZ
    // (observed: the pre-exit firmware calls hang ~7/8 boots — firmware
    // exceptions would land in the kernel's vectors, claim 9746). From
    // here on any fault produces an `[EXC]` report instead of a silent
    // hang. The report writer degrades to a no-op until the serial console
    // is probed below (console_kind == .none); the GIC is NOT programmed
    // here — that is the next card.
    userspace.init();
    syscall.init(exception_report_writer);
    // Claim 5804: the EL0 task runs in its own address space, so the
    // uaccess regions are USER VAs (what the user root maps and what the
    // task's syscall pointers refer to) — not the physical image ranges
    // `build_identity_map` consumed above.
    syscall.set_user_regions(userspace.text_va_region(), userspace.stack_va_region());
    exceptions.set_svc_dispatcher(syscall.handle_svc);
    // Claim 7948 (roadmap item 5, second half): GIC + generic timer. The
    // MADT/GTDT discovery ran PRE-EXIT inside pci.dump_acpi (post-exit ACPI
    // reads hang on VZ, claim 0013); program the controller + timer NOW —
    // post-MMU, when the kernel owns EL1 and device MMIO is reachable
    // (claim 1517), with the claim-9746 vectors already installed so any
    // misstep reports instead of hanging. Only then register the IRQ chain
    // and unmask IRQs, so no interrupt can arrive before the whole path
    // (GIC -> vector -> dispatcher -> timer) is armed.
    gic.init(timer.ppi, timer.interrupt_edge);
    timer.init();
    exceptions.set_irq_dispatcher(irq_dispatch);
    exceptions.irq_unmask();
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

    // Claim 9187: the interrupt-controller/timer state lands in the serial
    // log at every boot — the live gate's first assertion (before the
    // scripted `timer` command runs).
    uart_puts("interrupts: gic=");
    uart_puts(gic.kind_name());
    uart_puts(" armed=");
    uart_puts(if (gic.armed() and timer.armed()) "1" else "0");
    uart_puts(" dist=");
    uart_hex(gic.dist_base);
    uart_puts(" redist=");
    uart_hex(gic.redist_base);
    uart_puts(" active=");
    uart_hex(gic.active_redist_base);
    uart_puts(" fallback=");
    uart_puts(if (gic.used_fallback) "1" else "0");
    uart_puts(" ppi=");
    uart_hex(timer.ppi);
    uart_puts(" edge=");
    uart_puts(if (timer.interrupt_edge) "1" else "0");
    uart_puts(" freq=");
    uart_hex(timer.freq);
    uart_puts("\n");

    // Claim 6420: the ESP file window summary (the FAT volume mount result
    // + the root listing count). A second boot's line showing the file
    // `write` stored in boot one is the persistence-through-reboot
    // evidence in the serial log — the file now lives on the disk, not in
    // NVRAM variables (claim 3475's medium is replaced).
    uart_puts("esp window: esp=");
    uart_hex(@intCast(esp.esp_count()));
    uart_puts(" disk=");
    uart_puts(if (esp.disk_ready()) "1" else "0");
    uart_puts("\n");

    // Claim 6420: VZ resets the virtio-blk device at ExitBootServices (its
    // status reads 0 post-exit and the queue is dead). Re-arm the queue
    // now that the identity map is live, so the shell's `write` (live FAT
    // reads/writes through the transport) works. The pre-exit queue was
    // used only for the boot-time ESP mount.
    if (virtio_blk.blk_common != 0) _ = virtio_blk.blk_rearm();

    uart_puts("kernel terminal state\n");

    // macOS 27 custom-virtio spike (claim 0828): the smallest guest driver
    // for the spike device (`zig build spike-virtio`, DID 0x1082, claim
    // 5844). Probing, negotiation, DRIVER_OK, the queue-0 kick, and the
    // used-ring IRQ experiment all run POST-exit — post-MMU ECAM reads
    // work (claims 1517/6684) and the device's BAR2 window (0x50001000)
    // sits below the 4 GiB blanket. Silent no-op when the device is absent
    // (default builds are unchanged). Evidence: host runner stdout
    // (DRIVER_OK / notification / dequeued payload / returnToQueue) + this
    // serial report. The SPI window is disarmed after the report so the
    // shell runs without interrupt noise; the claim-9187 timer PPI stays
    // armed and the polled console paths are untouched.
    custom_virtio_spike();

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
    // Physical page allocator (claims 3972 + 5162): arm the pool from the
    // captured map's conventional + loader + boot-services regions,
    // excluding the live kernel image, stack, handoff page, and captured
    // map buffer. Fixed BSS bitmap, no allocation; the `pages` monitor
    // command reports the pool. Not armed (silently) when the map declares
    // no poolable memory in span.
    const exclusions = [_]alloc.Exclusion{
        alloc.exclusion_from_bytes(handoff_rec.kernel_base, handoff_rec.kernel_size),
        alloc.exclusion_from_bytes(handoff_rec.stack_base, handoff_rec.stack_size),
        alloc.exclusion_from_bytes(@intFromPtr(handoff_rec), memmap.page_size),
        alloc.exclusion_from_bytes(@intFromPtr(map_buffer.buffer.ptr), map_buffer.buffer.len),
    };
    _ = alloc.init(map_view, &exclusions);
    // Milestone four (claim 2665): boot-time seed — post-MMU (after the
    // allocator arms), pull a fixed 64-byte seed from the REAL virtio
    // entropy device and key the CSPRNG. VZ resets virtio devices at
    // ExitBootServices (claim 6420), so the transport is re-armed here
    // first (the claim-6420 lesson applied to the entropy device; the live
    // gate's `entropy: seeded n=64` line is the proof the re-armed path
    // works). A failed read falls back to a deterministic key and reports
    // honestly — the live gate requires the real path.
    var seed_buf: [csprng.seed_len]u8 align(16) = undefined;
    // Claim 6420's lesson, verified live: VZ resets virtio devices at
    // ExitBootServices — the pre-re-arm status is printed so the host sees
    // the reset (0) before the re-arm restores DRIVER_OK and the seed read
    // delivers 64 real bytes.
    uart_puts("entropy: pre-rearm st=");
    uart_hex8(virtio_entropy.ent_status());
    uart_puts("\n");
    if (virtio_entropy.entropy_rearm() and virtio_entropy.entropy_read(&seed_buf)) {
        csprng.seed(&seed_buf);
        uart_puts("entropy: seeded n=64\n");
    } else {
        csprng.seed_fallback();
        uart_puts("entropy: seed failed n=0 (deterministic fallback)\n");
    }
    // Claim 3693 (milestone-four follow-on): ASLR for the BOOT-time static
    // EL0 payload too. The pre-install user root (built inside
    // build_identity_map) maps the stack at the fixed userspace.stack_va;
    // now that the CSPRNG is seeded with REAL entropy, rebuild the root
    // with a randomized stack placement so the static payload — not just
    // exec'd programs (claim 2665) — runs with per-boot stack ASLR.
    // exec.rebuild_user_root is the single shared sequence (randomize →
    // map → clean → re-arm; see claims 6783/2665 for why it works
    // post-install). stack_len is the FULL .userbss section length (the
    // timer-preemption witness sits just past the 8 KiB stack, and its VA
    // is base-relative, so the rebuilt root must map it too). An unseeded
    // (fallback) boot skips the rebuild and keeps the fixed stack —
    // behavior unchanged there.
    if (csprng.seeded()) {
        if (exec.rebuild_user_root(user_text.base, user_text.len, user_stack.len)) |aslr_stack_va| {
            uart_puts("aslr: boot user stack=");
            uart_hex(aslr_stack_va);
            uart_puts("\n");
        } else {
            // Honest fallback: keep the fixed stack (the initial root still
            // maps it) and report the failed rebuild.
            userspace.set_stack_va(userspace.stack_va);
            uart_puts("aslr: boot user root rebuild failed (fixed stack)\n");
        }
    }
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
    // Claim 5275: the first milestone-three tasks card — a tick-driven
    // round-robin scheduler. Task 0 is the EL1h shell/main task itself (its
    // context is captured on the first preemption); task 1 is the EL1h demo
    // worker on its own static stack; task 2 is the claim-8215 EL0t payload
    // with separate EL1 exception and EL0 execution stacks. Scheduling starts
    // only HERE, once the shell loop is the running context, so boot-time
    // printing (banner,
    // map, spike) is never preempted. The first tick then preempts the
    // shell, worker, and EL0 task run one quantum each — every timer PPI
    // (claim 9187) is a context switch.
    _ = scheduler.init();
    _ = scheduler.register_worker(@intFromPtr(&worker_entry));
    _ = scheduler.register_user(@intFromPtr(&userspace.entry), base);
    scheduler.start();
    shell.boot_and_park(&mon, m15.rx_wired());
    // No return after takeover. WFE is a terminal state, not a firmware call.
    // Note: with RX wired (nvram builds) boot_and_park loops forever, so
    // this flush is unreachable there — the trailing prompt is flushed by
    // readByteFn when the scripted session ends. Kept as a safety net for
    // the no-RX path, where boot_and_park returns after the prompt.
    if (comptime build_options.nvram_console) nvram_console.flush();
    halt_forever();
}

/// Claim 5275: the demo worker task. Runs in its own task context (one
/// quantum per tick): increments its advance counter, asks the shell idle
/// loop to report it (main-context console discipline — the worker itself
/// never prints), and spins a bounded delay so a 1 s quantum holds several
/// advances. Preempted by the next timer tick; never returns.
const worker_report_every: u64 = 64;
fn worker_entry() void {
    var local: u64 = 0;
    while (true) {
        local += 1;
        scheduler.note_advance();
        if (local % worker_report_every == 0) scheduler.request_report();
        var spins: usize = 0;
        while (spins < 2_000_000) : (spins += 1) asm volatile ("nop");
    }
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

/// Two lowercase hex digits for one byte (no "0x", no separator) — the
/// claim-0828 reply readback prints each byte this way so arbitrary reply
/// contents (including non-printables) are represented faithfully.
fn uart_hex8(value: u8) void {
    uart_putc(hex_digit(value >> 4));
    uart_putc(hex_digit(value & 0xf));
}

fn hex_digit(v: u8) u8 {
    return if (v < 10) '0' + v else 'a' + v - 10;
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

/// Walk the installed TTBR0 tables for `va` (4 K pages, L0-rooted) and
/// print the descriptor chain — diagnostic for the claim-0828 BAR window.
fn walk_print(tag: []const u8, va: u64) void {
    var ttbr0: u64 = undefined;
    asm volatile ("mrs %[v], ttbr0_el1"
        : [v] "=r" (ttbr0),
    );
    var addr = ttbr0 & ~@as(u64, 0xfff);
    var level: u8 = 0;
    var desc: u64 = 0;
    var ok = true;
    while (level <= 3) {
        const shift: u6 = switch (level) {
            0 => 39,
            1 => 30,
            2 => 21,
            else => 12,
        };
        const index = (va >> shift) & 0x1ff;
        desc = @as(*const volatile u64, @ptrFromInt(addr + index * 8)).*;
        if ((desc & 3) == 0) {
            ok = false;
            break;
        }
        if ((desc & 3) == 1 or level == 3) break; // block or page
        addr = desc & ~@as(u64, 0xfff);
        level += 1;
    }
    uart_puts("cvspike: walk ");
    uart_puts(tag);
    uart_puts(" va=");
    uart_hex(va);
    uart_puts(" l");
    uart_puts(&.{'0' + level});
    uart_puts("=");
    uart_hex(desc);
    uart_puts(" ");
    uart_puts(if (ok) "ok" else "INVALID");
    uart_puts("\n");
}

// ---------------------------------------------------------------------------
// Claims 0828/4374/9492/9737/4837: custom-virtio transport experiment
// ---------------------------------------------------------------------------

/// SPI window armed for the spike device's used-ring notification (INTID
/// unknown in advance — 32..191 covers VZ's virtio SPIs; the report names
/// whatever actually fires).
const cv_spi_first: u32 = 32;
const cv_spi_count: u32 = 160;
/// Bounded wait budget per exchange: kick -> host notification -> dequeue
/// -> reply write -> returnToQueue -> used ring + SPI assert -> vector,
/// all sub-millisecond on the host.
const cv_wait_budget: usize = 16_000_000;
/// The small-exchange reply buffer (the write descriptor; the host echoes
/// the 16-byte payload back into it — claims 0828/4374).
var cv_reply_buf: [virtio_custom.reply_cap]u8 align(16) = undefined;
/// The claim-9492 big payload + reply buffers: 12,340 bytes across three
/// device-read descriptors; the host reassembles the spans and echoes the
/// full payload back, which this guest verifies byte-for-byte.
var cv_big_payload: [virtio_custom.big_payload_len]u8 align(16) = undefined;
var cv_big_reply: [virtio_custom.big_payload_len]u8 align(16) = undefined;
/// Guest log lines sent over queue 1 (claim 4837). Stored as raw BYTE
/// arrays (no slice pointers): the kernel is a flat image loaded at a
/// runtime-chosen base, so any .rodata table of baked slice pointers (as
/// an array of string literals would be) holds unrelocated image-relative
/// addresses and faults when dereferenced (observed: q1 data abort at the
/// "cvlog-1" string address). Raw [N:0]u8 arrays contain only bytes —
/// every reference goes through a runtime-computed PC-relative address.
const cv_log_lines = [_][7:0]u8{ "cvlog-1".*, "cvlog-2".*, "cvlog-3".* };

/// Drive the spike device: init (probe + negotiate + DRIVER_OK + both
/// queues armed), arm the SPI window, then run the transport experiment:
/// (1) claim 4374 — two batches of four CONCURRENT in-flight exchanges on
/// queue 0 with descriptor recycling (the second batch must reallocate the
/// same head indices); (2) claim 9492 — a 12,340-byte payload across
/// three read descriptors with host reassembly + full byte-for-byte reply
/// verification; (3) claim 4837 — guest log lines over queue 1 with host
/// echo; (4) claim 9737's feature report (what VZ offers, what was
/// accepted, the negotiated kick width) with the negotiated
/// notification/layout behavior exercised. Then report the accumulated
/// used-ring IRQ observation and disarm the window.
fn custom_virtio_spike() void {
    // Cap decode FIRST, one short line per cap (a line longer than the
    // 128-byte TX buffer flushes mid-line and the follow-up flush can drop
    // on a still-full ring, claim 0016).
    for (virtio_custom.cv_caps[0..virtio_custom.cv_cap_count]) |cap| {
        uart_puts("cvspike: cap @");
        uart_hex(cap.base);
        uart_puts(" head=");
        uart_hex(cap.head);
        uart_puts(" t=");
        uart_hex(cap.cfg_type);
        uart_puts(" bar=");
        uart_hex(cap.bar);
        uart_puts(" off=");
        uart_hex(cap.off);
        uart_puts("\n");
    }
    uart_puts("cvspike: probe dev=");
    uart_hex(virtio_custom.cv_dev);
    uart_puts(" common=");
    uart_hex(virtio_custom.cv_common);
    uart_puts(" notify=");
    uart_hex(virtio_custom.cv_notify);
    uart_puts(" bar=");
    uart_hex(virtio_custom.cv_bar);
    uart_puts(" b0=");
    uart_hex(virtio_custom.cv_bars[0]);
    uart_puts(" b2=");
    uart_hex(virtio_custom.cv_bars[2]);
    uart_puts(" cp=");
    uart_hex(virtio_custom.cv_cap_ptr);
    uart_puts(" nc=");
    uart_hex(virtio_custom.cv_cap_count);
    uart_puts("\n");
    // Verify the identity map actually resolves the transport BARs (the
    // console's 0x100010000 vs the custom's 0x100020000): walk TTBR0.
    walk_print("console-bar", virtio_console.vp_common & ~@as(u64, 0xfff));
    walk_print("cv-bar", virtio_custom.cv_common & ~@as(u64, 0xfff));
    if (!virtio_custom.init()) {
        uart_puts("cvspike: init failed (transport not armed)\n");
        return;
    }
    uart_puts("cvspike: init ok\n");
    gic.arm_spi_window(cv_spi_first, cv_spi_count);
    virtio_custom.reset_irq_observation();

    uart_puts("cvspike: dev=");
    uart_hex(virtio_custom.cv_dev);
    uart_puts(" did=0x1082 common=");
    uart_hex(virtio_custom.cv_common);
    uart_puts(" notify=");
    uart_hex(virtio_custom.cv_notify);
    uart_puts(" qoff=");
    uart_hex(virtio_custom.cv_rings[0].notify_off);
    uart_puts(" qoff1=");
    uart_hex(virtio_custom.cv_rings[1].notify_off);
    uart_puts(" ready=1\n");

    // Claim 9737: the feature report — what VZ offers (64-bit device
    // features), what the driver accepted, and the kick format the
    // negotiation produced (honest either way).
    uart_puts("cvspike: feat="); // uart_hex emits the 0x prefix itself
    uart_hex(virtio_custom.device_features);
    uart_puts(" acc=");
    uart_hex(virtio_custom.guest_features);
    uart_puts(" nd=");
    uart_puts(if (virtio_custom.has_notification_data) "1" else "0");
    uart_puts(" al=");
    uart_puts(if (virtio_custom.has_any_layout) "1" else "0");
    uart_puts(" notify=");
    uart_puts(if (virtio_custom.has_notification_data) "32bit" else "16bit");
    uart_puts("\n");

    virtio_custom.init_payload(); // BSS copy — .rodata pointers are image-relative
    uart_puts("cvspike: payload=\"");
    uart_puts(virtio_custom.payload[0..virtio_custom.payload_len]);
    uart_puts("\" len=");
    uart_hex(virtio_custom.payload_len);
    uart_puts("\n");

    // ---- Claim 4374: concurrent in-flight exchanges + recycling --------
    // Batch 1: four elements submitted back-to-back WITHOUT waiting — the
    // ring allocator hands out four 2-descriptor chains (heads 0,2,4,6 on
    // the reversed-LIFO free list; low indices, the claim-0828-proven
    // pattern). The host drains them per notification and echoes each
    // payload. Batch 2 runs after batch 1 is freed and MUST reallocate the
    // exact same head indices (the recycle proof).
    var ok_q0 = true;
    var batch1: [4]u16 = undefined;
    var batch2: [4]u16 = undefined;
    // Scatter via the BSS staging array (an anonymous `&.{...}` slice
    // array folds into .rodata with baked image-relative pointers).
    virtio_custom.cv_scatter[0] = virtio_custom.payload[0..virtio_custom.payload_len];
    for (0..4) |i| {
        const h = virtio_custom.submit_ex(0, virtio_custom.cv_scatter[0..1], cv_reply_buf[0..virtio_custom.payload_len], false) orelse {
            ok_q0 = false;
            break;
        };
        batch1[i] = h;
    }
    for (0..4) |i| {
        const n = virtio_custom.wait(0, batch1[i], cv_wait_budget, cv_reply_buf[0..virtio_custom.payload_len]) orelse {
            ok_q0 = false;
            continue;
        };
        const echo_ok = @as(usize, n) == virtio_custom.payload_len and std.mem.eql(u8, cv_reply_buf[0..virtio_custom.payload_len], virtio_custom.payload[0..virtio_custom.payload_len]);
        if (!echo_ok) ok_q0 = false;
        uart_puts("cvspike: q0 xchg=");
        uart_putc('0' + @as(u8, @intCast(i + 1)));
        uart_puts(" n=0x10 echo=");
        uart_puts(if (echo_ok) "ok" else "bad");
        uart_puts("\n");
    }
    // Free in REVERSE order: the LIFO free list returns the last-freed
    // chain's head first, so reversing the frees makes batch 2's heads
    // come back in the same order as batch 1's (the recycle comparison).
    var fi: usize = 4;
    while (fi > 0) {
        fi -= 1;
        virtio_custom.free_chain_q(0, batch1[fi]);
    }
    for (0..4) |i| {
        const h = virtio_custom.submit_ex(0, virtio_custom.cv_scatter[0..1], cv_reply_buf[0..virtio_custom.payload_len], false) orelse {
            ok_q0 = false;
            break;
        };
        batch2[i] = h;
    }
    var recycle = true;
    for (0..4) |i| {
        const n = virtio_custom.wait(0, batch2[i], cv_wait_budget, cv_reply_buf[0..virtio_custom.payload_len]) orelse {
            ok_q0 = false;
            recycle = false;
            continue;
        };
        if (!(@as(usize, n) == virtio_custom.payload_len and std.mem.eql(u8, cv_reply_buf[0..virtio_custom.payload_len], virtio_custom.payload[0..virtio_custom.payload_len]))) ok_q0 = false;
        if (batch2[i] != batch1[i]) recycle = false;
    }
    for (batch2) |h| virtio_custom.free_chain_q(0, h);
    uart_puts("cvspike: q0 heads=");
    uart_hex(batch1[0]);
    uart_puts(",");
    uart_hex(batch1[1]);
    uart_puts(",");
    uart_hex(batch1[2]);
    uart_puts(",");
    uart_hex(batch1[3]);
    uart_puts(" recycle=");
    uart_puts(if (recycle) "1" else "0");
    uart_puts("\n");

    // ---- Claim 9492: multi-descriptor >4 KiB payload --------------------
    // 12,340 bytes (0x3034) of a deterministic non-printable pattern across
    // three device-read descriptors (4 KiB + 4 KiB + 4148 B) + one
    // device-write reply descriptor of the same size. With ANY_LAYOUT
    // negotiated (claim 9737) the reply descriptor is posted FIRST in the
    // chain (any layout, Virtio 1.3 §2.7.6); otherwise classic order. The
    // host reassembles the three read spans and echoes the full payload;
    // this guest compares it byte-for-byte.
    for (&cv_big_payload, 0..) |*b, i| b.* = @truncate((i % 251) + 1);
    // Build the 3-part scatter in BSS (anonymous slice arrays are
    // .rodata-folded with baked pointers — see cv_scatter).
    virtio_custom.cv_scatter[0] = cv_big_payload[0..4096];
    virtio_custom.cv_scatter[1] = cv_big_payload[4096..8192];
    virtio_custom.cv_scatter[2] = cv_big_payload[8192..virtio_custom.big_payload_len];
    var big_ok = false;
    if (virtio_custom.submit_ex(0, virtio_custom.cv_scatter[0..3], cv_big_reply[0..], virtio_custom.has_any_layout)) |big_head| {
        if (virtio_custom.wait(0, big_head, cv_wait_budget, cv_big_reply[0..])) |n| {
            big_ok = @as(usize, n) == virtio_custom.big_payload_len and std.mem.eql(u8, cv_big_reply[0..], cv_big_payload[0..]);
        } else {
            ok_q0 = false;
        }
        virtio_custom.free_chain_q(0, big_head);
    } else {
        ok_q0 = false;
    }
    if (!big_ok) ok_q0 = false;
    uart_puts("cvspike: q0 big n=0x3034 echo=");
    uart_puts(if (big_ok) "ok" else "bad");
    uart_puts("\n");
    uart_puts("cvspike: q0 ok=");
    uart_puts(if (ok_q0) "1" else "0");
    uart_puts("\n");

    // ---- Claim 4837: guest log transport over queue 1 -------------------
    // Each line rides one queue-1 element; the host prints it verbatim to
    // its stdout and replies ACK:<len>, which cvlog_puts verifies. The
    // transport is polled (no IRQ dependency), so it is robust against
    // VZ's per-burst used-buffer IRQ coalescing (claim 0828).
    var log_count: usize = 0;
    for (cv_log_lines) |line| {
        // `line` is a stack copy of the raw bytes; its slice is valid for
        // the synchronous cvlog_puts call (which copies it into BSS).
        if (!virtio_custom.cvlog_puts(line[0..])) continue;
        log_count += 1;
        uart_puts("cvspike: q1 log=\"");
        uart_puts(virtio_custom.cv_log_line[0..virtio_custom.cv_log_line_len]);
        uart_puts("\" ack=\"");
        uart_puts(virtio_custom.cv_log_ack_buf[0..virtio_custom.cv_log_ack_len]);
        uart_puts("\" n=");
        uart_hex(virtio_custom.used_len);
        uart_puts("\n");
    }
    uart_puts("cvspike: q1 ok=");
    uart_putc('0' + @as(u8, @intCast(log_count)));
    uart_puts("\n");

    // The used-ring advances are observed by poll (fast); the device IRQs
    // travel through the GIC + vector and can trail them. Give the
    // notifications a bounded window to assert, so the report names how
    // many IRQs the whole experiment actually delivered (VZ coalesces per
    // burst — claim 0828 — so expect a small count, honest either way).
    var drain: usize = 0;
    while (drain < cv_wait_budget and virtio_custom.irq_count < 1) : (drain += 1) {}

    uart_puts("cvspike: irq=");
    uart_hex(virtio_custom.irq_count);
    if (virtio_custom.irq_count > 0) {
        uart_puts(" first="); // uart_hex emits the 0x prefix itself
        uart_hex(virtio_custom.irq_first);
        uart_puts(" spi=");
        uart_hex(virtio_custom.irq_first);
    } else {
        uart_puts(" first=none");
    }
    uart_puts(" armed=");
    uart_hex(cv_spi_first);
    uart_puts("..");
    uart_hex(cv_spi_first + cv_spi_count - 1);
    uart_puts("\n");

    gic.disarm_spi_window(cv_spi_first, cv_spi_count);
}

/// Console writer for the claim-9746 exception report. Wraps the polled
/// uart; a no-op until the console is probed (console_kind == .none).
fn exception_report_writer(text: []const u8) void {
    uart_puts(text);
}

/// Claim 9187 IRQ chain, registered as the exception module's dispatcher:
/// ack from the GIC, handle the timer tick if the INTID is the timer's
/// PPI (re-arming the comparator), then EOI. Runs in IRQ context with a
/// register frame on the stack — NO console access (the heartbeat prints
/// from the shell idle loop, where a print cannot re-enter the polled
/// virtio TX path mid-flush). Claim 5275: on a timer PPI the scheduler
/// tick runs before the EOI; it stages the next task's restore frame
/// (exceptions.resume_frame) and programs ELR/SPSR, but the actual SP
/// switch happens in the vector stub (`mov sp, x0`) only after this
/// function returns — so the EOI is still issued on the interrupted
/// task's stack, which is harmless (the CPU interface is task-agnostic).
/// Claim 0828: every non-timer INTID is recorded into the custom-virtio
/// spike's observation window (an increment + first-INTID store,
/// console-free); in default builds no SPI is armed so the branch never
/// fires.
fn irq_dispatch() void {
    const intid = gic.ack();
    if (gic.is_spurious(intid)) return;
    gic.note_irq(intid);
    if (timer.is_ppi(intid)) {
        timer.handle();
        scheduler.tick();
    } else {
        virtio_custom.note_irq(intid);
    }
    gic.eoi(intid);
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
