//! Handoff-v2 contract: shared struct definition and validation
//! (ADR 0004 D5, Milestone 1.5 commands & personality).
//!
//! The boot stub allocates this 4K-aligned `EfiLoaderData` page and passes
//! its pointer in x3; the milestone-two kernel validates it on entry. This
//! module is the canonical struct for the monitor command layer and its
//! host-side tests. The later Console & Shell Core stream may switch
//! `kernel/src/main.zig`'s private copy to import this module.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");

pub const magic: u32 = 0x324b5344; // "DSK2"
pub const version: u32 = 2;
pub const expected_stack_size: u64 = 16 * 1024; // 16 KiB, ADR 0004 D5

/// Exact ADR 0004 D5 layout, offsets 0..56.
pub const HandoffV2 = extern struct {
    magic: u32,
    version: u32,
    kernel_base: u64,
    kernel_size: u64,
    system_table: u64,
    image_handle: u64,
    stack_base: u64,
    stack_size: u64,
    flags: u64,
};

pub const ValidateError = enum {
    none,
    bad_magic,
    bad_version,
    bad_flags,
    bad_stack_size,
    unaligned_kernel_base,
    unaligned_stack_base,
    zero_image_handle,
    zero_stack_base,
    zero_kernel_size,
    kernel_bounds_overflow,
    stack_bounds_overflow,
};

/// Struct-internal validation of a handoff-v2 record. Entry-time mirror
/// checks against the x0/x2 register arguments (`kernel_base == base`,
/// `system_table == st`) are performed by the kernel entry path, not here:
/// the monitor only ever sees the struct, and displays its validity.
pub fn validate(h: *const HandoffV2) ValidateError {
    if (h.magic != magic) return .bad_magic;
    if (h.version != version) return .bad_version;
    if (h.flags != 0) return .bad_flags;
    if (h.stack_size != expected_stack_size) return .bad_stack_size;
    if ((h.kernel_base & 0xfff) != 0) return .unaligned_kernel_base;
    if ((h.stack_base & 0xfff) != 0) return .unaligned_stack_base;
    if (h.image_handle == 0) return .zero_image_handle;
    if (h.stack_base == 0) return .zero_stack_base;
    if (h.kernel_size == 0) return .zero_kernel_size;
    if (h.kernel_base > std.math.maxInt(u64) - h.kernel_size) return .kernel_bounds_overflow;
    if (h.stack_base > std.math.maxInt(u64) - h.stack_size) return .stack_bounds_overflow;
    return .none;
}

/// Short, deterministic reason string for diagnostics.
pub fn error_name(err: ValidateError) []const u8 {
    return switch (err) {
        .none => "valid",
        .bad_magic => "bad magic",
        .bad_version => "bad version",
        .bad_flags => "nonzero flags",
        .bad_stack_size => "bad stack size",
        .unaligned_kernel_base => "unaligned kernel base",
        .unaligned_stack_base => "unaligned stack base",
        .zero_image_handle => "zero image handle",
        .zero_stack_base => "zero stack base",
        .zero_kernel_size => "zero kernel size",
        .kernel_bounds_overflow => "kernel bounds overflow",
        .stack_bounds_overflow => "stack bounds overflow",
    };
}

fn valid_fixture() HandoffV2 {
    return .{
        .magic = magic,
        .version = version,
        .kernel_base = 0x7e4df000,
        .kernel_size = 0x823e8,
        .system_table = 0xfeed000,
        .image_handle = 0x2,
        .stack_base = 0x7e520000,
        .stack_size = expected_stack_size,
        .flags = 0,
    };
}

test "handoff: valid fixture passes" {
    var h = valid_fixture();
    try std.testing.expectEqual(ValidateError.none, validate(&h));
}

test "handoff: each corruption is rejected with a specific reason" {
    var h = valid_fixture();

    h.magic = 0xdeadbeef;
    try std.testing.expectEqual(ValidateError.bad_magic, validate(&h));
    h = valid_fixture();

    h.version = 1;
    try std.testing.expectEqual(ValidateError.bad_version, validate(&h));
    h = valid_fixture();

    h.flags = 1;
    try std.testing.expectEqual(ValidateError.bad_flags, validate(&h));
    h = valid_fixture();

    h.stack_size = 4096;
    try std.testing.expectEqual(ValidateError.bad_stack_size, validate(&h));
    h = valid_fixture();

    h.kernel_base = 0x7e4df001;
    try std.testing.expectEqual(ValidateError.unaligned_kernel_base, validate(&h));
    h = valid_fixture();

    h.stack_base = 0x7e520001;
    try std.testing.expectEqual(ValidateError.unaligned_stack_base, validate(&h));
    h = valid_fixture();

    h.image_handle = 0;
    try std.testing.expectEqual(ValidateError.zero_image_handle, validate(&h));
    h = valid_fixture();

    h.stack_base = 0;
    try std.testing.expectEqual(ValidateError.zero_stack_base, validate(&h));
    h = valid_fixture();

    h.kernel_size = 0;
    try std.testing.expectEqual(ValidateError.zero_kernel_size, validate(&h));
    h = valid_fixture();

    h.kernel_base = std.math.maxInt(u64) - 0xfff;
    h.kernel_size = 0x2000;
    try std.testing.expectEqual(ValidateError.kernel_bounds_overflow, validate(&h));
    h = valid_fixture();

    h.stack_base = std.math.maxInt(u64) - 0xfff;
    try std.testing.expectEqual(ValidateError.stack_bounds_overflow, validate(&h));
}

test "handoff: error_name returns deterministic strings" {
    try std.testing.expectEqualStrings("valid", error_name(.none));
    try std.testing.expectEqualStrings("bad magic", error_name(.bad_magic));
    try std.testing.expectEqualStrings("bad version", error_name(.bad_version));
    try std.testing.expectEqualStrings("unaligned stack base", error_name(.unaligned_stack_base));
}
