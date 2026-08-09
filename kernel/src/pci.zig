//! DipshitOS PCI config-space access + discovery (extracted verbatim from
//! the former kernel/src/main.zig junk drawer; claim 0023 mechanical split
//! — no behavior change).
//!
//! ECAM access, config-space read/write, bus-0 device discovery + BAR
//! decoding, and the ACPI walk (`dump_acpi`) that discovers the MCFG/ECAM
//! base (and dumps the SPCR/DBG2/FACP tables along the way). The ACPI walk
//! lives here because its purpose in this codebase is ECAM discovery for
//! the virtio-pci console — keeping it whole means the walk cannot drift.
//! All of it runs PRE-EXIT (firmware maps the ECAM window; post-exit it is
//! undeclared and the read could fault/hang).
//!
//! The virtio-pci transport (virtio_console.zig) drives the console via
//! `pci_ecam` + `pci_read32`; the probe/console driver in main.zig uses the
//! shared MMIO accessors from mmio.zig.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");
const uefi = std.os.uefi;
const SystemTable = uefi.tables.SystemTable;
const ConfigurationTable = uefi.tables.ConfigurationTable;
const mmio = @import("mmio.zig");
const evidence = @import("evidence.zig");
// Claim 7948: the ACPI walk also names the interrupt controller. The MADT
// (sig "APIC") and GTDT are parsed here, pre-exit, into the gic.zig /
// timer.zig discovery globals so the kernel can program them post-MMU.
const gic = @import("gic.zig");
const timer = @import("timer.zig");

/// Set from the MCFG table during dump_acpi; read by virtio_console.zig
/// for the console's config-space access.
pub var pci_ecam: u64 = 0;

/// Pre-exit ACPI discovery (claim 0013): locate the RSDP via the ACPI 2.0
/// config-table GUID (observed present in run 2), walk the RSDT/XSDT, and
/// dump every table's signature + address plus the raw first 96 bytes of the
/// SPCR (Serial Port Console Redirection — names the console UART and its
/// exact base) and DBG2 (debug ports) tables. This is the authoritative VZ
/// device list; it supersedes heuristic MMIO scanning. Tables live in
/// firmware RAM below 4 GiB (covered by the blanket map); reads are volatile.
/// (Historical note: claim 0013 first targeted post-exit discovery, then
/// observed post-exit window reads hang on VZ — hence the PRE-EXIT only
/// placement and the comment in the body below.)
pub fn dump_acpi(st: *const SystemTable) void {
    // Runs PRE-EXIT (all firmware RAM readable; the full buffer is persisted
    // once by the caller). ACPI tables are plain RAM below 4 GiB, so no MMIO
    // reads here — this cannot hit the post-exit fivars-region stall.
    evidence.dump_str("ACPI start\n");
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
        evidence.dump_str("ACPI: no RSDP config-table entry\n");
        return;
    }
    evidence.dump_str("ACPI RSDP @");
    evidence.dump_hex(rsdp_addr);
    evidence.dump_str("\n");
    // Revision sits at offset 15 (after sig+checksum+OEM ID); offset 8 is an
    // OEM ID byte. ACPI 2.0+ carries the XSDT address at +24.
    const revision = mmio.mmio_read8(rsdp_addr + 15);
    evidence.dump_str("ACPI rev=");
    evidence.dump_hex(revision);
    evidence.dump_str("\n");
    const is_xsdt = revision >= 2;
    const root_addr: u64 = if (is_xsdt) mmio.mmio_read64(rsdp_addr + 24) else mmio.mmio_read32(rsdp_addr + 16);
    if (root_addr == 0) {
        evidence.dump_str("ACPI: no RSDT/XSDT\n");
        return;
    }
    const root_len = mmio.mmio_read32(root_addr + 4);
    evidence.dump_str("ACPI root @");
    evidence.dump_hex(root_addr);
    evidence.dump_str(" len=");
    evidence.dump_hex(root_len);
    evidence.dump_str("\n");
    const stride: u64 = if (is_xsdt) 8 else 4;
    var off: u64 = 36;
    var count: usize = 0;
    while (off + stride <= root_len and count < 24) : (off += stride) {
        const taddr: u64 = if (is_xsdt) mmio.mmio_read64(root_addr + off) else mmio.mmio_read32(root_addr + off);
        if (taddr == 0 or taddr > 4 * 1024 * 1024 * 1024) continue;
        const sig = mmio.mmio_read32(taddr);
        evidence.dump_str("ACPI T=");
        evidence.dump_hex(sig);
        evidence.dump_str(" @");
        evidence.dump_hex(taddr);
        evidence.dump_str("\n");
        if (sig == 0x52504353) { // "SPCR" (LE)
            evidence.dump_str("SPCR\n");
            evidence.dump_raw(taddr, 96, "  ");
        }
        if (sig == 0x32474244) { // "DBG2" (LE)
            evidence.dump_str("DBG2\n");
            evidence.dump_raw(taddr, 96, "  ");
        }
        if (sig == 0x50434146) { // "FACP" (LE) — FADT
            // DSDT pointer at offset 40: the AML device list (claims the
            // platform's serial devices with _HID/_CRS base addresses).
            const dsdt = mmio.mmio_read32(taddr + 40);
            evidence.dump_str("FACP DSDT @");
            evidence.dump_hex(dsdt);
            evidence.dump_str("\n");
            if (dsdt != 0 and dsdt < 4 * 1024 * 1024 * 1024) {
                const dsdt_len = mmio.mmio_read32(dsdt + 4);
                evidence.dump_str("DSDT len=");
                evidence.dump_hex(dsdt_len);
                evidence.dump_str("\n");
                evidence.dump_raw(dsdt, 96, "DSDT");
            }
        }
        if (sig == 0x4746434d) { // "MCFG" (LE) — PCI ECAM base
            const ecam = mmio.mmio_read64(taddr + 44);
            pci_ecam = ecam;
            evidence.dump_str("MCFG ECAM @");
            evidence.dump_hex(ecam);
            evidence.dump_str("\n");
            dump_pci(ecam);
        }
        // Claims 7948/9187: the interrupt controller + timer live in ACPI
        // too. Parse the MADT (sig "APIC") for the GIC distributor /
        // redistributor / CPU-interface bases and the GTDT for the EL1
        // physical-timer PPI — PRE-EXIT (post-exit ACPI reads hang on VZ,
        // claim 0013). The parsed values are persisted through the evidence
        // dump so the host can see the real VZ GIC.
        if (sig == 0x43495041) { // "APIC" (LE) — MADT
            const len = mmio.mmio_read32(taddr + 4);
            gic.discover(taddr, len);
            evidence.dump_str("MADT GIC kind=");
            evidence.dump_str(gic.kind_name());
            evidence.dump_str(" dist=");
            evidence.dump_hex(gic.dist_base);
            evidence.dump_str(" redist=");
            evidence.dump_hex(gic.redist_base);
            evidence.dump_str(" cpu=");
            evidence.dump_hex(gic.cpu_base);
            evidence.dump_str("\n");
        }
        if (sig == 0x54445447) { // "GTDT" (LE)
            timer.discover(taddr);
            evidence.dump_str("GTDT timer ppi=");
            evidence.dump_hex(timer.ppi);
            evidence.dump_str("\n");
        }
        count += 1;
    }
}

pub fn pci_read32(ecam: u64, bus: u32, dev: u32, func: u32, off: u32) u32 {
    const addr = ecam | (@as(u64, bus) << 20) | (@as(u64, dev) << 15) | (@as(u64, func) << 12) | off;
    return mmio.mmio_read32(addr);
}

/// Present but unused by the current code (no BAR rebase pre/post-exit on
/// this milestone); kept verbatim with its original semantics.
pub fn pci_write32(ecam: u64, bus: u32, dev: u32, func: u32, off: u32, value: u32) void {
    const addr = ecam | (@as(u64, bus) << 20) | (@as(u64, dev) << 15) | (@as(u64, func) << 12) | off;
    mmio.mmio_write32(addr, value);
}

/// Byte-granular config-space read: the capability header fields sit at odd
/// offsets (c+1, c+3, c+4), and an unaligned 32-bit read on Device (nGnRnE)
/// memory is an alignment fault on ARMv8 — the cap walk MUST use byte reads
/// (claim 0013: every walk run faulted here, ladder M2_VPS04 → M2_VPS05 gap,
/// while the aligned/byte dumps in dump_pci survived).
pub fn pci_read8(ecam: u64, bus: u32, dev: u32, func: u32, off: u32) u8 {
    const addr = ecam | (@as(u64, bus) << 20) | (@as(u64, dev) << 15) | (@as(u64, func) << 12) | off;
    return mmio.mmio_read8(addr);
}

/// 32-bit config-space read assembled from four byte reads (safe at any
/// offset). Only for fields that may sit unaligned (capability header
/// payloads); the BAR/command fields at 0x10..0x24 stay aligned reads.
pub fn pci_read32_unaligned(ecam: u64, bus: u32, dev: u32, func: u32, off: u32) u32 {
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
pub fn dump_pci(ecam: u64) void {
    if (ecam == 0 or ecam > 4 * 1024 * 1024 * 1024) {
        evidence.dump_str("PCI: no ECAM\n");
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
            evidence.dump_str("PCI D=");
            evidence.dump_hex(dev);
            evidence.dump_str(" F=");
            evidence.dump_hex(func);
            evidence.dump_str(" VID=");
            evidence.dump_hex(vid);
            evidence.dump_str(" DID=");
            evidence.dump_hex(did);
            evidence.dump_str(" CLS=");
            evidence.dump_hex((pci_read32(ecam, 0, dev, func, 8) >> 8) & 0xffffff);
            var b: u32 = 0;
            while (b < 6) : (b += 1) {
                evidence.dump_str(" B");
                evidence.dump_hex(b);
                evidence.dump_str("=");
                evidence.dump_hex(pci_read32(ecam, 0, dev, func, 0x10 + b * 4));
            }
            evidence.dump_str("\n");
            found += 1;
        }
    }
    evidence.dump_str("PCI found=");
    evidence.dump_hex(found);
    evidence.dump_str("\n");
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
        evidence.dump_str("CFGSPACE D=");
        evidence.dump_hex(dev2);
        evidence.dump_str("\n");
        var w: u32 = 0;
        while (w < 0x80) : (w += 4) {
            evidence.dump_str("W ");
            evidence.dump_hex(w);
            evidence.dump_str("=");
            evidence.dump_hex(pci_read32(ecam, 0, dev2, 0, w));
            evidence.dump_str("\n");
        }
        break;
    }
}
