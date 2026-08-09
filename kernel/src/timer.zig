//! DipshitOS ARM generic timer (claim 7948 — roadmap item 5's remaining
//! half; delivers into the claim-9746 EL1 IRQ vector via the GIC).
//!
//! The EL1 *physical* timer (CNTP_*): the comparator CNTP_CVAL_EL0 is
//! armed to CNTPCT_EL0 + one second of ticks (CNTFRQ_EL0 gives the
//! frequency). When the count passes the comparator the timer raises its
//! PPI (group 1, conventionally 30 — the GTDT's Non-Secure EL1 timer GSIV
//! at offset 56 is authoritative), the GIC delivers it as an IRQ, the
//! claim-9746 vector runs, and the kernel's irq_dispatch calls
//! `handle()`: increment the tick counter, re-arm for the next period,
//! and every 5 ticks mark a heartbeat pending.
//!
//! The heartbeat is NOT printed from IRQ context (printing would re-enter
//! the polled virtio TX path mid-flush, and IRQ-context console writes are
//! not reentrancy-safe). Instead the shell idle loop calls `poll()` (to
//! consume a fired comparator when the GIC never signals — Apple VZ's
//! GICR is a RAZ/WI stub, claim 7948 evidence) and `maybe_heartbeat` in
//! the main context, where a print is safe. The IRQ handler itself is
//! console-free: ack -> handle -> eoi.
//!
//! Discovery (the GTDT's GSIV) runs PRE-EXIT (ACPI reads hang post-exit on
//! VZ, claim 0013); the GSIV lands in a global. Programming (init/arm)
//! runs POST-MMU, aarch64 only.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");
const builtin = @import("builtin");
const mmio = @import("mmio.zig");
const console = @import("console.zig");

/// Conventional EL1 physical-timer PPI when the GTDT is absent or silent.
pub const ppi_default: u32 = 30;
/// Heartbeat cadence: every N ticks.
pub const heartbeat_every: u64 = 5;
/// One tick period: 1 second.
pub const period_ns: u64 = 1_000_000_000;

// ---------------------------------------------------------------------------
// State (module globals; read by the monitor `timer` command)
// ---------------------------------------------------------------------------

/// Timer counter frequency (CNTFRQ_EL0), 0 until programmed.
pub var freq: u64 = 0;
/// The EL1 physical-timer PPI/GSIV (GTDT, pre-exit).
pub var ppi: u32 = ppi_default;
/// Ticks delivered since the timer was armed.
pub var ticks: u64 = 0;
var period_ticks: u64 = 0;
var armed_flag: bool = false;
var pending_heartbeat: bool = false;

/// True once `init` armed the timer on real hardware.
pub fn armed() bool {
    return armed_flag;
}

// ---------------------------------------------------------------------------
// Discovery (PRE-EXIT; called from the pci.zig ACPI walk on the GTDT)
// ---------------------------------------------------------------------------

/// Read the Non-Secure EL1 timer GSIV from the GTDT at offset 56; a zero
/// GSIV (or absent table) leaves the conventional PPI 30 in place.
pub fn discover(gtdt_addr: u64) void {
    if (gtdt_addr == 0) return;
    const gsiv = mmio.mmio_read32(gtdt_addr + 56);
    if (gsiv != 0 and gsiv < 1024) ppi = gsiv;
}

// ---------------------------------------------------------------------------
// Programming (POST-MMU, aarch64 only)
// ---------------------------------------------------------------------------

fn cntfrq() u64 {
    var v: u64 = 0;
    asm volatile ("mrs %[v], cntfrq_el0"
        : [v] "=r" (v),
    );
    return v;
}

fn cntpct() u64 {
    var v: u64 = 0;
    asm volatile ("mrs %[v], cntpct_el0"
        : [v] "=r" (v),
    );
    return v;
}

/// Arm (or re-arm) the comparator one period from now and enable the timer.
pub fn arm() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (period_ticks == 0) return;
    const cval = cntpct() + period_ticks;
    asm volatile ("msr cntp_cval_el0, %[v]"
        :
        : [v] "r" (cval),
    );
    asm volatile ("msr cntp_ctl_el0, %[v]"
        :
        : [v] "r" (@as(u64, 1)), // enable, IMASK=0
    );
    asm volatile ("isb");
}

/// Program the timer: read the frequency, compute the 1 s period, arm.
/// Caller is responsible for the GIC being programmed first (the PPI must
/// be enabled for the tick to be delivered) and for unmasking IRQs after.
pub fn init() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    freq = cntfrq();
    if (freq == 0) return;
    period_ticks = freq * period_ns / 1_000_000_000;
    arm();
    armed_flag = true;
}

/// The tick that actually fired. Host-safe: increments the counter and
/// marks the heartbeat; the asm (`arm`) stays out of host test processes.
pub fn on_tick() void {
    ticks += 1;
    if (ticks % heartbeat_every == 0) pending_heartbeat = true;
}

/// IRQ-context tick handler (called by the kernel's irq_dispatch when the
/// acknowledged INTID matches `ppi`). Console-free by design.
pub fn handle() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    on_tick();
    arm();
}

/// True when `intid` is this timer's PPI.
pub fn is_ppi(intid: u32) bool {
    return intid == ppi;
}

/// Consume a fired comparator in the MAIN context (the shell idle loop).
/// With a working GIC the IRQ handler re-arms before this runs, so the
/// comparator is always in the future and this is a no-op. On Apple VZ the
/// GICR is a RAZ/WI stub — no interrupt is ever presented to the CPU, for
/// PPIs, SGIs, or SPIs (claim 7948 live evidence) — so this poll is what
/// consumes the tick (one per period) and keeps the heartbeat cadence
/// honest. Never called from IRQ context; host-testable as a no-op on
/// non-aarch64.
pub fn poll() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (!armed_flag) return;
    var cval: u64 = 0;
    asm volatile ("mrs %[v], cntp_cval_el0"
        : [v] "=r" (cval),
    );
    if (cntpct() >= cval) {
        on_tick();
        arm();
    }
}

// ---------------------------------------------------------------------------
// Heartbeat (main context only — the shell idle loop)
// ---------------------------------------------------------------------------

/// Print the periodic heartbeat line if one is pending. Safe to call from
/// the main context; never from an IRQ handler.
pub fn maybe_heartbeat(con: *console.Console) void {
    if (!pending_heartbeat) return;
    pending_heartbeat = false;
    con.puts("timer heartbeat ticks=");
    con.print_u64(ticks);
    con.puts("\n");
}

// ---------------------------------------------------------------------------
// Tests (host-side; fixtures are RAM buffers, asm is aarch64-only)
// ---------------------------------------------------------------------------

test "timer: GTDT fixture yields the EL1 physical timer GSIV" {
    var buf: [96]u8 align(16) = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[56..60], 30, .little);
    ppi = 0;
    discover(@intFromPtr(&buf));
    try std.testing.expectEqual(@as(u32, 30), ppi);
}

test "timer: GTDT with zero GSIV keeps the conventional PPI" {
    var buf: [96]u8 align(16) = undefined;
    @memset(&buf, 0);
    ppi = ppi_default;
    discover(@intFromPtr(&buf));
    try std.testing.expectEqual(ppi_default, ppi);
    discover(0);
    try std.testing.expectEqual(ppi_default, ppi);
}

test "timer: heartbeat cadence is every 5 ticks and prints once" {
    var mock = console.MockConsole(1024){};
    var con = mock.console();
    var tick: u64 = 0;
    while (tick < 11) : (tick += 1) {
        on_tick();
        maybe_heartbeat(&con);
    }
    const out = mock.contents();
    // 11 ticks -> heartbeats at 5 and 10 -> two lines.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "timer heartbeat ticks="));
    try std.testing.expect(std.mem.indexOf(u8, out, "timer heartbeat ticks=5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "timer heartbeat ticks=10\n") != null);
    // The pending flag is consumed: another call prints nothing.
    mock.reset();
    maybe_heartbeat(&con);
    try std.testing.expectEqual(@as(usize, 0), mock.contents().len);
}

test "timer: ppi matching is exact" {
    ppi = 30;
    try std.testing.expect(is_ppi(30));
    try std.testing.expect(!is_ppi(29));
    try std.testing.expect(!is_ppi(31));
    try std.testing.expect(!is_ppi(1023));
}

test "timer: period math for a 1 s tick" {
    try std.testing.expectEqual(@as(u64, 24_000_000), 24_000_000 * period_ns / 1_000_000_000);
    try std.testing.expectEqual(@as(u64, 100_000_000), 100_000_000 * period_ns / 1_000_000_000);
}
