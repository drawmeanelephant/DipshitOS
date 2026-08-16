//! DipshitOS Milestone 10: Kernel Per-Process File Handle Table (ADR 0010, Cards F1 & F2).
//!
//! Exposes a bounded in-memory file handle table for EL0 userland storage:
//! - 8 open file handles per process slot (`max_handles_per_process = 8`).
//! - 0 heap allocations; pure static BSS tables (`[process.max_processes][8]FileHandle`).
//! - Tracks partition (`.esp` or `.data`), path, byte cursor offset, file size, access mode.
//! - Path canonicalization and volume routing (`/esp/...`, `/data/...`, bare paths -> DATA).
//! - Traversal defense (`..` rejection).
//! - Process lifecycle cleanup auto-closes all handles on process termination.

const std = @import("std");
const process = @import("process.zig");
const fat = @import("fat.zig");
const virtio_blk = @import("virtio_blk.zig");

pub const max_handles_per_process: usize = 8;
pub const max_path_len: usize = 64;

// Access mode bitmasks (ADR 0010 D2)
pub const MODE_READ: u32 = 0x0001;
pub const MODE_WRITE: u32 = 0x0002;
pub const MODE_CREATE: u32 = 0x0004;
pub const MODE_APPEND: u32 = 0x0008;

// Wire DirEntry layout (ADR 0010 D3: exactly 40 bytes)
pub const DirEntry = extern struct {
    name: [32]u8 = [_]u8{0} ** 32,
    size: u32 = 0,
    is_dir: u8 = 0,
    reserved: [3]u8 = [_]u8{0} ** 3,
};

pub const Partition = enum {
    esp,
    data,
};

pub const FileHandle = struct {
    in_use: bool = false,
    partition: Partition = .data,
    flags: u32 = 0,
    cursor: u32 = 0,
    size: u32 = 0,
    path: [max_path_len]u8 = [_]u8{0} ** max_path_len,
    path_len: u8 = 0,
};

pub const ParsedPath = struct {
    partition: Partition,
    path: [max_path_len]u8,
    path_len: u8,

    pub fn parsed_len(self: ParsedPath) usize {
        return self.path_len;
    }
};

// ---------------------------------------------------------------------------
// Module State (Static BSS)
// ---------------------------------------------------------------------------

var handles: [process.max_processes][max_handles_per_process]FileHandle = [_][max_handles_per_process]FileHandle{[_]FileHandle{.{}} ** max_handles_per_process} ** process.max_processes;
var initialized = false;
var test_ops_override: ?fat.DiskOps = null;

pub fn set_disk_ops_for_test(ops: ?fat.DiskOps) void {
    test_ops_override = ops;
}

fn get_disk_ops() ?fat.DiskOps {
    if (test_ops_override) |ops| return ops;
    return virtio_blk.disk_ops();
}

fn mount_partition(p: Partition) bool {
    const ops = get_disk_ops() orelse return false;
    const res = switch (p) {
        .esp => fat.mount(ops),
        .data => fat.mount_data(ops),
    };
    return res == .ok;
}

pub fn init() void {
    for (&handles) |*proc_handles| {
        for (proc_handles) |*h| {
            h.* = .{};
        }
    }
    initialized = true;
}

pub fn reset_process(pid: u64) void {
    if (pid >= process.max_processes) return;
    for (&handles[pid]) |*h| {
        h.* = .{};
    }
}

// ---------------------------------------------------------------------------
// Path Parsing, Canonicalization & Volume Routing (Card F2)
// ---------------------------------------------------------------------------

/// Parse and normalize userland path, routing to the appropriate partition.
/// Rejects directory traversal attempts (`..`) and paths exceeding `max_path_len`.
pub fn parse_path(raw: []const u8) ?ParsedPath {
    if (raw.len == 0 or raw.len > max_path_len) return null;

    // Check for forbidden directory traversal ('..')
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '.') {
            if (i + 1 < raw.len and raw[i + 1] == '.') {
                // Must be isolated by boundary or slash
                const prev_bound = (i == 0 or raw[i - 1] == '/');
                const next_bound = (i + 2 == raw.len or raw[i + 2] == '/');
                if (prev_bound and next_bound) {
                    return null; // Forbidden traversal
                }
            }
        }
        i += 1;
    }

    var partition: Partition = .data;
    var subpath = raw;

    // Strip leading slashes for prefix detection
    while (subpath.len > 0 and subpath[0] == '/') {
        subpath = subpath[1..];
    }

    // Check for volume prefixes: "esp/", "esp:", "data/", "data:"
    if (subpath.len >= 4 and std.ascii.eqlIgnoreCase(subpath[0..4], "esp/")) {
        partition = .esp;
        subpath = subpath[4..];
    } else if (subpath.len >= 4 and std.ascii.eqlIgnoreCase(subpath[0..4], "esp:")) {
        partition = .esp;
        subpath = subpath[4..];
    } else if (subpath.len == 3 and std.ascii.eqlIgnoreCase(subpath[0..3], "esp")) {
        partition = .esp;
        subpath = "";
    } else if (subpath.len >= 5 and std.ascii.eqlIgnoreCase(subpath[0..5], "data/")) {
        partition = .data;
        subpath = subpath[5..];
    } else if (subpath.len >= 5 and std.ascii.eqlIgnoreCase(subpath[0..5], "data:")) {
        partition = .data;
        subpath = subpath[5..];
    } else if (subpath.len == 4 and std.ascii.eqlIgnoreCase(subpath[0..4], "data")) {
        partition = .data;
        subpath = "";
    }

    // Clean up multiple consecutive slashes and strip leading/trailing slashes
    var out: [max_path_len]u8 = [_]u8{0} ** max_path_len;
    var out_len: usize = 0;

    var s_idx: usize = 0;
    while (s_idx < subpath.len) {
        const c = subpath[s_idx];
        if (c == '/') {
            // Collapse consecutive slashes
            if (out_len > 0 and out[out_len - 1] != '/') {
                if (out_len >= max_path_len) return null;
                out[out_len] = '/';
                out_len += 1;
            }
        } else {
            if (out_len >= max_path_len) return null;
            out[out_len] = c;
            out_len += 1;
        }
        s_idx += 1;
    }

    // Remove trailing slash if path is non-empty
    while (out_len > 0 and out[out_len - 1] == '/') {
        out_len -= 1;
    }

    return ParsedPath{
        .partition = partition,
        .path = out,
        .path_len = @intCast(out_len),
    };
}

// ---------------------------------------------------------------------------
// File Handle Operations (Card F1)
// ---------------------------------------------------------------------------

/// Open a file for `pid` with given `flags`.
/// Returns fd (0..7) on success, or negative error code:
/// - `-1` (`EINVAL`): Invalid flags, bad path syntax, traversal attempted
/// - `-2` (`EBADF`): Not applicable for open
/// - `-5` (`ENOSPC`): Handle table full (8 open handles) or disk full
/// - `-6` (`ENOENT`): File not found and MODE_CREATE not set
/// - `-8` (`ENAMETOOLONG`): Path length > 64
pub fn open(pid: u64, path_bytes: []const u8, flags: u32) i64 {
    if (pid >= process.max_processes) return -1;
    if (flags == 0) return -1;
    if ((flags & ~(MODE_READ | MODE_WRITE | MODE_CREATE | MODE_APPEND)) != 0) return -1;
    if ((flags & (MODE_READ | MODE_WRITE)) == 0) return -1;

    if (path_bytes.len > max_path_len) return -8;
    const parsed = parse_path(path_bytes) orelse return -1;

    // Find free handle slot for calling process
    var free_slot: ?usize = null;
    for (handles[pid], 0..) |h, idx| {
        if (!h.in_use) {
            free_slot = idx;
            break;
        }
    }
    const slot = free_slot orelse return -5; // ENOSPC (table full)

    if (!mount_partition(parsed.partition)) return -6; // ENOENT

    const subpath = parsed.path[0..parsed.parsed_len()];
    const existing_size = fat.file_size(subpath);

    var file_size_val: u32 = 0;
    var cursor_val: u32 = 0;

    if (existing_size) |sz| {
        file_size_val = sz;
        if ((flags & MODE_APPEND) != 0) {
            cursor_val = sz;
        } else {
            cursor_val = 0;
        }
    } else {
        // File does not exist
        if ((flags & MODE_CREATE) == 0) {
            return -6; // ENOENT
        }
        // MODE_CREATE is set: create empty file
        const wr = fat.write_file(subpath, "");
        if (wr != .ok) {
            return switch (wr) {
                .disk_full => -5,
                .name_too_long => -8,
                .content_too_long => -5,
                .bad_path => -6,
                .no_disk => -6,
                else => -1,
            };
        }
        file_size_val = 0;
        cursor_val = 0;
    }

    handles[pid][slot] = .{
        .in_use = true,
        .partition = parsed.partition,
        .flags = flags,
        .cursor = cursor_val,
        .size = file_size_val,
        .path = parsed.path,
        .path_len = parsed.path_len,
    };

    return @intCast(slot);
}

/// Read from open handle `fd`.
/// Returns bytes read (0 at EOF), or negative error code.
pub fn read(pid: u64, fd: u64, out_buf: []u8) i64 {
    if (pid >= process.max_processes or fd >= max_handles_per_process) return -2;
    var h = &handles[pid][fd];
    if (!h.in_use) return -2; // EBADF
    if ((h.flags & MODE_READ) == 0) return -7; // EACCES

    if (out_buf.len == 0) return 0;
    if (h.cursor >= h.size) return 0; // EOF

    if (!mount_partition(h.partition)) return -6;

    var staging: [fat.write_content_max]u8 = undefined;
    const subpath = h.path[0..h.path_len];
    const total = fat.read_file(subpath, &staging) orelse return 0;
    if (h.cursor >= total) return 0;

    const available = total - h.cursor;
    const take = @min(out_buf.len, available);
    @memcpy(out_buf[0..take], staging[h.cursor .. h.cursor + take]);
    h.cursor += @intCast(take);

    return @intCast(take);
}

/// Write to open handle `fd`.
/// Returns bytes written, or negative error code.
pub fn write(pid: u64, fd: u64, in_buf: []const u8) i64 {
    if (pid >= process.max_processes or fd >= max_handles_per_process) return -2;
    var h = &handles[pid][fd];
    if (!h.in_use) return -2; // EBADF
    if ((h.flags & MODE_WRITE) == 0) return -7; // EACCES

    if (in_buf.len == 0) return 0;
    if (h.cursor + in_buf.len > fat.write_content_max) return -5; // ENOSPC

    if (!mount_partition(h.partition)) return -6;

    var staging: [fat.write_content_max]u8 = [_]u8{0} ** fat.write_content_max;
    var existing_len: usize = 0;
    const subpath = h.path[0..h.path_len];

    if (h.size > 0) {
        if (fat.read_file(subpath, &staging)) |got| {
            existing_len = got;
        }
    }

    @memcpy(staging[h.cursor .. h.cursor + in_buf.len], in_buf);
    const new_len = @max(existing_len, h.cursor + in_buf.len);

    const wr = fat.write_file(subpath, staging[0..new_len]);
    if (wr != .ok) {
        return switch (wr) {
            .disk_full => -5,
            .content_too_long => -5,
            .name_too_long => -8,
            .bad_path => -6,
            .no_disk => -6,
            else => -1,
        };
    }

    h.size = @intCast(new_len);
    h.cursor += @intCast(in_buf.len);

    return @intCast(in_buf.len);
}

/// Close open handle `fd`.
/// Returns 0 on success, or -2 (`EBADF`).
pub fn close(pid: u64, fd: u64) i64 {
    if (pid >= process.max_processes or fd >= max_handles_per_process) return -2;
    if (!handles[pid][fd].in_use) return -2; // EBADF

    handles[pid][fd] = .{};
    return 0;
}

/// Enumerate directory entries at `path_bytes` into `out_entries`.
/// Returns number of entries written (>= 0), or negative error code.
pub fn dir_list(pid: u64, path_bytes: []const u8, out_entries: []DirEntry) i64 {
    if (pid >= process.max_processes) return -1;
    if (out_entries.len == 0) return 0;

    const parsed = if (path_bytes.len == 0)
        ParsedPath{ .partition = .data, .path = [_]u8{0} ** max_path_len, .path_len = 0 }
    else
        parse_path(path_bytes) orelse return -1;

    if (!mount_partition(parsed.partition)) return -6;

    var raw_entries: [fat.max_root_slots]fat.DirEntry = undefined;
    const subpath = parsed.path[0..parsed.path_len];
    const count = fat.list_path(subpath, &raw_entries);

    const take = @min(count, out_entries.len);
    var i: usize = 0;
    while (i < take) : (i += 1) {
        const raw = &raw_entries[i];
        var de = DirEntry{
            .name = [_]u8{0} ** 32,
            .size = raw.size,
            .is_dir = if (raw.is_dir) 1 else 0,
            .reserved = .{ 0, 0, 0 },
        };
        const nlen = @min(@as(usize, raw.name_len), 31);
        @memcpy(de.name[0..nlen], raw.name[0..nlen]);
        out_entries[i] = de;
    }

    return @intCast(take);
}

// ---------------------------------------------------------------------------
// Mutating operations (Milestone 13, card B1 — claim 5801)
// ---------------------------------------------------------------------------

/// Delete the file at `path`. Returns 0 on success, or a negative error
/// code (EINVAL bad path / directory, ENOENT absent / unmounted).
pub fn delete(pid: u64, path_bytes: []const u8) i64 {
    if (pid >= process.max_processes) return -1;
    if (path_bytes.len == 0 or path_bytes.len > max_path_len) return -1;
    const parsed = parse_path(path_bytes) orelse return -1;
    if (!mount_partition(parsed.partition)) return -6;
    const subpath = parsed.path[0..parsed.parsed_len()];
    return switch (fat.delete_file(subpath)) {
        .ok => 0,
        .not_found => -6,
        .is_dir => -1,
        .no_disk => -6,
        .io_failed => -6,
    };
}

/// Rename `old_path` to `new_path` (same directory — cross-directory moves
/// and cross-volume renames are refused with EINVAL). Returns 0 on success.
pub fn rename(pid: u64, old_bytes: []const u8, new_bytes: []const u8) i64 {
    if (pid >= process.max_processes) return -1;
    if (old_bytes.len == 0 or old_bytes.len > max_path_len or
        new_bytes.len == 0 or new_bytes.len > max_path_len) return -1;
    const old = parse_path(old_bytes) orelse return -1;
    const new = parse_path(new_bytes) orelse return -1;
    if (old.partition != new.partition) return -1; // cross-volume unsupported
    if (!mount_partition(old.partition)) return -6;
    return switch (fat.rename_file(old.path[0..old.parsed_len()], new.path[0..new.parsed_len()])) {
        .ok => 0,
        .not_found => -6,
        .exists => -1, // no EEXIST row in the frozen ABI — documented EINVAL
        .is_dir => -1,
        .name_too_long => -8,
        .bad_path => -1,
        .no_disk => -6,
        .io_failed => -6,
    };
}

/// Resize the OPEN handle `fd` to `new_size` bytes (shrink truncates, grow
/// zero-fills). Returns 0; EBADF for a bad/closed handle, EACCES when not
/// open for write, ENOSPC for an over-large size.
pub fn truncate(pid: u64, fd: u64, new_size: u32) i64 {
    if (pid >= process.max_processes or fd >= max_handles_per_process) return -2;
    var h = &handles[pid][fd];
    if (!h.in_use) return -2; // EBADF
    if ((h.flags & MODE_WRITE) == 0) return -7; // EACCES
    if (!mount_partition(h.partition)) return -6;

    const subpath = h.path[0..h.path_len];
    const res: i64 = switch (fat.truncate_file(subpath, new_size)) {
        .ok => 0,
        .not_found => -6,
        .is_dir => -1,
        .too_large => -5,
        .no_disk => -6,
        .io_failed => -6,
    };
    if (res == 0) {
        h.size = new_size;
        if (h.cursor > new_size) h.cursor = new_size;
    }
    return res;
}

/// Free bytes on a volume (0 = DATA, 1 = ESP). Returns the byte count, or a
/// negative error (EINVAL bad volume, ENOENT unmounted).
pub fn free_space(pid: u64, volume: u32) i64 {
    if (pid >= process.max_processes) return -1;
    const part: Partition = switch (volume) {
        0 => .data,
        1 => .esp,
        else => return -1,
    };
    if (!mount_partition(part)) return -6;
    return @intCast(fat.free_space());
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "file_table: path parsing and volume routing" {
    // Data default
    const p1 = parse_path("hello.txt").?;
    try std.testing.expectEqual(Partition.data, p1.partition);
    try std.testing.expectEqualStrings("hello.txt", p1.path[0..p1.path_len]);

    // Explicit data prefix
    const p2 = parse_path("/data/notes.txt").?;
    try std.testing.expectEqual(Partition.data, p2.partition);
    try std.testing.expectEqualStrings("notes.txt", p2.path[0..p2.path_len]);

    // Explicit esp prefix
    const p3 = parse_path("/esp/efi/boot/bootaa64.efi").?;
    try std.testing.expectEqual(Partition.esp, p3.partition);
    try std.testing.expectEqualStrings("efi/boot/bootaa64.efi", p3.path[0..p3.path_len]);

    // Colon syntax
    const p4 = parse_path("data:config.sys").?;
    try std.testing.expectEqual(Partition.data, p4.partition);
    try std.testing.expectEqualStrings("config.sys", p4.path[0..p4.path_len]);

    // Traversal defense: rejection of '..'
    try std.testing.expect(parse_path("../secret.txt") == null);
    try std.testing.expect(parse_path("/data/../secret.txt") == null);
    try std.testing.expect(parse_path("dir/../../file") == null);
    try std.testing.expect(parse_path("..") == null);
}

test "file_table: handle allocation, bounds, and lifecycle reset" {
    init();
    const pid: u64 = 1;

    // Invalid flags
    try std.testing.expectEqual(@as(i64, -1), open(pid, "test.txt", 0));
    try std.testing.expectEqual(@as(i64, -1), open(pid, "test.txt", 0x100));

    // Reset process frees all handles
    reset_process(pid);
    try std.testing.expectEqual(@as(i64, -2), close(pid, 0));
}

test "file_table: wire DirEntry size is exactly 40 bytes" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(DirEntry));
}

test "file_table: mutating ops validate pids, paths, and volumes (claim 5801)" {
    // Bad pid for every new op.
    try std.testing.expectEqual(@as(i64, -1), delete(process.max_processes, "x.txt"));
    try std.testing.expectEqual(@as(i64, -1), rename(process.max_processes, "a.txt", "b.txt"));
    try std.testing.expectEqual(@as(i64, -1), free_space(process.max_processes, 0));

    // Empty / traversal paths are refused without a disk.
    try std.testing.expectEqual(@as(i64, -1), delete(1, ""));
    try std.testing.expectEqual(@as(i64, -1), delete(1, "../x.txt"));
    try std.testing.expectEqual(@as(i64, -1), rename(1, "a.txt", "../b.txt"));

    // Bad volume for the free-space query.
    try std.testing.expectEqual(@as(i64, -1), free_space(1, 2));

    // Truncate on an unopened handle is EBADF.
    init();
    try std.testing.expectEqual(@as(i64, -2), truncate(1, 0, 4));
}

test "file_table: cross-volume rename is refused with EINVAL (claim 5801)" {
    try std.testing.expectEqual(@as(i64, -1), rename(1, "/data/a.txt", "/esp/b.txt"));
}
