//! Claim 7896 (claim-6460 follow-up) class-D diagnostic: post-switch
//! walk-validity probe battery. After `install_identity_map()` (which since
//! claim 1517 always ends with the full `tlbi vmalle1` invalidation) read a
//! battery of sentinel addresses with volatile loads, each bracketed by an
//! NVRAM marker, to test whether the installed translation tables actually
//! resolve under the programmed T0SZ and to NAME the first address whose
//! walk (or MMIO read) does not return.
//!
//! Why this separates the start-level mismatch from the residual hang: at
//! the legacy T0SZ=25 (W=39) the 4 KiB stage-1 walk starts at level 1, but
//! the built tables are L0-rooted, so ANY fresh walk faults (ROOT[1..3] = 0
//! for VAs >= 1 GiB; misparsed descriptors below 1 GiB). The old no-TLBI
//! crutch (ADR 0006) hid this by riding stale firmware TLB entries; the
//! production fix (claim 1517) executes the TLBI with the corrected start
//! level T0SZ=16 (walk starts at level 0, matching the tables), so the
//! battery passes. A `-Dt0sz25` build faults deterministically right after
//! the switch (wp-depth 0).
//!
//! The battery is RAM-only plus the virtio BAR (a real device), so a read
//! can never hang on an unbacked Device window: P1 is the kernel's own BSS
//! (~2 GiB RAM), P2/P3 are conventional-RAM words above 1 GiB, P4 is the
//! first page of conventional RAM, P5 is the virtio-pci console BAR window
//! (readable pre-exit, claim 0013). Values are folded into `probe_sum`
//! (volatile) so the reads are observable and unelidable.
//!
//! Default builds do NOT contain this module: the call in main.zig is
//! comptime-gated and the linker eliminates it (default builds stay
//! byte-identical).
const std = @import("std");
const SystemTable = std.os.uefi.tables.SystemTable;
const mmio = @import("mmio.zig");
const evidence = @import("evidence.zig");

/// Fold target: written by every probe so the loads are observable and
/// unelidable (its own address is also probe P1 — a RAM walk control).
var probe_sum: u64 = 0;

/// Probe battery (VA == PA identity addresses, all mapped by the blanket or
/// the extra BAR window, all <= 2^39):
///   P2 ram-hi  — conventional RAM, high region (1.23 GiB)
///   P3 ram-mid — conventional RAM, mid region (1.22 GiB)
///   P4 ram-lo  — conventional RAM, first page (1 GiB + 4 KiB)
///   P5 bar     — the virtio-pci console BAR window (a real device)
const probes = [_]u64{
    0x4f000000,
    0x4e000000,
    0x40001000,
    0x100010000,
};

const wp_markers = [_]u64{
    evidence.marker_wp02,
    evidence.marker_wp03,
    evidence.marker_wp04,
    evidence.marker_wp05,
};

/// Run the battery. Each probe is a volatile u32 load; a marker is persisted
/// after each read returns. Death between M2_WP_0k and M2_WP_0(k+1) names
/// the first address that did not resolve.
pub fn run(st: *const SystemTable) void {
    evidence.write_marker_var(st, evidence.marker_wp00);
    // P1: the kernel's own BSS word (~2 GiB RAM) — proves the walk serves
    // RAM at the kernel's own VA before any other address is touched.
    probe_sum ^= @as(u64, mmio.mmio_read32(@intCast(@intFromPtr(&probe_sum))));
    evidence.write_marker_var(st, evidence.marker_wp01);
    for (probes, 0..) |addr, i| {
        probe_sum ^= @as(u64, mmio.mmio_read32(addr));
        evidence.write_marker_var(st, wp_markers[i]);
    }
}
