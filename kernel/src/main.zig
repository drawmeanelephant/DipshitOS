//! DipshitOS milestone-one kernel stub.
//!
//! The smallest freestanding AArch64 thing that proves control was
//! transferred from the boot loader. It is compiled for `aarch64-
//! freestanding` (no libc, no POSIX, no OS) and linked into the flat
//! kernel image `KERNEL.BIN` by `tools/elf2bin.py` (see
//! docs/decisions/0002-kernel-handoff.md for the format).
//!
//! Handoff ABI (AAPCS, registers on entry -- see ADR 0002):
//!   x0 = kernel image base address (4K-aligned)
//!   x1 = kernel image size in bytes
//!   x2 = pointer to the EFI System Table
//!   x3 = pointer to the already-open ESP root directory (EFI File protocol)
//! Returns a u64 status in x0 (0 = success).
//!
//! The kernel attempts to write its own evidence, \KERNEL.TXT, on the ESP
//! via the UEFI Simple File System protocol -- the same mechanism the boot
//! loader uses for \BOOTED.TXT -- including the *observed* base address,
//! size, and System Table pointer, then returns to the loader. It
//! deliberately does NOT call ExitBootServices (a documented milestone-one
//! decision): it still runs with the full UEFI Boot Services environment,
//! on the loader's stack.
//!
//! Observed on Apple Virtualization.framework (macOS 27 / Apple silicon):
//! the loader's own file writes (BOOTED.TXT, LOADER.TXT, MEMMAP.TXT,
//! RC.TXT) land byte-perfect, and -- since the loader places the kernel
//! CONTENT at base+0 (the 24-byte DSK1 header is parsed but not loaded into
//! RAM) -- the kernel's own \KERNEL.TXT write lands byte-perfect too. See
//! ADR 0002 for the resolved scramble root cause: when the content sat at
//! base+24 (file loaded verbatim), LLVM's ADRP+ADD references to .rodata
//! computed (PC page) + VMA offset and silently dropped the +24, reading
//! every literal 24 bytes early; ADR references carry the +24 inside the
//! PC and were unaffected. With the content at base+0 both forms resolve
//! to the correct bytes.
//!
//! Position independence: Zig/LLVM addresses everything in this kernel with
//! PC-relative instructions (adr/adrp; verified by disassembly), so the
//! image can be loaded at any 4K-aligned base without relocations.

const std = @import("std");
const uefi = std.os.uefi;

const SystemTable = uefi.tables.SystemTable;
const File = uefi.protocol.File;

/// Convert a comptime ASCII string into a null-terminated UTF-16LE array as
/// required by the EFI APIs. (All of our strings are pure ASCII.)
fn utf16z(comptime s: []const u8) [s.len + 1:0]u16 {
    var buf: [s.len + 1:0]u16 = undefined;
    for (s, 0..) |c, i| buf[i] = c;
    buf[s.len] = 0;
    return buf;
}

const line_banner = utf16z("DIPSHITOS KERNEL\r\n");
const marker_path = utf16z("\\KERNEL.TXT");

/// Kernel entry point. Runs entirely in registers + loader stack; only uses
/// UEFI Boot Services. Best-effort evidence writing (must never crash the
/// boot even if the volume is unwritable).
export fn _start(
    base: u64,
    size: u64,
    system_table: *const SystemTable,
    root: *File,
) callconv(.c) u64 {
    // 1. Evidence: our own marker file, written by the kernel itself via the
    //    UEFI Simple File System protocol (root volume passed by the loader).
    write_marker(root, base, size, @intFromPtr(system_table));

    // 2. Print via ConOut (Apple's VZ firmware routes no text to
    //    serial/framebuffer -- see README -- but the call is harmless).
    if (system_table.con_out) |con_out| {
        _ = con_out.outputString(&line_banner) catch {};
    }

    // 3. Return to the loader, which returns to the firmware.
    return 0;
}

/// Open \KERNEL.TXT (create if absent) and write the observed handoff state.
/// Best effort: any failure returns quietly.
fn write_marker(root: *File, base: u64, size: u64, st: u64) void {
    const marker = root.open(&marker_path, .read_write_create, .{}) catch return;
    defer marker.close() catch {};

    var content: [192]u8 = undefined;
    var n: usize = 0;
    n += copy_into(content[n..], "DIPSHITOS KERNEL\n");
    n += copy_into(content[n..], "entry reached via handoff\n");
    n += copy_into(content[n..], "base=");
    n += append_hex(content[n..], base);
    n += copy_into(content[n..], " size=");
    n += append_hex(content[n..], size);
    n += copy_into(content[n..], " st=");
    n += append_hex(content[n..], st);
    n += copy_into(content[n..], "\n");

    _ = marker.write(content[0..n]) catch {};
    marker.flush() catch {};
}

fn copy_into(dst: []u8, src: []const u8) usize {
    @memcpy(dst[0..src.len], src);
    return src.len;
}

/// Write "0x" + 16 lowercase hex digits of `value` into `buf` and return the
/// number of bytes written (18). Pure register arithmetic, no data section,
/// no libc; never aliases `buf` back onto itself.
fn append_hex(buf: []u8, value: u64) usize {
    buf[0] = '0';
    buf[1] = 'x';
    var v = value;
    var i: usize = 15;
    while (true) : (i -= 1) {
        const d: u8 = @intCast(v & 0xf);
        buf[2 + i] = if (d < 10) '0' + d else 'a' + (d - 10);
        v >>= 4;
        if (i == 0) break;
    }
    return 18;
}
