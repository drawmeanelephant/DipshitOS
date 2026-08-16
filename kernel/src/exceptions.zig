//! DipshitOS exception vectors (claim 9746 — the first half of roadmap
//! item 5; GIC + timer programming is the next card).
//!
//! Installs a real VBAR_EL1 vector table with basic synchronous and IRQ
//! handlers. Until this module, any fault at EL1 silently hung (no vectors
//! programmed); now a synchronous exception produces an `[EXC]` report over
//! the kernel console — ESR_EL1 (class + ISS), FAR_EL1, ELR_EL1, SPSR_EL1,
//! and the x0/x30 saved at the fault — and either resumes (only for a
//! deliberate test fault, see `trigger_test_fault`) or parks.
//!
//! Vector layout: a single contiguous 2048-byte region, one self-contained
//! stub per 128-byte architectural vector slot (4 exception types x 4
//! source modes; the kernel runs at EL1h — SPSel=1, observed SPSR.M=0x5 on
//! VZ — so the EL1h vectors at 0x200..0x380 are the current-EL entries).
//! Each stub saves a register frame on the current SP,
//! passes (frame, esr, far, elr, spsr, kind) to the shared C dispatch,
//! then either restores the frame and `eret`s (resume) or parks in WFE.
//! The region is pure position-independent code with no cross-region
//! branch or absolute address, so it is correct at any load base — the
//! flat loader applies no relocations (claim 0015 root cause).
//!
//! IRQ handling (claim 7948): with a dispatcher registered
//! (`set_irq_dispatcher` — the GIC ack -> timer handle -> GIC eoi chain),
//! taken IRQs dispatch to it and the stub `eret`s back to the interrupted
//! instruction with no report. Without one, IRQ/FIQ/SError vectors report
//! + park: nothing programs the GIC in that case, so an IRQ cannot legally
//! fire; if one does, reporting and parking beats silently running off
//! into firmware vectors. The synchronous handler's resume path is the
//! only place ELR_EL1 is rewritten, and only while `resume_armed` is set
//! by `trigger_test_fault` (the `dipshit> fault` command). The dispatcher
//! runs in IRQ context with a register frame on the stack and MUST NOT
//! touch the console (claim 7948: heartbeats print from the shell idle
//! loop).
//!
//! No libc, no POSIX, no allocation, no GIC programming (that lives in
//! gic.zig / timer.zig; this module only routes taken IRQs to it).

const std = @import("std");
const builtin = @import("builtin");
const uaccess = @import("uaccess.zig"); // claim 6120: fault-safe copy-in/copy-out window

// ---------------------------------------------------------------------------
// Exception kinds (the x5 value each stub passes; also the vector offset's
// low 5 bits, 0x0/0x8/0x10/0x18 in 32-bit slots, i.e. 0x000/0x080/0x100/0x180
// per mode).
// ---------------------------------------------------------------------------

pub const kind_sync: u64 = 0;
pub const kind_irq: u64 = 1;
pub const kind_fiq: u64 = 2;
pub const kind_serror: u64 = 3;

/// Saved by every vector stub, in reverse pair order because each `stp`
/// pre-decrements the stack. Keeping the layout helpers here prevents SVC
/// handlers from repeating the easy-to-get-wrong slot arithmetic.
pub const vector_frame_slots: usize = 32;
pub const vector_frame_bytes: u64 = vector_frame_slots * @sizeOf(u64);

/// The FP/SIMD block every vector stub pushes below the GPR frame (q0..q31,
/// 512 bytes) so the kernel may use NEON freely without corrupting EL0 state
/// that was live across the exception (claim 8877 bisect: DESKTOP's marker
/// build hoisted `ldr q0` across an `svc` and the kernel's ReleaseSmall
/// memcpy destroyed it). The C-visible `VectorFrame` EXCLUDES this block;
/// the restore macro pops it first via `sub sp, x0, #fp_save_bytes` + 16
/// `ldp q` pairs. `build_initial_frame` reserves the same block (zeroed)
/// beneath every synthetic frame.
pub const fp_save_bytes: u64 = 32 * @sizeOf(u128);
pub const VectorFrame = [vector_frame_slots]u64;

fn frame_index(reg: u5) ?usize {
    if (reg <= 17) return 18 - 2 * (@as(usize, reg) / 2) + (@as(usize, reg) & 1);
    if (reg == 30) return 0;
    // Claim 6729: the callee-saved extension (x19..x28 + x29) appended at
    // the TOP of the frame ([20..31]) by the vector stubs' first pushes.
    if (reg == 29) return 20;
    if (reg >= 19 and reg <= 28) return @as(usize, if (reg % 2 == 0) 51 else 49) - reg;
    return null;
}

pub fn frame_read(frame: *const VectorFrame, reg: u5) u64 {
    const index = frame_index(reg) orelse return 0;
    return frame[index];
}

pub fn frame_write(frame: *VectorFrame, reg: u5, value: u64) bool {
    const index = frame_index(reg) orelse return false;
    frame[index] = value;
    return true;
}

// ---------------------------------------------------------------------------
// Report writer (set by the kernel seam so this module stays transport-
// agnostic and host-testable).
// ---------------------------------------------------------------------------

var report_writer: ?*const fn ([]const u8) void = null;

/// Set the console writer the `[EXC]` report is emitted through. The
/// kernel passes a wrapper over its polled uart; host tests may leave it
/// null and assert on `format_report` directly.
pub fn init(writer: *const fn ([]const u8) void) void {
    report_writer = writer;
}

// ---------------------------------------------------------------------------
// IRQ dispatcher (claim 7948)
// ---------------------------------------------------------------------------

/// Called for every taken IRQ (kind == kind_irq) once registered. Runs in
/// IRQ context with a register frame on the stack: it must not touch the
/// console (the timer heartbeat prints from the shell idle loop instead).
pub const IrqDispatcher = *const fn () void;

var irq_dispatcher: ?IrqDispatcher = null;

/// Register the IRQ chain (kernel seam: gic.ack -> timer.handle ->
/// scheduler.tick -> gic.eoi composed in main.zig). Host tests can
/// register a plain function and assert dispatch behavior.
pub fn set_irq_dispatcher(d: IrqDispatcher) void {
    irq_dispatcher = d;
}

/// Minimal synchronous lower-EL seam. The registered handler owns only
/// recognized AArch64 SVC exceptions from EL0t; returning false leaves the
/// exception on the normal report-and-park path. The mutable vector frame is
/// the syscall ABI: arguments arrive in saved GPRs and x0 carries the result.
pub const SvcDispatcher = *const fn (*VectorFrame, u16) bool;

var svc_dispatcher: ?SvcDispatcher = null;

pub fn set_svc_dispatcher(d: SvcDispatcher) void {
    svc_dispatcher = d;
}

/// The vector-frame pointer the IRQ stub must restore from when the
/// dispatcher chain returns (claim 5275). Set to the interrupted task's
/// frame at IRQ entry; the scheduler may rewrite it to the next task's
/// frame, and the stub's `mov sp, x0` + register restore + `eret` then
/// lands in that task as if IT had been interrupted. Meaningful only in
/// IRQ context.
pub var resume_frame: u64 = 0;

/// SP_EL0 to install before the vector stub restores registers and `eret`s.
/// EL1h tasks do not consume it, but an EL0t task must regain its separate
/// userspace stack when scheduled after an EL1 task.
pub var resume_sp_el0: u64 = 0;

/// Unmask IRQs (clear DAIF.I). The caller arms the GIC + timer first so no
/// interrupt can arrive before the chain is ready. No-op on non-aarch64
/// hosts (never meaningful in a host test process).
pub fn irq_unmask() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    asm volatile ("msr daifclr, #2");
}

// ---------------------------------------------------------------------------
// Install
// ---------------------------------------------------------------------------

/// Program VBAR_EL1 with the vector region. No-op on non-aarch64 hosts
/// (the module must stay `zig test`-able on x86_64 CI). The vector region
/// is emitted only for aarch64 targets (see `exception_vectors`).
pub fn install() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    const table_addr = @intFromPtr(&exception_vectors);
    asm volatile ("msr vbar_el1, %[addr]"
        :
        : [addr] "r" (table_addr),
    );
    asm volatile ("isb");
    installed_flag = true;
}

/// True once `install` has actually programmed VBAR_EL1 (only inside the
/// kernel — never in a host test process, even on an aarch64 host where a
/// user-space `msr` or `udf` would SIGILL). The `fault` command gates on
/// this, so a host transcript can never execute the real instructions.
var installed_flag: bool = false;
pub fn installed() bool {
    return installed_flag;
}

// ---------------------------------------------------------------------------
// Counters
// ---------------------------------------------------------------------------

var handled_count_value: u64 = 0;
var resume_count_value: u64 = 0;

/// Total exceptions taken since boot.
pub fn handled_count() u64 {
    return handled_count_value;
}

/// Exceptions that were resumed (the deliberate test fault).
pub fn resume_count() u64 {
    return resume_count_value;
}

// ---------------------------------------------------------------------------
// Pure decoders (host-tested)
// ---------------------------------------------------------------------------

/// ESR_EL1 EC (bits [31:26]) -> human name. Bounded table; unknown classes
/// decode to a stable "ec-unknown-0x<hex>" string.
pub fn ec_name(esr: u64) []const u8 {
    return switch ((esr >> 26) & 0x3f) {
        0x00 => "unknown-reason",
        0x01 => "trapped-wfi-wfe",
        0x15 => "svc64",
        0x18 => "trapped-msr-mrs",
        0x19 => "trapped-eret",
        0x20 => "instruction-abort-lower",
        0x21 => "instruction-abort-same",
        0x22 => "pc-alignment",
        0x24 => "data-abort-lower",
        0x25 => "data-abort-same",
        0x26 => "sp-alignment",
        0x30 => "breakpoint-lower",
        0x31 => "breakpoint-same",
        0x32 => "step-lower",
        0x33 => "step-same",
        0x34 => "watchpoint-lower",
        0x35 => "watchpoint-same",
        0x3c => "brk64",
        else => "ec-unknown",
    };
}

/// Decode the AArch64 source mode from SPSR_EL1.M[3:0]. The old decoder
/// shifted every mode up by one exception level and called the observed
/// 0x5 EL1t; architecturally it is EL1h.
pub fn mode_name(spsr: u64) []const u8 {
    return switch (spsr & 0xf) {
        0x0 => "EL0t",
        0x4 => "EL1t",
        0x5 => "EL1h",
        0x8 => "EL2t",
        0x9 => "EL2h",
        0xc => "EL3t",
        0xd => "EL3h",
        else => "mode-unknown",
    };
}

pub fn is_svc64_from_el0(kind: u64, esr: u64, spsr: u64) bool {
    return kind == kind_sync and ((esr >> 26) & 0x3f) == 0x15 and (spsr & 0xf) == 0;
}

/// Decode the exception kind (the stub's x5) to a report name.
pub fn kind_name(kind: u64) []const u8 {
    return switch (kind) {
        0 => "sync",
        1 => "irq",
        2 => "fiq",
        3 => "serror",
        else => "exc-kind-unknown",
    };
}

/// May the handler resume execution after the report? Only a synchronous
/// exception while the deliberate test fault is armed. Pure decision so
/// the host tests pin the exact rule.
pub fn should_resume(kind: u64, armed: bool) bool {
    return armed and kind == kind_sync;
}

// ---------------------------------------------------------------------------
// Report formatting (pure, host-tested)
// ---------------------------------------------------------------------------

const hex_digits = "0123456789abcdef";

fn append_slice(buf: []u8, text: []const u8) usize {
    if (text.len > buf.len) return 0;
    @memcpy(buf[0..text.len], text);
    return text.len;
}

/// Fixed-width lowercase hex (no "0x" prefix), `digits` wide.
fn append_hex(buf: []u8, value: u64, digits: usize) usize {
    if (digits > buf.len) return 0;
    var index: usize = 0;
    while (index < digits) : (index += 1) {
        const shift = 4 * (digits - 1 - index);
        buf[index] = hex_digits[@as(usize, @intCast((value >> @intCast(shift)) & 0xf))];
    }
    return digits;
}

/// Decimal u64 (no padding).
fn append_u64(buf: []u8, value: u64) usize {
    var tmp: [20]u8 = undefined;
    var index: usize = 0;
    var v = value;
    if (v == 0) {
        if (buf.len == 0) return 0;
        buf[0] = '0';
        return 1;
    }
    while (v > 0) : (v /= 10) {
        tmp[index] = @intCast('0' + (v % 10));
        index += 1;
    }
    if (index > buf.len) return 0;
    var out: usize = 0;
    while (index > 0) {
        index -= 1;
        buf[out] = tmp[index];
        out += 1;
    }
    return out;
}

/// Format the full `[EXC]` report into `buf` (caller-owned, >= 512 bytes
/// recommended) and return the written slice. Deterministic byte-for-byte:
/// the class B gate asserts substrings of this exact shape in vm-serial.log.
pub fn format_report(
    buf: []u8,
    kind: u64,
    esr: u64,
    far: u64,
    elr: u64,
    spsr: u64,
    count: u64,
    x0: u64,
    x30: u64,
    sp_el0: u64,
    x1: u64,
    x2: u64,
    x29: u64,
    will_resume: bool,
) []const u8 {
    var pos: usize = 0;

    pos += append_slice(buf[pos..], "[EXC] ");
    pos += append_slice(buf[pos..], kind_name(kind));
    pos += append_slice(buf[pos..], " from ");
    pos += append_slice(buf[pos..], mode_name(spsr));
    pos += append_slice(buf[pos..], " count=");
    pos += append_u64(buf[pos..], count);
    pos += append_slice(buf[pos..], "\n");

    pos += append_slice(buf[pos..], "[EXC] esr=0x");
    pos += append_hex(buf[pos..], esr, 16);
    pos += append_slice(buf[pos..], " ec=0x");
    pos += append_hex(buf[pos..], (esr >> 26) & 0x3f, 2);
    pos += append_slice(buf[pos..], " ");
    pos += append_slice(buf[pos..], ec_name(esr));
    pos += append_slice(buf[pos..], " iss=0x");
    pos += append_hex(buf[pos..], esr & 0xffffff, 6);
    pos += append_slice(buf[pos..], "\n");

    pos += append_slice(buf[pos..], "[EXC] far=0x");
    pos += append_hex(buf[pos..], far, 16);
    pos += append_slice(buf[pos..], "\n");

    pos += append_slice(buf[pos..], "[EXC] elr=0x");
    pos += append_hex(buf[pos..], elr, 16);
    pos += append_slice(buf[pos..], " spsr=0x");
    pos += append_hex(buf[pos..], spsr, 16);
    pos += append_slice(buf[pos..], "\n");

    pos += append_slice(buf[pos..], "[EXC] x0=0x");
    pos += append_hex(buf[pos..], x0, 16);
    pos += append_slice(buf[pos..], " x30=0x");
    pos += append_hex(buf[pos..], x30, 16);
    pos += append_slice(buf[pos..], "\n");

    pos += append_slice(buf[pos..], "[EXC] sp=0x");
    pos += append_hex(buf[pos..], sp_el0, 16);
    pos += append_slice(buf[pos..], " x1=0x");
    pos += append_hex(buf[pos..], x1, 16);
    pos += append_slice(buf[pos..], " x2=0x");
    pos += append_hex(buf[pos..], x2, 16);
    pos += append_slice(buf[pos..], " x29=0x");
    pos += append_hex(buf[pos..], x29, 16);
    pos += append_slice(buf[pos..], "\n");

    if (will_resume) {
        pos += append_slice(buf[pos..], "[EXC] resume-armed: skipping faulting instruction\n");
    } else {
        pos += append_slice(buf[pos..], "[EXC] parking: no recovery path for this exception\n");
    }
    return buf[0..pos];
}

// ---------------------------------------------------------------------------
// Deliberate test fault (`dipshit> fault`)
// ---------------------------------------------------------------------------

/// Arm the resume flag and execute a permanently-undefined instruction.
/// The synchronous handler sees `resume_armed`, reports, advances ELR_EL1
/// past the 32-bit `udf`, and returns — so this function returns normally
/// and the shell continues. On non-aarch64 hosts this is a no-op (no
/// vectors exist in a host test binary).
pub fn trigger_test_fault() void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    if (!installed_flag) return; // host test process: never execute `udf`
    resume_armed = true;
    asm volatile ("udf #0x0" ::: .{ .memory = true });
}

var resume_armed: bool = false;

// ---------------------------------------------------------------------------
// Shared C dispatch (called by every vector stub)
// ---------------------------------------------------------------------------

/// Shared handler for every vector. `frame` is the saved register frame
/// pushed by the stub ([0] = x30, [1] = pad, [2..19] = x16..x17 through
/// x0..x1 in descending register-pair order); the
/// system registers are passed in from the stub's `mrs` reads. Returns the
/// vector-frame pointer the stub should restore from (then `eret`), or 0
/// to park. For the plain IRQ/sync paths that is the entry frame itself
/// (the restore macro selects that frame); a context-switching
/// dispatcher chain may return another task's frame (claim 5275).
///
/// Must be callable from the naked asm with exactly this signature and
/// symbol name (`bl exc_dispatch`), hence `export` + `callconv(.c)`.
pub const Resume = extern struct {
    frame: u64,
    sp_el0: u64,
};

fn read_sp_el0() u64 {
    if (comptime builtin.is_test or builtin.cpu.arch != .aarch64) return 0;
    var value: u64 = 0;
    asm volatile ("mrs %[v], sp_el0"
        : [v] "=r" (value),
    );
    return value;
}

fn source_sp_el0(frame: *const VectorFrame, spsr: u64) u64 {
    // An EL1t source used SP_EL0 for the vector frame itself; once the 160
    // saved bytes are popped, that task's logical stack is frame+160.
    if ((spsr & 0xf) == 0x4) return @intFromPtr(frame) + vector_frame_bytes;
    // EL1h and EL0t sources preserve SP_EL0 independently while the vector
    // and C dispatcher run on SP_EL1.
    return read_sp_el0();
}

export fn exc_dispatch(
    frame: *VectorFrame,
    esr: u64,
    far: u64,
    elr: u64,
    spsr: u64,
    kind: u64,
) callconv(.c) Resume {
    handled_count_value += 1;
    resume_frame = @intFromPtr(frame);
    resume_sp_el0 = source_sp_el0(frame, spsr);
    // Claim 7948: taken IRQs route to the registered dispatcher (GIC ack
    // -> timer handle -> scheduler tick -> GIC eoi); the stub restores the
    // frame and erets. IRQs were masked until the whole chain was armed,
    // so a dispatcher that is present is always ready. Without one (host
    // tests, or the pre-GIC milestone), IRQs fall through to the report +
    // park path. Claim 5275: stage the interrupted task's frame pointer so
    // the scheduler can save it (and rewrite it to the next task's frame);
    // the stub's `mov sp, x0` restores from whatever frame is left staged.
    if (kind == kind_irq) {
        if (irq_dispatcher) |d| {
            d();
            return .{ .frame = resume_frame, .sp_el0 = resume_sp_el0 };
        }
    }
    if (is_svc64_from_el0(kind, esr, spsr)) {
        if (svc_dispatcher) |d| {
            const immediate: u16 = @truncate(esr & 0xffff);
            if (d(frame, immediate)) {
                // A normal syscall leaves resume_frame pointing at `frame`.
                // Cooperative yield/exit may instead stage another runnable
                // task through the scheduler; honor the same return-frame
                // seam the IRQ path already uses.
                return .{ .frame = resume_frame, .sp_el0 = resume_sp_el0 };
            }
        }
    }
    // Claim 6120: a synchronous data abort while a uaccess window is active
    // is a bad user pointer inside a bounded copy, not a kernel bug. The
    // uaccess module latches the fault and advances ELR past the 4-byte
    // faulting instruction; the copy loop observes the latch and returns
    // EFAULT, so the shell/user task survives. Any other synchronous
    // exception falls through to the normal report/park path.
    if (kind == kind_sync and uaccess.try_recover(esr, elr)) {
        return .{ .frame = @intFromPtr(frame), .sp_el0 = resume_sp_el0 };
    }
    const will_resume = should_resume(kind, resume_armed);
    var buf: [512]u8 = undefined;
    const report = format_report(
        &buf,
        kind,
        esr,
        far,
        elr,
        spsr,
        handled_count_value,
        frame_read(frame, 0),
        frame_read(frame, 30),
        resume_sp_el0,
        frame_read(frame, 1),
        frame_read(frame, 2),
        frame_read(frame, 29),
        will_resume,
    );
    if (report_writer) |w| w(report);
    if (will_resume) {
        resume_armed = false;
        resume_count_value += 1;
        // Skip the 32-bit faulting instruction (the test `udf`), so the
        // resumed code continues right after it instead of re-faulting.
        // Only ever reached while resume_armed was set by the test trigger.
        asm volatile ("msr elr_el1, %[v]"
            :
            : [v] "r" (elr + 4),
        );
        asm volatile ("isb");
        return .{ .frame = @intFromPtr(frame), .sp_el0 = resume_sp_el0 };
    }
    return .{ .frame = 0, .sp_el0 = resume_sp_el0 };
}

// ---------------------------------------------------------------------------
// Vector region (aarch64 only)
// ---------------------------------------------------------------------------

/// The VBAR_EL1 vector region: 16 stubs, one per 128-byte slot (offsets
/// 0x000/0x080/0x100/0x180 x EL1t/EL1h/EL0-64/EL0-32). Each stub saves the
/// full GPR frame (x0..x17 + x30 + the claim-6729 callee set x19..x28 +
/// x29 = 32 slots) on the current SP, passes kind in x5 (0 sync / 1 irq /
/// 2 fiq / 3 serror), and branches to the shared `exc_fp_common`, which
/// pushes the FP/SIMD block (q0..q31, 512 bytes) below the GPR frame,
/// loads (esr, far, elr, spsr) from the EL1 system registers, and calls
/// `exc_dispatch`. On return (x0 != 0) the restore macro pops the FP block
/// first, then the GPR frame, and `eret`s; x0 == 0 parks in WFE.
/// `exc_dispatch` returns a two-register C aggregate: x0 is the vector-frame
/// pointer (the GPR base — `VectorFrame` excludes the FP block) and x1 is
/// the SP_EL0 belonging to the selected task. The restore macro switches
/// to SP_EL1 before installing SP_EL0, so the same exit path safely targets
/// EL1h and EL0t contexts.
///
/// The FP block is the claim 8877 fix: the kernel uses NEON freely (e.g.
/// ReleaseSmall memcpy), and without the save a user `ldr q0` hoisted
/// across an `svc` was silently corrupted — DESKTOP's manifest marker lost
/// its first 15 bytes to exactly the kernel's q0/q1 values.
///
/// The region is emitted only on aarch64: this function is referenced
/// solely from `install`'s comptime-aarch64 branch, so x86 host tests
/// never codegen the AArch64 assembly. `.balign 2048` at the start plus
/// the fn's `align(2048)` guarantee slot i sits at VBAR + i*128; each stub
/// body is 18 instructions (72 bytes: 16 GPR `stp` pairs + `movz` + `b
/// exc_fp_common`), padded to the 128-byte slot boundary by the trailing
/// `.balign 128`. `exc_fp_common` + the tail live beyond the table (the
/// hardware only fetches the 16 slots). The tail pops the full frame and
/// `eret`s — the callee-saved half is what makes the scheduler's per-task
/// context switch safe for compiled tasks (claim 6729 bisect: the shell's
/// live `mon` in x19 was clobbered by the preempting task's value because
/// the old 20-slot frame never saved x19..x28).
fn exception_vectors() align(2048) callconv(.naked) void {
    asm volatile (
        \\.balign 2048
        \\.macro exc_restore
        \\msr spsel, #1
        \\sub sp, x0, #512
        \\ldp q30, q31, [sp], #32
        \\ldp q28, q29, [sp], #32
        \\ldp q26, q27, [sp], #32
        \\ldp q24, q25, [sp], #32
        \\ldp q22, q23, [sp], #32
        \\ldp q20, q21, [sp], #32
        \\ldp q18, q19, [sp], #32
        \\ldp q16, q17, [sp], #32
        \\ldp q14, q15, [sp], #32
        \\ldp q12, q13, [sp], #32
        \\ldp q10, q11, [sp], #32
        \\ldp q8, q9, [sp], #32
        \\ldp q6, q7, [sp], #32
        \\ldp q4, q5, [sp], #32
        \\ldp q2, q3, [sp], #32
        \\ldp q0, q1, [sp], #32
        \\msr sp_el0, x1
        \\b exc_restore_tail
        \\.endm
        \\// Entry 0x000: EL1t synchronous (kind 0)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #0
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x080: EL1t IRQ (kind 1)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #1
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x100: EL1t FIQ (kind 2)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #2
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x180: EL1t SError (kind 3)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #3
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x200: EL1h synchronous (kind 0)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #0
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x280: EL1h IRQ (kind 1)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #1
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x300: EL1h FIQ (kind 2)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #2
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x380: EL1h SError (kind 3)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #3
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x400: lower EL AArch64 synchronous (kind 0)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #0
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x480: lower EL AArch64 IRQ (kind 1)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #1
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x500: lower EL AArch64 FIQ (kind 2)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #2
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x580: lower EL AArch64 SError (kind 3)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #3
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x600: lower EL AArch32 synchronous (kind 0)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #0
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x680: lower EL AArch32 IRQ (kind 1)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #1
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x700: lower EL AArch32 FIQ (kind 2)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #2
        \\b exc_fp_common
        \\.balign 128
        \\// Entry 0x780: lower EL AArch32 SError (kind 3)
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp x29, xzr, [sp, #-16]!
        \\stp x0, x1, [sp, #-16]!
        \\stp x2, x3, [sp, #-16]!
        \\stp x4, x5, [sp, #-16]!
        \\stp x6, x7, [sp, #-16]!
        \\stp x8, x9, [sp, #-16]!
        \\stp x10, x11, [sp, #-16]!
        \\stp x12, x13, [sp, #-16]!
        \\stp x14, x15, [sp, #-16]!
        \\stp x16, x17, [sp, #-16]!
        \\stp x30, xzr, [sp, #-16]!
        \\movz x5, #3
        \\b exc_fp_common
        \\.balign 128
        \\exc_fp_common:
        \\stp q0, q1, [sp, #-32]!
        \\stp q2, q3, [sp, #-32]!
        \\stp q4, q5, [sp, #-32]!
        \\stp q6, q7, [sp, #-32]!
        \\stp q8, q9, [sp, #-32]!
        \\stp q10, q11, [sp, #-32]!
        \\stp q12, q13, [sp, #-32]!
        \\stp q14, q15, [sp, #-32]!
        \\stp q16, q17, [sp, #-32]!
        \\stp q18, q19, [sp, #-32]!
        \\stp q20, q21, [sp, #-32]!
        \\stp q22, q23, [sp, #-32]!
        \\stp q24, q25, [sp, #-32]!
        \\stp q26, q27, [sp, #-32]!
        \\stp q28, q29, [sp, #-32]!
        \\stp q30, q31, [sp, #-32]!
        \\add x0, sp, #512
        \\mrs x1, esr_el1
        \\mrs x2, far_el1
        \\mrs x3, elr_el1
        \\mrs x4, spsr_el1
        \\bl exc_dispatch
        \\cbz x0, exc_park
        \\exc_restore
        \\exc_restore_tail:
        \\ldp x30, xzr, [sp], #16
        \\ldp x16, x17, [sp], #16
        \\ldp x14, x15, [sp], #16
        \\ldp x12, x13, [sp], #16
        \\ldp x10, x11, [sp], #16
        \\ldp x8, x9, [sp], #16
        \\ldp x6, x7, [sp], #16
        \\ldp x4, x5, [sp], #16
        \\ldp x2, x3, [sp], #16
        \\ldp x0, x1, [sp], #16
        \\ldp x29, xzr, [sp], #16
        \\ldp x27, x28, [sp], #16
        \\ldp x25, x26, [sp], #16
        \\ldp x23, x24, [sp], #16
        \\ldp x21, x22, [sp], #16
        \\ldp x19, x20, [sp], #16
        \\eret
        \\exc_park:
        \\wfe
        \\b exc_park
    );
}

// ---------------------------------------------------------------------------
// Tests (host-side; the asm region is proven on real VZ hardware by the
// class B gate, tools/verify-live-exceptions.sh)
// ---------------------------------------------------------------------------

var test_svc_immediate: u16 = 0;
var test_svc_resume_frame: ?*VectorFrame = null;

fn test_svc_handler(frame: *VectorFrame, immediate: u16) bool {
    test_svc_immediate = immediate;
    _ = frame_write(frame, 0, frame_read(frame, 0) + 1);
    if (test_svc_resume_frame) |selected| resume_frame = @intFromPtr(selected);
    return true;
}

test "exceptions: ec_name decodes known and unknown classes" {
    try std.testing.expectEqualStrings("unknown-reason", ec_name(0x00000000));
    try std.testing.expectEqualStrings("unknown-reason", ec_name(0x00000000)); // udf
    try std.testing.expectEqualStrings("svc64", ec_name(0x15 << 26));
    try std.testing.expectEqualStrings("trapped-msr-mrs", ec_name(0x18 << 26));
    try std.testing.expectEqualStrings("data-abort-same", ec_name(0x25 << 26));
    try std.testing.expectEqualStrings("brk64", ec_name(0x3c << 26));
    try std.testing.expectEqualStrings("ec-unknown", ec_name(0x3f << 26));
}

test "exceptions: mode_name decodes SPSR M field" {
    try std.testing.expectEqualStrings("EL0t", mode_name(0x0));
    try std.testing.expectEqualStrings("EL1t", mode_name(0x4));
    try std.testing.expectEqualStrings("EL1h", mode_name(0x5));
    try std.testing.expectEqualStrings("EL2t", mode_name(0x8));
    try std.testing.expectEqualStrings("EL2h", mode_name(0x9));
    try std.testing.expectEqualStrings("EL3t", mode_name(0xc));
    try std.testing.expectEqualStrings("EL3h", mode_name(0xd));
    try std.testing.expectEqualStrings("mode-unknown", mode_name(0x1));
}

test "exceptions: vector-frame helpers match the reverse stp layout" {
    var frame: VectorFrame = [_]u64{0} ** vector_frame_slots;
    try std.testing.expect(frame_write(&frame, 0, 0x10));
    try std.testing.expect(frame_write(&frame, 1, 0x11));
    try std.testing.expect(frame_write(&frame, 8, 0x18));
    try std.testing.expect(frame_write(&frame, 17, 0x21));
    try std.testing.expect(frame_write(&frame, 30, 0x30));
    try std.testing.expectEqual(@as(u64, 0x10), frame[18]);
    try std.testing.expectEqual(@as(u64, 0x11), frame[19]);
    try std.testing.expectEqual(@as(u64, 0x18), frame[10]);
    try std.testing.expectEqual(@as(u64, 0x21), frame[3]);
    try std.testing.expectEqual(@as(u64, 0x30), frame[0]);
    try std.testing.expectEqual(@as(u64, 0x18), frame_read(&frame, 8));
    // Claim 6729: the callee-saved extension is writable and lands at the
    // frame top ([20] = x29, [30] = x19, [31] = x20).
    try std.testing.expect(frame_write(&frame, 29, 0x29));
    try std.testing.expect(frame_write(&frame, 19, 0x19));
    try std.testing.expect(frame_write(&frame, 20, 0x20));
    try std.testing.expectEqual(@as(u64, 0x29), frame[20]);
    try std.testing.expectEqual(@as(u64, 0x19), frame[30]);
    try std.testing.expectEqual(@as(u64, 0x20), frame[31]);
    try std.testing.expectEqual(@as(u64, 0x29), frame_read(&frame, 29));
    try std.testing.expect(!frame_write(&frame, 18, 1)); // x18 is not part of the frame
    try std.testing.expect(!frame_write(&frame, 31, 1)); // x31 (SP) is not saved
}

test "exceptions: only AArch64 SVC from EL0t reaches the SVC seam" {
    const svc_esr: u64 = (0x15 << 26) | 0x42;
    try std.testing.expect(is_svc64_from_el0(kind_sync, svc_esr, 0x0));
    try std.testing.expect(!is_svc64_from_el0(kind_irq, svc_esr, 0x0));
    try std.testing.expect(!is_svc64_from_el0(kind_sync, svc_esr, 0x5));
    try std.testing.expect(!is_svc64_from_el0(kind_sync, 0, 0x0));
}

test "exceptions: SVC dispatcher mutates x0 and resumes the same EL0 frame" {
    var frame: VectorFrame = [_]u64{0} ** vector_frame_slots;
    try std.testing.expect(frame_write(&frame, 0, 41));
    test_svc_immediate = 0;
    test_svc_resume_frame = null;
    set_svc_dispatcher(test_svc_handler);
    const esr: u64 = (0x15 << 26) | 0x1234;
    const dispatch_result = exc_dispatch(&frame, esr, 0, 0x4000, 0, kind_sync);
    try std.testing.expectEqual(@intFromPtr(&frame), dispatch_result.frame);
    try std.testing.expectEqual(@as(u64, 0), dispatch_result.sp_el0); // host has no SP_EL0
    try std.testing.expectEqual(@as(u16, 0x1234), test_svc_immediate);
    try std.testing.expectEqual(@as(u64, 42), frame_read(&frame, 0));
}

test "exceptions: handled SVC may select another existing scheduler frame" {
    var frame: VectorFrame = [_]u64{0} ** vector_frame_slots;
    var selected: VectorFrame = [_]u64{0} ** vector_frame_slots;
    test_svc_resume_frame = &selected;
    set_svc_dispatcher(test_svc_handler);
    const result = exc_dispatch(&frame, 0x15 << 26, 0, 0x4000, 0, kind_sync);
    try std.testing.expectEqual(@intFromPtr(&selected), result.frame);
    test_svc_resume_frame = null;
}

test "exceptions: kind_name is stable" {
    try std.testing.expectEqualStrings("sync", kind_name(0));
    try std.testing.expectEqualStrings("irq", kind_name(1));
    try std.testing.expectEqualStrings("fiq", kind_name(2));
    try std.testing.expectEqualStrings("serror", kind_name(3));
    try std.testing.expectEqualStrings("exc-kind-unknown", kind_name(9));
}

test "exceptions: resume decision is sync-and-armed only" {
    try std.testing.expect(should_resume(kind_sync, true));
    try std.testing.expect(!should_resume(kind_sync, false));
    try std.testing.expect(!should_resume(kind_irq, true));
    try std.testing.expect(!should_resume(kind_fiq, true));
    try std.testing.expect(!should_resume(kind_serror, true));
}

test "exceptions: format_report is deterministic (resume path)" {
    var buf: [512]u8 = undefined;
    // A udf at EL1h: ESR EC=0x00 (unknown reason), SPSR.M=0x5 (EL1h).
    const esr: u64 = 0;
    const report = format_report(&buf, kind_sync, esr, 0, 0x7e4dfabc, 0x5, 1, 0x2a, 0x7e4df000, 0x1234, 0x2b, 0x2c, 0x29, true);
    try std.testing.expectEqualStrings(
        "[EXC] sync from EL1h count=1\n" ++
            "[EXC] esr=0x0000000000000000 ec=0x00 unknown-reason iss=0x000000\n" ++
            "[EXC] far=0x0000000000000000\n" ++
            "[EXC] elr=0x000000007e4dfabc spsr=0x0000000000000005\n" ++
            "[EXC] x0=0x000000000000002a x30=0x000000007e4df000\n" ++
            "[EXC] sp=0x0000000000001234 x1=0x000000000000002b x2=0x000000000000002c x29=0x0000000000000029\n" ++
            "[EXC] resume-armed: skipping faulting instruction\n",
        report,
    );
}

test "exceptions: format_report is deterministic (park path, irq)" {
    var buf: [512]u8 = undefined;
    const esr: u64 = 0x80000000; // EC=0x20 (instruction abort, lower EL)
    const report = format_report(&buf, kind_irq, esr, 0xdead0000, 0x1234, 0x0, 7, 0, 0, 0, 0, 0, 0, false);
    try std.testing.expectEqualStrings(
        "[EXC] irq from EL0t count=7\n" ++
            "[EXC] esr=0x0000000080000000 ec=0x20 instruction-abort-lower iss=0x000000\n" ++
            "[EXC] far=0x00000000dead0000\n" ++
            "[EXC] elr=0x0000000000001234 spsr=0x0000000000000000\n" ++
            "[EXC] x0=0x0000000000000000 x30=0x0000000000000000\n" ++
            "[EXC] sp=0x0000000000000000 x1=0x0000000000000000 x2=0x0000000000000000 x29=0x0000000000000000\n" ++
            "[EXC] parking: no recovery path for this exception\n",
        report,
    );
}

test "exceptions: install and trigger never execute in a host test process" {
    // On x86_64 CI these are comptime no-ops. On an aarch64 host the test
    // process is user-space EL0: executing `msr vbar_el1` or `udf` would
    // SIGILL, so the test must not call them there — the real vectors are
    // proven on VZ hardware by the class B gate
    // (tools/verify-live-exceptions.sh) instead.
    if (comptime builtin.cpu.arch == .aarch64) return;
    install();
    trigger_test_fault();
    try std.testing.expect(handled_count() == 0);
}

test "exceptions: report buffer is bounded (max-size fields never overflow)" {
    var buf: [512]u8 = undefined;
    const report = format_report(
        &buf,
        kind_serror,
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        false,
    );
    try std.testing.expect(report.len < buf.len);
    try std.testing.expect(std.mem.indexOf(u8, report, "ec=0x3f") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "count=18446744073709551615") != null);
}
