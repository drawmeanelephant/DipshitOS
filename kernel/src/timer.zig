//! VirelaiOS ARM generic timer (claims 7948/9187 — roadmap item 5's
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
/// WMP card 3: how long a RESCHEDULE NUDGE waits after a woken task becomes
/// runnable before the comparator fires. The 1 Hz period above is the wall
/// clock; this is the scheduling latency floor, and they are deliberately
/// different numbers. 2 ms sits far below a compositor frame (the measured
/// present's own transfer+flush is ~0.3 ms, a full WM loop is tens of ms) so
/// a woken task runs "now" in any user-visible sense, while staying long
/// enough that a wake burst coalesces into a single extra comparator fire
/// rather than an interrupt storm.
pub const nudge_period_ns: u64 = 2_000_000;

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
// WMP card 3 observability. `nudge_armed_total` counts comparators pulled
// forward; `nudge_served` counts those that actually delivered a nudge
// (the remainder were subsumed by the period boundary arriving first);
// `nudge_coalesced` counts requests that found one already in flight — the
// number that proves the coalescing rule is doing its job rather than the
// load simply being light. BSS counters only, IRQ-safe (same discipline as
// the tick counters above).
pub var nudge_armed_total: u64 = 0;
pub var nudge_served: u64 = 0;
pub var nudge_coalesced: u64 = 0;
pub var nudge_period_first: u64 = 0;
var period_ticks: u64 = 0;
/// Comparator delta for a reschedule nudge, derived once from CNTFRQ_EL0.
var nudge_ticks: u64 = 0;
/// Absolute CNTPCT value of the NEXT 1 Hz period boundary, as recorded by
/// `arm()`. A nudge moves the comparator off this value and `handle()` moves
/// it back, so the wall clock never loses or gains a second.
var period_deadline: u64 = 0;
/// A nudge is armed and the comparator is currently pulled forward of
/// `period_deadline`. At most one at a time (the coalescing rule).
var nudge_armed_flag: bool = false;
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

// ---------------------------------------------------------------------------
// Wall clock (#1058)
// ---------------------------------------------------------------------------
/// Boot-time Unix wall-clock seconds, captured from the handoff (EFI
/// RuntimeServices.GetTime in the loader), or `std.math.maxInt(u64)` when
/// the firmware gave no epoch.
pub var boot_epoch_secs: u64 = std.math.maxInt(u64);

/// Record the handoff's boot epoch once at kernel entry.
pub fn set_boot_epoch_secs(v: u64) void {
    boot_epoch_secs = v;
}

/// Current Unix wall-clock seconds: the boot epoch advanced by the elapsed
/// 1 Hz ticks. Null when no firmware epoch was captured (the honest uptime
/// fallback). Reads two module globals; no hardware, so it is host-testable
/// via `on_tick`.
pub fn wall_epoch() ?u64 {
    if (boot_epoch_secs == std.math.maxInt(u64)) return null;
    return boot_epoch_secs + ticks;
}

/// Current LOCAL seconds since midnight: `wall_epoch() % 86400`. Null when
/// there is no firmware epoch.
pub fn local_time_of_day() ?u64 {
    const e = wall_epoch() orelse return null;
    return e % 86_400;
}

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

/// Program the comparator to an absolute CNTPCT value and enable the timer.
fn program_cval(target: u64) void {
    asm volatile ("msr cntp_cval_el0, %[v]"
        :
        : [v] "r" (target),
    );
    asm volatile ("msr cntp_ctl_el0, %[v]"
        :
        : [v] "r" (@as(u64, 1)), // enable, IMASK=0
    );
    asm volatile ("isb");
}

/// Arm (or re-arm) the comparator one period from now and enable the timer.
pub fn arm() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (period_ticks == 0) return;
    const cval = cntpct() + period_ticks;
    period_deadline = cval;
    program_cval(cval);
}

/// WMP card 3: the pure arming decision, split out so the coalescing rule is
/// host-testable (`cntpct()`/CNTFRQ are unreachable in a host test binary, so
/// the counter arithmetic is the only part that can be pinned there). Returns
/// the absolute value to program, or null when the request is dropped:
/// either a nudge is already in flight (COALESCE — one comparator pull per
/// rotation, not one per wake) or the 1 Hz boundary is already at least as
/// soon as the nudge would be (nothing to gain, and pulling the comparator
/// would only move the wall clock).
pub fn nudge_target(nudge_in_flight: bool, now: u64, deadline: u64, delta: u64) ?u64 {
    if (nudge_in_flight) return null;
    const target = now + delta;
    if (target >= deadline) return null;
    return target;
}

/// WMP card 3: pull the comparator forward so the pending reschedule is
/// served in `nudge_period_ns` rather than at the next 1 Hz boundary. Called
/// by the scheduler from ordinary task context (an event push waking a
/// blocked task), never from the tick handler itself. IRQ-safe: BSS writes
/// plus two `msr`s, no console, no allocation, no lock.
///
/// The nudge rides whatever core's comparator the caller is on, so the
/// SCHEDULER is the layer that decides which core is worth nudging (there it
/// is core 0, whose PPI carries the rotation for the shell/desktop). This
/// function only refuses when the timer was never programmed.
pub fn nudge() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (period_ticks == 0 or nudge_ticks == 0) return;
    const target = nudge_target(nudge_armed_flag, cntpct(), period_deadline, nudge_ticks) orelse {
        if (nudge_armed_flag) nudge_coalesced +%= 1 else nudge_period_first +%= 1;
        return;
    };
    nudge_armed_flag = true;
    nudge_armed_total +%= 1;
    program_cval(target);
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

/// Issue #1163 (GOOS=virelai phase 0a): guarantee EL0 FP/ASIMD access.
/// The gc Go runtime is NEON-heavy (duffzero, GC bitmaps, string ops) and
/// dies at its first FPU instruction if CPACR_EL1.FPEN denies EL0 — the
/// kernel itself never wrote CPACR, so EL0 state was inherited from
/// firmware/VZ (untested territory until now). Arm FPEN=0b11 (full access
/// at EL0 and EL1); idempotent when already full access. Per-PE config,
/// so both init paths arm it (mirrors allow_el0_counter). No-op on
/// non-aarch64 hosts.
pub fn allow_el0_fpu() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    asm volatile ("msr cpacr_el1, %[v]"
        :
        : [v] "r" (@as(u64, 0b11 << 20)),
    );
    asm volatile ("isb");
}

/// Program the timer: read the frequency, compute the 1 s period, arm.
/// Caller is responsible for the GIC being programmed first (the PPI must
/// be enabled for the tick to be delivered) and for unmasking IRQs after.
pub fn init() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    allow_el0_counter();
    allow_el0_fpu();
    freq = cntfrq();
    if (freq == 0) return;
    period_ticks = freq * period_ns / 1_000_000_000;
    nudge_ticks = freq * nudge_period_ns / 1_000_000_000;
    arm();
    armed_flag = true;
}

/// Initialize local physical timer for a secondary CPU core.
pub fn init_secondary() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    allow_el0_counter();
    allow_el0_fpu();
    arm();
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
///
/// Returns TRUE when this delivery was the **1 Hz period boundary** — the
/// caller may advance the wall clock (scheduler `on_tick`: tick_count,
/// sleepers, app timers, WM pacing, CPU accounting) — and FALSE when it
/// served a **reschedule nudge**, which must NOT be mistaken for a second
/// passing. WMP card 3 hangs the whole "a woken task runs promptly" change
/// on that distinction: the fix pays for scheduling latency out of shared
/// wall-clock ticks, so the period must stay exactly 1 Hz while extra,
/// uncounted comparator fires appear between them.
pub fn handle() bool {
    if (comptime builtin.cpu.arch != .aarch64) return true;
    if (nudge_armed_flag and cntpct() < period_deadline) {
        // A nudge: the comparator was pulled forward to serve a pending
        // reschedule, not to mark a second. Record NO tick — that is the
        // whole point — and put the comparator back on the boundary the wall
        // clock is keeping, so the next period arrives on schedule.
        nudge_armed_flag = false;
        nudge_served +%= 1;
        program_cval(period_deadline);
        return false;
    }
    // The period boundary. This also subsumes a nudge that was still armed:
    // the rotation it owed is about to run anyway, so there is nothing left
    // for it to serve and the flag must not survive into the next period.
    nudge_armed_flag = false;
    record_tick(.irq);
    arm();
    return true;
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

test "timer: wall_epoch tracks the boot epoch and local_time_of_day wraps (#1058)" {
    const saved = boot_epoch_secs;
    const saved_ticks = ticks;
    defer {
        boot_epoch_secs = saved;
        ticks = saved_ticks;
    }

    // No firmware epoch captured: the honest null (uptime fallback).
    set_boot_epoch_secs(std.math.maxInt(u64));
    ticks = 0;
    try std.testing.expectEqual(@as(?u64, null), wall_epoch());
    try std.testing.expectEqual(@as(?u64, null), local_time_of_day());

    // Boot epoch + elapsed seconds.
    const boot = 1_789_043_696; // 2026-09-10 12:34:56 wall-clock
    set_boot_epoch_secs(boot);
    ticks = 0;
    try std.testing.expectEqual(@as(?u64, boot), wall_epoch());
    try std.testing.expectEqual(@as(?u64, 12 * 3600 + 34 * 60 + 56), local_time_of_day());

    // 20 s later is 12:35:16 the same day.
    ticks = 20;
    try std.testing.expectEqual(@as(?u64, boot + 20), wall_epoch());
    try std.testing.expectEqual(@as(?u64, 12 * 3600 + 35 * 60 + 16), local_time_of_day());

    // A boot at 23:59:50 crosses midnight: 00:00:10 the next day.
    set_boot_epoch_secs(boot - (12 * 3600 + 34 * 60 + 56) + 23 * 3600 + 59 * 60 + 50);
    ticks = 20;
    try std.testing.expectEqual(@as(?u64, 10), local_time_of_day());
}

// ---------------------------------------------------------------------------
// WMP card 3 — the reschedule nudge's arming rule
// ---------------------------------------------------------------------------

// The nudge is the answer to WMP card 1's measurement: round-robin evaluated
// preemption only at the 1 Hz tick, so a woken WM waited 786-1216 ms typical
// and 3004 ms worst for its frame. Pulling the comparator forward serves the
// owed rotation in ~2 ms instead.
//
// Only the DECISION is reachable from a host test — `cntpct()` returns 0
// under `builtin.is_test` and `arm()` never programs a comparator without a
// CNTFRQ — so the counter arithmetic (`nudge_target`) is pinned here and the
// real arming/delivery split is pinned live by the class-B `live-wm-pacing`
// gate, which reads `nudge_armed`/`nudge_served` off the pacing row.
test "timer: nudge_target pulls the comparator forward, coalesces, and yields to the period" {
    const deadline: u64 = 10_000_000;
    const delta: u64 = 48_000; // 2 ms at a 24 MHz counter

    // The ordinary case: nothing in flight and the period is far enough away
    // that 2 ms from now genuinely beats it. This is the arm that makes a
    // woken task run promptly.
    try std.testing.expectEqual(@as(?u64, 1_000 + delta), nudge_target(false, 1_000, deadline, delta));

    // COALESCE: a nudge is already in flight, so the caller's demand is
    // absorbed rather than armed again. This is the rule that caps a wake
    // burst at ONE extra comparator fire — without it every wake in a pointer
    // storm would arm its own interrupt and the comparator would never stop.
    try std.testing.expectEqual(@as(?u64, null), nudge_target(true, 1_000, deadline, delta));
    try std.testing.expectEqual(@as(?u64, null), nudge_target(true, 9_999_999, deadline, delta));

    // The 1 Hz boundary is already at least as soon as the nudge would be:
    // arming would move the wall clock for no scheduling gain, so the request
    // is dropped and the period serves the owed rotation.
    try std.testing.expectEqual(@as(?u64, null), nudge_target(false, deadline, deadline, delta));
    try std.testing.expectEqual(@as(?u64, null), nudge_target(false, deadline - 1, deadline, delta));

    // Exactly touching the boundary is the edge: a target of `deadline` is
    // NOT strictly sooner, so the period wins and no second is at risk; one
    // tick earlier still arms.
    try std.testing.expectEqual(@as(?u64, deadline - 1), nudge_target(false, deadline - delta - 1, deadline, delta));
    try std.testing.expectEqual(@as(?u64, null), nudge_target(false, deadline - delta, deadline, delta));
}

test "timer: the nudge period is far below the frame it serves and far above an interrupt storm" {
    // The two constants are a deliberate pair and both must hold: the nudge
    // has to be invisible next to the work it unblocks (a WM loop is tens of
    // ms; even a present's own transfer+flush is ~0.3 ms), and it must not be
    // so short that the comparator is pulled forward for every wake.
    try std.testing.expect(nudge_period_ns <= period_ns / 100);
    try std.testing.expect(nudge_period_ns >= 1_000_000);
    // At the counter frequency the guest actually sees, the delta is not zero
    // ticks — a zero delta would re-arm the comparator to "now" and spin.
    try std.testing.expect(24_000_000 * nudge_period_ns / 1_000_000_000 > 0);
}
