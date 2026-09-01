//! VirelaiOS twelfth ESP user program — TYPE.BIN (milestone ten, card F4, claim 0510).
//!
//! Reads and echoes persistent data from `/host/hello.txt` from EL0 (M34
//! HF5 issue #739 — user data lives in the host folder):
//!   1. `sys_file_open("/host/hello.txt", 15, MODE_READ(1))` (slot 23).
//!   2. `sys_file_read(fd, buf, 64)` (slot 24).
//!   3. `sys_file_close(fd)` (slot 26).
//!   4. `sys_write(1, "type: read ", 11)` (slot 1) + `sys_write(1, buf, count)` (slot 1).
//!   5. `sys_write(1, "type: success\n", 14)` (slot 1).
//!   6. `sys_exit(0)` (slot 3).

const std = @import("std");

pub const filename: []const u8 = "/host/hello.txt"; // M34 HF5 (#739)
pub const prefix_line: []const u8 = "type: read ";
pub const success_line: []const u8 = "type: success\n";

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// 1. sys_file_open("/host/hello.txt", 15, MODE_READ = 1)
        \\adr x0, 1f
        \\mov x1, #15
        \\mov x2, #1
        \\mov x8, #23
        \\svc #0
        \\cmp x0, #0
        \\b.lt 0f
        \\mov x19, x0 // fd
        \\
        \\// 2. sys_file_read(fd, sp, 64)
        \\sub sp, sp, #64
        \\mov x0, x19
        \\mov x1, sp
        \\mov x2, #64
        \\mov x8, #24
        \\svc #0
        \\cmp x0, #0
        \\b.le 0f
        \\mov x20, x0 // bytes read
        \\
        \\// 3. sys_file_close(fd)
        \\mov x0, x19
        \\mov x8, #26
        \\svc #0
        \\cmp x0, #0
        \\b.ne 0f
        \\
        \\// 4. sys_write(1, prefix_line, 11)
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #11
        \\mov x8, #1
        \\svc #0
        \\
        \\// 5. sys_write(1, buf, bytes_read)
        \\mov x0, #1
        \\mov x1, sp
        \\mov x2, x20
        \\mov x8, #1
        \\svc #0
        \\
        \\// 6. sys_write(1, success_line, 14)
        \\mov x0, #1
        \\adr x1, 3f
        \\mov x2, #14
        \\mov x8, #1
        \\svc #0
        \\
        \\// 7. sys_exit(0)
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
        \\1: .ascii "/host/hello.txt"
        \\2: .ascii "type: read "
        \\3: .ascii "type: success\n"
    );
}
