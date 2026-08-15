//! DipshitOS eleventh ESP user program — SAVETEXT.BIN (milestone ten, card F4, claim 0510).
//!
//! Creates and writes persistent data to `/data/hello.txt` from EL0:
//!   1. `sys_file_open("/data/hello.txt", 15, MODE_CREATE | MODE_WRITE)` (slot 23).
//!   2. `sys_file_write(fd, "Hello from DipshitOS EL0 Storage!\n", 34)` (slot 25).
//!   3. `sys_file_close(fd)` (slot 26).
//!   4. `sys_write(1, "savetext: wrote /data/hello.txt\n", 32)` (slot 1).
//!   5. `sys_exit(0)` (slot 3).

const std = @import("std");

pub const filename: []const u8 = "/data/hello.txt";
pub const content: []const u8 = "Hello from DipshitOS EL0 Storage!\n";
pub const done_line: []const u8 = "savetext: wrote /data/hello.txt\n";

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// 1. sys_file_open("/data/hello.txt", 15, MODE_CREATE(4) | MODE_WRITE(2) = 6)
        \\adr x0, 1f
        \\mov x1, #15
        \\mov x2, #6
        \\mov x8, #23
        \\svc #0
        \\// Check fd >= 0
        \\cmp x0, #0
        \\b.lt 0f
        \\mov x19, x0 // Save fd in x19
        \\
        \\// 2. sys_file_write(fd, content, 34)
        \\mov x0, x19
        \\adr x1, 2f
        \\mov x2, #34
        \\mov x8, #25
        \\svc #0
        \\cmp x0, #34
        \\b.ne 0f
        \\
        \\// 3. sys_file_close(fd)
        \\mov x0, x19
        \\mov x8, #26
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\
        \\// 4. sys_write(1, done_line, 32)
        \\mov x0, #1
        \\adr x1, 3f
        \\mov x2, #32
        \\mov x8, #1
        \\svc #0
        \\
        \\// 5. sys_exit(0)
        \\mov x0, #0
        \\mov x8, #3
        \\svc #0
        \\
        \\// Error trap
        \\0:
        \\wfi
        \\b 0b
        \\
        \\// Literals
        \\.p2align 2
        \\1: .ascii "/data/hello.txt"
        \\2: .ascii "Hello from DipshitOS EL0 Storage!\n"
        \\3: .ascii "savetext: wrote /data/hello.txt\n"
    );
}
