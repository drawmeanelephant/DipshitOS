//! DipshitOS virtio-pci block transport (milestone-three storage card, claim 6420).
//!
//! Drives the disk the runner attaches as `VZVirtioBlockDeviceConfiguration`
//! — to the guest a modern virtio-pci block device (VID 0x1af4, DID 0x1041
//! per the spec; VZ on this platform presents it as DID 0x1042, claim 6420
//! discovery) on bus 0, found via the MCFG ECAM base exactly like the
//! console (DID 0x1043, claim 0013). The transport mirrors
//! `virtio_console.zig`'s proven patterns: discovery + capability walk +
//! feature negotiation + split-ring queue setup run PRE-EXIT (firmware
//! identity-maps config space and the BARs); post-exit only the notify MMIO
//! + queue RAM are touched, and every VA used sits below the 4 GiB blanket
//! (mapped Device) or in the extra Device window main.zig maps for the block
//! BAR (claim 1517 made post-MMU transport access reliable: T0SZ=16 + TLBI
//! at the switch).
//!
//! Requests use the three-descriptor chain the virtio-blk spec requires
//! (§5.2.6.2): header (device-reads), data (device-reads for writes /
//! device-writes for reads), and a status byte (device-writes). Queue size
//! 4 (power of two, §4.1.4.3) with one request outstanding at a time, so
//! the split-ring invariant (outstanding = avail.idx - used.idx < queue
//! size, §2.7) always holds. The block size is fixed at 512 bytes; each
//! public call transfers one sector (the filesystem loops for more).
//!
//! Cache correctness mirrors the console: clean the D-cache over
//! driver-written buffers before the kick, invalidate over device-written
//! buffers after completion, and invalidate the used ring before polling.
//!
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const build_options = @import("build_options");
const mmio = @import("mmio.zig");
const mmu = @import("mmu.zig");
const pci = @import("pci.zig");
const evidence = @import("evidence.zig");

const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
    ring: [4]u16,
};
const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};
const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [4]VirtqUsedElem,
};

/// Split-ring size: 4 (power of two, Virtio 1.3 §4.1.4.3). This is the
/// minimum that fits the three-descriptor request chain (header → data →
/// status: the descriptor table holds `queue_size` entries, so 1 would
/// truncate the chain — VZ never completes a request on a 1-slot queue,
/// claim 6420). One request is outstanding at a time, so the ring
/// invariant (outstanding = avail.idx - used.idx < queue size, §2.7)
/// always holds; each entry is placed in `ring[avail.idx % queue_size]`
/// per spec (with a single request chain every slot carries desc 0).
const queue_size: u16 = 4;
const desc_header: u16 = 0;
const desc_data: u16 = 1;
const desc_status: u16 = 2;

const virtq_f_write: u16 = 0x2; // VIRTQ_DESC_F_WRITE
const virtq_f_next: u16 = 0x1; // VIRTQ_DESC_F_NEXT

/// Completion-poll budget per wait, and how many fresh budgets a stuck
/// device gets before the request is failed honestly. A sector request on
/// VZ completes in well under this; the retries absorb host-side latency
/// spikes (real disk I/O on the image file) without a permanent hang.
const poll_budget: usize = 16_000_000;
const poll_retries: usize = 3;

// Request type codes (virtio-blk §5.2.6.1).
const req_in: u32 = 0; // read
const req_out: u32 = 1; // write

/// One request: 16-byte header + 512-byte data + status byte. The three
/// descriptors point into this single aligned buffer.
const Request = struct {
    header: extern struct {
        type: u32,
        reserved: u32,
        sector: u64,
    },
    data: [512]u8,
    status: u8,
};

var blk_req: Request align(512) = undefined;
pub var blk_desc: [3]VirtqDesc align(16) = undefined;
pub var blk_avail: VirtqAvail align(2) = undefined;
pub var blk_used: VirtqUsed align(4) = undefined;
var blk_last_used: u16 = 0;

/// Transport state. Discovery/setup run pre-exit; post-exit the sector
/// paths read only the notify MMIO + queue RAM.
pub var blk_dev: u32 = 0; // block device PCI device number
pub var blk_ready: bool = false; // transport initialized, I/O armed
pub var blk_common: u64 = 0; // common-config struct address (BAR + cap offset)
pub var blk_notify: u64 = 0; // notify region base (BAR + cap offset)
pub var blk_notify_mult: u32 = 0; // notify_off_multiplier
pub var blk_queue_notify_off: u16 = 0; // queue 0 notify offset
pub var blk_bar0: u64 = 0; // block BAR0 base (the identity-map window)

/// Re-arm the transport POST-exit (claim 6420): VZ resets the virtio-blk
/// device at ExitBootServices (its status register reads 0 and the queue is
/// disabled), while the console is left alone. The queue setup therefore
/// runs twice: pre-exit for the boot-time ESP mount, and again here after
/// the MMU switch so the live FAT reads/writes land. Common-config MMIO
/// writes work post-exit through the mapped Device window (verified: the
/// device returns DRIVER_OK after this sequence). PCI config-space reads
/// (the discovery above) must stay pre-exit (claim 0013).
pub fn blk_rearm() bool {
    if (blk_common == 0) return false;
    vp_write8(0x14, 0); // reset
    var spins: usize = 0;
    while (vp_read8(0x14) != 0) : (spins += 1) {
        if (spins > 1_000_000) return false;
    }
    vp_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER
    vp_write32(0x08, 1);
    vp_write32(0x0c, 1); // accept VIRTIO_F_VERSION_1
    vp_write8(0x14, 1 | 2 | 8); // FEATURES_OK
    if ((vp_read8(0x14) & 8) == 0) return false;
    vp_write16(0x16, 0); // queue_select = 0
    vp_write16(0x18, queue_size);
    var i: usize = 0;
    while (i < 3) : (i += 1) blk_desc[i] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    blk_avail = .{ .flags = 0, .idx = 0, .ring = .{ 0, 0, 0, 0 } };
    blk_used = .{ .flags = 0, .idx = 0, .ring = .{ .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 } } };
    mmu.clean_dcache_range(@intFromPtr(&blk_used), @sizeOf(VirtqUsed));
    blk_last_used = 0;
    // Claim 5804: queue GPAs and descriptor addrs are guest PHYSICAL
    // addresses — translate the post-jump kernel VAs.
    const qd = mmu.to_phys(@intFromPtr(&blk_desc));
    mmio.mmio_write32(blk_common + 0x20, @truncate(qd));
    mmio.mmio_write32(blk_common + 0x24, @truncate(qd >> 32));
    const qa = mmu.to_phys(@intFromPtr(&blk_avail));
    mmio.mmio_write32(blk_common + 0x28, @truncate(qa));
    mmio.mmio_write32(blk_common + 0x2c, @truncate(qa >> 32));
    const qu = mmu.to_phys(@intFromPtr(&blk_used));
    mmio.mmio_write32(blk_common + 0x30, @truncate(qu));
    mmio.mmio_write32(blk_common + 0x34, @truncate(qu >> 32));
    vp_write16(0x1c, 1); // queue_enable
    blk_queue_notify_off = vp_read16(0x1e);
    vp_write8(0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    if ((vp_read8(0x14) & 4) == 0) return false;
    blk_ready = true;
    evidence.dump_str("VB rearm st=");
    evidence.dump_hex(vp_read8(0x14));
    evidence.dump_str(" qen=");
    evidence.dump_hex(vp_read16(0x1c));
    evidence.dump_str("\n");
    return true;
}

fn vp_read8(off: u32) u8 {
    return mmio.mmio_read8(blk_common + off);
}

fn vp_write8(off: u32, value: u8) void {
    mmio.mmio_write8(blk_common + off, value);
}

fn vp_read16(off: u32) u16 {
    return mmio.mmio_read16(blk_common + off);
}

fn vp_write16(off: u32, value: u16) void {
    mmio.mmio_write16(blk_common + off, value);
}

fn vp_read32(off: u32) u32 {
    return mmio.mmio_read32(blk_common + off);
}

fn vp_write32(off: u32, value: u32) void {
    mmio.mmio_write32(blk_common + off, value);
}

/// Resolve the virtio common/notify capability addresses for `dev` (its
/// BARs + cap walk). Returns the common-config address, or 0 on failure.
fn resolve_dev(dev: u32) u64 {
    var bar_base: [6]u64 = .{0} ** 6;
    var bi: usize = 0;
    while (bi < 6) : (bi += 1) {
        const low = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0x10 + @as(u32, @intCast(bi)) * 4);
        if ((low & 1) != 0) continue; // I/O space — ignored
        const base: u64 = low & ~@as(u32, 0xf);
        bar_base[bi] = base;
        if (((low >> 1) & 0x3) == 2 and bi + 1 < 6) { // 64-bit BAR
            const high = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0x10 + @as(u32, @intCast(bi + 1)) * 4);
            bar_base[bi] |= @as(u64, high) << 32;
            bi += 1;
        }
    }
    const cap_ptr = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0x34) & 0xff;
    var common_bar: u32 = 0;
    var common_off: u32 = 0;
    var notify_bar: u32 = 0;
    var notify_off: u32 = 0;
    var c: u32 = cap_ptr;
    var caps: usize = 0;
    while (c != 0 and c < 0x100 and (c & 3) == 0 and caps < 16) : (caps += 1) {
        const head = pci.pci_read32(pci.pci_ecam, 0, dev, 0, c);
        const id = head & 0xff;
        const next = (head >> 8) & 0xff;
        if (id == 0x09) {
            const cfg_type = (head >> 24) & 0xff;
            const bar = pci.pci_read32(pci.pci_ecam, 0, dev, 0, c + 4) & 0xff;
            const off = pci.pci_read32(pci.pci_ecam, 0, dev, 0, c + 8);
            switch (cfg_type) {
                1 => {
                    common_bar = bar;
                    common_off = off;
                },
                2 => {
                    notify_bar = bar;
                    notify_off = off;
                },
                else => {},
            }
        }
        c = next;
    }
    if (common_bar >= 6 or notify_bar >= 6) return 0;
    const common = bar_base[common_bar] + common_off;
    blk_notify = bar_base[notify_bar] + notify_off;
    blk_bar0 = bar_base[0];
    return common;
}

/// Initialize the modern virtio-pci block transport: locate the block
/// device (DID 0x1041) on bus 0, resolve BARs + the virtio capabilities
/// (common/notify), program features (VIRTIO_F_VERSION_1 mandatory), set up
/// queue 0 (split ring, size 4), and reach DRIVER_OK. PRE-EXIT only (the
/// console's proven placement — post-exit config-space reads hang on VZ,
/// claim 0013). Evidence is dumped to the probe buffer so the host sees the
/// device + queue state either way.
pub fn virtio_blk_init() bool {
    if (pci.pci_ecam == 0) {
        evidence.dump_str("VB: no ECAM\n");
        return false;
    }

    // Locate the block device: modern DID 0x1041 (spec) — but VZ on this
    // platform presents virtio-blk as DID 0x1042 with the virtio-blk class
    // (0x018000, mass-storage/other; claim 6420 discovery: dev 6, while
    // the console sits at 0x1043). Both DIDs are accepted; the class code
    // cross-checks so a non-storage virtio device is never mistaken for
    // the disk. Bus 0, function 0.
    var found_dev: u32 = 32; // sentinel: not found
    var dev: u32 = 0;
    while (dev < 32) : (dev += 1) {
        const id = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0);
        if ((id & 0xffff) == 0xffff) continue;
        const did = id >> 16;
        if (did != 0x1041 and did != 0x1042) continue;
        const cls = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 8) >> 8;
        if ((cls >> 16) != 0x01) continue; // not a mass-storage controller
        found_dev = dev;
        break;
    }
    blk_dev = found_dev;
    evidence.dump_str("VB dev=");
    evidence.dump_hex(blk_dev);
    evidence.dump_str("\n");

    blk_common = resolve_dev(blk_dev);
    if (blk_common == 0) {
        evidence.dump_str("VB: missing capability structs\n");
        return false;
    }
    evidence.dump_str("VB common=");
    evidence.dump_hex(blk_common);
    evidence.dump_str(" notify=");
    evidence.dump_hex(blk_notify);
    evidence.dump_str(" bar0=");
    evidence.dump_hex(blk_bar0);
    evidence.dump_str("\n");

    // Modern transport init: reset, ACKNOWLEDGE|DRIVER, accept
    // VIRTIO_F_VERSION_1, FEATURES_OK (the console's exact sequence).
    vp_write8(0x14, 0); // reset
    var reset_spins: usize = 0;
    while (vp_read8(0x14) != 0) : (reset_spins += 1) {
        if (reset_spins >= 1_000_000) {
            evidence.dump_str("VB: reset timeout\n");
            return false;
        }
    }
    vp_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER
    vp_write32(0x00, 1);
    const features_hi = vp_read32(0x04);
    vp_write32(0x00, 0);
    evidence.dump_str("VB feats=");
    evidence.dump_hex(vp_read32(0x04));
    evidence.dump_str("/");
    evidence.dump_hex(features_hi);
    evidence.dump_str("\n");
    if ((features_hi & 1) == 0) {
        evidence.dump_str("VB: no VIRTIO_F_VERSION_1\n");
        return false;
    }
    vp_write32(0x08, 1);
    vp_write32(0x0c, 1); // accept VIRTIO_F_VERSION_1
    vp_write32(0x08, 0);
    vp_write32(0x0c, 0);
    vp_write8(0x14, 1 | 2 | 8); // FEATURES_OK
    if ((vp_read8(0x14) & 8) == 0) {
        evidence.dump_str("VB: FEATURES_OK failed\n");
        return false;
    }

    // Queue 0 = the block request queue.
    vp_write16(0x16, 0); // queue_select = 0
    const qsz = vp_read16(0x18);
    if (qsz < queue_size) {
        evidence.dump_str("VB: queue 0 too small\n");
        return false;
    }
    vp_write16(0x18, queue_size); // queue_size = 4 (power of 2, §4.1.4.3)
    var i: usize = 0;
    while (i < 3) : (i += 1) blk_desc[i] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    blk_avail = .{ .flags = 0, .idx = 0, .ring = .{ 0, 0, 0, 0 } };
    blk_used = .{ .flags = 0, .idx = 0, .ring = .{ .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 } } };
    // Clean the used ring's init write to RAM now (BSS is not trusted
    // zeroed; the poll would otherwise re-read stale RAM garbage — the
    // console's claim-0013 lesson).
    mmu.clean_dcache_range(@intFromPtr(&blk_used), @sizeOf(VirtqUsed));
    blk_last_used = 0;
    // Queue GPA registers are le64; VZ's common-cfg emulation accepts
    // 32-bit accesses (claim 0013), so write each half as a 32-bit store.
    // Claim 5804: queue GPAs are guest PHYSICAL — translate post-jump VAs.
    const qd = mmu.to_phys(@intFromPtr(&blk_desc));
    mmio.mmio_write32(blk_common + 0x20, @truncate(qd));
    mmio.mmio_write32(blk_common + 0x24, @truncate(qd >> 32));
    const qa = mmu.to_phys(@intFromPtr(&blk_avail));
    mmio.mmio_write32(blk_common + 0x28, @truncate(qa));
    mmio.mmio_write32(blk_common + 0x2c, @truncate(qa >> 32));
    const qu = mmu.to_phys(@intFromPtr(&blk_used));
    mmio.mmio_write32(blk_common + 0x30, @truncate(qu));
    mmio.mmio_write32(blk_common + 0x34, @truncate(qu >> 32));
    vp_write16(0x1c, 1); // queue_enable
    blk_queue_notify_off = vp_read16(0x1e);
    vp_write8(0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    if ((vp_read8(0x14) & 4) == 0) {
        evidence.dump_str("VB: DRIVER_OK failed\n");
        return false;
    }
    evidence.dump_str("VB qsz=");
    evidence.dump_hex(vp_read16(0x18));
    evidence.dump_str(" qen=");
    evidence.dump_hex(vp_read16(0x1c));
    evidence.dump_str(" qoff=");
    evidence.dump_hex(blk_queue_notify_off);
    evidence.dump_str(" st=");
    evidence.dump_hex(vp_read8(0x14));
    evidence.dump_str("\n");
    blk_ready = true;
    return true;
}

/// Wait for the device to consume the outstanding request (used.idx to
/// advance past `blk_last_used`). Returns true on completion, false after
/// `poll_retries` fresh `poll_budget` polls. Every wait refreshes the used
/// ring's cache line first, exactly like the console RX poll.
fn wait_completion() bool {
    var attempt: usize = 0;
    while (attempt < poll_retries) : (attempt += 1) {
        var spins: usize = 0;
        while (spins < poll_budget) : (spins += 1) {
            mmu.invalidate_dcache_range(@intFromPtr(&blk_used), @sizeOf(VirtqUsed));
            if (blk_used.idx != blk_last_used) {
                blk_last_used = blk_used.idx;
                return true;
            }
        }
    }
    return false;
}

/// Submit one sector request and wait for completion. Returns true iff the
/// device reported status OK. `out` selects a write (device reads `data`)
/// vs a read (device writes `data`). One request at a time; a stuck device
/// (completion timeout) returns false without touching the rings again.
fn submit(sector: u64, data: *[512]u8, out: bool) bool {
    if (!blk_ready) return false;
    // Drain any previous completion first: a timed-out poll leaves the
    // request outstanding, and its used-ring advance must not be attributed
    // to the next request (which would shift every later read/write by one
    // sector). With queue size 1 the invariant is "zero outstanding"; fail
    // honestly if the previous request is still un-drained.
    mmu.invalidate_dcache_range(@intFromPtr(&blk_used), @sizeOf(VirtqUsed));
    if (blk_avail.idx != blk_used.idx) {
        if (!wait_completion()) return false;
    }
    blk_req.header = .{ .type = if (out) req_out else req_in, .reserved = 0, .sector = sector };
    blk_req.status = 0xff;
    if (out) @memcpy(&blk_req.data, data);
    blk_desc[desc_header] = .{ .addr = mmu.to_phys(@intFromPtr(&blk_req.header)), .len = 16, .flags = virtq_f_next, .next = desc_data };
    blk_desc[desc_data] = .{ .addr = mmu.to_phys(@intFromPtr(&blk_req.data)), .len = 512, .flags = virtq_f_next | (if (out) 0 else virtq_f_write), .next = desc_status };
    blk_desc[desc_status] = .{ .addr = mmu.to_phys(@intFromPtr(&blk_req.status)), .len = 1, .flags = virtq_f_write, .next = 0xffff };
    // Spec indexing: entry `avail.idx` lives in ring[avail.idx % qsize]
    // (with a single request chain every slot carries desc 0).
    blk_avail.ring[blk_avail.idx % queue_size] = desc_header;
    blk_avail.idx +%= 1;
    // Clean the rings + driver-written buffers so the device's DMA reads
    // the real contents.
    mmu.clean_dcache_range(@intFromPtr(&blk_desc), @sizeOf([3]VirtqDesc));
    mmu.clean_dcache_range(@intFromPtr(&blk_avail), @sizeOf(VirtqAvail));
    mmu.clean_dcache_range(@intFromPtr(&blk_req.header), 16 + @as(u64, if (out) 512 else 0));
    // Virtio 1.3 §4.1.5.2.1: without VIRTIO_F_NOTIFICATION_DATA the
    // notification is a 16-bit write of the queue index (0).
    mmio.mmio_write16(blk_notify + @as(u64, blk_queue_notify_off) * blk_notify_mult, 0);
    if (!wait_completion()) return false;
    // The device wrote data (reads) and the status byte; invalidate both
    // before the CPU reads them.
    mmu.invalidate_dcache_range(@intFromPtr(&blk_req.data), 512);
    mmu.invalidate_dcache_range(@intFromPtr(&blk_req.status), 1);
    if (blk_req.status != 0) return false;
    if (!out) @memcpy(data, &blk_req.data);
    return true;
}

/// Read one 512-byte sector into `buf`. Returns false on transport failure
/// (device error, timeout, or unarmed transport).
pub fn blk_read_sector(lba: u64, buf: *[512]u8) bool {
    return submit(lba, buf, false);
}

/// Write one 512-byte sector from `data`. Returns false on transport
/// failure (the write was NOT accepted).
pub fn blk_write_sector(lba: u64, data: *const [512]u8) bool {
    return submit(lba, @constCast(data), true);
}

/// The `fat.DiskOps` interface over this transport (one sector per call).
pub fn disk_ops() fat.DiskOps {
    return .{ .read = &blk_read_sector, .write = &blk_write_sector };
}

const fat = @import("fat.zig");

// ---------------------------------------------------------------------------
// Host tests — only the pieces that need no device
// ---------------------------------------------------------------------------

test "virtio_blk: request layout is the spec shape" {
    // 16-byte header + 512 data + 1 status, sector-aligned request buffer.
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(blk_req.header)));
    try std.testing.expectEqual(@as(usize, 512), @sizeOf(@TypeOf(blk_req.data)));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(@TypeOf(blk_req.status)));
    try std.testing.expect(@intFromPtr(&blk_req) % 512 == 0);
    // A fresh transport reports no-disk honestly.
    blk_ready = false;
    try std.testing.expectEqual(fat.WriteResult.no_disk, fat.write_file("x.txt", "x"));
}
