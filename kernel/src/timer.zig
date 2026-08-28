//! DipshitOS ARM generic timer (claims 7948/9187 — roadmap item 5's
//! remaining half; delivers into claim 9746's EL1 IRQ vector via the GIC).
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
//! Output is NOT written from IRQ context (printing would re-enter the
//! polled virtio TX path mid-flush, and IRQ-context console writes are not
//! reentrancy-safe). Instead the shell idle loop calls `maybe_heartbeat`
//! in main context. Claim 9187 removed the old production `poll()` call
//! after observing it race working IRQ delivery. Separate IRQ/poll counters
//! make the delivery source observable and prevent a diagnostic poll from
//! being mistaken for an interrupt.
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
/// GTDT trigger mode for the Non-Secure EL1 timer: false=level, true=edge.
pub var interrupt_edge: bool = false;
/// Ticks delivered since the timer was armed.
pub var ticks: u64 = 0;
/// Ticks that entered through the EL1 IRQ vector.
pub var irq_ticks: u64 = 0;
/// Ticks consumed by an explicit diagnostic comparator poll.
pub var poll_ticks: u64 = 0;
var period_ticks: u64 = 0;
var armed_flag: bool = false;
var pending_heartbeat: bool = false;
var pending_irq_report: bool = false;
// Snapshots taken when the flags are set (claim 5275): with the scheduler
// preempting the shell between ticks, the shell prints these lines from a
// later idle loop, so the live counters at print time would overstate the
// event. The snapshot describes the event itself (tick 5, irq 5), which is
// also what the live gates assert.
var heartbeat_ticks: u64 = 0;
var heartbeat_irq: u64 = 0;
var heartbeat_poll: u64 = 0;
var irq_report_irq: u64 = 0;

/// True once `init` armed the timer on real hardware.
pub fn armed() bool {
    return armed_flag;
}

// ---------------------------------------------------------------------------
// Discovery (PRE-EXIT; called from the pci.zig ACPI walk on the GTDT)
// ---------------------------------------------------------------------------

/// Read the Non-Secure EL1 timer GSIV and flags from the GTDT at offsets
/// 56 and 60. ACPI GTDT flags bit 0 is the trigger mode (0=level, 1=edge).
/// A zero GSIV (or absent table) leaves the conventional PPI 30 in place.
pub fn discover(gtdt_addr: u64) void {
    if (gtdt_addr == 0) return;
    const gsiv = mmio.mmio_read32(gtdt_addr + 56);
    if (gsiv != 0 and gsiv < 1024) ppi = gsiv;
    interrupt_edge = (mmio.mmio_read32(gtdt_addr + 60) & 1) != 0;
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

/// Read the physical counter register (CNTPCT_EL0) on AArch64; 0 in host tests or on non-aarch64.
pub fn cntpct() u64 {
    if (comptime builtin.cpu.arch != .aarch64 or builtin.is_test) return 0;
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

/// Grant EL0 access to the counter registers (CNTPCT_EL0, CNTFRQ_EL0,
/// CNTP_CTL_EL0) so EL0 processes can read time without a syscall slot.
/// M24 K13/K14 (calc/dates.zig `now()`) read CNTPCT_EL0/CNTFRQ_EL0
/// directly — the march card claims "EL0-accessible", which is only true
/// once CNTKCTL_EL1.EL0PCTEN is set. Without it, an EL0 `mrs cntpct_el0`
/// traps as a data abort (far=0, ec=0x18) and the fault dispatcher reaps
/// the process (observed live: CALC's `r` key, verify-live-calc-depth).
/// Set EL0PCTEN|EL0VCTEN|EL0PTEN|EL0VTEN (bits 0-3). No-op on non-aarch64
/// hosts (never meaningful in a host test process).
pub fn allow_el0_counter() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    asm volatile ("msr cntkctl_el1, %[v]"
        :
        : [v] "r" (@as(u64, 0b1111)),
    );
    asm volatile ("isb");
}

/// Program the timer: read the frequency, compute the 1 s period, arm.
/// Caller is responsible for the GIC being programmed first (the PPI must
/// be enabled for the tick to be delivered) and for unmasking IRQs after.
pub fn init() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    allow_el0_counter();
    freq = cntfrq();
    if (freq == 0) return;
    period_ticks = freq * period_ns / 1_000_000_000;
    arm();
    armed_flag = true;
}

const TickSource = enum { test_only, irq, poll };

/// Record a fired comparator and where it was consumed. Host tests use
/// `.test_only`; only the real IRQ and polling paths alter their source
/// counters.
fn record_tick(source: TickSource) void {
    ticks += 1;
    switch (source) {
        .test_only => {},
        .irq => {
            irq_ticks += 1;
            if (irq_ticks == 1) {
                pending_irq_report = true;
                irq_report_irq = irq_ticks;
            }
        },
        .poll => poll_ticks += 1,
    }
    if (ticks % heartbeat_every == 0) {
        pending_heartbeat = true;
        heartbeat_ticks = ticks;
        heartbeat_irq = irq_ticks;
        heartbeat_poll = poll_ticks;
    }
}

/// Host-safe test hook: advances the cadence without claiming an IRQ or
/// poll delivery source.
pub fn on_tick() void {
    record_tick(.test_only);
}

/// IRQ-context tick handler (called by the kernel's irq_dispatch when the
/// acknowledged INTID matches `ppi`). Console-free by design.
pub fn handle() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    record_tick(.irq);
    arm();
}

/// True when `intid` is this timer's PPI.
pub fn is_ppi(intid: u32) bool {
    return intid == ppi;
}

/// Diagnostic-only comparator poll. Production does not call this: polling
/// a level-signalled comparator can race a pending IRQ and double-consume a
/// period. The separate `poll_ticks` counter makes any deliberate use
/// explicit. Never call from IRQ context; host-testable as a no-op on
/// non-aarch64.
pub fn poll() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (!armed_flag) return;
    var cval: u64 = 0;
    asm volatile ("mrs %[v], cntp_cval_el0"
        : [v] "=r" (cval),
    );
    if (cntpct() >= cval) {
        record_tick(.poll);
        arm();
    }
}

// ---------------------------------------------------------------------------
// Heartbeat (main context only — the shell idle loop)
// ---------------------------------------------------------------------------

/// Print the periodic heartbeat line if one is pending. Safe to call from
/// the main context; never from an IRQ handler.
pub fn maybe_heartbeat(con: *console.Console) void {
    if (pending_irq_report) {
        pending_irq_report = false;
        con.puts("timer irq delivered ppi=");
        con.print_hex_min(ppi);
        con.puts(" irq_ticks=");
        con.print_u64(irq_report_irq);
        con.puts("\n");
    }
    if (pending_heartbeat) {
        pending_heartbeat = false;
        con.puts("timer heartbeat ticks=");
        con.print_u64(heartbeat_ticks);
        con.puts(" irq=");
        con.print_u64(heartbeat_irq);
        con.puts(" poll=");
        con.print_u64(heartbeat_poll);
        con.puts("\n");
    }
}

// ---------------------------------------------------------------------------
// Tests (host-side; fixtures are RAM buffers, asm is aarch64-only)
// ---------------------------------------------------------------------------

test "timer: GTDT fixture yields the EL1 physical timer GSIV" {
    var buf: [96]u8 align(16) = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[56..60], 30, .little);
    std.mem.writeInt(u32, buf[60..64], 1, .little);
    ppi = 0;
    interrupt_edge = false;
    discover(@intFromPtr(&buf));
    try std.testing.expectEqual(@as(u32, 30), ppi);
    try std.testing.expect(interrupt_edge);
}

test "timer: GTDT with zero GSIV keeps the conventional PPI" {
    var buf: [96]u8 align(16) = undefined;
    @memset(&buf, 0);
    ppi = ppi_default;
    interrupt_edge = true;
    discover(@intFromPtr(&buf));
    try std.testing.expectEqual(ppi_default, ppi);
    try std.testing.expect(!interrupt_edge);
    discover(0);
    try std.testing.expectEqual(ppi_default, ppi);
}

test "timer: heartbeat cadence is every 5 ticks and prints once" {
    var mock = console.MockConsole(1024){};
    var con = mock.console();
    ticks = 0;
    irq_ticks = 0;
    poll_ticks = 0;
    pending_heartbeat = false;
    pending_irq_report = false;
    var tick: u64 = 0;
    while (tick < 11) : (tick += 1) {
        on_tick();
        maybe_heartbeat(&con);
    }
    const out = mock.contents();
    // 11 ticks -> heartbeats at 5 and 10 -> two lines.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "timer heartbeat ticks="));
    try std.testing.expect(std.mem.indexOf(u8, out, "timer heartbeat ticks=5 irq=0 poll=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "timer heartbeat ticks=10 irq=0 poll=0\n") != null);
    // The pending flag is consumed: another call prints nothing.
    mock.reset();
    maybe_heartbeat(&con);
    try std.testing.expectEqual(@as(usize, 0), mock.contents().len);
}

test "timer: first IRQ is reported separately from heartbeat cadence" {
    var mock = console.MockConsole(1024){};
    var con = mock.console();
    ticks = 0;
    irq_ticks = 0;
    poll_ticks = 0;
    ppi = 30;
    pending_heartbeat = false;
    pending_irq_report = false;
    record_tick(.irq);
    maybe_heartbeat(&con);
    try std.testing.expectEqualStrings(
        "timer irq delivered ppi=0x1e irq_ticks=1\n",
        mock.contents(),
    );
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
