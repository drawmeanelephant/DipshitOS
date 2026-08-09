//! DipshitOS Generic Interrupt Controller (claim 7948 — roadmap item 5's
//! remaining half; the claim-9746 IRQ vector is the delivery point).
//!
//! Two phases, split by the ExitBootServices boundary:
//!
//! 1. DISCOVERY (PRE-EXIT, `discover`): parse the ACPI MADT (signature
//!    "APIC") for the GIC distributor (type 0x0B, physical base @+8, GIC
//!    version @+20), the GICv3 redistributor (type 0x0D, discovery base
//!    @+4), and the GICv2 CPU interface (type 0x0C, base @+32). The bases
//!    and version land in module globals so the kernel can program the
//!    controller AFTER the identity-map switch, when it owns EL1. ACPI
//!    reads are pre-exit only on VZ (claim 0013: post-exit window reads
//!    hang) — the values are captured, never re-read.
//!
//! 2. PROGRAMMING (POST-MMU, `init`): distributor + redistributor/CPU
//!    interface configuration, and the ack/EOI pair the IRQ handler uses.
//!    GICv3 uses the system-register CPU interface (ICC_SRE_EL1 /
//!    ICC_PMR_EL1 / ICC_IGRPEN1_EL1 / ICC_IAR1_EL1 / ICC_EOIR1_EL1);
//!    GICv2 programs the GICC MMIO window. Only the EL1 physical timer
//!    PPI (conventionally 30, discovered from the GTDT by timer.zig) is
//!    enabled — nothing else should ever fire on this platform.
//!
//! The module never touches the console: `dispatch` (ack -> caller's timer
//! handling -> eoi) runs in IRQ context with a register frame on the stack,
//! so printing there would re-enter the polled virtio TX path mid-flush.
//! The timer heartbeat is printed from the shell idle loop instead.
//!
//! Platform wall (measured, documented in the claim): Apple VZ's GIC
//! accepts distributor + CPU-interface configuration (read-back proven) but
//! NEVER presents an interrupt to the guest — the GICR is a RAZ/WI stub
//! (PPIs/SGIs), SPI config sticks in the distributor yet nothing is ever
//! delivered, and even a fully-cleared DAIF + explicit IROUTER changes
//! nothing. The kernel therefore keeps the spec-correct ack/EOI path for
//! real hardware AND consumes the fired timer comparator in the shell idle
//! loop (`timer.poll`) — honest on both platforms.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");
const builtin = @import("builtin");
const mmio = @import("mmio.zig");

// ---------------------------------------------------------------------------
// Discovery result
// ---------------------------------------------------------------------------

pub const GicKind = enum { none, v2, v3 };

/// Interrupt controller discovered from the MADT (pre-exit). `.none` until
/// `discover` runs (and stays `.none` in host test processes, where the
/// programming path must never execute EL1 instructions).
pub var kind: GicKind = .none;
/// GIC distributor (GICD) physical base.
pub var dist_base: u64 = 0;
/// GICv3 redistributor (GICR) base — CPU0's frame is at base+0x0000.
pub var redist_base: u64 = 0;
/// GICv2 CPU interface (GICC) physical base.
pub var cpu_base: u64 = 0;
/// The MADT GICD "GIC Version" byte (0x10 v2 / 0x20 v3 / 0x30 v4 / 0xFF
/// unversioned). Used with the presence of GICR/GICC entries to pick the
/// programming path.
var version_byte: u8 = 0;

pub fn kind_name() []const u8 {
    return switch (kind) {
        .none => "none",
        .v2 => "v2",
        .v3 => "v3",
    };
}

/// Apple VZ platform layout (fallback when the MADT is non-conformant).
/// Evidence: the VZ guest device tree (`arm,gic-v3`, reg GICD 0x10000000 /
/// GICR 0x10010000 — observed in the wild) and live register probes on
/// this codebase's VZ runs: GICD_CTLR=0x50 (ARE_NS set → GICv3 affinity
/// routing), GICD_TYPER=0x0478001f (ITLines=31), GICR_CTLR/WAKER sane at
/// 0x10010000. The VZ MADT's GIC structures do NOT follow the ACPI
/// GICD/GICC/GICR layouts (its 0x0B/0x0C/0x0D entries are malformed — the
/// strict parse below finds nothing), so this fallback is what makes the
/// controller programmble here.
const vz_dist_base: u64 = 0x10000000;
const vz_redist_base: u64 = 0x10010000;

// ---------------------------------------------------------------------------
// Discovery (PRE-EXIT; called from the pci.zig ACPI walk on the APIC table)
// ---------------------------------------------------------------------------

/// Read an 8-byte little-endian field with two 32-bit reads (safe at any
/// alignment, on Normal RAM and in host test fixtures alike).
fn read64(addr: u64) u64 {
    const lo = mmio.mmio_read32(addr);
    const hi = mmio.mmio_read32(addr + 4);
    return lo | (@as(u64, hi) << 32);
}

/// Parse the MADT (sig "APIC") at `madt_addr` for GICD/GICR/GICC entries.
/// Entries start at offset 36 (the 36-byte ACPI header). Host-testable
/// against a RAM fixture; on the kernel this runs pre-exit only.
pub fn discover(madt_addr: u64, madt_len: u32) void {
    dist_base = 0;
    redist_base = 0;
    cpu_base = 0;
    version_byte = 0;
    kind = .none;
    if (madt_addr != 0 and madt_len > 36) {
        var off: u32 = 36;
        while (off + 2 <= madt_len) {
            const entry_type = mmio.mmio_read8(madt_addr + off);
            const entry_len = mmio.mmio_read8(madt_addr + off + 1);
            if (entry_len < 2) break;
            switch (entry_type) {
                0x0B => { // GIC Distributor: base @+8, version @+20
                    dist_base = read64(madt_addr + off + 8);
                    version_byte = mmio.mmio_read8(madt_addr + off + 20);
                },
                0x0C => { // GIC CPU Interface (v2): base @+32
                    cpu_base = read64(madt_addr + off + 32);
                },
                0x0D => { // GIC Redistributor (v3): discovery base @+4
                    redist_base = read64(madt_addr + off + 4);
                },
                else => {}, // ITS (0x0E), reserved types, and everything else: ignored
            }
            off += entry_len;
        }
        // Version byte is authoritative when it names a generation;
        // otherwise infer from which CPU-interface structures are present
        // (a GICv3 MADT still lists GICC entries with base 0 — the v3
        // interface is the system registers — so GICR presence wins over
        // GICC).
        kind = switch (version_byte) {
            0x10 => .v2,
            0x20, 0x30 => .v3,
            else => if (redist_base != 0) .v3 else if (cpu_base != 0) .v2 else .none,
        };
    }
    // Apple VZ fallback, UNCONDITIONAL when no conformant controller was
    // found: VZ's MADT is non-conformant (its GIC structures do not follow
    // the ACPI GICD/GICC/GICR layouts — measured), so the device-tree /
    // live-probed layout (GICv3 at 0x10000000/0x10010000) is the ground
    // truth on this platform.
    if (kind == .none) {
        kind = .v3;
        dist_base = vz_dist_base;
        redist_base = vz_redist_base;
        cpu_base = 0;
        version_byte = 0x20;
    }
}

// ---------------------------------------------------------------------------
// Programming (POST-MMU, kernel owns EL1; aarch64 only)
// ---------------------------------------------------------------------------

var programmed: bool = false;
/// True once `init` has programmed the controller (only inside the kernel;
/// a host test process must never touch GIC registers).
pub fn armed() bool {
    return programmed;
}

/// Program the discovered controller: distributor, per-CPU interface, and
/// the EL1 physical-timer PPI (its number comes from timer.zig's GTDT
/// discovery). Does NOT unmask IRQs — the kernel does that after everything
/// (including the timer) is armed.
pub fn init() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (kind == .none) return;
    switch (kind) {
        .v3 => init_v3(),
        .v2 => init_v2(),
        .none => {},
    }
    programmed = true;
}

fn init_v3() void {
    // Distributor: enable Group 1 (bit 1) + Group 0 non-secure (bit 0).
    var ctlr = mmio.mmio_read32(dist_base + 0x0000);
    ctlr |= 0b11;
    mmio.mmio_write32(dist_base + 0x0000, ctlr);

    // Redistributor, CPU0's frame (base + 0x0000; VZ runs 2 vCPUs and our
    // kernel is the boot CPU; the other CPU is parked by firmware and never
    // takes Group 1 interrupts on its own).
    const rbase = redist_base;
    // GICR_WAKER: wake the redistributor (clear ProcessorSleep) and wait
    // for ChildrenAsleep to clear. Bounded: a stuck bit must not hang boot.
    var waker = mmio.mmio_read32(rbase + 0x0014);
    waker &= ~@as(u32, 1);
    mmio.mmio_write32(rbase + 0x0014, waker);
    var spins: usize = 0;
    while ((mmio.mmio_read32(rbase + 0x0014) & 2) != 0 and spins < 100_000) : (spins += 1) {}
    // PPI 30 -> Group 1 (IGROUPR0 bit 30).
    var igroup = mmio.mmio_read32(rbase + 0x0080);
    igroup |= @as(u32, 1) << 30;
    mmio.mmio_write32(rbase + 0x0080, igroup);
    wait_rwp(rbase);
    // Priority 0x80 (mid, below PMR=0xff so it always passes).
    mmio.mmio_write8(rbase + 0x0400 + 30, 0x80);
    wait_rwp(rbase);
    // Edge-triggered (ICFGR1 field for PPI 30 = bits [29:28] = 0b01); the
    // generic timer comparator is an edge.
    var icfg = mmio.mmio_read32(rbase + 0x0c04);
    icfg &= ~@as(u32, 0b11 << 28);
    icfg |= @as(u32, 1) << 28;
    mmio.mmio_write32(rbase + 0x0c04, icfg);
    wait_rwp(rbase);
    // Enable PPI 30 (ISENABLER0 bit 30).
    mmio.mmio_write32(rbase + 0x0100, @as(u32, 1) << 30);
    wait_rwp(rbase);

    // CPU interface via the system registers (GICv3).
    var sre: u64 = 0;
    asm volatile ("mrs %[v], icc_sre_el1"
        : [v] "=r" (sre),
    );
    sre |= 1; // SRE: system-register interface
    asm volatile ("msr icc_sre_el1, %[v]"
        :
        : [v] "r" (sre),
    );
    asm volatile ("msr icc_pmr_el1, %[v]"
        :
        : [v] "r" (@as(u64, 0xff)),
    );
    asm volatile ("msr icc_igrpen1_el1, %[v]"
        :
        : [v] "r" (@as(u64, 1)),
    );
    asm volatile ("isb");
}

fn init_v2() void {
    // Distributor: EnableGrp0 | EnableGrp1.
    var ctlr = mmio.mmio_read32(dist_base + 0x0000);
    ctlr |= 0b11;
    mmio.mmio_write32(dist_base + 0x0000, ctlr);
    // PPI 30 -> Group 1 (IGROUPR0 bit 30).
    var igroup = mmio.mmio_read32(dist_base + 0x0080);
    igroup |= @as(u32, 1) << 30;
    mmio.mmio_write32(dist_base + 0x0080, igroup);
    // Priority byte for PPI 30 (IPRIORITYR0 + 30).
    mmio.mmio_write8(dist_base + 0x0400 + 30, 0x80);
    // Edge-triggered (ICFGR1 field for PPI 30 = bits [29:28] = 0b01).
    var icfg = mmio.mmio_read32(dist_base + 0x0c04);
    icfg &= ~@as(u32, 0b11 << 28);
    icfg |= @as(u32, 1) << 28;
    mmio.mmio_write32(dist_base + 0x0c04, icfg);
    // Enable PPI 30 (ISENABLER0 bit 30).
    mmio.mmio_write32(dist_base + 0x0100, @as(u32, 1) << 30);
    // CPU interface (GICC): enable + priority mask.
    var ctlr2 = mmio.mmio_read32(cpu_base + 0x0000);
    ctlr2 |= 0b11;
    mmio.mmio_write32(cpu_base + 0x0000, ctlr2);
    mmio.mmio_write32(cpu_base + 0x0004, 0xff);
}

/// Poll GICR_CTLR.RWP (bit 3) until the redistributor finished processing
/// register writes. Bounded: a stuck bit must not hang boot.
fn wait_rwp(rbase: u64) void {
    var spins: usize = 0;
    while ((mmio.mmio_read32(rbase + 0x0000) & (1 << 3)) != 0 and spins < 100_000) : (spins += 1) {}
}

// ---------------------------------------------------------------------------
// IRQ-handler primitives (called by the kernel's irq_dispatch, in IRQ
// context — never touch the console here)
// ---------------------------------------------------------------------------

/// Non-spurious interrupts acked since init (diagnostic; the timer command
/// prints it — if the GIC delivers on a different INTID than the timer's
/// PPI, irqs_acked grows while ticks stays 0).
pub var irqs_acked: u32 = 0;
/// The first non-spurious INTID acked (0xffffffff until one arrives).
pub var first_intid: u32 = 0xffffffff;

/// Read the acknowledged INTID from the CPU interface (ICC_IAR1_EL1 for
/// v3, GICC_IAR for v2). 1023 = spurious (the same value in both).
pub fn ack() u32 {
    if (comptime builtin.cpu.arch != .aarch64) return 1023;
    return switch (kind) {
        .v3 => blk: {
            var iar: u64 = 1023;
            asm volatile ("mrs %[v], icc_iar1_el1"
                : [v] "=r" (iar),
            );
            break :blk @as(u32, @intCast(iar & 0xffffff));
        },
        .v2 => mmio.mmio_read32(cpu_base + 0x000c) & 0x3ff,
        .none => 1023,
    };
}

/// Spurious-interrupt sentinel (1023 on both GICv2's 10-bit IAR and
/// GICv3's 24-bit IAR).
pub fn is_spurious(intid: u32) bool {
    return intid == 1023;
}

/// Record a non-spurious ack for diagnostics.
pub fn note_irq(intid: u32) void {
    irqs_acked += 1;
    if (first_intid == 0xffffffff) first_intid = intid;
}

/// Deactivate the interrupt (ICC_EOIR1_EL1 for v3, GICC_EOIR for v2).
pub fn eoi(intid: u32) void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    switch (kind) {
        .v3 => asm volatile ("msr icc_eoir1_el1, %[v]"
            :
            : [v] "r" (@as(u64, intid)),
        ),
        .v2 => mmio.mmio_write32(cpu_base + 0x0010, intid),
        .none => {},
    }
}

// ---------------------------------------------------------------------------
// Tests (host-side; fixtures are RAM buffers, programming is aarch64-only)
// ---------------------------------------------------------------------------

const Header = struct {
    len: u32,
};

fn fixture_madt(comptime entries: []const struct { type: u8, len: u8, bytes: []const u8 }, header_len: u32, buf: []u8) Header {
    // header_len is the total table length (header + entries); the first
    // 36 bytes are the ACPI header, entries start at 36.
    @memset(buf[0..], 0);
    std.mem.writeInt(u32, buf[4..8], header_len, .little);
    var off: usize = 36;
    for (entries) |e| {
        buf[off] = e.type;
        buf[off + 1] = e.len;
        @memcpy(buf[off + 2 .. off + 2 + e.bytes.len], e.bytes);
        off += e.len;
    }
    return .{ .len = header_len };
}

fn put64(buf: []u8, off: usize, value: u64) void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, value, .little);
    @memcpy(buf[off .. off + 8], &tmp);
}

fn put32(buf: []u8, off: usize, value: u32) void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, value, .little);
    @memcpy(buf[off .. off + 4], &tmp);
}

test "gic: MADT v3 fixture parses distributor + redistributor + gicc" {
    var buf: [512]u8 align(16) = undefined;
    // GICD: base @+8, version @+20 (0x20 = GICv3). GICR: base @+4.
    // GICC: base @+32 (0 for v3 — the interface is the system registers).
    const h = fixture_madt(&.{
        .{ .type = 0x0b, .len = 24, .bytes = &.{} },
        .{ .type = 0x0d, .len = 20, .bytes = &.{} },
        .{ .type = 0x0c, .len = 80, .bytes = &.{} },
    }, 36 + 24 + 20 + 80, &buf);
    put64(&buf, 36 + 8, 0x2f000000);
    buf[36 + 20] = 0x20;
    put64(&buf, 36 + 24 + 4, 0x2f100000);
    put64(&buf, 36 + 24 + 20 + 32, 0);
    discover(@intFromPtr(&buf), h.len);
    try std.testing.expectEqual(GicKind.v3, kind);
    try std.testing.expectEqual(@as(u64, 0x2f000000), dist_base);
    try std.testing.expectEqual(@as(u64, 0x2f100000), redist_base);
    try std.testing.expectEqual(@as(u64, 0), cpu_base);
    try std.testing.expectEqualStrings("v3", kind_name());
}

test "gic: MADT v2 fixture parses GICC and picks the MMIO path" {
    var buf: [512]u8 align(16) = undefined;
    const h = fixture_madt(&.{
        .{ .type = 0x0b, .len = 24, .bytes = &.{} },
        .{ .type = 0x0c, .len = 80, .bytes = &.{} },
    }, 36 + 24 + 80, &buf);
    put64(&buf, 36 + 8, 0x2f000000);
    buf[36 + 20] = 0x10;
    put64(&buf, 36 + 24 + 32, 0x2f020000);
    discover(@intFromPtr(&buf), h.len);
    try std.testing.expectEqual(GicKind.v2, kind);
    try std.testing.expectEqual(@as(u64, 0x2f000000), dist_base);
    try std.testing.expectEqual(@as(u64, 0x2f020000), cpu_base);
    try std.testing.expectEqual(@as(u64, 0), redist_base);
}

test "gic: unversioned MADT infers v3 from GICR presence" {
    var buf: [512]u8 align(16) = undefined;
    const h = fixture_madt(&.{
        .{ .type = 0x0b, .len = 24, .bytes = &.{} },
        .{ .type = 0x0d, .len = 20, .bytes = &.{} },
    }, 36 + 24 + 20, &buf);
    put64(&buf, 36 + 8, 0x2f000000);
    buf[36 + 20] = 0xff; // "GIC version not identified"
    put64(&buf, 36 + 24 + 4, 0x2f100000);
    discover(@intFromPtr(&buf), h.len);
    try std.testing.expectEqual(GicKind.v3, kind);
    try std.testing.expectEqual(@as(u64, 0x2f100000), redist_base);
}

test "gic: unknown entry types are skipped; malformed lengths stop the walk" {
    var buf: [512]u8 align(16) = undefined;
    // An ITS (0x0E) entry before the GICD, then a GICD, then a broken
    // entry (length 1 < 2) that must stop the walk.
    const h = fixture_madt(&.{
        .{ .type = 0x0e, .len = 16, .bytes = &.{} },
        .{ .type = 0x0b, .len = 24, .bytes = &.{} },
    }, 36 + 16 + 24, &buf);
    // GICD starts after the 16-byte ITS entry: base at 36+16+8, version
    // byte at 36+16+20.
    put64(&buf, 36 + 16 + 8, 0x2f000000);
    buf[36 + 16 + 20] = 0x20;
    // Append a length-1 entry right after the GICD: walk must stop there.
    buf[36 + 16 + 24] = 0x0c;
    buf[36 + 16 + 24 + 1] = 1;
    discover(@intFromPtr(&buf), h.len + 2);
    try std.testing.expectEqual(GicKind.v3, kind);
    try std.testing.expectEqual(@as(u64, 0x2f000000), dist_base);
}

test "gic: absent/non-conformant MADT falls back to the VZ layout" {
    discover(0, 0);
    try std.testing.expectEqual(GicKind.v3, kind);
    try std.testing.expectEqual(@as(u64, 0x10000000), dist_base);
    try std.testing.expectEqual(@as(u64, 0x10010000), redist_base);
    var buf: [36]u8 align(16) = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[4..8], 36, .little); // header only, no entries
    discover(@intFromPtr(&buf), 36);
    try std.testing.expectEqual(GicKind.v3, kind);
}

test "gic: spurious sentinel is 1023 on both paths" {
    try std.testing.expect(is_spurious(1023));
    try std.testing.expect(!is_spurious(30));
    try std.testing.expect(!is_spurious(0));
}
