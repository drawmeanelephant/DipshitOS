//! DipshitOS twenty-second ESP user program — FSTEST.BIN (Milestone 13, Card B1).
//!
//! Headless class-B proof for the mutating filesystem seam (ADR 0007 slots
//! 34–37, claim 5801): create + write, truncate, read back, rename, free-space
//! query, and delete — one sequence against the DATA partition, printing a
//! marker after each step for `tools/verify-live-fs-mutation.sh`.

const ui = @import("lib/ui.zig");

pub const path: []const u8 = "/data/b1test.txt";
pub const renamed_path: []const u8 = "/data/b1ren.txt";
pub const content: []const u8 = "hello world";

fn append_str(buf: []u8, pos: usize, src: []const u8) usize {
    @memcpy(buf[pos .. pos + src.len], src);
    return pos + src.len;
}

fn fmt_u64(buf: []u8, value: u64) []const u8 {
    var v = value;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
        return buf[i..];
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
    }
    return buf[i..];
}

pub export fn _start() callconv(.c) noreturn {
    // 1. Create + write the scratch file.
    const fd = ui.file_open(path, ui.MODE_CREATE | ui.MODE_WRITE);
    if (fd < 0) {
        ui.write_console("fstest: open failed\n");
        ui.exit_process(1);
    }
    const w = ui.file_write(@as(u32, @intCast(fd)), content);
    ui.file_close(@as(u32, @intCast(fd)));
    if (w != content.len) {
        ui.write_console("fstest: write failed\n");
        ui.exit_process(1);
    }
    ui.write_console("fstest: wrote\n");

    // 2. Truncate the file to 5 bytes (slot 36).
    const fd2 = ui.file_open(path, ui.MODE_WRITE);
    if (fd2 < 0) {
        ui.write_console("fstest: open2 failed\n");
        ui.exit_process(1);
    }
    const t = ui.file_truncate(@as(u32, @intCast(fd2)), 5);
    ui.file_close(@as(u32, @intCast(fd2)));
    if (t < 0) {
        ui.write_console("fstest: truncate failed\n");
        ui.exit_process(1);
    }
    ui.write_console("fstest: truncate ok\n");

    // 3. Read back the shrunk content ("hello").
    const fd3 = ui.file_open(path, ui.MODE_READ);
    if (fd3 < 0) {
        ui.write_console("fstest: open3 failed\n");
        ui.exit_process(1);
    }
    var buf: [16]u8 = [_]u8{0} ** 16;
    const n = ui.file_read(@as(u32, @intCast(fd3)), &buf);
    ui.file_close(@as(u32, @intCast(fd3)));
    if (n < 0) {
        ui.write_console("fstest: read failed\n");
        ui.exit_process(1);
    }

    var obuf: [48]u8 = undefined;
    var pos: usize = 0;
    pos = append_str(&obuf, pos, "fstest: shrunk=");
    pos = append_str(&obuf, pos, fmt_u64(obuf[pos..], @intCast(n)));
    pos = append_str(&obuf, pos, " ");
    pos = append_str(&obuf, pos, buf[0..@intCast(n)]);
    obuf[pos] = '\n';
    ui.write_console(obuf[0 .. pos + 1]);

    // 4. Rename (slot 35).
    const r = ui.file_rename(path, renamed_path);
    if (r < 0) {
        ui.write_console("fstest: rename failed\n");
        ui.exit_process(1);
    }
    ui.write_console("fstest: rename ok\n");

    // 5. Free-space query on the DATA volume (slot 37).
    const free = ui.file_free(0);
    if (free < 0) {
        ui.write_console("fstest: free failed\n");
        ui.exit_process(1);
    }
    var fbuf: [48]u8 = undefined;
    var fpos: usize = 0;
    fpos = append_str(&fbuf, fpos, "fstest: free=");
    fpos = append_str(&fbuf, fpos, fmt_u64(fbuf[fpos..], @intCast(free)));
    fbuf[fpos] = '\n';
    ui.write_console(fbuf[0 .. fpos + 1]);

    // 6. Delete (slot 34).
    const d = ui.file_delete(renamed_path);
    if (d < 0) {
        ui.write_console("fstest: delete failed\n");
        ui.exit_process(1);
    }
    ui.write_console("fstest: delete ok\n");

    // 7. Prove the delete took: the renamed path is gone.
    const fd4 = ui.file_open(renamed_path, ui.MODE_READ);
    if (fd4 >= 0) {
        ui.write_console("fstest: delete failed (still present)\n");
        ui.exit_process(1);
    }
    ui.write_console("fstest: deleted-gone\n");

    ui.write_console("fstest: done\n");
    ui.exit_process(0);
}
