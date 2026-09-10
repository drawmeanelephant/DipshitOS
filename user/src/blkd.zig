//! VirelaiOS M43 U3 EL0 consumer — BLKD.BIN (issue #1034, claim #1048).
//!
//! Reads the raw USB mass-storage disk through the M10 file-table seam:
//!   1. sys_file_open("usb", 3, MODE_READ) -> fd   (slot 23)
//!   2. sys_file_read(fd, buf, 1024)       -> n    (slot 24; LBA 0 + LBA 1)
//!   3. prints `blkd: pattern=` + the first 14 bytes of the host-staged
//!      LBA-1 marker, then `blkd: done`
//!   4. sys_file_close(fd) (slot 26); sys_exit(0) (slot 3)
//!
//! The gate's MSD image stages the ASCII marker "M43USBMSDPROBE" at LBA 1,
//! so the transcript asserts those bytes — content staged on the disk by
//! the host is observed BYTE-EXACT from EL0 through the new `.usb` volume.

const std = @import("std");

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// 1. open("usb", 3, MODE_READ=1)
        \\adr x0, 1f
        \\mov x1, #3
        \\mov x2, #1
        \\mov x8, #23
        \\svc #0
        \\cmp x0, #0
        \\b.ge 10f
        \\// open failed: say so and exit 1
        \\mov x0, #1
        \\adr x1, 5f
        \\mov x2, #18
        \\mov x8, #1
        \\svc #0
        \\mov x0, #1
        \\mov x8, #3
        \\svc #0
        \\10:
        \\mov x19, x0 // fd
        \\// 2. read(fd, sp-1024, 1024) — LBA 0 (MBR) + LBA 1 (marker)
        \\sub sp, sp, #1024
        \\mov x0, x19
        \\mov x1, sp
        \\mov x2, #1024
        \\mov x8, #24
        \\svc #0
        \\// 3a. write(1, "blkd: pattern=", 14)
        \\mov x0, #1
        \\adr x1, 2f
        \\mov x2, #14
        \\mov x8, #1
        \\svc #0
        \\// 3b. write(1, sp+512, 14) — the LBA-1 marker bytes. Printed even
        \\// on a short read: the gate must see the real bytes (or junk), and
        \\// fail loudly; the app never invents content.
        \\mov x0, #1
        \\add x1, sp, #512
        \\mov x2, #14
        \\mov x8, #1
        \\svc #0
        \\// 3c. write(1, "\nblkd: done\n", 12)
        \\mov x0, #1
        \\adr x1, 3f
        \\mov x2, #12
        \\mov x8, #1
        \\svc #0
        \\// 4. close(fd)
        \\mov x0, x19
        \\mov x8, #26
        \\svc #0
        \\// 5. exit(0)
        \\add sp, sp, #1024
        \\mov x0, #0
        \\mov x8, #3
        \\svc #0
        \\1:
        \\.ascii "usb"
        \\2:
        \\.ascii "blkd: pattern="
        \\3:
        \\.ascii "\nblkd: done\n"
        \\5:
        \\.ascii "blkd: open failed\n"
    );
}
