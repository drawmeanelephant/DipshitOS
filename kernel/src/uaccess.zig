//! DipshitOS milestone-three uaccess card (claim 6120), extended by the
//! per-task address-space card (claim 5804).
//!
//! Fault-safe, bounded user-memory transfer primitives over the EL0
//! apertures. Since claim 5804 the EL0 task runs in its own address space:
//! the apertures are USER VAs (`text_va`/`stack_va`) mapped only by the
//! user root, and the kernel reaches them through whichever TTBR0 is live
//! (the user root during the task's syscalls; the monitor diagnostic swaps
//! to it explicitly). Two layers make a bad pointer safe:
//!
//!   1. **Validation before access** — `copy_in`/`copy_out` require the whole
//!      range to sit inside a configured EL0 region (user text is readable,
//!      user stack is read-write) with no wrap-around, before any memory is
//!      touched. Everything else (kernel RAM, MMIO, above the identity
//!      blanket, overflow) returns `EFAULT` without dereferencing.
//!   2. **Fault recovery as a second line** — the copy runs inside a masked
//!      "uaccess window". A synchronous data abort (ESR EC 0x24/0x25) taken
//!      while the window is active is a bad user pointer, not a kernel bug:
//!      the claim-9746 exception path calls `try_recover`, which latches the
//!      fault and advances ELR past the 4-byte faulting instruction so the
//!      copy loop resumes, observes the latch, and returns `EFAULT` instead
//!      of crashing EL1. The window is the only code that dereferences user
//!      memory, so every data abort inside it is attributable to a bad user
//!      pointer. IRQs are masked for the window (they are already masked
//!      inside SVC handlers; the monitor diagnostic masks them explicitly),//! so no unrelated task can fault inside the window.
//!
//! No allocation, no libc, no POSIX. The latch is a plain BSS flag written
//! only by the synchronous handler on the same core; the copy's post-loop
//! check keeps the EFAULT contract correct even if an optimizer hoists the
//! in-loop check.

const std = @import("std");
const builtin = @import("builtin");
const mmu = @import("mmu.zig");

/// Result of a bounded transfer. `ok` means the whole range was copied;
/// `fault` means the pointer was bad (validation or a recovered fault) and
/// the syscall layer returns EFAULT.
pub const Outcome = enum { ok, fault };

pub const Region = struct { base: u64, len: u64 };

/// EFAULT as the frozen syscall ABI returns it (the x0 bit pattern of -3;
/// ADR 0007 row -3).
pub const efault: u64 = @bitCast(@as(i64, -3));

/// Diagnostic probe address for the monitor `uaccess` command: 512 MiB above
/// the identity blanket's 4 GiB end, outside every observed VZ device window
/// (console BAR `0x1_0001_0000`, virtio-blk and custom-virtio BARs), so a
/// read is a guaranteed translation fault at EL1 while the uaccess window is
/// active. Revisit if the blanket or BAR placement ever grows.
pub const diagnostic_unmapped: u64 = 0x1_2000_0000;

/// EL0-readable regions (copy-in sources): user text (RX) + user stack (RW) + dynamic segments.
var read_regions: [8]Region = [_]Region{.{ .base = 0, .len = 0 }} ** 8;
var read_region_count: usize = 0;
/// EL0-writable regions (copy-out destinations): the user stack only — the
/// text aperture is read-only at EL0, so copying into it is a permission
/// fault (rejected at validation).
var write_regions: [8]Region = [_]Region{.{ .base = 0, .len = 0 }} ** 8;
var write_region_count: usize = 0;

/// The window state is VOLATILE on purpose. `window_active` has no reader
/// inside the copy loop, so without volatile semantics the optimizer
/// (ReleaseSmall + LTO, with the probe address and BSS addresses as known
/// constants) can legally sink the `window_active = true` store below the
/// first user-memory load — then when that load faults, the exception path
/// reads `window_active` as still false and parks instead of recovering
/// (observed: `[EXC] parking` with far=diagnostic_unmapped on the first
/// live run). Volatile accesses cannot be reordered across the copy's
/// memory operations, so the handler always observes the window open at the
/// moment of the fault; the compiler barrier pins it for good measure.
///
/// True while a bounded copy is executing. The claim-9746 synchronous path
/// checks this before converting a data abort into EFAULT.
var window_active: bool = false;
/// Set by `try_recover` when a data abort inside the window was consumed.
/// The copy loop breaks on it and returns `.fault`.
var fault_latch: bool = false;
/// DAIF to restore when the window closes (main-context monitor diagnostic;
/// SVC context already entered with IRQs masked and restores the same value).
var saved_daif: u64 = 0;

fn window_active_read() bool {
    return @as(*volatile bool, &window_active).*;
}

fn set_window_active(value: bool) void {
    @as(*volatile bool, &window_active).* = value;
}

fn latch_read() bool {
    return @as(*volatile bool, &fault_latch).*;
}

fn set_latch(value: bool) void {
    @as(*volatile bool, &fault_latch).* = value;
}

/// Compiler barrier: no memory operation may move across it. Pins the
/// window-open stores before the copy loop and the copy before the
/// window-close stores.
fn compiler_barrier() void {
    asm volatile ("" ::: .{ .memory = true });
}

var copies_value: u64 = 0;
var validation_faults_value: u64 = 0;
var recoveries_value: u64 = 0;

pub const Stats = struct {
    copies: u64,
    validation_faults: u64,
    recoveries: u64,
};

/// Reset module state (kernel boot / host tests). Regions are re-configured
/// with `set_regions` immediately after.
pub fn init() void {
    read_regions = [_]Region{.{ .base = 0, .len = 0 }} ** 8;
    write_regions = [_]Region{.{ .base = 0, .len = 0 }} ** 8;
    read_region_count = 0;
    write_region_count = 0;
    set_window_active(false);
    set_latch(false);
    saved_daif = 0;
    copies_value = 0;
    validation_faults_value = 0;
    recoveries_value = 0;
}

/// Configure the claim-8215 EL0 apertures (text readable, stack read-write).
/// The syscall layer delegates its `set_user_regions` here.
pub fn set_regions(text: Region, stack: Region) void {
    read_regions = [_]Region{.{ .base = 0, .len = 0 }} ** 8;
    write_regions = [_]Region{.{ .base = 0, .len = 0 }} ** 8;
    read_regions[0] = text;
    read_regions[1] = stack;
    read_region_count = 2;
    write_regions[0] = stack;
    write_region_count = 1;
}

/// Add an additional readable EL0 aperture (e.g. interpreter text, dynamic segments, shared libs).
pub fn add_read_region(reg: Region) void {
    if (reg.len == 0) return;
    if (read_region_count < read_regions.len) {
        read_regions[read_region_count] = reg;
        read_region_count += 1;
    }
}

/// Add an additional writable EL0 aperture (e.g. data segment, heap).
pub fn add_write_region(reg: Region) void {
    if (reg.len == 0) return;
    if (write_region_count < write_regions.len) {
        write_regions[write_region_count] = reg;
        write_region_count += 1;
    }
}

pub fn stats() Stats {
    return .{
        .copies = copies_value,
        .validation_faults = validation_faults_value,
        .recoveries = recoveries_value,
    };
}

/// Range check: `[address, address+len)` must be non-wrapping and fully
/// contained in one of `regions`. Zero length is always ok (nothing to
/// access). This is the first line of defense; the fault window is the second.
fn range_ok(regions: []const Region, address: u64, len: u64) bool {
    if (len == 0) return true;
    const end = address +% len;
    if (end < address) return false; // overflow: bad pointer
    for (regions) |region| {
        if (region.len == 0) continue;
        const region_end = region.base +% region.len;
        if (region_end < region.base) continue;
        if (address >= region.base and end <= region_end) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Bounded transfers
// ---------------------------------------------------------------------------

/// Copy `len` bytes from user memory at `address` into `dst` (kernel-owned).
/// Returns `.fault` — without touching memory — when the range is not fully
/// inside a readable EL0 region, and `.fault` when a data abort was
/// recovered mid-copy (unmapped/permission case that slipped past range
/// validation).
pub fn copy_in(dst: []u8, address: u64, len: usize) Outcome {
    if (len == 0) return .ok;
    if (len > dst.len) return .fault; // caller bug: bounded by the buffer
    if (!range_ok(read_regions[0..read_region_count], address, @intCast(len))) {
        validation_faults_value +%= 1;
        return .fault;
    }
    open_window();
    const result = copy_in_window(dst[0..len], address, len);
    close_window();
    copies_value +%= 1;
    return result;
}

/// Copy `len` bytes from `src` (kernel-owned) into user memory at `address`.
/// Only the writable EL0 region (user stack) is accepted; the read-only text
/// aperture is a permission fault at validation.
pub fn copy_out(address: u64, src: []const u8, len: usize) Outcome {
    if (len == 0) return .ok;
    if (len > src.len) return .fault; // caller bug: bounded by the buffer
    if (!range_ok(write_regions[0..write_region_count], address, @intCast(len))) {
        validation_faults_value +%= 1;
        return .fault;
    }
    open_window();
    const result = copy_out_window(address, src[0..len], len);
    close_window();
    copies_value +%= 1;
    return result;
}

/// Diagnostic (monitor `uaccess`): copy from `address` with NO range
/// validation, to prove the fault-recovery path on real hardware — the raw
/// load from an unmapped address above the identity blanket takes a real
/// EL1 data abort that `try_recover` converts to `.fault`. Host test
/// processes have no vectors (the dereference would SIGSEGV the test), so
/// there it returns `.fault` without touching memory; the recovery path
/// itself is proven live by the class-B gate.
pub fn raw_copy_in(dst: []u8, address: u64, len: usize) Outcome {
    if (len == 0) return .ok;
    if (len > dst.len) return .fault;
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return .fault;
    open_window();
    const result = copy_in_window(dst[0..len], address, len);
    close_window();
    copies_value +%= 1;
    return result;
}

/// Copy loop for user -> kernel. The caller has already opened the window
/// (IRQs masked, latch clear); the loop breaks on the latch so a data abort
/// consumed by `try_recover` aborts the copy with `.fault` — the post-loop
/// check keeps the EFAULT contract even if an optimizer hoists the in-loop
/// one (the skipped instruction can only be a 4-byte load/store).
fn copy_in_window(dst: []u8, address: u64, len: usize) Outcome {
    const src: [*]const u8 = @ptrFromInt(address);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (latch_read()) break;
        dst[i] = src[i];
    }
    return if (latch_read()) .fault else .ok;
}

/// Copy loop for kernel -> user (window already open by the caller).
fn copy_out_window(address: u64, src: []const u8, len: usize) Outcome {
    const dst: [*]u8 = @ptrFromInt(address);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (latch_read()) break;
        dst[i] = src[i];
    }
    return if (latch_read()) .fault else .ok;
}

// ---------------------------------------------------------------------------
// The uaccess window
// ---------------------------------------------------------------------------

/// Mask IRQs for the window and return the previous DAIF to restore. In SVC
/// context IRQs are already masked at exception entry (no-op); in main
/// context (the monitor diagnostic) this keeps the window free of scheduler
/// preemption so no unrelated task can fault while `window_active` is set.
fn open_window() void {
    saved_daif = mask_irqs();
    set_window_active(true);
    set_latch(false);
    compiler_barrier();
}

fn close_window() void {
    compiler_barrier();
    set_window_active(false);
    restore_daif(saved_daif);
}

fn mask_irqs() u64 {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    var daif: u64 = 0;
    asm volatile ("mrs %[v], daif"
        : [v] "=r" (daif),
    );
    asm volatile ("msr daifset, #2");
    return daif;
}

fn restore_daif(daif: u64) void {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return;
    asm volatile ("msr daif, %[v]"
        :
        : [v] "r" (daif),
    );
}

/// Called by the claim-9746 synchronous path (`exc_dispatch`) before the
/// report-and-park fallback. Consumes a data abort taken while the uaccess
/// window is active: latch the fault, advance ELR past the 4-byte faulting
/// instruction (every AArch64 load/store is 4 bytes), and return true so the
/// vector resumes the copy loop, which aborts with EFAULT. Any other
/// synchronous exception — or a data abort outside a window — is not a user
/// pointer problem: return false and let the normal path report/park.
/// Exception context: no console, no allocation.
pub fn try_recover(esr: u64, elr: u64) bool {
    if (!window_active_read()) return false;
    const ec: u64 = (esr >> 26) & 0x3f;
    if (ec != 0x24 and ec != 0x25) return false; // data-abort-lower / -same
    set_latch(true);
    recoveries_value +%= 1;
    if (comptime !builtin.is_test and builtin.cpu.arch == .aarch64) {
        asm volatile ("msr elr_el1, %[v]"
            :
            : [v] "r" (elr + 4),
        );
        asm volatile ("isb");
    }
    return true;
}

// ---------------------------------------------------------------------------
// Monitor diagnostic
// ---------------------------------------------------------------------------

pub const DiagResult = struct {
    valid_copy: bool,
    fault_copy: bool,
    recoveries: u64,
    copies: u64,
    validation_faults: u64,
};

/// Monitor `uaccess` diagnostic: prove both paths on live hardware. The
/// validated copy reads the first readable region (the user text aperture)
/// and must succeed; the raw copy dereferences an unmapped address above the
/// identity blanket and must fault and be recovered (`recoveries >= 1` — a
/// real data abort consumed, not just a range rejection). No console output
/// here; the caller prints the result.
pub fn diag() DiagResult {
    var buf: [8]u8 = undefined;
    // Claim 5804: the regions are USER VAs (`text_va`/`stack_va`), mapped
    // only by the user root. The monitor command runs in the shell task,
    // whose TTBR0 is the kernel (identity) root — a raw dereference of a
    // user VA there would read the wrong page — so swap TTBR0 to the user
    // root for the copies and restore after. The raw fault copy still
    // faults: the user root maps only text+stack, so the unmapped probe
    // address is a real EL1 data abort either way. No-ops on host tests.
    const prev_ttbr0 = mmu.current_ttbr0();
    mmu.set_ttbr0(mmu.user_root_phys());
    defer mmu.set_ttbr0(prev_ttbr0);
    const valid = copy_in(&buf, read_regions[0].base, 8) == .ok;
    const fault = raw_copy_in(&buf, diagnostic_unmapped, 8) == .fault;
    return .{
        .valid_copy = valid,
        .fault_copy = fault,
        .recoveries = recoveries_value,
        .copies = copies_value,
        .validation_faults = validation_faults_value,
    };
}

// ---------------------------------------------------------------------------
// Tests (host-side; the hardware recovery is proven live by the class-B
// gate tools/verify-live-uaccess.sh)
// ---------------------------------------------------------------------------

test "uaccess: copy_in copies exact bytes from a readable region" {
    init();
    const text = "hello, user";
    var dst: [64]u8 = undefined;
    set_regions(
        .{ .base = @intFromPtr(text.ptr), .len = text.len },
        .{ .base = 0, .len = 0 },
    );
    try std.testing.expectEqual(Outcome.ok, copy_in(dst[0..text.len], @intFromPtr(text.ptr), text.len));
    try std.testing.expectEqualStrings(text, dst[0..text.len]);
    const s = stats();
    try std.testing.expectEqual(@as(u64, 1), s.copies);
    try std.testing.expectEqual(@as(u64, 0), s.validation_faults);
    try std.testing.expectEqual(@as(u64, 0), s.recoveries);
}

test "uaccess: copy_out writes exact bytes to a writable region" {
    init();
    const text = "kernel says hi";
    var user: [64]u8 = undefined;
    set_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = @intFromPtr(&user), .len = user.len },
    );
    try std.testing.expectEqual(Outcome.ok, copy_out(@intFromPtr(&user), text, text.len));
    try std.testing.expectEqualStrings(text, user[0..text.len]);
}

test "uaccess: boundary — range ending exactly at the region end is ok, one past faults" {
    init();
    const text = "12345678";
    var dst: [64]u8 = undefined;
    set_regions(
        .{ .base = @intFromPtr(text.ptr), .len = text.len },
        .{ .base = 0, .len = 0 },
    );
    // [ptr, ptr+len) exactly fills the region: ok.
    try std.testing.expectEqual(Outcome.ok, copy_in(dst[0..text.len], @intFromPtr(text.ptr), text.len));
    // One byte past the end: fault, without touching memory.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..1], @intFromPtr(text.ptr) + text.len, 1));
    // Starting one byte before the start: fault.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..1], @intFromPtr(text.ptr) - 1, 1));
    // Spanning across the region end: fault.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..text.len], @intFromPtr(text.ptr) + 1, text.len - 1 + 1));
    const s = stats();
    try std.testing.expectEqual(@as(u64, 1), s.copies);
    try std.testing.expectEqual(@as(u64, 3), s.validation_faults);
}

test "uaccess: overflow and zero length" {
    init();
    var dst: [8]u8 = undefined;
    set_regions(
        .{ .base = 0x1000, .len = 0x1000 },
        .{ .base = 0, .len = 0 },
    );
    // address + len wraps: bad pointer.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..], std.math.maxInt(u64) - 1, 4));
    // Zero length is legal even at a wild address (nothing is accessed).
    try std.testing.expectEqual(Outcome.ok, copy_in(dst[0..0], std.math.maxInt(u64), 0));
    // Caller bug guard: len larger than the destination buffer.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..4], 0x1000, 8));
    const s = stats();
    try std.testing.expectEqual(@as(u64, 1), s.validation_faults);
}

test "uaccess: out-of-region kernel/MMIO/blanket addresses fault" {
    init();
    var dst: [8]u8 = undefined;
    const text = "abcdefgh";
    set_regions(
        .{ .base = @intFromPtr(text.ptr), .len = text.len },
        .{ .base = 0, .len = 0 },
    );
    // A kernel address below the blanket (identity-mapped Normal RAM) is
    // NOT in any user region: rejected before any dereference.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..], 0x0, 8));
    // An address above the 4 GiB identity blanket (unmapped) is rejected by
    // validation here; the hardware recovery for such addresses is proven by
    // the raw diagnostic + live gate.
    try std.testing.expectEqual(Outcome.fault, copy_in(dst[0..], diagnostic_unmapped, 8));
}

test "uaccess: copy_out to the read-only text aperture is a permission fault" {
    init();
    const text = "abcdefgh";
    var user: [64]u8 = undefined;
    set_regions(
        .{ .base = @intFromPtr(text.ptr), .len = text.len },
        .{ .base = @intFromPtr(&user), .len = user.len },
    );
    // Text is readable but not writable: copy_out rejects it.
    try std.testing.expectEqual(Outcome.fault, copy_out(@intFromPtr(text.ptr), "12345678", 8));
    // The writable stack region is fine.
    try std.testing.expectEqual(Outcome.ok, copy_out(@intFromPtr(&user), "12345678", 8));
}

test "uaccess: a fault inside the window aborts the copy with EFAULT" {
    init();
    const text = "abcdefgh";
    var dst: [8]u8 = undefined;
    set_regions(
        .{ .base = @intFromPtr(text.ptr), .len = text.len },
        .{ .base = 0, .len = 0 },
    );
    // Simulate a data abort consumed by try_recover mid-copy: open the
    // window, set the latch (as the synchronous handler would), and run the
    // copy loop — it must observe the latch and abort before completing,
    // never dereferencing the bad range. The real path is proven live by
    // the class-B gate.
    open_window();
    set_latch(true);
    try std.testing.expectEqual(Outcome.fault, copy_in_window(dst[0..8], @intFromPtr(text.ptr), 8));
    close_window();
    // A clean window completes normally. Only the public entry points count
    // a copy; the direct loop call above (with the window already open) does
    // not.
    try std.testing.expectEqual(Outcome.ok, copy_in(dst[0..8], @intFromPtr(text.ptr), 8));
    try std.testing.expectEqualStrings(text, dst[0..8]);
    const s = stats();
    try std.testing.expectEqual(@as(u64, 1), s.copies);
    try std.testing.expectEqual(@as(u64, 0), s.recoveries);
}

test "uaccess: try_recover consumes only data aborts inside the window" {
    init();
    set_regions(.{ .base = 0, .len = 0 }, .{ .base = 0, .len = 0 });
    open_window();
    // Data abort from the same EL (the copy runs at EL1h): consumed.
    try std.testing.expect(try_recover(0x25 << 26, 0x4000));
    try std.testing.expectEqual(@as(u64, 1), recoveries_value);
    // Data abort from a lower EL: also consumed while the window is active.
    try std.testing.expect(try_recover(0x24 << 26, 0x4004));
    try std.testing.expectEqual(@as(u64, 2), recoveries_value);
    // A non-data-abort (SVC) inside the window is NOT ours.
    try std.testing.expect(!try_recover(0x15 << 26, 0x4008));
    close_window();
    // Outside the window nothing is consumed.
    try std.testing.expect(!try_recover(0x25 << 26, 0x400c));
    try std.testing.expectEqual(@as(u64, 2), recoveries_value);
}

test "uaccess: raw_copy_in is host-gated and diag is honest off-hardware" {
    init();
    const text = "abcdefgh";
    var dst: [8]u8 = undefined;
    set_regions(
        .{ .base = @intFromPtr(text.ptr), .len = text.len },
        .{ .base = 0, .len = 0 },
    );
    // Host: no vectors, so the raw probe returns fault without dereferencing.
    try std.testing.expectEqual(Outcome.fault, raw_copy_in(dst[0..], diagnostic_unmapped, 8));
    const d = diag();
    try std.testing.expect(d.valid_copy);
    try std.testing.expect(d.fault_copy);
    try std.testing.expectEqual(@as(u64, 0), d.recoveries);
}
