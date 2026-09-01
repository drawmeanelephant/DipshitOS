//! VirelaiOS thirteenth ESP user program — DIR.BIN (milestone ten, card F4, claim 0510).
//!
//! Enumerates directory entries from EL0 (M34 HF5 issue #739 — the
//! listing target is the host folder):
//!   1. `sys_dir_list("/host", 5, buf, 8)` (slot 27).
//!   2. `sys_write(1, "dir: listing /host\n", 19)` (slot 1).
//!   3. For each entry, writes name to console.
//!   4. `sys_write(1, "dir: success\n", 13)` (slot 1).
//!   5. `sys_exit(0)` (slot 3).

const std = @import("std");

pub const target_path: []const u8 = "/host"; // M34 HF5 (#739)
pub const header_line: []const u8 = "dir: listing /host\n";
pub const success_line: []const u8 = "dir: success\n";

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// 1. sys_dir_list("/host", 5, sp, 8)
        \\sub sp, sp, #320 // 8 entries * 40 bytes
        \\adr x0, 1f
        \\mov x1, #5
        \\mov x2, sp
        \\mov x3, #8
        \\mov x8, #27
        \\svc #0
        \\cmp x0, #0
        \\b.lt 0f
        \\mov x19, x0 // entry count
        \\
        \\// 2. sys_write(1, header_line, 19)
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #19
        \\mov x8, #1
        \\svc #0
        \\
        \\// 3. Print entries
        \\mov x21, sp // pointer to current DirEntry
        \\10:
        \\cmp x19, #0
        \\b.eq 12f
        \\
        \\// Write entry prefix: "  "
        \\mov x0, #1
        \\adr x1, 4f
        \\mov x2, #2
        \\mov x8, #1
        \\svc #0
        \\
        \\// Write entry name (up to 32 bytes or until null)
        \\mov x0, #1
        \\mov x1, x21
        \\mov x2, #32
        \\mov x8, #1
        \\svc #0
        \\
        \\// Newline
        \\mov x0, #1
        \\adr x1, 5f
        \\mov x2, #1
        \\mov x8, #1
        \\svc #0
        \\
        \\add x21, x21, #40 // next DirEntry
        \\sub x19, x19, #1
        \\b 10b
        \\
        \\12:
        \\// 4. sys_write(1, success_line, 13)
        \\mov x0, #1
        \\adr x1, 3f
        \\mov x2, #13
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
        \\1: .ascii "/host"
        \\2: .ascii "dir: listing /host\n"
        \\3: .ascii "dir: success\n"
        \\4: .ascii "  "
        \\5: .ascii "\n"
    );
}
