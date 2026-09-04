//! VirelaiOS Milestone 10: Kernel Per-Process File Handle Table (ADR 0010, Cards F1 & F2).
//!
//! Exposes a bounded in-memory file handle table for EL0 userland storage:
//! - 8 open file handles per process slot (`max_handles_per_process = 8`).
//! - 0 heap allocations; pure static BSS tables (`[process.max_processes][8]FileHandle`).
//! - Tracks the host share partition (`.host`), path, byte cursor offset,
//!   file size, access mode.
//! - Path canonicalization and volume routing (`/host/...`, bare paths -> host share).
//! - Traversal defense (`..` rejection).
//! - Process lifecycle cleanup auto-closes all handles on process termination.
//!
//! M34 HF6 (issue #740): the FAT surface is GONE — `fat.zig`, the ESP/DATA
//! partitions, and the post-exit virtio-blk path were deleted. The `.host`
//! share (`--cvc-file`) is the ONLY file partition: reads stay stateless
//! (vf STAT for the size, vf READ at the guest cursor), writes ride the
//! host's handle-table cursor (vf OPEN/WRITE/TRUNCATE/CLOSE) with legacy
//! FAT replace semantics (write-open truncates to 0 unless append).

const std = @import("std");
const process = @import("process.zig");
// M34 HF4 (issue #738): the `.host` partition serves the `--cvc-file`
// share through the host file channel — no FAT. HF5 (issue #739) makes
// it READ-WRITE for userland (the persistence consumers re-point from
// `/data` to `/host`); reads stay stateless (vf READ at the guest
// cursor), writes ride the host's handle-table cursor (vf OPEN/WRITE/
// TRUNCATE/CLOSE).
const virtio_file = @import("virtio_file.zig");

pub const max_handles_per_process: usize = 8;
pub const max_path_len: usize = 64;

// Access mode bitmasks (ADR 0010 D2)
pub const MODE_READ: u32 = 0x0001;
pub const MODE_WRITE: u32 = 0x0002;
pub const MODE_CREATE: u32 = 0x0004;
pub const MODE_APPEND: u32 = 0x0008;
/// M25 Lane B (claim 2539): with MODE_CREATE, create a DIRECTORY instead
/// of an empty file (host vf MKDIR). The returned handle rejects
/// read/write — it only marks the creation.
pub const MODE_DIR: u32 = 0x0010;

// Wire DirEntry layout (ADR 0010 D3: exactly 40 bytes)
pub const DirEntry = extern struct {
    name: [32]u8 = [_]u8{0} ** 32,
    size: u32 = 0,
    is_dir: u8 = 0,
    reserved: [3]u8 = [_]u8{0} ** 3,
};

/// The single partition: the host share (`--cvc-file`), served by the
/// queue-5 file channel. M34 HF6 (issue #740) deleted the ESP/DATA
/// partitions — the enum is kept so `FileHandle`/`ParsedPath` keep their
/// routed shape and the partition is explicit at every handle site.
pub const Partition = enum {
    /// M34 HF4 (issue #738): the host share (`--cvc-file`), served by
    /// the queue-5 file channel. HF5 made it READ-WRITE; HF6 made it the
    /// ONLY partition.
    host,
};

pub const FileHandle = struct {
    in_use: bool = false,
    partition: Partition = .host,
    flags: u32 = 0,
    cursor: u32 = 0,
    size: u32 = 0,
    path: [max_path_len]u8 = [_]u8{0} ** max_path_len,
    path_len: u8 = 0,
    /// M25 Lane B (claim 2539): set when MODE_DIR created the entry —
    /// the handle must never be read or written (a directory write would
    /// overwrite host metadata through the channel's replace path).
    is_dir: bool = false,
    /// M34 HF5 (issue #739): a `.host` write handle's host-side cursor
    /// (the vf wire has no write-at-offset — the HOST's 8-slot table owns
    /// the write position). Reads on host handles stay stateless (vf READ
    /// at the guest `cursor`); writes advance the host cursor, mirrored
    /// here by the confirmed byte count. Freed on close / process reset.
    host_handle: u16 = 0,
    host_handle_valid: bool = false,
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
        // HF5: a killed/exited process must free its HOST write handles
        // (the host table is global — a leaked slot would starve others).
        if (h.in_use and h.host_handle_valid) {
            _ = virtio_file.close(h.host_handle);
        }
        h.* = .{};
    }
}

// ---------------------------------------------------------------------------
// Path Parsing, Canonicalization & Volume Routing (Card F2)
// ---------------------------------------------------------------------------

/// Parse and normalize userland path, routing to the host share partition.
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

    var partition: Partition = .host;
    var subpath = raw;

    // Strip leading slashes for prefix detection
    while (subpath.len > 0 and subpath[0] == '/') {
        subpath = subpath[1..];
    }

    // M34 HF4 (issue #738): the host-share prefix routes to `.host` with
    // the path relative to the share root. HF6 (issue #740): with the
    // ESP/DATA partitions gone, EVERY path routes to the share — bare
    // paths, `/host/...`, and `host:...` all land on `.host`.
    if (subpath.len >= 5 and std.ascii.eqlIgnoreCase(subpath[0..5], "host/")) {
        partition = .host;
        subpath = subpath[5..];
    } else if (subpath.len >= 5 and std.ascii.eqlIgnoreCase(subpath[0..5], "host:")) {
        partition = .host;
        subpath = subpath[5..];
    } else if (subpath.len == 4 and std.ascii.eqlIgnoreCase(subpath[0..4], "host")) {
        partition = .host;
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
/// - `-5` (`ENOSPC`): Handle table full (8 open handles)
/// - `-6` (`ENOENT`): File not found and MODE_CREATE not set (or no share)
/// - `-8` (`ENAMETOOLONG`): Path length > 64
/// - `-9` (`EEXIST`): MODE_DIR create and the name already exists
pub fn open(pid: u64, path_bytes: []const u8, flags: u32) i64 {
    if (pid >= process.max_processes) return -1;
    if (flags == 0) return -1;
    if ((flags & ~(MODE_READ | MODE_WRITE | MODE_CREATE | MODE_APPEND | MODE_DIR)) != 0) return -1;
    if ((flags & (MODE_READ | MODE_WRITE)) == 0) return -1;
    // M25 Lane B: directory creation rides the mutating open flags.
    if ((flags & MODE_DIR) != 0 and (flags & (MODE_CREATE | MODE_WRITE)) != (MODE_CREATE | MODE_WRITE)) return -1;

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

    if (!virtio_file.available()) return -6; // ENOENT (no host file channel)

    const subpath = parsed.path[0..parsed.parsed_len()];

    // M34 HF5 (issue #739): the host share is READ-WRITE now — the file
    // channel is user data. MODE_DIR creates a directory (parity with the
    // FAT mkdir path); MODE_WRITE (with optional CREATE/APPEND) opens a
    // host write handle (the HOST owns the cursor; write-open without
    // append truncates to 0 — the legacy FAT replace semantics the
    // persistence consumers were built on); MODE_READ-only stays
    // stateless (vf STAT for the size, vf READ at the guest cursor).
    if ((flags & MODE_DIR) != 0) {
        const md = virtio_file.mkdir(subpath);
        if (md == virtio_file.st_exists) return -9; // EEXIST
        if (md != virtio_file.st_ok) return switch (md) {
            virtio_file.st_not_found => -6,
            else => -1,
        };
        handles[pid][slot] = .{
            .in_use = true,
            .partition = .host,
            .flags = flags,
            .path = parsed.path,
            .path_len = parsed.path_len,
            .is_dir = true,
        };
        return @intCast(slot);
    }
    if ((flags & MODE_WRITE) != 0) {
        var oflags: u8 = 0;
        if ((flags & MODE_CREATE) != 0) oflags |= virtio_file.open_flag_create;
        if ((flags & MODE_APPEND) != 0) oflags |= virtio_file.open_flag_append;
        var h: u16 = 0;
        const ost = virtio_file.open(subpath, oflags, &h);
        if (ost == virtio_file.st_not_found) return -6; // ENOENT (no create)
        if (ost != virtio_file.st_ok) return -1; // EINVAL (host error / handle limit)
        if ((flags & MODE_APPEND) == 0) {
            // Replace semantics: a fresh write-open truncates. A failed
            // truncate is honest (the handle is closed; nothing leaked).
            if (virtio_file.truncate(h, 0) != virtio_file.st_ok) {
                _ = virtio_file.close(h);
                return -1;
            }
        }
        handles[pid][slot] = .{
            .in_use = true,
            .partition = .host,
            .flags = flags,
            .cursor = 0,
            .size = 0,
            .path = parsed.path,
            .path_len = parsed.path_len,
            .is_dir = false,
            .host_handle = h,
            .host_handle_valid = true,
        };
        return @intCast(slot);
    }
    var st = virtio_file.StatResult{};
    if (virtio_file.stat(subpath, &st) != virtio_file.st_ok) return -6; // ENOENT
    if (st.is_dir) return -1; // EINVAL: a directory opens as its own path, not a handle
    handles[pid][slot] = .{
        .in_use = true,
        .partition = .host,
        .flags = flags,
        .cursor = 0,
        // Clamp to u32 (the frozen ABI); host manifests are tiny and
        // the read loop's EOF bound still holds for larger files.
        .size = @intCast(@min(st.size, std.math.maxInt(u32))),
        .path = parsed.path,
        .path_len = parsed.path_len,
        .is_dir = false,
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
    if (h.is_dir) return 0; // M25 Lane B: a dir handle reads as empty

    if (out_buf.len == 0) return 0;
    if (h.cursor >= h.size) return 0; // EOF

    if (!virtio_file.available()) return -6;

    // M34 HF4: the host share is stateless — each chunk is one vf READ
    // round trip at the handle's cursor (a handle is path + size here).
    // Issue #846: read_chunk copies directly into out_buf under vf_lock,
    // eliminating reply-buffer races across concurrent tasks and cores.
    const subpath = h.path[0..h.path_len];
    var total: usize = 0;
    while (total < out_buf.len and h.cursor < h.size) {
        const rc = virtio_file.read_chunk(subpath, h.cursor, out_buf[total..]);
        if (rc.status != virtio_file.st_ok or rc.bytes == 0) break;
        total += rc.bytes;
        h.cursor += @intCast(rc.bytes);
    }
    return @intCast(total);
}

/// Write to open handle `fd`.
/// Returns bytes written, or negative error code.
pub fn write(pid: u64, fd: u64, in_buf: []const u8) i64 {
    if (pid >= process.max_processes or fd >= max_handles_per_process) return -2;
    var h = &handles[pid][fd];
    if (!h.in_use) return -2; // EBADF
    if ((h.flags & MODE_WRITE) == 0) return -7; // EACCES
    if (h.is_dir) return -7; // M25 Lane B: never write through a dir handle

    // M34 HF5 (issue #739): host writes ride the host handle's cursor
    // (chunked across WRITE round trips; the host returns the confirmed
    // count, which is what advances our mirror cursor).
    if (!h.host_handle_valid) return -7; // EACCES (no write handle)
    if (in_buf.len == 0) return 0;
    var off: usize = 0;
    while (off < in_buf.len) {
        const take = @min(in_buf.len - off, virtio_file.write_chunk_max);
        var written: u64 = 0;
        const st = virtio_file.write(h.host_handle, in_buf[off .. off + take], &written);
        if (st != virtio_file.st_ok) {
            // A partial write already advanced the host cursor; the guest
            // mirror reflects only confirmed bytes — honest accounting.
            return if (off > 0) @intCast(off) else -1;
        }
        off += @intCast(written);
        h.cursor += @intCast(written);
    }
    h.size = @max(h.size, h.cursor);
    return @intCast(in_buf.len);
}

/// Close open handle `fd`.
/// Returns 0 on success, or -2 (`EBADF`). A host write handle is closed
/// on the HOST (flush + free the table slot) before the guest slot frees.
pub fn close(pid: u64, fd: u64) i64 {
    if (pid >= process.max_processes or fd >= max_handles_per_process) return -2;
    if (!handles[pid][fd].in_use) return -2; // EBADF

    if (handles[pid][fd].host_handle_valid) {
        _ = virtio_file.close(handles[pid][fd].host_handle);
    }
    handles[pid][fd] = .{};
    return 0;
}

/// Enumerate directory entries at `path_bytes` into `out_entries`.
/// Returns number of entries written (>= 0), or negative error code.
pub fn dir_list(pid: u64, path_bytes: []const u8, out_entries: []DirEntry) i64 {
    if (pid >= process.max_processes) return -1;
    if (out_entries.len == 0) return 0;

    const parsed = if (path_bytes.len == 0)
        ParsedPath{ .partition = .host, .path = [_]u8{0} ** max_path_len, .path_len = 0 }
    else
        parse_path(path_bytes) orelse return -1;

    if (!virtio_file.available()) return -6;

    const subpath = parsed.path[0..parsed.path_len];

    // M34 HF4: LIST the share through the file channel; the vf row shape
    // (name / size / is_dir) maps 1:1 onto the frozen 40-byte DirEntry.
    var lr = virtio_file.ListResult{};
    if (virtio_file.list(subpath, &lr) != virtio_file.st_ok) return -6;
    const take = @min(lr.count, out_entries.len);
    var i: usize = 0;
    while (i < take) : (i += 1) {
        const raw = &lr.entries[i];
        var de = DirEntry{
            .name = [_]u8{0} ** 32,
            .size = @intCast(@min(raw.size, std.math.maxInt(u32))),
            .is_dir = if (raw.type == virtio_file.dir_type_dir) 1 else 0,
            .reserved = .{ 0, 0, 0 },
        };
        const nlen = @min(raw.name_len, 31);
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
    if (!virtio_file.available()) return -6;
    const subpath = parsed.path[0..parsed.parsed_len()];
    // M34 HF5 (issue #739): host deletes route to the channel.
    return switch (virtio_file.delete(subpath)) {
        virtio_file.st_ok => 0,
        virtio_file.st_not_found => -6,
        virtio_file.st_is_dir => -1,
        else => -6,
    };
}

/// Rename `old_path` to `new_path` (same directory — cross-directory moves
/// are refused with EINVAL). Returns 0 on success.
pub fn rename(pid: u64, old_bytes: []const u8, new_bytes: []const u8) i64 {
    if (pid >= process.max_processes) return -1;
    if (old_bytes.len == 0 or old_bytes.len > max_path_len or
        new_bytes.len == 0 or new_bytes.len > max_path_len) return -1;
    const old = parse_path(old_bytes) orelse return -1;
    const new = parse_path(new_bytes) orelse return -1;
    if (old.partition != new.partition) return -1; // cross-partition unsupported
    if (!virtio_file.available()) return -6;
    // M34 HF5 (issue #739): host renames route to the channel (stateless
    // NUL-framed RENAME; the host overwrites the target, like FAT).
    return switch (virtio_file.rename(old.path[0..old.parsed_len()], new.path[0..new.parsed_len()])) {
        virtio_file.st_ok => 0,
        virtio_file.st_not_found => -6,
        else => -1, // exists/host error — no EEXIST row in the frozen ABI
    };
}

/// Resize the OPEN handle `fd` to `new_size` bytes (shrink truncates, grow
/// zero-fills). Returns 0; EBADF for a bad/closed handle, EACCES when not
/// open for write.
pub fn truncate(pid: u64, fd: u64, new_size: u32) i64 {
    if (pid >= process.max_processes or fd >= max_handles_per_process) return -2;
    var h = &handles[pid][fd];
    if (!h.in_use) return -2; // EBADF
    if ((h.flags & MODE_WRITE) == 0) return -7; // EACCES
    if (h.is_dir) return -7; // M25 Lane B: never truncate through a dir handle
    // M34 HF5 (issue #739): host truncate rides the host handle.
    if (!h.host_handle_valid) return -7; // EACCES
    const st = virtio_file.truncate(h.host_handle, new_size);
    if (st != virtio_file.st_ok) return -1; // EINVAL (host error)
    h.size = new_size;
    if (h.cursor > new_size) h.cursor = new_size;
    return 0;
}

/// Free bytes on a volume. M34 HF6 (issue #740): the ESP/DATA partitions
/// are GONE and the host channel has no free-space op — every volume is
/// an honest EINVAL (the frozen ABI row stays; no userland caller exists
/// since `fstest` was deleted).
pub fn free_space(pid: u64, volume: u32) i64 {
    _ = volume;
    if (pid >= process.max_processes) return -1;
    return -1; // EINVAL: no file volumes exist
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "file_table: path parsing and volume routing" {
    // Bare paths default to the host share (HF6: the only partition).
    const p1 = parse_path("hello.txt").?;
    try std.testing.expectEqual(Partition.host, p1.partition);
    try std.testing.expectEqualStrings("hello.txt", p1.path[0..p1.path_len]);

    // M34 HF4 (issue #738): the host-share prefix routes to `.host` with
    // the path relative to the share root.
    const ph1 = parse_path("/host/APPS.TXT").?;
    try std.testing.expectEqual(Partition.host, ph1.partition);
    try std.testing.expectEqualStrings("APPS.TXT", ph1.path[0..ph1.path_len]);
    const ph2 = parse_path("host:sub/app.bin").?;
    try std.testing.expectEqual(Partition.host, ph2.partition);
    try std.testing.expectEqualStrings("sub/app.bin", ph2.path[0..ph2.path_len]);
    const ph3 = parse_path("/host").?;
    try std.testing.expectEqual(Partition.host, ph3.partition);
    try std.testing.expectEqual(ph3.path_len, 0);

    // Traversal defense: rejection of '..'
    try std.testing.expect(parse_path("../secret.txt") == null);
    try std.testing.expect(parse_path("/host/../secret.txt") == null);
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

    // Every volume is an honest EINVAL — the FAT volumes are gone (HF6)
    // and the host channel has no free-space op.
    try std.testing.expectEqual(@as(i64, -1), free_space(1, 0));
    try std.testing.expectEqual(@as(i64, -1), free_space(1, 1));

    // Truncate on an unopened handle is EBADF.
    init();
    try std.testing.expectEqual(@as(i64, -2), truncate(1, 0, 4));
}
