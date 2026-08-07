//! DipshitOS M1.5 machine controls — real `reboot`/`shutdown` via EFI
//! Runtime Services `ResetSystem` (machine-controls slice).
//!
//! Implements the monitor's `MachineControl` interface (`kernel/src/
//! monitor.zig`, reused as-is) with a real post-ExitBootServices mechanism:
//! EFI `ResetSystem` from the Runtime Services table. Runtime services
//! (unlike Boot Services) survive `ExitBootServices` — the same table whose
//! `SetVariable` is observed working post-exit on VZ (claims 0009/0010),
//! and the kernel maps `runtime_services_code`/`runtime_services_data` as
//! Normal WB, so the runtime services code is reachable after the MMU
//! switch.
//!
//! Honesty rules: if no runtime services pointer was captured (or a test
//! injects none), reboot/shutdown report `not_implemented` — never a fake
//! power-off. The reset call is issued through a function pointer typed
//! **non-noreturn** (ABI-identical to the real `_resetSystem`; only the
//! declared return type differs) so that if the firmware returns anyway the
//! kernel parks in a WFE loop instead of running off the end.
//!
//! Evidence: immediately before the reset call the kernel persists the
//! `M2_RST!` stage as the claim-0009 NVRAM variable (`DipshitM2`), so the
//! host can see in `artifacts/efi-vars.bin` that the call fired.
//!
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const monitor = @import("monitor.zig");

const RuntimeServices = uefi.tables.RuntimeServices;
const ResetType = uefi.tables.ResetType;
const Status = uefi.Status;
const MachineResult = monitor.MachineResult;
const MachineControl = monitor.MachineControl;

/// EFI Runtime Services `ResetSystem` as a **non-noreturn** function type.
/// The real `_resetSystem` pointer is declared `noreturn`; casting it to
/// this ABI-identical signature (same parameters, same calling convention;
/// only the declared return type differs) is what lets the kernel park in
/// WFE if the firmware returns anyway — code after a `noreturn` call would
/// otherwise be unreachable.
pub const ResetSystemFn = *const fn (
    reset_type: ResetType,
    reset_status: Status,
    data_size: usize,
    reset_data: ?[*]const u16,
) callconv(uefi.cc) void;

/// EFI Runtime Services `SetVariable` — the claim-0009 NVRAM marker channel.
const SetVariableFn = *const fn (
    var_name: [*:0]const u16,
    vendor_guid: *const uefi.Guid,
    attributes: RuntimeServices.VariableAttributes,
    data_size: usize,
    data: [*]const u8,
) callconv(uefi.cc) Status;

// ---------------------------------------------------------------------------
// State and machine control
// ---------------------------------------------------------------------------

/// M1.5 machine-control state. The kernel is single-threaded and this
/// module has no entry points beyond `init`/`control`, so module-level
/// state is safe; tests exercise the same surface with injected fakes.
const State = struct {
    reset_fn: ?ResetSystemFn = null,
    set_var_fn: ?SetVariableFn = null,

    /// Issue one reset: persist the `M2_RST!` marker, then call ResetSystem
    /// with status 0 (EFI_SUCCESS) and no reset data. Returns
    /// `.not_implemented` when no runtime-services pointer was captured.
    /// Returns `.ok` only if the (non-noreturn) call comes back — real
    /// firmware never does; the vtable wrapper then parks.
    fn do_reset(self: *State, reset_type: ResetType) MachineResult {
        const reset = self.reset_fn orelse return .not_implemented;
        const set_var = self.set_var_fn orelse return .not_implemented;
        write_rst_marker(set_var);
        reset(reset_type, .success, 0, null);
        return .ok;
    }
};

/// Module state, captured once by `init` (kernel_main, pre-exit).
var state: State = .{};

/// Capture the EFI Runtime Services table so reboot/shutdown can call
/// `ResetSystem` after ExitBootServices. Called once, pre-exit, from
/// kernel_main. If it is never called, reboot/shutdown honestly report
/// `.not_implemented`.
pub fn init(rt: *RuntimeServices) void {
    state.reset_fn = @ptrCast(rt._resetSystem);
    state.set_var_fn = @ptrCast(rt._setVariable);
}

/// The M1.5 machine-control implementation for the monitor seam: real
/// ResetSystem-backed reboot/shutdown, honest `not_implemented` when no
/// runtime services were captured.
pub fn control() MachineControl {
    const Impl = struct {
        fn reboot(ctx: *anyopaque) MachineResult {
            const self: *State = @ptrCast(@alignCast(ctx));
            const result = self.do_reset(.cold);
            if (result == .ok) park(); // firmware returned anyway: park honestly
            return result;
        }
        fn shutdown(ctx: *anyopaque) MachineResult {
            const self: *State = @ptrCast(@alignCast(ctx));
            const result = self.do_reset(.shutdown);
            if (result == .ok) park(); // firmware returned anyway: park honestly
            return result;
        }
    };
    return .{
        .ctx = &state,
        .vtable = &.{ .reboot = Impl.reboot, .shutdown = Impl.shutdown },
    };
}

/// ResetSystem is declared noreturn; if a firmware returns anyway the
/// kernel must not run off the end — it parks in a WFE loop. On the host
/// (tests only) this is unreachable unless a test deliberately drives a
/// returning fake through the full vtable path, which is a bug and should
/// fail loudly.
fn park() noreturn {
    if (comptime builtin.cpu.arch == .aarch64) {
        while (true) asm volatile ("wfe");
    } else {
        unreachable;
    }
}

// ---------------------------------------------------------------------------
// Claim-0009 NVRAM marker channel (mirrors kernel/src/main.zig's ladder)
// ---------------------------------------------------------------------------

/// "M2_RST!" (7 chars + NUL), stored little-endian as a u64 — the same
/// convention as main.zig's M2_* stage words. `M2_RST!` marks the instant
/// immediately before the ResetSystem call, so a host-side scan of
/// artifacts/efi-vars.bin can prove the call fired.
const marker_rst: u64 = 0x00215453525f324d;

const marker_variable_name = utf16z("DipshitM2");
const marker_vendor_guid = uefi.Guid{
    .time_low = 0x4d324d32, // "M2M2"
    .time_mid = 0x5f44, // "_D"
    .time_high_and_version = 0x4950, // "IP"
    .clock_seq_high_and_reserved = 0x53, // "S"
    .clock_seq_low = 0x48, // "H"
    .node = .{ 0x49, 0x54, 0x4f, 0x53, 0x2d, 0x4d }, // "ITOS-M"
};

fn utf16z(comptime text: []const u8) [text.len + 1:0]u16 {
    var result: [text.len + 1:0]u16 = undefined;
    for (text, 0..) |byte, index| result[index] = byte;
    result[text.len] = 0;
    return result;
}

/// Best-effort persist of the `M2_RST!` stage. A failed runtime call never
/// changes control flow; the real evidence is the reset call itself.
fn write_rst_marker(set_var: SetVariableFn) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, marker_rst, .little);
    _ = set_var(
        &marker_variable_name,
        &marker_vendor_guid,
        .{ .non_volatile = true, .bootservice_access = true, .runtime_access = true },
        bytes.len,
        &bytes,
    );
}

// ---------------------------------------------------------------------------
// Tests (host-side; injected fakes, no hardware)
// ---------------------------------------------------------------------------

var spy_reset_type: ?ResetType = null;
var spy_reset_status: ?Status = null;
var spy_data_size: ?usize = null;
var spy_reset_data: ?[*]const u16 = null;
var spy_set_var_calls: usize = 0;
var spy_marker_bytes: [8]u8 = undefined;
var spy_marker_len: usize = 0;

fn spyReset(
    reset_type: ResetType,
    reset_status: Status,
    data_size: usize,
    reset_data: ?[*]const u16,
) callconv(uefi.cc) void {
    spy_reset_type = reset_type;
    spy_reset_status = reset_status;
    spy_data_size = data_size;
    spy_reset_data = reset_data;
}

fn spySetVar(
    _: [*:0]const u16,
    _: *const uefi.Guid,
    _: RuntimeServices.VariableAttributes,
    data_size: usize,
    data: [*]const u8,
) callconv(uefi.cc) Status {
    spy_set_var_calls += 1;
    spy_marker_len = @min(data_size, spy_marker_bytes.len);
    @memcpy(spy_marker_bytes[0..spy_marker_len], data[0..spy_marker_len]);
    return .success;
}

/// Reset module state to a spy-backed state and clear the spy counters so
/// tests are independent (module-level spies accumulate otherwise).
fn make_state() *State {
    spy_reset_type = null;
    spy_reset_status = null;
    spy_data_size = null;
    spy_reset_data = null;
    spy_set_var_calls = 0;
    spy_marker_len = 0;
    state = .{
        .reset_fn = &spyReset,
        .set_var_fn = &spySetVar,
    };
    return &state;
}

test "machine: reboot issues a cold reset with success status and no data" {
    const st = make_state();
    try std.testing.expectEqual(MachineResult.ok, st.do_reset(.cold));
    try std.testing.expectEqual(ResetType.cold, spy_reset_type.?);
    try std.testing.expectEqual(Status.success, spy_reset_status.?);
    try std.testing.expectEqual(@as(usize, 0), spy_data_size.?);
    try std.testing.expect(spy_reset_data == null);
}

test "machine: shutdown issues a shutdown reset with success status and no data" {
    const st = make_state();
    try std.testing.expectEqual(MachineResult.ok, st.do_reset(.shutdown));
    try std.testing.expectEqual(ResetType.shutdown, spy_reset_type.?);
    try std.testing.expectEqual(Status.success, spy_reset_status.?);
    try std.testing.expectEqual(@as(usize, 0), spy_data_size.?);
    try std.testing.expect(spy_reset_data == null);
}

test "machine: the M2_RST! marker is persisted before the reset call" {
    const st = make_state();
    _ = st.do_reset(.cold);
    try std.testing.expectEqual(@as(usize, 1), spy_set_var_calls);
    try std.testing.expectEqual(@as(usize, 8), spy_marker_len);
    try std.testing.expectEqualStrings("M2_RST!\x00", spy_marker_bytes[0..8]);
}

test "machine: no captured runtime services reports not_implemented honestly" {
    state = .{};
    spy_reset_type = null;
    spy_reset_status = null;
    spy_data_size = null;
    spy_reset_data = null;
    spy_set_var_calls = 0;
    try std.testing.expectEqual(MachineResult.not_implemented, state.do_reset(.cold));
    try std.testing.expectEqual(MachineResult.not_implemented, state.do_reset(.shutdown));
    try std.testing.expectEqual(@as(usize, 0), spy_set_var_calls);
}

test "machine: control() wires the monitor MachineControl shape" {
    _ = make_state();
    const control_val = control();
    // The vtable is wired onto module state and exposes distinct reboot/
    // shutdown entries, shaped exactly like monitor.MachineControl. (A
    // returning fake drives the non-noreturn call; the wrapper's post-ok
    // park is only reachable in the kernel if real firmware misbehaves, so
    // the full wrapper path is not exercised on the host.)
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&state)), control_val.ctx);
    try std.testing.expect(control_val.vtable.reboot != control_val.vtable.shutdown);
}
