// Kernel stub for the handoff milestone.
const std = @import("std");

pub const BootInfo = struct {
    base: u64,
    size: u64,
};

pub fn handoff(info: *BootInfo) u64 {
    _ = info;
    return 0;
}

const MAX_IMAGE_SIZE: u64 = 16 * 1024 * 1024;
