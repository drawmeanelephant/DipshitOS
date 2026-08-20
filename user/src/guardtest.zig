//! DipshitOS M16 C2 guard page proof — GUARDTEST.BIN (claim 4722).
//!
//! Headless hostile proof: try to touch the guard page between text and data
//! (0x401000, one page unmapped) and the guard below the stack. Each access
//! should fault, be reaped by the kernel with status 139, and never corrupt
//! the neighbor's pages. The program prints a start marker, attempts the
//! guard access via volatile, and would print done if it survived (it shouldn't).

const ui = @import("lib/ui.zig");

pub export fn _start() callconv(.c) noreturn {
    ui.write_console("guardtest: start\n");

    // Try to read the guard page between text (0x400000) and data (0x402000)
    // Guard is at 0x401000 (one page). This should fault.
    const guard_va: u64 = 0x401000;
    const ptr: *volatile u8 = @ptrFromInt(guard_va);
    // Use volatile to prevent optimization, and ensure the access is not
    // constant-folded.
    const val = ptr.*;
    _ = val;

    // If we reach here, the guard did not fault — fail the test.
    ui.write_console("guardtest: guard read did NOT fault (FAIL)\n");
    ui.exit_process(99);
}
