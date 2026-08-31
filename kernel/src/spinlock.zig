//! VirelaiOS kernel spinlock synchronization primitives (Milestone 28, claim 6438).
//!
//! Provides mutual exclusion across multi-core processors (AArch64 SMP) without
//! allocation or external dependencies.
//!
//! No libc, no POSIX, no heap allocation.

const std = @import("std");
const builtin = @import("builtin");

/// BSS-resident mutual exclusion spinlock.
pub const Spinlock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub const unlocked_val: u32 = 0;
    pub const locked_val: u32 = 1;

    /// Initialize a spinlock.
    pub fn init() Spinlock {
        return .{ .state = std.atomic.Value(u32).init(unlocked_val) };
    }

    /// Acquire the spinlock, spinning until available.
    pub fn lock(self: *Spinlock) void {
        while (self.state.cmpxchgWeak(unlocked_val, locked_val, .acquire, .monotonic) != null) {
            if (builtin.cpu.arch == .aarch64) {
                asm volatile ("yield");
            }
        }
    }

    /// Try to acquire the spinlock without blocking.
    /// Returns true if the lock was acquired, false otherwise.
    pub fn try_lock(self: *Spinlock) bool {
        return self.state.cmpxchgWeak(unlocked_val, locked_val, .acquire, .monotonic) == null;
    }

    /// Release the spinlock.
    pub fn unlock(self: *Spinlock) void {
        self.state.store(unlocked_val, .release);
    }

    /// Check if currently locked (snapshot).
    pub fn is_locked(self: *const Spinlock) bool {
        return self.state.load(.monotonic) != unlocked_val;
    }
};

/// Spinlock wrapper that saves and disables local CPU IRQs during the critical section.
pub const IrqSaveSpinlock = struct {
    lock_impl: Spinlock = Spinlock.init(),

    pub fn lock(self: *IrqSaveSpinlock) u64 {
        const daif = disable_irq_save();
        self.lock_impl.lock();
        return daif;
    }

    pub fn unlock(self: *IrqSaveSpinlock, saved_daif: u64) void {
        self.lock_impl.unlock();
        restore_irq(saved_daif);
    }
};

fn disable_irq_save() u64 {
    if (comptime builtin.cpu.arch == .aarch64) {
        var daif: u64 = 0;
        asm volatile ("mrs %[v], daif"
            : [v] "=r" (daif),
        );
        asm volatile ("msr daifset, #2"); // Mask IRQ (bit 1)
        return daif;
    }
    return 0;
}

fn restore_irq(saved_daif: u64) void {
    if (comptime builtin.cpu.arch == .aarch64) {
        asm volatile ("msr daif, %[v]"
            :
            : [v] "r" (saved_daif),
        );
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "spinlock: basic uncontended lock and unlock" {
    var sl = Spinlock.init();
    try std.testing.expect(!sl.is_locked());
    sl.lock();
    try std.testing.expect(sl.is_locked());
    sl.unlock();
    try std.testing.expect(!sl.is_locked());
}

test "spinlock: try_lock behavior" {
    var sl = Spinlock.init();
    try std.testing.expect(sl.try_lock());
    try std.testing.expect(sl.is_locked());
    try std.testing.expect(!sl.try_lock());
    sl.unlock();
    try std.testing.expect(!sl.is_locked());
    try std.testing.expect(sl.try_lock());
    sl.unlock();
}

test "spinlock: concurrent multi-threaded stress test" {
    const Context = struct {
        sl: *Spinlock,
        counter: *u32,
        iterations: usize,

        fn run(ctx: @This()) void {
            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                ctx.sl.lock();
                ctx.counter.* += 1;
                ctx.sl.unlock();
            }
        }
    };

    var sl = Spinlock.init();
    var counter: u32 = 0;
    const iterations = 50_000;

    const t1 = try std.Thread.spawn(.{}, Context.run, .{Context{
        .sl = &sl,
        .counter = &counter,
        .iterations = iterations,
    }});
    const t2 = try std.Thread.spawn(.{}, Context.run, .{Context{
        .sl = &sl,
        .counter = &counter,
        .iterations = iterations,
    }});

    t1.join();
    t2.join();

    try std.testing.expectEqual(@as(u32, iterations * 2), counter);
}
