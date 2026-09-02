//! VirelaiOS userspace-service gate (claim 9498: unpinned user tasks on any
//! core).
//!
//! One holder-tracked, IRQ-masking spinlock serializing every entry into
//! the kernel's shared user-visible service state — user syscalls (any
//! core), EL1h monitor commands (core 0), the exit/fault teardown, and
//! demand-paging faults. The gate is COARSE by design: the file, window,
//! network, mailbox, events, timer, and registry subsystems were all
//! written single-core and share module globals; per-subsystem locks would
//! need an audit of every cross-module call chain. One gate restores the
//! single-core semantic ("the kernel is single-threaded through any
//! userspace service entry") on the multi-vCPU VM.
//!
//! Why IRQ-masking matters (the claim-2369 serial-lock lesson): a holder
//! whose IRQs stay enabled can be preempted mid-critical-section (a tick
//! switching tasks), and a masked spinner on the same core would then wait
//! forever — the preempted holder never gets a quantum. Masking IRQs for
//! the whole hold means a holder ALWAYS runs to completion, so any
//! context — SVC (already masked), main, fault/exception (masked) — may
//! spin safely. Cross-core contention is bounded by the holder completing.
//!
//! The IRQ tick (core 0, the compositor/app-timer/CPU-limit work) may NOT
//! spin — it runs on a core whose main context can hold the gate. It uses
//! `try_acquire` and skips the beat when the gate is busy (a 1 s cadence
//! loss on contention is far cheaper than a cross-core race, and syscalls
//! are short so contention at tick time is rare).
//!
//! The core count is a literal and the core id is read host-guarded from
//! MPIDR_EL1, exactly like claim 7339's `resume_cores` — importing smp
//! here would cycle smp -> exceptions -> usergate -> smp (exceptions must
//! gate its demand-paging path).
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");
const builtin = @import("builtin");
const spinlock = @import("spinlock.zig");

/// CPU count (matches smp.max_cores); literal to dodge the smp import cycle.
pub const cores: usize = 4;

fn core_id() usize {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    var mpidr: u64 = 0;
    asm volatile ("mrs %[v], mpidr_el1"
        : [v] "=r" (mpidr),
    );
    const aff0: usize = @intCast(mpidr & 0xFF);
    return if (aff0 < cores) aff0 else 0;
}

/// The gate itself (a plain spinlock; IRQ masking is done explicitly so
/// the try path can skip the mask when already masked).
var gate = spinlock.Spinlock{};
/// The core currently inside the gate (`cores` = nobody). A same-core
/// reentry (the exit teardown inside a syscall) must proceed — the outer
/// hold already serialized.
var holder: usize = cores;
/// The pre-acquire DAIF per core, restored by the matching release. Only
/// the outermost (acquiring) hold on a core writes it; reentrant holds
/// skip acquire entirely, so the slot holds exactly one outstanding save.
var saved_daif: [cores]u64 = [_]u64{ 0, 0, 0, 0 };

fn mask_irq_save() u64 {
    // Host test binaries run at EL0 (`mrs daif` is illegal there), so
    // exclude tests even on Apple Silicon hosts.
    if (comptime !builtin.is_test and builtin.cpu.arch == .aarch64) {
        var daif: u64 = 0;
        asm volatile ("mrs %[v], daif"
            : [v] "=r" (daif),
        );
        asm volatile ("msr daifset, #2"); // Mask IRQ (bit 1)
        return daif;
    }
    return 0;
}

fn restore_irq(saved: u64) void {
    if (comptime !builtin.is_test and builtin.cpu.arch == .aarch64) {
        asm volatile ("msr daif, %[v]"
            :
            : [v] "r" (saved),
        );
    }
}

/// Enter the gate (spinning). Callers: the SVC syscall dispatch on any
/// core, the EL1h monitor command dispatch, the exit/fault teardown, and
/// demand-paging fault handling. IRQs are masked for the whole hold so the
/// holder can never be preempted mid-critical-section.
pub fn acquire() void {
    const c = core_id();
    saved_daif[c] = mask_irq_save();
    gate.lock();
    holder = c;
}

/// Leave the gate, restoring the pre-acquire IRQ state. Must pair with the
/// matching `acquire` (or a successful `try_acquire`) on the same core.
pub fn release() void {
    const c = core_id();
    holder = cores;
    gate.unlock();
    restore_irq(saved_daif[c]);
}

/// True when the calling core already holds the gate (a reentrant entry —
/// e.g. the exit teardown inside a syscall). Reentrant callers must NOT
/// acquire again; they proceed under the outer hold and must NOT release
/// (the outer pair does).
pub fn held() bool {
    return holder == core_id();
}

/// Try to enter the gate without blocking (IRQ tick path). Returns false —
/// and touches nothing — when the gate is busy OR when the calling core
/// already holds it: the IRQ tick can fire over a paused main-context
/// holder on the same core only if that holder did NOT mask IRQs, which
/// this gate's acquire always does — but a same-core hit is still refused
/// so a reentrant tick beat never mutates state a paused holder is
/// mid-way through (the claim-2369 `heap-oworker` interleave,
/// structurally). Callers skip their beat.
pub fn try_acquire() bool {
    const c = core_id();
    if (holder == c) return false;
    if (!gate.try_lock()) return false;
    saved_daif[c] = mask_irq_save(); // already masked in IRQ context; the restore is a no-op
    holder = c;
    return true;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "usergate: acquire/release round-trips and held() tracks the core" {
    try std.testing.expect(!held());
    acquire();
    defer release();
    try std.testing.expect(held());
}

test "usergate: try_acquire skips when the calling core already holds" {
    acquire();
    defer release();
    // Same-core reentry must be refused: the caller skips its beat instead
    // of proceeding into a paused critical section.
    try std.testing.expect(!try_acquire());
}

test "usergate: try_acquire succeeds when free and pairs with release" {
    try std.testing.expect(try_acquire());
    try std.testing.expect(held());
    release();
    try std.testing.expect(!held());
    // And a fresh acquire after release is a new hold.
    try std.testing.expect(try_acquire());
    release();
    try std.testing.expect(!held());
}
