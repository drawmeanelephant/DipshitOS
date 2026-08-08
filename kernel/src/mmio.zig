//! Volatile MMIO register accessors (extracted verbatim from the former
//! kernel/src/main.zig junk drawer; claim 0023 mechanical split).
//!
//! The kernel's post-ExitBootServices world is direct memory/register
//! access only: every device read/write goes through these volatile
//! accesses so the compiler can never reorder, cache, or elide them.
//! Shared by the PCI config-space code (pci.zig), the virtio-pci console
//! transport (virtio_console.zig), the serial probe/console driver
//! (main.zig), and the diagnostic dump machinery (evidence.zig).
//!
//! No libc, no POSIX, no allocation.

pub fn mmio_read32(address: u64) u32 {
    return @as(*volatile u32, @ptrFromInt(address)).*;
}

pub fn mmio_read64(address: u64) u64 {
    return @as(*volatile u64, @ptrFromInt(address)).*;
}

pub fn mmio_write64(address: u64, value: u64) void {
    @as(*volatile u64, @ptrFromInt(address)).* = value;
}

pub fn mmio_write32(address: u64, value: u32) void {
    @as(*volatile u32, @ptrFromInt(address)).* = value;
}

pub fn mmio_read8(address: u64) u8 {
    return @as(*volatile u8, @ptrFromInt(address)).*;
}

pub fn mmio_write8(address: u64, value: u8) void {
    @as(*volatile u8, @ptrFromInt(address)).* = value;
}

pub fn mmio_read16(address: u64) u16 {
    return @as(*volatile u16, @ptrFromInt(address)).*;
}

pub fn mmio_write16(address: u64, value: u16) void {
    @as(*volatile u16, @ptrFromInt(address)).* = value;
}
