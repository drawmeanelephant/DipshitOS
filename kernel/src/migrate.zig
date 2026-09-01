//! M34 HF5 (issue #739): ONE-TIME migration of the guest's `/data` (the
//! deprecated DATA FAT32 partition) into the `--cvc-file` host share.
//!
//! Runs at boot, right after the queue-5 probe arms the channel: if the
//! channel is present AND the hidden marker `.virelai-migrated` is absent
//! from the share, walk `/data` (bounded depth), copy every file to the
//! share (skip-if-exists — an existing user file WINS over the migration;
//! only missing entries are added), then write the marker. On later boots
//! the marker short-circuits, so the copy happens exactly once.
//!
//! Why a hidden marker: the host's LIST replies use `.skipsHiddenFiles`,
//! so `.virelai-migrated` never appears in guest listings — the migration
//! does not perturb `file: listing N entries` counts or the file manager.
//! The host's path defense treats it as an ordinary component (no
//! leading-dot rule; hidden only to listings).
//!
//! No libc, no POSIX, no heap: a single 2 KiB staging buffer (files on
//! `/data` are ≤ fat.write_content_max = 2048 B by construction) and
//! stack paths. Honest lines print only on share boots, so default boots
//! stay byte-identical.

const std = @import("std");
const fat = @import("fat.zig");
const virtio_blk = @import("virtio_blk.zig");
const virtio_file = @import("virtio_file.zig");
const main = @import("main.zig");

/// The one-time marker (hidden — the host LIST skips hidden files).
pub const marker_name = ".virelai-migrated";
/// Recurse at most 3 directory levels below the /data root (parity with
/// the file manager's F4 du walk bound).
pub const max_depth: usize = 3;

/// Path length cap for the walk buffers (subpaths on /data are short;
/// the FAT 8.3 roots are at most a few levels deep).
const max_path: usize = 128;

var staging: [fat.write_content_max]u8 = undefined;
var copied: usize = 0;
/// BSS for the count renderer (a slice into a stack local would dangle).
var usize_buf: [20]u8 = undefined;

fn write_marker() bool {
    var h: u16 = 0;
    if (virtio_file.open(marker_name, virtio_file.open_flag_create, &h) != virtio_file.st_ok) return false;
    defer _ = virtio_file.close(h);
    _ = virtio_file.truncate(h, 0);
    var written: u64 = 0;
    return virtio_file.write(h, "1\n", &written) == virtio_file.st_ok;
}

/// Copy one `/data` file to the share (skip when the target already
/// exists — the user's share wins; migration only ADDS what's missing).
fn copy_one(src: []const u8, dst: []const u8) void {
    var st = virtio_file.StatResult{};
    if (virtio_file.stat(dst, &st) == virtio_file.st_ok) return;
    const n = fat.read_file(src, &staging) orelse return;
    var h: u16 = 0;
    if (virtio_file.open(dst, virtio_file.open_flag_create, &h) != virtio_file.st_ok) return;
    defer _ = virtio_file.close(h);
    var off: usize = 0;
    while (off < n) {
        const take = @min(n - off, virtio_file.write_chunk_max);
        var written: u64 = 0;
        if (virtio_file.write(h, staging[off .. off + take], &written) != virtio_file.st_ok) return;
        off += @intCast(written);
    }
    copied += 1;
    main.uart_puts("migrate: copied /data/");
    main.uart_puts(dst);
    main.uart_puts(" -> /host/");
    main.uart_puts(dst);
    main.uart_puts("\n");
}

fn walk(dir: []const u8, depth: usize) void {
    if (depth >= max_depth) return;
    var raw: [fat.max_root_slots]fat.DirEntry = undefined;
    const n = fat.list_path(dir, &raw);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = raw[i];
        const name = e.name[0..e.name_len];
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        // src path on /data: dir==\"\" → name, else dir + \"/\" + name.
        var src_buf: [max_path]u8 = undefined;
        var src: []const u8 = undefined;
        var dst: []const u8 = undefined;
        if (dir.len == 0) {
            src = name;
            dst = name;
        } else {
            const slen = dir.len + 1 + name.len;
            if (slen > max_path) continue;
            @memcpy(src_buf[0..dir.len], dir);
            src_buf[dir.len] = '/';
            @memcpy(src_buf[dir.len + 1 ..][0..name.len], name);
            src = src_buf[0..slen];
            // dst is the same shape relative to the share root.
            dst = src_buf[0..slen];
        }
        if (e.is_dir) {
            // Create the host directory (skip-if-exists is the host's own
            // MKDIR contract) then descend.
            _ = virtio_file.mkdir(dst);
            walk(src, depth + 1);
        } else {
            copy_one(src, dst);
        }
    }
}

/// The boot step. No-op on default boots (no channel) — byte-identical.
pub fn run() void {
    if (!virtio_file.available()) return;
    // Marker present → migration already done.
    var st = virtio_file.StatResult{};
    if (virtio_file.stat(marker_name, &st) == virtio_file.st_ok) return;
    copied = 0;
    if (fat.mount_data(virtio_blk.disk_ops()) != .ok) {
        // No /data to migrate (HF6 will delete it) — mark done anyway so
        // the boot step is a cheap no-op from here on.
        _ = write_marker();
        main.uart_puts("migrate: no /data partition — nothing to migrate (marker written)\n");
        return;
    }
    walk("", 0);
    _ = write_marker();
    main.uart_puts("migrate: copied ");
    main.uart_puts(usize_str(copied));
    main.uart_puts(" file(s) from /data to /host — /data (DATA partition) is deprecated, user data lives in the host folder\n");
}

fn usize_str(n: usize) []const u8 {
    var i: usize = usize_buf.len;
    var v = n;
    if (v == 0) {
        usize_buf[i - 1] = '0';
        return usize_buf[i - 1 ..];
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        usize_buf[i] = @intCast('0' + (v % 10));
    }
    return usize_buf[i..];
}
