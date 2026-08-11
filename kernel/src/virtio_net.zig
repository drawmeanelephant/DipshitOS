//! DipshitOS virtio-pci network transport (milestone five, card N1 —
//! claim 1373).
//!
//! Drives the device the runner attaches as `VZVirtioNetworkDeviceConfiguration`
//! under `--net <capture-file>` — to the guest a modern virtio-pci net
//! device (VID 0x1af4, DID 0x1041, virtio device ID 1) on bus 0, found via
//! the MCFG ECAM base exactly like the console (0x1043, claim 0013), block
//! (0x1042, claim 6420) and entropy (0x1044, claim 2665) devices. The
//! 2026-08-11 DID correction established the modern DID = Virtio Device ID
//! + 0x1040 scheme, so modern virtio-net = **0x1041**; the transitional
//! form 0x1001 is also accepted (the console's 0x1003 precedent) and
//! whatever DID is OBSERVED is recorded in the `net` report (confirm-at-
//! claim-time — a differing DID is a claim-time finding, recorded as the
//! 6420/2665 corrections were).
//!
//! The transport mirrors the blk/entropy patterns: discovery + capability
//! walk + feature negotiation + split-ring queue setup run PRE-EXIT
//! (post-exit config-space reads hang on VZ, claim 0013); post-MMU the
//! transport is RE-ARMED (the claim-6420/2665 lesson — VZ resets virtio
//! devices at ExitBootServices, so status reads 0 and the queues are dead
//! until the re-arm) and TX runs only after that re-arm.
//!
//! N1 negotiates VIRTIO_F_VERSION_1 (mandatory) and VIRTIO_NET_F_MAC when
//! offered (the host-set address — the runner fixes the MAC on the host
//! config so the guest read is deterministic and gate-assertable); NO
//! offload/checksum features are negotiated, so a TX buffer is the RAW
//! ETHERNET FRAME with no virtio_net_hdr prefix (the transitional reading:
//! QEMU's reference device strips a 12-byte header only when checksum
//! offload is negotiated — see `tx_hdr_len`, a confirm-at-claim-time
//! constant). Queue 0 = RX, queue 1 = TX per the virtio-net spec §5.2;
//! RX buffer supply + used-ring drain + MAC filtering + `net recv` are
//! card N2 (queue 0 is set up but supplied with ZERO buffers — honest
//! bounds). TX completion is drained from the used ring POLLED (the
//! claim-6420 one-request-at-a-time blk shape); IRQ delivery is already
//! proven (claims 9187/0828) and lands with RX in N2.
//!
//! The logic is host-testable through injectable transport ops (the
//! fat.zig injected-sector-I/O pattern): feature selection, MAC read,
//! frame build, staging bounds and used-ring drain accounting are pure
//! functions over an `Ops` struct the tests mock; the real device binding
//! is a thin layer of fn pointers over the mmio/pci/mmu helpers.
//!
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const mmio = @import("mmio.zig");
const mmu = @import("mmu.zig");
const pci = @import("pci.zig");
const evidence = @import("evidence.zig");

// ---------------------------------------------------------------------------
// Split-ring structures (the blk/entropy/console shared layout)
// ---------------------------------------------------------------------------

const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
    ring: [queue_size]u16,
};
const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};
const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [queue_size]VirtqUsedElem,
};

/// Split-ring size: 4 (power of two, Virtio 1.3 §4.1.4.3) — the blk/entropy
/// proven size. One TX request outstanding at a time keeps the ring
/// invariant (§2.7) trivially true.
pub const queue_size: u16 = 4;

const virtq_f_write: u16 = 0x2; // VIRTQ_DESC_F_WRITE

/// Completion-poll budget per wait, and how many fresh budgets a stuck
/// device gets before a request fails honestly (mirrors blk/entropy).
const poll_budget: usize = 16_000_000;
const poll_retries: usize = 3;

// ---------------------------------------------------------------------------
// Feature bits (64-bit device-features space)
// ---------------------------------------------------------------------------

const vf_version_1: u64 = 0x1 << 32; // VIRTIO_F_VERSION_1 (bit 32)
const vf_net_mac: u64 = 0x1 << 5; // VIRTIO_NET_F_MAC (bit 5)
const vf_net_mtu: u64 = 0x1 << 3; // VIRTIO_NET_F_MTU (bit 3)
/// Bit 16: VIRTIO_NET_F_STATUS under the legacy (xnu/Linux) numbering,
/// VIRTIO_NET_F_CTRL_RX under the modern spec numbering — accepted
/// either way, harmless for N1 (no control queue is used).
const vf_net_bit16: u64 = 0x1 << 16;
const vf_ring_packed: u64 = 0x1 << 34; // VIRTIO_F_RING_PACKED (bit 34)

/// Whether the landed mask includes RING_PACKED (the device then expects
/// the PACKED virtqueue layout — see `net_send`/`setup_queue`).
pub var net_packed: bool = false;

// ---------------------------------------------------------------------------
// Ethernet framing constants (raw Ethernet for N1 — no IP/ARP yet)
// ---------------------------------------------------------------------------

pub const eth_type_ipv4: u16 = 0x0800;
pub const eth_hdr_len: usize = 14; // dst MAC (6) + src MAC (6) + ethertype (2)
/// Payload bound = the standard Ethernet MTU (1500) without offload
/// features. `netsend` truncates honestly at this bound.
pub const payload_max: usize = 1500;
/// Largest single TX frame: 14-byte header + 1500-byte payload.
pub const frame_max: usize = eth_hdr_len + payload_max; // 1514

/// TX buffer layout, OBSERVED at claim time (2026-08-11, the live VZ
/// gate): VZ's virtio-net device consumes a 12-byte virtio_net_hdr prefix
/// on EVERY TX buffer, even with no offload/checksum feature negotiated
/// (the initial QEMU-transitional assumption of 0 — raw frame only — was
/// wrong; the host capture stripped exactly 12 bytes: our dst+src MACs
/// became the "header" and the delivered frame was ethertype+payload).
/// The driver therefore prepends a ZEROED virtio_net_hdr (all fields
/// zero = no offloads, raw Ethernet follows) to every TX buffer. Recorded
/// as the claim-1373 correction, the 6420/2665 pattern.
const tx_hdr_len: usize = 12;

/// Broadcast destination for the N1 known frame.
pub const broadcast_mac = [6]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
/// Fixed BSS MAC fallback (used only when VIRTIO_NET_F_MAC is NOT offered —
/// deterministic and gate-assertable; the host-set address is expected).
pub const fallback_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 };

/// Where the reported MAC came from (`net` reports it honestly).
pub const MacSource = enum {
    feature, // VIRTIO_NET_F_MAC negotiated — read from the device config
    fallback, // no MAC feature — fixed BSS address
};

// ---------------------------------------------------------------------------
// Injectable transport ops (the fat.zig injected-sector-I/O pattern)
// ---------------------------------------------------------------------------

/// The device-touching operations, injected so host tests can substitute a
/// mock (in-RAM config + rings) and drive the full submit/drain path. The
/// real implementation binds these to the module globals resolved pre-exit.
pub const Ops = struct {
    /// Read a 32-bit DEVICE-CONFIG register (virtio-net §5.2.2 — the MAC
    /// lives at offset 0; VZ's emulation accepts 32-bit accesses, the
    /// claim-0013 common-cfg lesson).
    dev_read32: *const fn (off: u32) u32,
    cfg_read8: *const fn (off: u32) u8,
    cfg_read16: *const fn (off: u32) u16,
    cfg_read32: *const fn (off: u32) u32,
    cfg_write8: *const fn (off: u32, value: u8) void,
    cfg_write16: *const fn (off: u32, value: u16) void,
    cfg_write32: *const fn (off: u32, value: u32) void,
    /// Kick a queue (the notify MMIO write).
    notify: *const fn (q: u16) void,
    /// Kernel VA -> guest physical (claim 5804: queue GPAs are physical).
    to_phys: *const fn (va: usize) u64,
    clean: *const fn (ptr: usize, len: usize) void,
    invalidate: *const fn (ptr: usize, len: usize) void,
};

// ---------------------------------------------------------------------------
// Device state (fixed BSS — the one-and-only real instance)
// ---------------------------------------------------------------------------

/// Per-queue split rings + TX accounting. Lives in BSS so the queue RAM has
/// stable physical addresses fed to the device (blk/entropy shape).
pub const Device = struct {
    rx_desc: [queue_size]VirtqDesc align(16) = undefined,
    rx_avail: VirtqAvail align(2) = undefined,
    rx_used: VirtqUsed align(4) = undefined,
    tx_desc: [queue_size]VirtqDesc align(16) = undefined,
    tx_avail: VirtqAvail align(2) = undefined,
    tx_used: VirtqUsed align(4) = undefined,
    /// Drain point on the TX used ring (the last consumed index).
    tx_last_used: u16 = 0,
    /// TX counters: completions drained from the used ring and the bytes
    /// submitted (the `net` report's tx=frames,bytes).
    tx_frames: u64 = 0,
    tx_bytes: u64 = 0,
    /// Negotiated device features (64-bit; reported low/high in `net`).
    feats_lo: u32 = 0,
    feats_hi: u32 = 0,
    q0_enabled: bool = false, // RX queue armed
    q1_enabled: bool = false, // TX queue armed
};

/// Fixed BSS staging for ONE TX frame: `netsend` builds the zeroed
/// virtio_net_hdr (12 B, observed contract) followed by the Ethernet frame
/// (dst/src/ethertype/payload) here, submits the whole buffer, drains the
/// used ring, and reports byte counts. No heap — bounded by
/// `tx_hdr_len + frame_max` (1526 B).
pub var tx_staging: [tx_hdr_len + frame_max]u8 = undefined;

pub var net_dev: Device = .{};
pub var net_ops: Ops = .{
    .dev_read32 = real_dev_read32,
    .cfg_read8 = real_cfg_read8,
    .cfg_read16 = real_cfg_read16,
    .cfg_read32 = real_cfg_read32,
    .cfg_write8 = real_cfg_write8,
    .cfg_write16 = real_cfg_write16,
    .cfg_write32 = real_cfg_write32,
    .notify = real_notify,
    .to_phys = real_to_phys,
    .clean = real_clean,
    .invalidate = real_invalidate,
};

/// Transport state. Discovery/setup run pre-exit; the TX path runs
/// post-MMU on the pre-exit-captured VAs after `net_rearm`.
pub var net_dev_no: u32 = 0; // net device PCI device number
pub var net_ready: bool = false; // transport initialized, TX armed
pub var net_rearmed: bool = false; // post-exit re-arm succeeded
pub var net_common: u64 = 0; // common-config struct address (BAR + cap offset)
pub var net_notify: u64 = 0; // notify region base (BAR + cap offset)
pub var net_notify_mult: u32 = 0; // notify_off_multiplier
pub var net_queue_notify_off: u16 = 0; // queue notify offset (read per queue)
pub var net_devcfg: u64 = 0; // device-config region (MAC read)
pub var net_bar0: u64 = 0; // net BAR0 base (the identity-map window)
pub var net_did: u32 = 0; // OBSERVED device ID (0x1041 expected)
pub var net_class: u32 = 0; // OBSERVED class code (0x020000 expected)
/// Why init/rearm failed (a static slice the `net` report can print — the
/// honest claim-time record; empty when the transport is armed).
pub var net_fail: []const u8 = "";
/// The raw device-config bytes at offset 0..5, captured PRE-EXIT (claim
/// 0013: config-space reads hang post-exit). On VZ this shows whether the
/// host-set MAC is exposed at config offset 0 even when the device does not
/// offer VIRTIO_NET_F_MAC (the claim-1373 observation; `net` prints it
/// for the record).
pub var net_devcfg_mac_obs: [6]u8 = .{0} ** 6;
pub var net_devcfg_mac_seen: bool = false;
/// The device's OFFERED features as observed at init/rearm (low/high), so
/// a failure can name exactly what the device offered (confirm-at-claim-
/// time record).
pub var net_dev_feats_lo: u32 = 0;
pub var net_dev_feats_hi: u32 = 0;
pub var net_mac: [6]u8 = fallback_mac;
pub var net_mac_source: MacSource = .fallback;
/// "02:00:00:00:00:01" — formatted at read time for the `net` report.
pub var net_mac_text: [17]u8 = undefined;
/// device_status observed at the last successful init/re-arm (0xff when
/// the transport was never armed). Stored (not re-read live) so the `net`
/// report is deterministic and host-testable.
pub var net_status_last: u8 = 0xff;

// ---------------------------------------------------------------------------
// Pure logic (host-testable without a device)
// ---------------------------------------------------------------------------

/// Choose the guest feature mask from the device's offered features
/// (64-bit space). N1 negotiates VIRTIO_F_VERSION_1 (mandatory for modern
/// devices) and VIRTIO_NET_F_MAC when offered (the host-set address); NO
/// offload/checksum features — TX frames are raw Ethernet.
pub fn select_features(device_feats: u64) u64 {
    // A device without VIRTIO_F_VERSION_1 is unusable on the modern
    // transport — refuse it (nothing accepted).
    if ((device_feats & vf_version_1) == 0) return 0;
    var guest: u64 = vf_version_1;
    if ((device_feats & vf_net_mac) != 0) guest |= vf_net_mac;
    return guest;
}

/// Read the device MAC: the VIRTIO_NET_F_MAC path reads the 6 bytes at
/// device-config offset 0 via injected 32-bit reads (LE); the fallback
/// path copies the fixed BSS MAC. Returns true when the feature path was
/// used (the caller records the source honestly).
pub fn read_mac(dev_read32: *const fn (u32) u32, have_mac_feature: bool, out: *[6]u8) bool {
    if (have_mac_feature) {
        const lo = dev_read32(0);
        const hi = dev_read32(4);
        out[0] = @truncate(lo);
        out[1] = @truncate(lo >> 8);
        out[2] = @truncate(lo >> 16);
        out[3] = @truncate(lo >> 24);
        out[4] = @truncate(hi);
        out[5] = @truncate(hi >> 8);
        return true;
    }
    @memcpy(out, &fallback_mac);
    return false;
}

/// Format a MAC as "aa:bb:cc:dd:ee:ff" into a fixed 17-byte buffer.
pub fn format_mac(mac: *const [6]u8, out: *[17]u8) void {
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        out[i * 3] = hex[mac[i] >> 4];
        out[i * 3 + 1] = hex[mac[i] & 0xf];
        if (i < 5) out[i * 3 + 2] = ':';
    }
}

/// Build one Ethernet frame in `buf`: dst MAC, src MAC, ethertype, then the
/// payload (bounded by `payload_max` — honest truncation, never a wrap).
/// Returns the frame length (14 + payload bytes).
pub fn build_frame(
    buf: *[frame_max]u8,
    dst: *const [6]u8,
    src: *const [6]u8,
    ethertype: u16,
    payload: []const u8,
) usize {
    @memcpy(buf[0..6], dst);
    @memcpy(buf[6..12], src);
    buf[12] = @truncate(ethertype >> 8);
    buf[13] = @truncate(ethertype);
    const n = @min(payload.len, payload_max);
    @memcpy(buf[eth_hdr_len .. eth_hdr_len + n], payload[0..n]);
    return eth_hdr_len + n;
}

/// Bounded payload: `requested` clamped to `payload_max` (honest
/// truncation — the reply reports how much was dropped).
pub fn truncate_payload(requested: usize) usize {
    return @min(requested, payload_max);
}

/// Build the N1 known frame in `buf` directly (no intermediate payload
/// copy): broadcast dst, `src` MAC, ethertype 0x0800, and `requested`
/// payload bytes of the deterministic byte-index pattern (byte i = i & 0xff,
/// truncated at `payload_max`). Returns the frame length. This exact layout
/// is the byte-exact fixture the class-B gate asserts in the host capture.
pub fn build_known_frame(
    buf: *[frame_max]u8,
    src: *const [6]u8,
    requested: usize,
) usize {
    const n = truncate_payload(requested);
    @memcpy(buf[0..6], &broadcast_mac);
    @memcpy(buf[6..12], src);
    buf[12] = @truncate(eth_type_ipv4 >> 8);
    buf[13] = @truncate(eth_type_ipv4);
    var i: usize = 0;
    while (i < n) : (i += 1) buf[eth_hdr_len + i] = @truncate(i);
    return eth_hdr_len + n;
}

/// Used-ring drain accounting: given the previous drain point and the
/// device's current used.idx, report how many completions and total
/// device-written bytes lie between them (the ring's `len` fields), for a
/// queue with `queue_size` slots. Pure and host-testable.
pub const DrainReport = struct {
    completed: u16,
    bytes: u64,
};

pub fn drain_delta(last_used: u16, used_idx: u16, used_ring: *const [queue_size]VirtqUsedElem) DrainReport {
    // The device advances used.idx by one per completed buffer, so the
    // delta is the (mod queue_size) difference — with at most `queue_size`
    // requests outstanding the true delta is always < queue_size, and the
    // modulo keeps the wrap (last_used near 0xffff) exact.
    const completed: u16 = (used_idx +% queue_size -% last_used) % queue_size;
    var bytes: u64 = 0;
    var i: u16 = 0;
    while (i < completed) : (i += 1) {
        const slot = (last_used +% i) % queue_size;
        bytes += used_ring[slot].len;
    }
    return .{ .completed = completed, .bytes = bytes };
}

// ---------------------------------------------------------------------------
// Real ops (bound to the module globals + mmio/pci/mmu)
// ---------------------------------------------------------------------------

fn real_dev_read32(off: u32) u32 {
    return mmio.mmio_read32(net_devcfg + off);
}
fn real_cfg_read8(off: u32) u8 {
    return mmio.mmio_read8(net_common + off);
}
fn real_cfg_read16(off: u32) u16 {
    return mmio.mmio_read16(net_common + off);
}
fn real_cfg_read32(off: u32) u32 {
    return mmio.mmio_read32(net_common + off);
}
fn real_cfg_write8(off: u32, value: u8) void {
    mmio.mmio_write8(net_common + off, value);
}
fn real_cfg_write16(off: u32, value: u16) void {
    mmio.mmio_write16(net_common + off, value);
}
fn real_cfg_write32(off: u32, value: u32) void {
    mmio.mmio_write32(net_common + off, value);
}
fn real_notify(q: u16) void {
    // Virtio 1.3 §4.1.5.2.1: without VIRTIO_F_NOTIFICATION_DATA the
    // notification is a 16-bit write of the queue index.
    mmio.mmio_write16(net_notify + @as(u64, net_queue_notify_off) * net_notify_mult, q);
}
fn real_to_phys(va: usize) u64 {
    return mmu.to_phys(va);
}
fn real_clean(ptr: usize, len: usize) void {
    mmu.clean_dcache_range(ptr, len);
}
fn real_invalidate(ptr: usize, len: usize) void {
    mmu.invalidate_dcache_range(ptr, len);
}

// ---------------------------------------------------------------------------
// Capability resolution + discovery (PRE-EXIT only — claim 0013)
// ---------------------------------------------------------------------------

/// Resolve the virtio common/notify/device capabilities for `dev` (its
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
    var notify_mult: u32 = 0;
    var devcfg_bar: u32 = 0;
    var devcfg_off: u32 = 0;
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
                    notify_mult = pci.pci_read32(pci.pci_ecam, 0, dev, 0, c + 16);
                },
                4 => {
                    devcfg_bar = bar;
                    devcfg_off = off;
                },
                else => {},
            }
        }
        c = next;
    }
    if (common_bar >= 6 or notify_bar >= 6) return 0;
    net_notify = bar_base[notify_bar] + notify_off;
    net_notify_mult = notify_mult;
    if (devcfg_bar < 6) net_devcfg = bar_base[devcfg_bar] + devcfg_off;
    net_bar0 = bar_base[0];
    return bar_base[common_bar] + common_off;
}

/// Full queue setup for one virtqueue (the blk/entropy exact sequence):
/// select, size, program the three ring GPAs (claim 5804: physical), read
/// the notify offset, enable. `desc`/`avail`/`used` are the device's ring
/// globals. Returns true when the queue accepted our size and enabled.
fn setup_queue(ops: *const Ops, queue: u16, desc: *[queue_size]VirtqDesc, avail: *VirtqAvail, used: *VirtqUsed) bool {
    ops.cfg_write16(0x16, queue); // queue_select
    const qsz = ops.cfg_read16(0x18);
    if (qsz < queue_size) return false;
    ops.cfg_write16(0x18, queue_size);
    const qd = ops.to_phys(@intFromPtr(desc));
    ops.cfg_write32(0x20, @truncate(qd));
    ops.cfg_write32(0x24, @truncate(qd >> 32));
    const qa = ops.to_phys(@intFromPtr(avail));
    ops.cfg_write32(0x28, @truncate(qa));
    ops.cfg_write32(0x2c, @truncate(qa >> 32));
    const qu = ops.to_phys(@intFromPtr(used));
    ops.cfg_write32(0x30, @truncate(qu));
    ops.cfg_write32(0x34, @truncate(qu >> 32));
    ops.cfg_write16(0x1c, 1); // queue_enable
    return ops.cfg_read16(0x1c) == 1;
}

/// Write the driver feature mask (low word then high word) and check
/// FEATURES_OK. Stores the observed status in `net_status_last` and the
/// accepted mask in `dev.feats_*` (the honest `net` report). Returns true
/// when the device kept FEATURES_OK.
fn accept_features(ops: *const Ops, dev: *Device, guest_feats: u64) bool {
    dev.feats_lo = @truncate(guest_feats);
    dev.feats_hi = @truncate(guest_feats >> 32);
    ops.cfg_write32(0x08, 0);
    ops.cfg_write32(0x0c, @truncate(guest_feats));
    ops.cfg_write32(0x08, 1);
    ops.cfg_write32(0x0c, @truncate(guest_feats >> 32));
    ops.cfg_write8(0x14, 1 | 2 | 8); // FEATURES_OK
    net_status_last = ops.cfg_read8(0x14); // observed status for the record
    return (net_status_last & 8) != 0;
}

/// Shared init sequence: reset, ACKNOWLEDGE|DRIVER, negotiate features,
/// FEATURES_OK, both queues, DRIVER_OK, then the MAC read. Runs pre-exit
/// (`virtio_net_init`) and again post-exit (`net_rearm`) — VZ resets the
/// device at ExitBootServices (the claim-6420/2665 lesson). Returns true
/// when DRIVER_OK holds.
fn transport_init(ops: *const Ops, dev: *Device, rearm: bool) bool {
    if (net_common == 0) return false;
    ops.cfg_write8(0x14, 0); // reset
    var reset_spins: usize = 0;
    while (ops.cfg_read8(0x14) != 0) : (reset_spins += 1) {
        if (reset_spins >= 1_000_000) {
            net_fail = if (rearm) "re-arm: reset timeout" else "reset timeout";
            return false;
        }
    }
    ops.cfg_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER

    // Read the device features (64-bit), then accept our selection. The
    // offered bits are recorded for the honest claim-time report.
    ops.cfg_write32(0x00, 0);
    const feats_lo = ops.cfg_read32(0x04);
    ops.cfg_write32(0x00, 1);
    const feats_hi = ops.cfg_read32(0x04);
    net_dev_feats_lo = feats_lo;
    net_dev_feats_hi = feats_hi;
    const device_feats = (@as(u64, feats_hi) << 32) | feats_lo;

    // Walk the candidate ladder: accept a mask, check FEATURES_OK, and on
    // rejection reset (spec §3.1.1: a failed FEATURES_OK must be followed
    // by a device reset) before the next attempt. The first candidate is
    // the spec-correct selection (select_features); the fixed list covers
    // the progressively reduced / packed-layout masks the quirky VZ device
    // might need (claim-1373: it clears FEATURES_OK even for VER1-only).
    // Only masks whose bits are all OFFERED are tried. The landed mask is
    // reported honestly in `net` (accepted=...); `net_packed` records
    // whether the device forced the packed virtqueue layout.
    var ladder: [10]u64 = undefined;
    var ladder_n: usize = 0;
    {
        const spec = select_features(device_feats); // VER1 (+ MAC when offered)
        // The claim-1373 ladder. The net device's offered bits beyond the
        // custom device's proven-negotiable set (28/29 + VER1 + PACKED) are
        // 3 (MTU), 5 (MAC/GUEST_TSO4) and 16 (STATUS/CTRL_RX) — and it
        // clears FEATURES_OK even for a minimal VER1-only mask, so the
        // "needed" feature (spec §3.1.1) must be among the offered bits.
        // Masks keeping the SPLIT ring layout come first; packed-layout
        // masks are the last resorts.
        const fixed = [_]u64{
            vf_version_1 | vf_net_mtu | vf_net_mac, // split rings, most features
            vf_version_1 | vf_net_mtu | vf_net_mac | vf_net_bit16, // split rings
            vf_version_1 | vf_net_mtu, // split rings
            vf_version_1 | vf_net_mac, // split rings
            vf_version_1 | vf_net_bit16, // split rings
            vf_version_1, // split rings, absolute minimum
            vf_version_1 | vf_net_mtu | vf_net_mac | vf_ring_packed, // packed rings
            vf_version_1 | vf_ring_packed, // packed rings, minimum
        };
        if (spec != 0) {
            ladder[ladder_n] = spec;
            ladder_n += 1;
        }
        for (fixed) |cand| {
            if ((cand & ~device_feats) != 0) continue; // not offered — skip
            var dup = false;
            for (ladder[0..ladder_n]) |seen| {
                if (seen == cand) {
                    dup = true;
                    break;
                }
            }
            if (!dup) {
                ladder[ladder_n] = cand;
                ladder_n += 1;
            }
        }
    }
    var guest_feats: u64 = 0;
    var landed = false;
    for (ladder[0..ladder_n]) |cand| {
        if (!accept_features(ops, dev, cand)) {
            // Reset before the next attempt.
            ops.cfg_write8(0x14, 0);
            reset_spins = 0;
            while (ops.cfg_read8(0x14) != 0) : (reset_spins += 1) {
                if (reset_spins >= 1_000_000) {
                    net_fail = if (rearm) "re-arm: reset timeout" else "reset timeout";
                    return false;
                }
            }
            ops.cfg_write8(0x14, 1 | 2); // ACKNOWLEDGE | DRIVER
            continue;
        }
        guest_feats = cand;
        landed = true;
        break;
    }
    if (!landed) {
        net_fail = if (rearm) "re-arm: FEATURES_OK failed (no ladder mask accepted)" else "FEATURES_OK failed (no ladder mask accepted)";
        return false;
    }
    net_packed = (guest_feats & vf_ring_packed) != 0;

    // Ring init (BSS is not trusted zeroed — the console's claim-0013
    // lesson; the used rings get a clean before the first poll).
    var i: usize = 0;
    while (i < queue_size) : (i += 1) {
        dev.rx_desc[i] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
        dev.tx_desc[i] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
    }
    dev.rx_avail = .{ .flags = 0, .idx = 0, .ring = .{0} ** queue_size };
    dev.rx_used = .{ .flags = 0, .idx = 0, .ring = [_]VirtqUsedElem{.{ .id = 0, .len = 0 }} ** queue_size };
    dev.tx_avail = .{ .flags = 0, .idx = 0, .ring = .{0} ** queue_size };
    dev.tx_used = .{ .flags = 0, .idx = 0, .ring = [_]VirtqUsedElem{.{ .id = 0, .len = 0 }} ** queue_size };
    ops.clean(@intFromPtr(&dev.rx_used), @sizeOf(VirtqUsed));
    ops.clean(@intFromPtr(&dev.tx_used), @sizeOf(VirtqUsed));
    dev.tx_last_used = 0;

    // Queue 0 = RX (set up per spec; ZERO buffers supplied — RX is N2).
    if (!setup_queue(ops, 0, &dev.rx_desc, &dev.rx_avail, &dev.rx_used)) {
        net_fail = if (rearm) "re-arm: queue 0 (RX) setup failed" else "queue 0 (RX) setup failed";
        return false;
    }
    dev.q0_enabled = true;
    // Queue 1 = TX (N1's queue — the used ring drains here).
    if (!setup_queue(ops, 1, &dev.tx_desc, &dev.tx_avail, &dev.tx_used)) {
        net_fail = if (rearm) "re-arm: queue 1 (TX) setup failed" else "queue 1 (TX) setup failed";
        return false;
    }
    dev.q1_enabled = true;
    net_queue_notify_off = ops.cfg_read16(0x1e); // queue 1's notify offset

    ops.cfg_write8(0x14, 1 | 2 | 8 | 4); // DRIVER_OK
    if ((ops.cfg_read8(0x14) & 4) == 0) {
        net_fail = if (rearm) "re-arm: DRIVER_OK failed" else "DRIVER_OK failed";
        return false;
    }
    net_status_last = ops.cfg_read8(0x14);

    // MAC: the feature path (host-set address) or the fixed BSS fallback.
    // On VZ (claim-1373 observation) the device does NOT offer the MAC
    // feature bit (or rejects accepting it), so the feature path is
    // typically unavailable and the fixed BSS MAC is the honest fallback —
    // unless the host-set address is observed in the device config anyway
    // (see `net_devcfg_mac_obs`, read pre-exit), in which case the driver
    // reads it directly (the observed contract).
    const have_mac = (guest_feats & vf_net_mac) != 0;
    if (have_mac and net_devcfg != 0) {
        net_mac_source = if (read_mac(ops.dev_read32, true, &net_mac)) .feature else .fallback;
    } else if (net_devcfg_mac_seen) {
        @memcpy(&net_mac, &net_devcfg_mac_obs);
        net_mac_source = .fallback; // observed contract, not a negotiated feature
    } else {
        @memcpy(&net_mac, &fallback_mac);
        net_mac_source = .fallback;
    }
    format_mac(&net_mac, &net_mac_text);

    if (rearm) {
        evidence.dump_str("VN rearm st=");
        evidence.dump_hex(ops.cfg_read8(0x14));
        evidence.dump_str(" qen=");
        evidence.dump_hex(ops.cfg_read16(0x1c));
        evidence.dump_str("\n");
    } else {
        evidence.dump_str("VN qsz=");
        evidence.dump_hex(ops.cfg_read16(0x18));
        evidence.dump_str(" qen=");
        evidence.dump_hex(ops.cfg_read16(0x1c));
        evidence.dump_str(" qoff=");
        evidence.dump_hex(net_queue_notify_off);
        evidence.dump_str(" st=");
        evidence.dump_hex(ops.cfg_read8(0x14));
        evidence.dump_str("\n");
    }
    return true;
}

/// Initialize the modern virtio-pci network transport PRE-EXIT: locate the
/// net device (DID 0x1041 — modern virtio-net; 0x1001 transitional also
/// accepted, the console's 0x1003 precedent), resolve BARs + the virtio
/// capabilities (common/notify/device), negotiate features, set up queue 0
/// (RX) + queue 1 (TX), and reach DRIVER_OK. Evidence is dumped to the
/// probe buffer so the host sees the device + queue state either way.
pub fn virtio_net_init() bool {
    if (pci.pci_ecam == 0) {
        evidence.dump_str("VN: no ECAM\n");
        net_fail = "no ECAM";
        return false;
    }

    // Locate the net device: modern DID 0x1041 (Virtio Device ID 1 + 0x1040,
    // the 2026-08-11 DID correction), transitional 0x1001 accepted too. The
    // DID actually OBSERVED is recorded in `net_did` (confirm-at-claim-
    // time: a differing DID is a finding, not an assumption). Bus 0, func 0.
    var found_dev: u32 = 32; // sentinel: not found
    var dev: u32 = 0;
    while (dev < 32) : (dev += 1) {
        const id = pci.pci_read32(pci.pci_ecam, 0, dev, 0, 0);
        if ((id & 0xffff) == 0xffff) continue;
        const did = id >> 16;
        if (did != 0x1041 and did != 0x1001) continue;
        found_dev = dev;
        net_did = did;
        net_class = (pci.pci_read32(pci.pci_ecam, 0, dev, 0, 8) >> 8) & 0xffffff;
        break;
    }
    if (found_dev == 32) {
        evidence.dump_str("VN: no virtio-net PCI device\n");
        net_fail = "DID 0x1041 not found on bus 0";
        return false;
    }
    net_dev_no = found_dev;
    evidence.dump_str("VN dev=");
    evidence.dump_hex(net_dev_no);
    evidence.dump_str(" did=");
    evidence.dump_hex(net_did);
    evidence.dump_str(" cls=");
    evidence.dump_hex(net_class);
    evidence.dump_str("\n");

    net_common = resolve_dev(net_dev_no);
    if (net_common == 0) {
        evidence.dump_str("VN: missing capability structs\n");
        net_fail = "missing capability structs";
        return false;
    }

    // Capture the raw device-config bytes at offset 0..5 PRE-EXIT (claim
    // 0013: config-space reads hang post-exit) — the claim-1373 record of
    // whether the host-set MAC is exposed even without VIRTIO_NET_F_MAC.
    if (net_devcfg != 0) {
        var mi: usize = 0;
        while (mi < 6) : (mi += 1) {
            net_devcfg_mac_obs[mi] = mmio.mmio_read8(net_devcfg + mi);
        }
        net_devcfg_mac_seen = true;
    }
    evidence.dump_str("VN common=");
    evidence.dump_hex(net_common);
    evidence.dump_str(" notify=");
    evidence.dump_hex(net_notify);
    evidence.dump_str(" devcfg=");
    evidence.dump_hex(net_devcfg);
    evidence.dump_str(" bar0=");
    evidence.dump_hex(net_bar0);
    evidence.dump_str("\n");

    if (!transport_init(&net_ops, &net_dev, false)) {
        evidence.dump_str("VN: init failed\n");
        // transport_init sets the granular reason; keep a catch-all only
        // when it failed before naming a step.
        if (net_fail.len == 0) net_fail = "init failed";
        return false;
    }
    evidence.dump_str("VN feats=");
    evidence.dump_hex(net_dev.feats_lo);
    evidence.dump_str("/");
    evidence.dump_hex(net_dev.feats_hi);
    evidence.dump_str("\n");
    net_fail = "";
    net_ready = true;
    return true;
}

/// Re-arm the transport POST-exit (claim 6420/2665's lesson): VZ resets
/// virtio devices at ExitBootServices, so the net device's status reads 0
/// and its queues are dead until the full reset → re-init sequence runs
/// again after the MMU switch. Common-config MMIO writes work post-exit
/// through the mapped Device window (verified for blk: DRIVER_OK after the
/// sequence); PCI config-space reads must stay pre-exit (claim 0013).
/// Unconditional and idempotent. The pre-rearm status is dumped so the
/// host sees whether VZ actually reset the device (the claim-6420
/// observation: status reads 0).
pub fn net_rearm() bool {
    if (net_common == 0) return false;
    evidence.dump_str("VN pre-rearm st=");
    evidence.dump_hex(net_ops.cfg_read8(0x14));
    evidence.dump_str("\n");
    if (!transport_init(&net_ops, &net_dev, true)) {
        net_fail = "re-arm failed (reset/features/queues/DRIVER_OK)";
        return false;
    }
    net_fail = "";
    net_rearmed = true;
    net_ready = true;
    return true;
}

/// Current device status (device_status register, common cfg + 0x14) —
/// reported by `net`. 0xff when the transport was never discovered.
pub fn net_status() u8 {
    if (net_common == 0) return 0xff;
    return net_ops.cfg_read8(0x14);
}

// ---------------------------------------------------------------------------
// TX path (queue 1, polled used-ring completion — claim-6420 shape)
// ---------------------------------------------------------------------------

pub const SendResult = enum {
    ok,
    not_ready,
    timeout,
};

/// Wait for the device to consume the outstanding TX request (used.idx to
/// advance past `tx_last_used`). Returns true on completion, false after
/// `poll_retries` fresh `poll_budget` polls. Every wait refreshes the used
/// ring's cache line first (the console/blk poll pattern).
fn wait_tx_completion(ops: *const Ops, dev: *Device) bool {
    var attempt: usize = 0;
    while (attempt < poll_retries) : (attempt += 1) {
        var spins: usize = 0;
        while (spins < poll_budget) : (spins += 1) {
            ops.invalidate(@intFromPtr(&dev.tx_used), @sizeOf(VirtqUsed));
            if (dev.tx_used.idx != dev.tx_last_used) {
                // Used-ring drain accounting: every advance between the
                // drain point and the device's index is one completion.
                const report = drain_delta(dev.tx_last_used, dev.tx_used.idx, &dev.tx_used.ring);
                dev.tx_last_used = dev.tx_used.idx;
                dev.tx_frames +%= report.completed;
                return true;
            }
        }
    }
    return false;
}

/// Submit one frame on queue 1 (TX) and drain the used ring (polled).
/// `frame` must point at a bounded buffer (≤ `frame_max`; `tx_hdr_len` is
/// accounted by the caller). Returns `.ok` once the device consumed it;
/// `.not_ready` when the transport is unarmed or the frame is out of
/// bounds; `.timeout` when the completion poll budgeted out honestly.
pub fn net_send(ops: *const Ops, dev: *Device, frame: []const u8) SendResult {
    // `frame` is the WHOLE device buffer (the caller — net_send_frame —
    // prepends the zeroed virtio_net_hdr when tx_hdr_len > 0). Bounded by
    // the staging capacity.
    if (frame.len == 0 or frame.len > tx_staging.len) return .not_ready;
    if (!net_ready) return .not_ready;

    // Drain any previous completion first (claim-6420 one-request-at-a-time
    // discipline): a timed-out poll leaves the request outstanding, and its
    // used-ring advance must not be attributed to the next request.
    ops.invalidate(@intFromPtr(&dev.tx_used), @sizeOf(VirtqUsed));
    if (dev.tx_avail.idx != dev.tx_used.idx) {
        if (!wait_tx_completion(ops, dev)) return .timeout;
    }

    // One device-read descriptor covering the whole frame. The staging
    // buffer (tx_staging) is the frame; with tx_hdr_len == 0 the frame IS
    // the raw Ethernet frame (see the constant's comment).
    dev.tx_desc[0] = .{
        .addr = ops.to_phys(@intFromPtr(frame.ptr)),
        .len = @intCast(frame.len),
        .flags = 0,
        .next = 0xffff,
    };
    dev.tx_avail.ring[dev.tx_avail.idx % queue_size] = 0; // descriptor 0
    dev.tx_avail.idx +%= 1;
    // Clean the rings + the driver-written frame so the device's DMA reads
    // the real contents.
    ops.clean(@intFromPtr(&dev.tx_desc), @sizeOf([queue_size]VirtqDesc));
    ops.clean(@intFromPtr(&dev.tx_avail), @sizeOf(VirtqAvail));
    ops.clean(@intFromPtr(frame.ptr), frame.len);
    ops.notify(1);
    if (!wait_tx_completion(ops, dev)) return .timeout;
    dev.tx_bytes +%= frame.len;
    return .ok;
}

/// Convenience wrapper over the real transport: build the N1 known frame
/// (broadcast dst, own MAC src, ethertype 0x0800, `requested` payload bytes
/// of the deterministic pattern) in the fixed staging buffer, submit it,
/// and drain. The frame length lands in `out_len` for exact byte reports.
pub fn net_send_frame(requested: usize, out_len: *usize) SendResult {
    // Zeroed virtio_net_hdr prefix (12 B — the claim-1373 observed
    // contract), then the frame. The device strips the header; the host
    // capture carries the raw Ethernet frame byte-exactly.
    @memset(tx_staging[0..tx_hdr_len], 0);
    const frame_buf: *[frame_max]u8 = @ptrCast(&tx_staging[tx_hdr_len]);
    const frame_len = build_known_frame(frame_buf, &net_mac, requested);
    out_len.* = frame_len;
    return net_send(&net_ops, &net_dev, tx_staging[0 .. tx_hdr_len + frame_len]);
}

// ---------------------------------------------------------------------------
// Host tests — pure logic + the full submit/drain path over mock ops
// ---------------------------------------------------------------------------

test "virtio_net: feature selection negotiates VER1 + MAC only" {
    // Device offers MAC (bit 5) + VER1 (bit 32) + a checksum offload we
    // must NOT accept (bit 0): the guest mask is exactly VER1|MAC.
    const offered = (@as(u64, 1) << 32) | (@as(u64, 1) << 5) | 0x1;
    try std.testing.expectEqual(@as(u64, 1) << 32 | (@as(u64, 1) << 5), select_features(offered));
    // No MAC feature: only VER1.
    try std.testing.expectEqual(@as(u64, 1) << 32, select_features(@as(u64, 1) << 32));
    // A device without VER1 is unusable (modern transport mandatory).
    try std.testing.expectEqual(@as(u64, 0), select_features(@as(u64, 1) << 5));
}

test "virtio_net: MAC read — feature path vs fixed fallback" {
    var mac: [6]u8 = undefined;
    // Feature path: the host-set address lives at device-config offset 0
    // (6 bytes, LE) — the runner fixes 02:00:00:00:00:01.
    const from_feature = read_mac(fake_dev_read32, true, &mac);
    try std.testing.expect(from_feature);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 }, &mac);
    // Fallback path: fixed BSS MAC, source reported honestly.
    const from_fallback = read_mac(fake_dev_read32, false, &mac);
    try std.testing.expect(!from_fallback);
    try std.testing.expectEqualSlices(u8, &fallback_mac, &mac);
    // Formatting is the gate-assertable "aa:bb:cc:dd:ee:ff" shape.
    var text: [17]u8 = undefined;
    format_mac(&mac, &text);
    try std.testing.expectEqualSlices(u8, "02:00:00:00:00:02", &text);
}

test "virtio_net: known-frame build is byte-exact against the fixture" {
    // netsend 32 -> 14-byte header + 32 payload bytes (byte i = i & 0xff):
    // ff*6, 02:00:00:00:00:01, 08 00, then 00..1f. This is the EXACT frame
    // the class-B gate asserts in the host capture file.
    var frame: [frame_max]u8 = undefined;
    const mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const len = build_known_frame(&frame, &mac, 32);
    try std.testing.expectEqual(@as(usize, 46), len);
    try std.testing.expectEqualSlices(u8, &broadcast_mac, frame[0..6]);
    try std.testing.expectEqualSlices(u8, &mac, frame[6..12]);
    try std.testing.expectEqual(@as(u8, 0x08), frame[12]);
    try std.testing.expectEqual(@as(u8, 0x00), frame[13]);
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        try std.testing.expectEqual(@as(u8, @intCast(i)), frame[14 + i]);
    }
}

test "virtio_net: staging bounds — payload truncation is honest" {
    // Over-limit requests truncate at the payload bound, never wrap.
    try std.testing.expectEqual(@as(usize, 1500), truncate_payload(1500));
    try std.testing.expectEqual(@as(usize, 1500), truncate_payload(4096));
    try std.testing.expectEqual(@as(usize, 0), truncate_payload(0));
    // The frame bound is exactly 14 + 1500.
    try std.testing.expectEqual(@as(usize, 1514), frame_max);
    try std.testing.expectEqual(@as(usize, 14), eth_hdr_len);
    var frame: [frame_max]u8 = undefined;
    const len = build_known_frame(&frame, &fallback_mac, 5000);
    try std.testing.expectEqual(@as(usize, 1514), len);
    // build_frame (the generic builder) truncates its payload the same way.
    const payload = [_]u8{0xab} ** 2000;
    const len2 = build_frame(&frame, &broadcast_mac, &fallback_mac, eth_type_ipv4, &payload);
    try std.testing.expectEqual(@as(usize, 1514), len2);
    try std.testing.expectEqual(@as(u8, 0xab), frame[1513]);
}

test "virtio_net: used-ring drain accounting is exact" {
    const E = VirtqUsedElem;
    // One completion: used.idx advanced by 1 past the drain point.
    var ring: [queue_size]E = .{ .{ .id = 0, .len = 46 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 } };
    var r = drain_delta(0, 1, &ring);
    try std.testing.expectEqual(@as(u16, 1), r.completed);
    try std.testing.expectEqual(@as(u64, 46), r.bytes);
    // Two completions sum both element lengths at slots 0 and 1.
    ring = .{ .{ .id = 0, .len = 46 }, .{ .id = 0, .len = 60 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 } };
    r = drain_delta(0, 2, &ring);
    try std.testing.expectEqual(@as(u16, 2), r.completed);
    try std.testing.expectEqual(@as(u64, 106), r.bytes);
    // A ring wrap: last_used=3, used=1 (2 completions at slots 3 and 0).
    ring = .{ .{ .id = 0, .len = 46 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 0 }, .{ .id = 0, .len = 60 } };
    r = drain_delta(3, 1, &ring);
    try std.testing.expectEqual(@as(u16, 2), r.completed);
    try std.testing.expectEqual(@as(u64, 106), r.bytes);
    // No advance: zero completions.
    r = drain_delta(4, 4, &ring);
    try std.testing.expectEqual(@as(u16, 0), r.completed);
}

test "virtio_net: full TX submit + drain over a mock transport" {
    // Mock ops: in-RAM config registers + a fake device that advances the
    // used ring on the kick. This drives the SAME net_send path the kernel
    // runs (descriptor, avail, clean, notify, poll, drain accounting).
    const ops = mock_ops();

    // Unarmed transport: honest refusal, no hang, nothing submitted.
    net_ready = false;
    var frame: [frame_max]u8 = undefined;
    const len = build_known_frame(&frame, &fallback_mac, 32);
    var dev = Device{};
    try std.testing.expectEqual(SendResult.not_ready, net_send(&ops, &dev, frame[0..len]));
    try std.testing.expectEqual(@as(u16, 0), dev.tx_avail.idx);
    try std.testing.expectEqual(@as(u64, 0), dev.tx_frames);

    // Armed: the submit lands one descriptor, the fake device completes it
    // on the kick, and the drain accounts the completion.
    net_ready = true;
    mock_used_idx = 0;
    mock_kicks = 0;
    try std.testing.expectEqual(SendResult.ok, net_send(&ops, &dev, frame[0..len]));
    try std.testing.expectEqual(@as(u16, 1), dev.tx_avail.idx);
    try std.testing.expectEqual(@as(u64, 1), dev.tx_frames);
    try std.testing.expectEqual(@as(u64, 46), dev.tx_bytes);
    try std.testing.expectEqual(@as(u16, 1), mock_kicks);
    try std.testing.expectEqual(@as(u16, 1), dev.tx_last_used);

    // A zero-length frame is refused before any submit.
    try std.testing.expectEqual(SendResult.not_ready, net_send(&ops, &dev, frame[0..0]));

    // The staging wrapper (the monitor's netsend path) reports the exact
    // frame length over the mock transport.
    const saved_ops = net_ops;
    net_ops = mock_ops();
    net_mac = fallback_mac;
    net_ready = true;
    var out_len: usize = 0;
    try std.testing.expectEqual(SendResult.ok, net_send_frame(32, &out_len));
    try std.testing.expectEqual(@as(usize, 46), out_len);
    net_ops = saved_ops;
    net_ready = false; // restore for other modules' tests
}

// --- test fixtures ----------------------------------------------------------

/// Fake device-config reads: the runner's fixed MAC 02:00:00:00:00:01 sits
/// at device-config offset 0 as 6 LE bytes (lo = bytes 0..3, hi = bytes
/// 4..5 + zero padding).
fn fake_dev_read32(off: u32) u32 {
    if (off == 0) return 0x00000002; // bytes 02 00 00 00
    return 0x00000100; // bytes 00 00 00 01 (the runner's ...:00:01)
}

// Module-global mock transport state (the fat.zig mock-ops shape: plain fn
// pointers close over these; one mock per test binary).
var mock_cfg: [0x40]u8 = .{0} ** 0x40;
var mock_kicks: u16 = 0;
var mock_used_idx: u16 = 0;

fn mock_dev_read32(off: u32) u32 {
    _ = off;
    return 0;
}
fn mock_cfg_read8(off: u32) u8 {
    return mock_cfg[off];
}
fn mock_cfg_read16(off: u32) u16 {
    return @as(u16, mock_cfg[off]) | (@as(u16, mock_cfg[off + 1]) << 8);
}
fn mock_cfg_read32(off: u32) u32 {
    return @as(u32, mock_cfg[off]) | (@as(u32, mock_cfg[off + 1]) << 8) | (@as(u32, mock_cfg[off + 2]) << 16) | (@as(u32, mock_cfg[off + 3]) << 24);
}
fn mock_cfg_write8(off: u32, value: u8) void {
    mock_cfg[off] = value;
}
fn mock_cfg_write16(off: u32, value: u16) void {
    mock_cfg[off] = @truncate(value);
    mock_cfg[off + 1] = @truncate(value >> 8);
}
fn mock_cfg_write32(off: u32, value: u32) void {
    mock_cfg[off] = @truncate(value);
    mock_cfg[off + 1] = @truncate(value >> 8);
    mock_cfg[off + 2] = @truncate(value >> 16);
    mock_cfg[off + 3] = @truncate(value >> 24);
}
fn mock_to_phys(va: usize) u64 {
    return va; // host test: identity
}
fn mock_clean(_: usize, _: usize) void {}
/// The fake device's "completion": before every used-ring poll the driver
/// invalidates the used ring; the mock replays the fake device state (used
/// index advanced on the kick) into the driver's real BSS ring.
fn mock_invalidate(ptr: usize, len: usize) void {
    _ = len;
    const used = @as(*VirtqUsed, @ptrFromInt(ptr));
    if (used.idx != mock_used_idx) {
        used.idx = mock_used_idx;
        used.ring[(used.idx -% 1) % queue_size].len = 0; // TX: device writes nothing
    }
}
fn mock_notify(q: u16) void {
    _ = q;
    mock_kicks +%= 1;
    mock_used_idx +%= 1; // the device consumes the request
}

fn mock_ops() Ops {
    return .{
        .dev_read32 = mock_dev_read32,
        .cfg_read8 = mock_cfg_read8,
        .cfg_read16 = mock_cfg_read16,
        .cfg_read32 = mock_cfg_read32,
        .cfg_write8 = mock_cfg_write8,
        .cfg_write16 = mock_cfg_write16,
        .cfg_write32 = mock_cfg_write32,
        .notify = mock_notify,
        .to_phys = mock_to_phys,
        .clean = mock_clean,
        .invalidate = mock_invalidate,
    };
}
