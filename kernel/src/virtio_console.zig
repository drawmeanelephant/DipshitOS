//! DipshitOS virtio-pci console transport (extracted verbatim from the
//! former kernel/src/main.zig junk drawer; claim 0023 mechanical split —
//! no behavior change).
//!
//! Modern virtio-pci capabilities, feature negotiation, split-virtqueue
//! setup (queue 1 = transmit), the TX flush path, and the build-gated
//! claim-0017/0020 TX diagnostics that drive the same transport. Discovery
//! and transport setup run PRE-EXIT (config-space and BAR MMIO are
//! firmware-identity-mapped and deterministic); post-exit only the notify
//! MMIO + queue RAM are touched for TX, and every VA used sits below the
//! 4 GiB blanket (mapped Device), so no post-switch fault is possible.
//!
//! The transport is the VZ serial attachment: the runner's
//! VZVirtioConsoleDeviceSerialPortConfiguration appears to the guest as a
//! modern virtio-pci console (VID 0x1af4, DID 0x1043) on bus 0, found via
//! the MCFG ECAM base — not the EFI MMIO windows (which the DSDT proves
//! hold only PCI0 + the efivars store; the 0x20050000 PrimeCell UART is
//! Apple's internal debug console, unconnected to the serial pipe).
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");
const SystemTable = std.os.uefi.tables.SystemTable;
const build_options = @import("build_options");
const mmio = @import("mmio.zig");
const mmu = @import("mmu.zig");
const pci = @import("pci.zig");
const evidence = @import("evidence.zig");

// Claim 0020: TX-transition matrix phases. Each option is default off; a
// default build is byte-identical. A diagnostic build enables exactly ONE
// phase, which runs a single controlled TX attempt at its named location
// (A pre-EBS, B post-EBS/pre-MMU, C post-MMU, D final location).
pub const tx_transition_a = build_options.tx_transition_a; // pre-ExitBootServices
pub const tx_transition_b = build_options.tx_transition_b; // post-EBS, firmware translation still active
pub const tx_transition_c = build_options.tx_transition_c; // post identity-map install, before unrelated work
pub const tx_transition_d = build_options.tx_transition_d; // normal final location (banner site)
pub const tx_transition_enabled = tx_transition_a or tx_transition_b or tx_transition_c or tx_transition_d;
// Claim 0020: the matrix is only meaningful with ONE phase per build — a
// second experiment in the same boot would contaminate the transport state
// of the later phase (its TX attempt would no longer be the first on the
// armed transport). Reject combined phase options at compile time.
comptime {
    if (tx_transition_enabled) {
        const phases = @as(usize, @intFromBool(tx_transition_a)) +
            @as(usize, @intFromBool(tx_transition_b)) +
            @as(usize, @intFromBool(tx_transition_c)) +
            @as(usize, @intFromBool(tx_transition_d));
        if (phases != 1) @compileError("tx-transition: enable EXACTLY ONE phase (-Dtx-transition-{a,b,c,d})");
    }
}

// Marker + dump aliases (definitions live in evidence.zig).
const marker_vpscan = evidence.marker_vpscan;
const marker_vpbar = evidence.marker_vpbar;
const marker_vpcap = evidence.marker_vpcap;
const marker_vpcapr = evidence.marker_vpcapr;
const marker_vpwalk = evidence.marker_vpwalk;
const marker_vpdev = evidence.marker_vpdev;
const marker_vptx = evidence.marker_vptx;
const marker_vpok = evidence.marker_vpok;
const marker_pext = evidence.marker_pext;
const marker_pexd = evidence.marker_pexd;
const marker_txst = evidence.marker_txst;
const marker_txnt = evidence.marker_txnt;
const marker_txpl = evidence.marker_txpl;
const marker_txfl = evidence.marker_txfl;
const marker_txda = evidence.marker_txda;
const marker_txcc = evidence.marker_txcc;
const marker_txbr = evidence.marker_txbr;
const marker_txar = evidence.marker_txar;
const marker_txbn = evidence.marker_txbn;
const marker_txan = evidence.marker_txan;
const marker_txup = evidence.marker_txup;
const marker_txuc = evidence.marker_txuc;
const marker_txfr = evidence.marker_txfr;
const marker_tra1 = evidence.marker_tra1;
const marker_tra2 = evidence.marker_tra2;
const marker_trau = evidence.marker_trau;
const marker_trb1 = evidence.marker_trb1;
const marker_trb2 = evidence.marker_trb2;
const marker_trbu = evidence.marker_trbu;
const marker_trc1 = evidence.marker_trc1;
const marker_trc2 = evidence.marker_trc2;
const marker_trcu = evidence.marker_trcu;
const marker_trd1 = evidence.marker_trd1;
const marker_trd2 = evidence.marker_trd2;
const marker_trdu = evidence.marker_trdu;
const marker_trnx = evidence.marker_trnx;

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
pub var virtio_desc: [1]VirtqDesc align(16) = undefined;
pub var virtio_avail: VirtqAvail align(2) = undefined;
pub var virtio_used: VirtqUsed align(4) = undefined;
pub var virtio_tx: [128]u8 align(16) = undefined;
var virtio_last_used: u16 = 0;
// Split-ring size (must be a power of 2, Virtio 1.3 §4.1.4.3): one
// descriptor, no chaining. The number of outstanding buffers
// (avail.idx - used.idx) must never exceed this (§2.7).
const virtio_queue_size: u16 = 1;

// Transport state. Discovery and setup run pre-exit; post-exit the TX path
// reads only the notify MMIO + queue RAM (main.zig reads vp_ready/vp_bar0
// for the identity map's extra Device window and the fw-mmu-capture diag).
pub var vp_dev: u32 = 0; // console PCI device number
pub var vp_ready: bool = false; // transport initialized, TX path armed
pub var vp_common: u64 = 0; // common-config struct address (BAR + cap offset)
pub var vp_notify: u64 = 0; // notify region base (BAR + cap offset)
pub var vp_notify_mult: u32 = 0; // notify_off_multiplier
pub var vp_queue_notify_off: u16 = 0; // queue 1 notify offset
pub var vp_common_off: u32 = 0; // common cfg offset within the BAR
pub var vp_notify_off: u32 = 0; // notify cfg offset within the BAR
pub var vp_bar0: u64 = 0; // console BAR0 base (the SEL record)
pub var vp_tx_len: usize = 0; // bytes buffered in virtio_tx
pub var st_tx: ?*const SystemTable = null; // for post-exit flush stage markers

fn vp_read8(off: u32) u8 {
    return mmio.mmio_read8(vp_common + off);
}

fn vp_write8(off: u32, value: u8) void {
    mmio.mmio_write8(vp_common + off, value);
}

fn vp_read16(off: u32) u16 {
    return mmio.mmio_read16(vp_common + off);
}

fn vp_write16(off: u32, value: u16) void {
    mmio.mmio_write16(vp_common + off, value);
}

fn vp_read32(off: u32) u32 {
    return mmio.mmio_read32(vp_common + off);
}

fn vp_write32(off: u32, value: u32) void {
    mmio.mmio_write32(vp_common + off, value);
}

/// Claim 0013: initialize the modern virtio-pci console as the kernel
/// console. Walks the device's virtio capabilities (ID 0x09, cfg types
/// common/notify), programs the modern transport (features, queue 1 =
/// transmit), and arms TX. PRE-EXIT only; evidence is dumped to the probe
/// buffer so the host sees the state either way.
pub fn virtio_pci_init(st: *const SystemTable) bool {
    if (pci.pci_ecam == 0) {
        evidence.dump_str("VP: no ECAM\n");
        return false;
    }

    // Locate the console: modern DID 0x1043, legacy 0x1003 (this milestone
    // drives the modern transport only). Bus 0, function 0.
    var console_dev: u32 = 32;
    var dev: u32 = 0;
    while (dev < 32) : (dev += 1) {
        const id = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0);
        if ((id & 0xffff) == 0xffff) continue;
        const did = id >> 16;
        if (did == 0x1043 or did == 0x1003) {
            console_dev = dev;
            break;
        }
    }
    if (console_dev == 32) {
        evidence.dump_str("VP: no virtio-console PCI device\n");
        return false;
    }
    vp_dev = console_dev;
    evidence.dump_str("VP dev=");
    evidence.dump_hex(console_dev);
    evidence.dump_str("\n");
    evidence.write_marker_var(st, marker_vpscan);

    // BAR bases (memory BARs; 64-bit pairs merged).
    var bar_base: [6]u64 = .{0} ** 6;
    var bi: usize = 0;
    while (bi < 6) : (bi += 1) {
        const low = pci.pci_read32(pci.pci_ecam, 0, console_dev, 0, 0x10 + @as(u32, @intCast(bi)) * 4);
        if ((low & 1) != 0) continue; // I/O space — ignored
        const base: u64 = low & ~@as(u32, 0xf);
        bar_base[bi] = base;
        if (((low >> 1) & 0x3) == 2 and bi + 1 < 6) { // 64-bit BAR
            const high = pci.pci_read32(pci.pci_ecam, 0, console_dev, 0, 0x10 + @as(u32, @intCast(bi + 1)) * 4);
            bar_base[bi] |= @as(u64, high) << 32;
            bi += 1;
        }
    }
    evidence.write_marker_var(st, marker_vpbar);

    // Walk the capability list for the virtio vendor-specific caps (ID 0x09):
    // each carries cfg_type + bar + offset; the notify cap adds a multiplier.
    evidence.write_marker_var(st, marker_vpcap);
    const cap_ptr = pci.pci_read32(pci.pci_ecam, 0, console_dev, 0, 0x34) & 0xff;
    evidence.write_marker_var(st, marker_vpcapr);
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
        const head = pci.pci_read32(pci.pci_ecam, 0, console_dev, 0, c);
        const id = head & 0xff;
        const next = (head >> 8) & 0xff;
        if (id == 0x09) {
            const cfg_type = (head >> 24) & 0xff;
            const bar = pci.pci_read32(pci.pci_ecam, 0, console_dev, 0, c + 4) & 0xff;
            const off = pci.pci_read32(pci.pci_ecam, 0, console_dev, 0, c + 8);
            switch (cfg_type) {
                1 => {
                    common_bar = bar;
                    common_off = off;
                    found_common = true;
                },
                2 => {
                    notify_bar = bar;
                    notify_off = off;
                    notify_mult = pci.pci_read32(pci.pci_ecam, 0, console_dev, 0, c + 16);
                    found_notify = true;
                },
                else => {},
            }
        }
        c = next;
    }
    evidence.write_marker_var(st, marker_vpwalk);

    // NOTE: no BAR rebase pre-exit — moving the window makes the device
    // unreachable pre-exit (observed: after rebasing to 0x10000, reads of
    // BOTH the old firmware base and 0x10000 hang — the firmware never maps
    // the low address). The firmware-assigned base is used for setup and
    // mapped in place post-switch (mmu.zig); no post-exit rebase runs — the
    // attempt was abandoned because post-exit config writes cannot move the
    // BAR on VZ (claims 0013/0020, docs/hardware-contract.md).
    // Offset 0 is a legitimate common-cfg offset (VZ: common @ BAR0+0x00);
    // the caps must simply both be present.
    if (!found_common or !found_notify or common_bar >= 6 or notify_bar >= 6) {
        evidence.dump_str("VP: missing capability structs\n");
        return false;
    }
    vp_common = bar_base[common_bar] + common_off;
    vp_notify = bar_base[notify_bar] + notify_off;
    vp_notify_mult = notify_mult;
    vp_common_off = common_off;
    vp_notify_off = notify_off;
    vp_bar0 = bar_base[0];
    evidence.dump_str("VP common=");
    evidence.dump_hex(vp_common);
    evidence.dump_str(" notify=");
    evidence.dump_hex(vp_notify);
    evidence.dump_str(" mult=");
    evidence.dump_hex(notify_mult);
    evidence.dump_str("\n");
    // Stage marker: device found, BARs + capabilities resolved. If the ladder
    // stops here, a config-space read in the walk is the death site.
    evidence.write_marker_var(st, marker_vpdev);
    // Persist the walk results now: if a transport write below stalls, the
    // host still sees the resolved common/notify addresses. Claim 0015: not
    // in nvram-console builds — the chunk channel needs the store space.
    if (comptime !build_options.nvram_console) evidence.write_probe_var(st);

    // Modern transport init: reset, ACKNOWLEDGE|DRIVER, accept
    // VIRTIO_F_VERSION_1, FEATURES_OK.
    vp_write8(0x14, 0); // reset
    // Virtio 1.3 §4.1.4.3: "After writing 0 to device_status, the driver
    // MUST wait for a read of device_status to return 0 before reinitializing
    // the device." Bounded poll so a stuck device fails honestly instead of
    // hanging, and the ACKNOWLEDGE write below can never race a device that
    // is still mid-reset.
    var reset_spins: usize = 0;
    while (vp_read8(0x14) != 0) : (reset_spins += 1) {
        if (reset_spins >= 1_000_000) {
            evidence.dump_str("VP: reset timeout\n");
            return false;
        }
    }
    vp_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER
    const features_lo = vp_read32(0x04);
    // device_feature_select lives at 0x00 (0x08 is the DRIVER's select).
    vp_write32(0x00, 1);
    const features_hi = vp_read32(0x04);
    vp_write32(0x00, 0);
    evidence.dump_str("VP feats=");
    evidence.dump_hex(features_lo);
    evidence.dump_str("/");
    evidence.dump_hex(features_hi);
    evidence.dump_str("\n");
    if ((features_hi & 1) == 0) {
        evidence.dump_str("VP: no VIRTIO_F_VERSION_1\n");
        return false;
    }
    vp_write32(0x08, 1);
    vp_write32(0x0c, 1); // accept VIRTIO_F_VERSION_1
    vp_write32(0x08, 0);
    vp_write32(0x0c, 0);
    vp_write8(0x14, 1 | 2 | 8); // FEATURES_OK
    if ((vp_read8(0x14) & 8) == 0) {
        evidence.dump_str("VP: FEATURES_OK failed\n");
        return false;
    }

    // Queue 1 = console transmit. Size 1 (one descriptor, no chaining).
    vp_write16(0x16, 1); // queue_select
    const qsz = vp_read16(0x18);
    if (qsz == 0) {
        evidence.dump_str("VP: queue 1 absent\n");
        return false;
    }
    vp_write16(0x18, virtio_queue_size); // queue_size = 1 (power of 2, §4.1.4.3)
    virtio_desc[0] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    virtio_avail = .{ .flags = 0, .idx = 0, .ring = .{0} };
    virtio_used = .{ .flags = 0, .idx = 0, .ring = .{.{ .id = 0, .len = 0 }} };
    // Clean the used ring's init write to RAM now: BSS is not trusted zeroed
    // here, and the flush's dc ivac on this line (the ring-full guard and the
    // used-poll) would otherwise discard this dirty write and re-read stale
    // RAM garbage as used.idx — which the guard would then treat as "ring
    // full" and drop TX forever.
    mmu.clean_dcache_range(@intFromPtr(&virtio_used), @sizeOf(VirtqUsed));
    virtio_last_used = 0;
    vp_tx_len = 0;
    // Queue GPA registers are le64; VZ's common-cfg emulation accepts 32-bit
    // accesses (claim 0013: byte reads of config space return garbage — the
    // emulation has access-size quirks), so write each half as a 32-bit store
    // rather than a single 64-bit one that may be dropped.
    const qd = @intFromPtr(&virtio_desc);
    mmio.mmio_write32(vp_common + 0x20, @truncate(qd));
    mmio.mmio_write32(vp_common + 0x24, @truncate(qd >> 32));
    const qa = @intFromPtr(&virtio_avail);
    mmio.mmio_write32(vp_common + 0x28, @truncate(qa));
    mmio.mmio_write32(vp_common + 0x2c, @truncate(qa >> 32));
    const qu = @intFromPtr(&virtio_used);
    mmio.mmio_write32(vp_common + 0x30, @truncate(qu));
    mmio.mmio_write32(vp_common + 0x34, @truncate(qu >> 32));
    vp_write16(0x1c, 1); // queue_enable
    vp_queue_notify_off = vp_read16(0x1e);
    vp_write8(0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    if ((vp_read8(0x14) & 4) == 0) {
        evidence.dump_str("VP: DRIVER_OK failed\n");
        return false;
    }
    // Stage marker: transport armed. If the ladder stops here, a queue-setup
    // write (mmio_write64 at vp_common+0x20..0x30) is the death site.
    evidence.write_marker_var(st, marker_vptx);
    // Pre-exit readback of the queue setup: qsz/qen/qoff + the GPA halves
    // written above + device status. Verifies the 32-bit queue writes landed.
    evidence.dump_str("VP qsz=");
    evidence.dump_hex(vp_read16(0x18));
    evidence.dump_str(" qen=");
    evidence.dump_hex(vp_read16(0x1c));
    evidence.dump_str(" qoff=");
    evidence.dump_hex(vp_read16(0x1e));
    evidence.dump_str(" qd=");
    evidence.dump_hex(mmio.mmio_read32(vp_common + 0x20));
    evidence.dump_str(" qa=");
    evidence.dump_hex(mmio.mmio_read32(vp_common + 0x28));
    evidence.dump_str(" qu=");
    evidence.dump_hex(mmio.mmio_read32(vp_common + 0x30));
    evidence.dump_str(" st=");
    evidence.dump_hex(vp_read8(0x14));
    evidence.dump_str("\n");
    vp_ready = true;
    evidence.dump_str("VP ready qoff=");
    evidence.dump_hex(vp_queue_notify_off);
    evidence.dump_str("\n");
    evidence.write_marker_var(st, marker_vpok);
    return true;
}

/// Transmit the buffered TX bytes through queue 1: post the buffer in the
/// desc/avail rings, clean the D-cache (the device reads guest RAM
/// directly), kick via the notify region, and wait for the used ring.
/// Runs POST-EXIT on the pre-exit-captured VAs. A stuck device times out
/// and drops the line instead of hanging the kernel (TX remains honest: the
/// serial log is the gate, and M2_TXOK! records that the path returned).
pub fn virtio_pci_flush() void {
    if (!vp_ready or vp_tx_len == 0) return;
    const st = st_tx;
    // Claim 0018 (build-gated -Dtx-diag): ten ordered 8-byte NVRAM markers
    // bracket each potentially fatal operation of the (first) post-exit
    // transmission — the ladder's last marker names the smallest confirmed
    // failure interval. The diag flush also drops the large post-exit
    // probe-tail SetVariable (a big post-exit write, the class claim 0013
    // proved hangs on VZ) and the logging-only status dump; the status read
    // itself stays, bracketed by TXBR!/TXAR!. Default builds are
    // byte-identical (coarse TXST!/TXNT!/TXPL! evidence path unchanged).
    if (comptime build_options.tx_diag) {
        if (st != null) evidence.write_marker_var(st.?, marker_txfl); // 1 entered virtio flush
    }
    // Split-ring invariant (Virtio 1.3 §2.7): the number of outstanding
    // buffers (avail.idx - used.idx) must never exceed the queue size, or a
    // new entry would overwrite a ring slot the device has not yet consumed.
    // Re-read used.idx fresh (the device writes it; invalidate its line
    // first). If the ring is still full — the previous buffer was never
    // consumed (e.g. the notify or the used-poll timed out) — drop this line
    // without touching the rings: the device is stuck, and dropping stays
    // honest without corrupting the ring.
    mmu.invalidate_dcache_range(@intFromPtr(&virtio_used), @sizeOf(VirtqUsed));
    const outstanding = virtio_avail.idx -% virtio_used.idx;
    if (outstanding >= virtio_queue_size) {
        vp_tx_len = 0;
        return;
    }
    virtio_desc[0] = .{ .addr = @intFromPtr(&virtio_tx), .len = @intCast(vp_tx_len), .flags = 0, .next = 0 };
    virtio_avail.ring[0] = 0; // descriptor index 0
    virtio_avail.idx +%= 1;
    if (comptime build_options.tx_diag) {
        if (st != null) evidence.write_marker_var(st.?, marker_txda); // 2 descriptor/avail buffers prepared
    }
    mmu.clean_dcache_range(@intFromPtr(&virtio_desc), @sizeOf(VirtqDesc));
    mmu.clean_dcache_range(@intFromPtr(&virtio_avail), @sizeOf(VirtqAvail));
    mmu.clean_dcache_range(@intFromPtr(&virtio_tx), vp_tx_len);
    if (comptime build_options.tx_diag) {
        if (st != null) evidence.write_marker_var(st.?, marker_txcc); // 3 DMA cache clean completed
    }
    if (comptime build_options.tx_diag) {
        // 4/5: the first post-exit BAR/common-config access (device status
        // read). Bracketed so a hang here is distinguishable from a hang at
        // the notify.
        if (st != null) evidence.write_marker_var(st.?, marker_txbr);
        _ = vp_read8(0x14);
        if (st != null) evidence.write_marker_var(st.?, marker_txar);
    } else {
        // Claim 0013 evidence path (default build, unchanged): coarse
        // markers + post-exit status probe + probe tail.
        if (st_tx != null) evidence.write_marker_var(st_tx.?, marker_txst);
        evidence.dump_str("VP pst=");
        evidence.dump_hex(vp_read8(0x14));
        evidence.dump_str("\n");
        // Claim 0015: the post-exit probe tail is skipped in nvram-console
        // builds for the same store-budget reason as the full dump. Claim
        // 0020: it is also skipped in TX-transition builds — a 512-byte
        // post-exit SetVariable inside the bracketed window would be a
        // confound (the class of write claim 0013 proved hangs post-exit;
        // claim 0018 removed it in diag builds for the same reason), leaving
        // only MMIO accesses + marker writes in the window.
        if (comptime (!build_options.nvram_console and !tx_transition_enabled)) {
            if (st_tx != null) evidence.write_probe_tail(st_tx.?);
        }
    }
    if (comptime build_options.tx_diag) {
        if (st != null) evidence.write_marker_var(st.?, marker_txbn); // 6 before queue notify MMIO write
    }
    // Virtio 1.3 §4.1.5.2.1: VIRTIO_F_NOTIFICATION_DATA is NOT negotiated
    // (only VERSION_1 was accepted above), so the driver notification MUST be
    // a 16-bit write whose value is the virtqueue index (1 = TX queue); the
    // address is cap.offset + queue_notify_off * notify_off_multiplier
    // (§4.1.4.4). A 32-bit store is a MUST violation even though many devices
    // tolerate it; a device not offering NOTIFICATION_DATA MUST accept 2-byte
    // accesses (§4.1.4.4.1). (Claim 0013's "16-bit store may be dropped"
    // belief has no documented evidence; the report flags it as inference.)
    mmio.mmio_write16(vp_notify + @as(u64, vp_queue_notify_off) * vp_notify_mult, 1);
    if (comptime build_options.tx_diag) {
        if (st != null) evidence.write_marker_var(st.?, marker_txan); // 7 after notify
    } else {
        if (st_tx != null) evidence.write_marker_var(st_tx.?, marker_txnt);
    }
    if (comptime build_options.tx_diag) {
        if (st != null) evidence.write_marker_var(st.?, marker_txup); // 8 entered used-ring poll
    }
    var spins: usize = 0;
    while (spins < 2_000_000) : (spins += 1) {
        mmu.invalidate_dcache_range(@intFromPtr(&virtio_used), @sizeOf(VirtqUsed));
        if (virtio_used.idx != virtio_last_used) {
            if (comptime build_options.tx_diag) {
                if (st != null) evidence.write_marker_var(st.?, marker_txuc); // 9 device changed used.idx
            }
            break;
        }
    }
    virtio_last_used = virtio_used.idx;
    if (comptime build_options.tx_diag) {
        if (st != null) evidence.write_marker_var(st.?, marker_txfr); // 10 flush returned
    } else {
        if (st_tx != null) evidence.write_marker_var(st_tx.?, marker_txpl);
    }
    vp_tx_len = 0;
}

// ---------------------------------------------------------------------------
// Claim 0017 diagnostic: PRE-EXIT virtio-pci TX experiment. Answers whether
// the current transport can transmit a known string while Boot Services and
// the firmware address space are still active. Uses the SAME discovered
// device, BAR, capability-decoded common/notify addresses, negotiated
// features, TX queue, desc/avail/used rings and 16-bit notify mechanism as
// the post-exit path — it stages a fixed line into `virtio_tx` and calls
// `virtio_pci_flush()` verbatim. Build-gated by `-Dpreexit-tx` (default off:
// every existing gate is byte-identical). Bracketed by the NVRAM marker
// ladder (claim 0009 channel): M2_PEXT! before the flush, the flush's own
// M2_TXST!/M2_TXNT!/M2_TXPL! stage markers (persisted because st_tx is
// set), M2_PEXD! after. If the experiment hangs, the ladder's last marker
// names the death site. NOTE: the flush also appends "VP pst=" to
// probe_dump — the probe variable is already persisted at this point, so
// that line stays in the in-RAM buffer only (harmless; the placement after
// persistence is deliberate so a hang cannot lose the probe evidence).
// ---------------------------------------------------------------------------
const preexit_tx_line = "DIPSHITOS PREEXIT VIRTIO TX\n";
pub fn preexit_tx_experiment(st: *const SystemTable) void {
    if (!vp_ready or vp_tx_len != 0) return;
    st_tx = st; // the flush's TXST/TXNT/TXPL stage markers now persist pre-exit
    evidence.write_marker_var(st, marker_pext);
    var i: usize = 0;
    while (i < preexit_tx_line.len and i < virtio_tx.len) : (i += 1) {
        virtio_tx[i] = preexit_tx_line[i];
    }
    vp_tx_len = i;
    virtio_pci_flush();
    evidence.write_marker_var(st, marker_pexd);
    st_tx = null;
}

// ---------------------------------------------------------------------------
// Claim 0020 diagnostic: TX-transition matrix. One phase per build (selected
// by -Dtx-transition-{a,b,c,d}), each running ONE controlled TX attempt at
// its named location with the SAME fixed payload, the SAME armed transport
// (armed pre-exit by virtio_pci_init, never transmitted before the phase's
// experiment) and the SAME virtio_pci_flush() as the production path. The
// attempt is bracketed by persistent NVRAM markers (claim-0009 channel):
// M2_TRx1! before the flush, M2_TRx2! when the flush returns, M2_TRxU! if
// used.idx advanced (the device consumed the buffer). The flush's own
// M2_TXST!/M2_TXNT!/M2_TXPL! stage markers (persisted because st_tx is set)
// name the hang site inside the flush. M2_TRNX! records a skipped attempt
// (transport not armed). The FIRST failed phase names the transition that
// destroys console access (see the claim file's interpretation table).
// ---------------------------------------------------------------------------
const transition_tx_line = "DIPSHITOS TRANSITION TX\n";
const TxPhase = enum { a, b, c, d };

pub fn transition_tx_experiment(st: *const SystemTable, phase: TxPhase) void {
    const enter: u64 = switch (phase) {
        .a => marker_tra1,
        .b => marker_trb1,
        .c => marker_trc1,
        .d => marker_trd1,
    };
    const returned: u64 = switch (phase) {
        .a => marker_tra2,
        .b => marker_trb2,
        .c => marker_trc2,
        .d => marker_trd2,
    };
    const used_adv: u64 = switch (phase) {
        .a => marker_trau,
        .b => marker_trbu,
        .c => marker_trcu,
        .d => marker_trdu,
    };
    if (!vp_ready or vp_tx_len != 0) {
        evidence.write_marker_var(st, marker_trnx);
        return;
    }
    evidence.write_marker_var(st, enter);
    st_tx = st; // flush stage markers (TXST!/TXNT!/TXPL!) persist
    var i: usize = 0;
    while (i < transition_tx_line.len and i < virtio_tx.len) : (i += 1) {
        virtio_tx[i] = transition_tx_line[i];
    }
    vp_tx_len = i;
    const used_before = virtio_last_used;
    virtio_pci_flush(); // may hang — the ladder's last marker names the site
    evidence.write_marker_var(st, returned);
    mmu.invalidate_dcache_range(@intFromPtr(&virtio_used), @sizeOf(VirtqUsed));
    if (virtio_used.idx != used_before) evidence.write_marker_var(st, used_adv);
    st_tx = null;
}

/// Legacy virtio-MMIO transport init. Present but never selected by the
/// current probe (the console is a virtio-PCI device); kept verbatim.
fn virtio_init(base: u64) bool {
    // This implementation uses only the modern virtio-mmio register path.
    // A version-1 (legacy) device is not selected because its PFN queue
    // layout would require a separate setup path.
    if (mmio.mmio_read32(base + 0x04) != 2) return false;
    mmio.mmio_write32(base + 0x14, 0);
    const device_features_low = mmio.mmio_read32(base + 0x10);
    mmio.mmio_write32(base + 0x14, 1);
    const device_features_high = mmio.mmio_read32(base + 0x10);
    if ((device_features_high & 1) == 0) return false; // VIRTIO_F_VERSION_1 (bit 32)

    mmio.mmio_write32(base + 0x70, 0);
    mmio.mmio_write32(base + 0x70, 1 | 2); // ACKNOWLEDGE | DRIVER
    mmio.mmio_write32(base + 0x24, 0);
    mmio.mmio_write32(base + 0x20, 0); // no optional low-word features
    mmio.mmio_write32(base + 0x24, 1);
    mmio.mmio_write32(base + 0x20, 1); // negotiate VIRTIO_F_VERSION_1
    _ = device_features_low;
    mmio.mmio_write32(base + 0x70, 1 | 2 | 8); // FEATURES_OK
    if ((mmio.mmio_read32(base + 0x70) & 8) == 0) return false;

    virtio_desc[0] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    virtio_avail = .{ .flags = 0, .idx = 0, .ring = .{0} };
    virtio_used = .{ .flags = 0, .idx = 0, .ring = .{.{ .id = 0, .len = 0 }} };
    virtio_last_used = 0;
    mmio.mmio_write32(base + 0x30, 1); // queue 1: console transmit queue
    const max = mmio.mmio_read32(base + 0x34);
    if (max == 0) return false;
    mmio.mmio_write32(base + 0x38, 1);
    mmio.mmio_write32(base + 0x80, @truncate(@intFromPtr(&virtio_desc)));
    mmio.mmio_write32(base + 0x84, @truncate(@intFromPtr(&virtio_desc) >> 32));
    mmio.mmio_write32(base + 0x90, @truncate(@intFromPtr(&virtio_avail)));
    mmio.mmio_write32(base + 0x94, @truncate(@intFromPtr(&virtio_avail) >> 32));
    mmio.mmio_write32(base + 0xa0, @truncate(@intFromPtr(&virtio_used)));
    mmio.mmio_write32(base + 0xa4, @truncate(@intFromPtr(&virtio_used) >> 32));
    mmio.mmio_write32(base + 0x44, 1);
    mmio.mmio_write32(base + 0x70, 1 | 2 | 8 | 4); // DRIVER_OK
    return (mmio.mmio_read32(base + 0x70) & 4) != 0;
}
