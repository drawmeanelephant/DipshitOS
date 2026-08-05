//! DipshitOS milestone-zero boot application.
//!
//! A minimal AArch64 UEFI application. It prints a fixed two-line message to
//! the UEFI Simple Text Output protocol (ConOut), waits briefly so the text
//! is visible, then returns control to the firmware (EFI_SUCCESS).
//!
//! Observation note: Apple's Virtualization EFI firmware does not route
//! ConOut to the virtio serial console or render it to the virtio-gpu
//! framebuffer, so the same two lines are ALSO written to `\BOOTED.TXT` on
//! the ESP using the UEFI Simple File System protocol. That file is
//! host-observable after the VM stops and is the primary execution evidence
//! on Apple silicon. This is still pure UEFI services: no libc, no POSIX,
//! no filesystem driver of our own.
//!
//! Zig 0.16.0 adjustment: older Zig examples exported `efi_main` with
//! `callconv(.win64)`. Zig 0.16's `std.start` for the `uefi` OS target
//! instead exports `EfiMain` (callconv(.c), which on AArch64 is AAPCS64) and
//! calls our `pub fn main() void`. It installs the firmware-provided EFI
//! System Table into `std.os.uefi.system_table` before main runs; that is
//! where we read ConOut and Boot Services from.

const std = @import("std");
const uefi = std.os.uefi;

/// Convert a comptime ASCII string into a null-terminated UTF-16LE array as
/// required by the EFI APIs. (All of our strings are pure ASCII.)
fn utf16z(comptime s: []const u8) [s.len + 1:0]u16 {
    var buf: [s.len + 1:0]u16 = undefined;
    for (s, 0..) |c, i| buf[i] = c;
    buf[s.len] = 0;
    return buf;
}

const line_banner = utf16z("DIPSHITOS BOOTLOADER\r\n");
const line_confirm = utf16z("firmware has agreed to cooperate\r\n");
const marker_path = utf16z("\\BOOTED.TXT");
const marker_text = "DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n";

pub fn main() void {
    const st = uefi.system_table;

    // 1. Primary action: print via the UEFI Simple Text Output protocol.
    if (st.con_out) |con_out| {
        _ = con_out.outputString(&line_banner) catch {};
        _ = con_out.outputString(&line_confirm) catch {};
    }

    // 2. Evidence: write the same message to \BOOTED.TXT on the ESP using
    //    the firmware's Simple File System protocol. Best effort only.
    write_marker(st);

    // Wait safely for a short while (a pure, memory-free busy loop) so the
    // message stays on screen, then fall through and return to the firmware.
    wait_a_moment();
}

/// Locate the volume the firmware loaded us from, open \BOOTED.TXT and write
/// the confirmation text. Uses only UEFI Boot Services + File protocols.
/// Any failure is silently ignored: the app must run even if the firmware
/// provides no writable filesystem.
fn write_marker(st: *const uefi.tables.SystemTable) void {
    const boot_services = st.boot_services orelse return;

    const loaded_image = (boot_services.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch null) orelse return;
    const device_handle = loaded_image.device_handle orelse return;

    const fs = (boot_services.handleProtocol(uefi.protocol.SimpleFileSystem, device_handle) catch null) orelse return;
    const root = fs.openVolume() catch return;
    defer root.close() catch {};

    const marker = root.open(&marker_path, .read_write_create, .{}) catch return;
    defer marker.close() catch {};

    _ = marker.write(marker_text) catch {};
    marker.flush() catch {};
}

fn wait_a_moment() void {
    var i: u64 = 0;
    while (i < 1_500_000_000) : (i += 1) {
        // The volatile asm prevents the optimizer from eliminating the loop.
        // (Zig 0.16 clobber syntax: a struct literal of clobber flags.)
        asm volatile ("" ::: .{ .memory = true });
    }
}
