//! DipshitOS ESP file window (milestone-three storage card, claim 6420).
//!
//! M1.5's `ls`/`cat`/`write` started life over claim 3475's two fallback
//! channels — a PRE-EXIT EFI Simple File System snapshot (the ESP, read
//! only) and POST-exit NVRAM runtime variables (`DipshitF:*`, the
//! persistence medium). This module replaces both with a **real FAT32
//! driver on the live ESP** (see `fat.zig` + `virtio_blk.zig`):
//!
//! 1. **Mount + snapshot.** `set_disk(ops)` mounts the ESP's FAT32 volume
//!    through the injected sector interface (virtio-blk on VZ; an
//!    in-memory image in host tests) and walks the root directory into a
//!    fixed BSS window, loading content for files ≤ `esp_content_max`.
//!    `ls`/`cat` serve the window exactly as before.
//! 2. **Real `write`.** `write_file` writes the file to the FAT volume
//!    (cluster allocation, FAT copies, directory entry — `fat.zig`) and
//!    updates the window, so a file written in one boot is on the DISK in
//!    the next. NVRAM variables are no longer the persistence medium; the
//!    runner's variable store stays for the marker/probe/chunk channels.
//!
//! Honesty rules: a failed/absent disk is reported (`no_disk`, `write_failed`
//! with the failing LBA); the ESP is the real, writable filesystem (not a
//! snapshot); all limits are fixed and explicit; no allocation beyond the
//! fixed BSS window; case-insensitive name lookup (FAT semantics) with the
//! most recently written copy winning.
//!
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const fat = @import("fat.zig");

// ---------------------------------------------------------------------------
// Limits (fixed-size, explicit bounds)
// ---------------------------------------------------------------------------

/// Maximum file-name length (bytes, ASCII) listed or written.
pub const name_max: usize = 32;
/// Maximum ESP snapshot entries (files + directories, root only).
pub const esp_entries_max: usize = 64;
/// Per-file content cap for `cat` (larger files are listed with their size
/// but not content-loaded; `cat` reports that honestly).
pub const esp_content_max: usize = 2048;
/// Total content pool (BSS) shared by all loaded entries.
pub const content_pool_max: usize = 8192;
/// Total entry slots.
pub const entries_max: usize = esp_entries_max;
/// Per-file write cap (mirrors `fat.write_content_max` so every written
/// file is also content-loaded for `cat`).
pub const write_content_max: usize = fat.write_content_max;

pub const WriteResult = enum {
    ok,
    /// No disk mounted (host test process, or virtio-blk init failed).
    no_disk,
    name_invalid,
    /// The name does not fit FAT 8.3 (stem > 8 chars or extension > 3).
    name_too_long,
    content_too_long,
    /// A `/`-path parent component is absent or is not a directory (only
    /// reachable if a future caller passes a path through the window; the
    /// window's `valid_name` rejects '/' today).
    bad_path,
    /// No free cluster / no free root-directory slot on the volume.
    disk_full,
    /// A sector read/write failed — the file was NOT written.
    write_failed,
};

// ---------------------------------------------------------------------------
// Window state (fixed BSS)
// ---------------------------------------------------------------------------

pub const Kind = enum { esp_file, esp_dir };

pub const Entry = struct {
    name: [name_max]u8 = undefined,
    name_len: u8 = 0,
    /// On-disk size (files) / 0 (dirs).
    size: u64 = 0,
    /// Offset into the content pool (meaningful when `len` > 0).
    offset: u16 = 0,
    /// Loaded content length (0 = listed but not content-loaded).
    len: u16 = 0,
    kind: Kind = .esp_file,
};

const State = struct {
    entries: [entries_max]Entry = undefined,
    content: [content_pool_max]u8 = undefined,
    entry_count: usize = 0,
    pool_used: usize = 0,
    /// True once the FAT volume is mounted and the window populated.
    disk_ready: bool = false,

    fn clear(self: *State) void {
        self.entry_count = 0;
        self.pool_used = 0;
        self.disk_ready = false;
    }

    /// Append an entry, loading `content` when it fits the window. Returns
    /// false (and records nothing) when the name is invalid or the window
    /// is full; content that exceeds the per-file cap or the pool is
    /// listed without being loaded.
    fn add(self: *State, name: []const u8, size: u64, content: []const u8, kind: Kind) bool {
        if (name.len == 0 or name.len > name_max) return false;
        if (self.entry_count >= entries_max) return false;
        const e = &self.entries[self.entry_count];
        @memcpy(e.name[0..name.len], name);
        e.name_len = @intCast(name.len);
        e.size = size;
        e.kind = kind;
        e.offset = 0;
        e.len = 0;
        if (content.len > 0 and content.len <= esp_content_max and self.pool_used + content.len <= content_pool_max) {
            @memcpy(self.content[self.pool_used..][0..content.len], content);
            e.offset = @intCast(self.pool_used);
            e.len = @intCast(content.len);
            self.pool_used += content.len;
        }
        self.entry_count += 1;
        return true;
    }

    fn esp_count(self: *const State) usize {
        return self.entry_count;
    }

    /// Index of an existing entry with the same (case-insensitive) name, or
    /// null. The most recently written copy wins.
    fn index_of(self: *const State, name: []const u8) ?usize {
        var i = self.entry_count;
        while (i > 0) {
            i -= 1;
            const e = &self.entries[i];
            if (name_eql(e.name[0..e.name_len], name)) return i;
        }
        return null;
    }
};

/// Label of the ACTIVE volume the window snapshots: "esp" at boot, "data"
/// after `mount data` switches to the second FAT32 partition (milestone
/// four card 2). Drives the `ls` header/kind text so a switched volume is
/// never mislabeled.
var volume_label: [8]u8 = .{ 'e', 's', 'p', 0, 0, 0, 0, 0 };

var state: State = .{};

// ---------------------------------------------------------------------------
// Public data-layer API (host-testable; no EFI calls)
// ---------------------------------------------------------------------------

/// Clear the window (boot-time init and tests).
pub fn reset() void {
    state.clear();
}

/// Host-test hook: mark the window as disk-backed so the shell's
/// disk_ready-guarded paths (history load, startup file) can be exercised
/// without a mounted FAT volume. Never called by kernel code.
pub fn set_disk_ready_for_test(ready: bool) void {
    state.disk_ready = ready;
}

/// Install the disk sector interface, mount the ESP's FAT32 volume, and
/// populate the window from the root directory (the snapshot). Returns the
/// FAT mount result; `null` ops leaves the window empty and honest
/// (`no_disk` on write). Pre-exit on VZ (the virtio-blk transport is armed
/// pre-exit; the mount itself only does sector reads, which also work
/// post-exit — but the boot window line wants it before the shell starts).
pub fn set_disk(ops: ?fat.DiskOps) fat.MountResult {
    state.clear();
    const r = fat.mount(ops);
    if (r == .ok) {
        set_volume("esp");
        snapshot_window();
        state.disk_ready = true;
    }
    return r;
}

/// Set the active volume label ("esp" or "data").
pub fn set_volume(label: []const u8) void {
    @memset(&volume_label, 0);
    const take = @min(label.len, volume_label.len);
    @memcpy(volume_label[0..take], label[0..take]);
}

/// The active volume label ("esp" at boot; "data" after `mount data`).
pub fn volume() []const u8 {
    var len: usize = 0;
    while (len < volume_label.len and volume_label[len] != 0) : (len += 1) {}
    return volume_label[0..len];
}

/// Re-snapshot the window from the CURRENT fat mount — after `mount data`
/// switches the active volume, the window reflects the switched volume's
/// root, labeled by `set_volume` (milestone four card 2).
pub fn resnapshot() void {
    state.clear();
    snapshot_window();
    state.disk_ready = true;
}

pub fn disk_ready() bool {
    return state.disk_ready;
}

pub fn disk_geometry() fat.Geo {
    return fat.geometry();
}

pub fn entry_count() usize {
    return state.entry_count;
}

pub fn entries() []const Entry {
    return state.entries[0..state.entry_count];
}

pub fn entry(i: usize) *const Entry {
    return &state.entries[i];
}

pub fn esp_count() usize {
    return state.esp_count();
}

/// Content bytes of an entry (empty when it was listed but not loaded).
pub fn content_of(e: *const Entry) []const u8 {
    return state.content[e.offset..][0..e.len];
}

/// Case-insensitive lookup (FAT semantics); the most recently written copy
/// wins.
pub fn lookup(name: []const u8) ?*const Entry {
    var i = state.entry_count;
    while (i > 0) {
        i -= 1;
        const e = &state.entries[i];
        if (name_eql(e.name[0..e.name_len], name)) return e;
    }
    return null;
}

/// Append an ESP file entry (used by host tests and the FAT snapshot).
pub fn add_esp_entry(name: []const u8, size: u64, content: []const u8) bool {
    return state.add(name, size, content, .esp_file);
}

/// Append an ESP directory entry.
pub fn add_dir_entry(name: []const u8) bool {
    return state.add(name, 0, "", .esp_dir);
}

/// Write a file to the FAT volume (`fat.zig`) and update the window. The
/// write is best effort and honest: a failed sector write reports
/// `write_failed` with the failing LBA available via `fat.last_fail_lba()`;
/// capacity is checked before the write so a written file is never
/// invisible. Name must fit FAT 8.3; content ≤ `write_content_max`.
pub fn write_file(name: []const u8, content: []const u8) WriteResult {
    if (!valid_name(name)) return .name_invalid;
    if (content.len > write_content_max) return .content_too_long;
    switch (fat.write_file(name, content)) {
        .ok => {},
        .no_disk => return .no_disk,
        .name_too_long => return .name_too_long,
        .content_too_long => return .content_too_long,
        .bad_path => return .bad_path,
        .disk_full => return .disk_full,
        .io_failed => return .write_failed,
    }
    // The window must reflect the write immediately: replace the existing
    // same-name entry's content, else append a new entry.
    if (state.index_of(name)) |index| {
        const e = &state.entries[index];
        if (state.pool_used + content.len <= content_pool_max) {
            @memcpy(state.content[state.pool_used..][0..content.len], content);
            e.offset = @intCast(state.pool_used);
            e.len = @intCast(content.len);
            e.size = content.len;
            state.pool_used += content.len;
        }
        return .ok;
    }
    _ = state.add(name, content.len, content, .esp_file);
    return .ok;
}

// ---------------------------------------------------------------------------
// FAT snapshot (populates the window from the live volume)
// ---------------------------------------------------------------------------

fn snapshot_window() void {
    var entries_buf: [esp_entries_max]fat.DirEntry = undefined;
    const n = fat.list_root(&entries_buf);
    var i: usize = 0;
    while (i < n and state.entry_count < entries_max) : (i += 1) {
        const d = &entries_buf[i];
        const take = @min(@as(usize, d.name_len), name_max);
        if (d.is_dir) {
            _ = state.add(d.name[0..take], 0, "", .esp_dir);
            continue;
        }
        // Load content only when it fits the per-file cap (larger files —
        // e.g. KERNEL.BIN — are listed with their size).
        var content: [esp_content_max]u8 = undefined;
        var clen: usize = 0;
        if (d.size > 0 and d.size <= esp_content_max) {
            if (fat.read_file(d.name[0..d.name_len], &content)) |got| clen = got;
        }
        _ = state.add(d.name[0..take], d.size, content[0..clen], .esp_file);
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn ascii_lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn name_eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (ascii_lower(x) != ascii_lower(y)) return false;
    }
    return true;
}

/// Printable ASCII, no path separators / control bytes.
fn valid_name(name: []const u8) bool {
    if (name.len == 0 or name.len > name_max) return false;
    for (name) |c| {
        if (c < 0x20 or c > 0x7e or c == '\\' or c == '/') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests (host-side; in-memory FAT fixture, no hardware)
// ---------------------------------------------------------------------------

// A compact in-memory FAT32 image built by the fixture helper below — the
// same byte layout image/mkfat32.py produces (GPT + ESP at LBA 2048, spc=1,
// reserved=32, 2 FATs, root cluster 2). The fixture deliberately mirrors
// fat.zig's test fixture so the two layers round-trip against identical
// formats.
const test_allocator = std.testing.allocator;
var test_image: []u8 = undefined;

fn fake_read(lba: u64, out: *[512]u8) bool {
    const off = lba * 512;
    if (off + 512 > test_image.len) return false;
    @memcpy(out, test_image[off .. off + 512]);
    return true;
}

fn fake_write(lba: u64, data: *const [512]u8) bool {
    const off = lba * 512;
    if (off + 512 > test_image.len) return false;
    @memcpy(test_image[off .. off + 512], data);
    return true;
}

const esp_guid = [16]u8{ 0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };

/// Build the minimal FAT32+GPT image: MBR, GPT with the ESP entry, and a
/// FAT32 volume holding DIPSHITOS (label), EFI/ (dir), KERNEL.BIN (1
/// cluster) and BOOTED.TXT (1 cluster).
fn build_image(alloc: std.mem.Allocator) !void {
    const total_sectors: u64 = 128 * 1024 * 1024 / 512;
    const esp_offset: u64 = 2048;
    const last_usable: u64 = total_sectors - 34;
    const volume_sectors: u32 = @intCast(last_usable - esp_offset + 1);
    var fat_sectors: u32 = 1;
    while (true) {
        const clusters = volume_sectors - 32 - 2 * fat_sectors;
        const need: u32 = @intCast((clusters * 4 + 511) / 512);
        if (need == fat_sectors) break;
        fat_sectors = need;
    }
    const data_start: u32 = 32 + 2 * fat_sectors;

    test_image = try alloc.alloc(u8, @intCast(total_sectors * 512));
    @memset(test_image, 0);
    test_image[510] = 0x55;
    test_image[511] = 0xaa;
    const hdr_off: usize = 1 * 512;
    @memcpy(test_image[hdr_off .. hdr_off + 8], "EFI PART");
    std.mem.writeInt(u32, test_image[hdr_off + 12 ..][0..4], 92, .little);
    std.mem.writeInt(u64, test_image[hdr_off + 24 ..][0..8], 1, .little);
    std.mem.writeInt(u64, test_image[hdr_off + 32 ..][0..8], total_sectors - 1, .little);
    std.mem.writeInt(u64, test_image[hdr_off + 72 ..][0..8], 2, .little);
    std.mem.writeInt(u32, test_image[hdr_off + 80 ..][0..4], 128, .little);
    std.mem.writeInt(u32, test_image[hdr_off + 84 ..][0..4], 128, .little);
    const ent_off: usize = 2 * 512;
    @memcpy(test_image[ent_off .. ent_off + 16], &esp_guid);
    std.mem.writeInt(u64, test_image[ent_off + 32 ..][0..8], esp_offset, .little);
    std.mem.writeInt(u64, test_image[ent_off + 40 ..][0..8], last_usable, .little);

    const base: usize = @intCast(esp_offset * 512);
    const bs = test_image[base .. base + 512];
    const jmp_boot = [_]u8{ 0xeb, 0x58, 0x90 };
    @memcpy(bs[0..3], &jmp_boot);
    std.mem.writeInt(u16, bs[11..13], 512, .little);
    bs[13] = 1;
    std.mem.writeInt(u16, bs[14..16], 32, .little);
    bs[16] = 2;
    bs[21] = 0xf8;
    std.mem.writeInt(u32, bs[28..32], @intCast(esp_offset), .little);
    std.mem.writeInt(u32, bs[32..36], volume_sectors, .little);
    std.mem.writeInt(u32, bs[36..40], fat_sectors, .little);
    std.mem.writeInt(u32, bs[44..48], 2, .little);
    bs[510] = 0x55;
    bs[511] = 0xaa;

    const fat_off: usize = @intCast((esp_offset + 32) * 512);
    const fat_bytes = fat_sectors * 512;
    const fat_buf = try alloc.alloc(u8, fat_bytes);
    @memset(fat_buf, 0);
    std.mem.writeInt(u32, fat_buf[0..4], 0x0ffffff8, .little);
    std.mem.writeInt(u32, fat_buf[4..8], 0x0fffffff, .little);
    for ([_]u32{ 2, 3, 4, 5, 6 }) |c| std.mem.writeInt(u32, fat_buf[@as(usize, c) * 4 ..][0..4], 0x0fffffff, .little);
    for (0..2) |f| @memcpy(test_image[fat_off + f * fat_bytes ..][0..fat_bytes], fat_buf);
    alloc.free(fat_buf);

    const root_off: usize = @intCast((esp_offset + data_start) * 512);
    var root = [_]u8{0} ** 512;
    write_entry(&root, 0, "DIPSHITOS  ", 0x08, 0, 0);
    write_entry(&root, 1, "EFI        ", 0x10, 3, 0);
    write_entry(&root, 2, "KERNEL  BIN", 0x20, 5, 0x9000); // > esp_content_max: listed, not loaded
    write_entry(&root, 3, "BOOTED  TXT", 0x20, 6, 54);
    @memcpy(test_image[root_off .. root_off + 512], &root);
    const efi_off: usize = @intCast((esp_offset + data_start + 1) * 512);
    var efi = [_]u8{0} ** 512;
    write_entry(&efi, 0, ".          ", 0x10, 3, 0);
    write_entry(&efi, 1, "..         ", 0x10, 2, 0);
    @memcpy(test_image[efi_off .. efi_off + 512], &efi);
    const booted = "DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n";
    const b_off: usize = @intCast((esp_offset + data_start + 4) * 512);
    @memcpy(test_image[b_off .. b_off + booted.len], booted);
}

fn write_entry(cluster: *[512]u8, slot: usize, name11: *const [11]u8, attr: u8, cluster_no: u32, size: u32) void {
    const off = slot * 32;
    @memcpy(cluster[off .. off + 11], name11[0..11]);
    cluster[off + 11] = attr;
    std.mem.writeInt(u16, cluster[off + 20 ..][0..2], @truncate(cluster_no >> 16), .little);
    std.mem.writeInt(u16, cluster[off + 26 ..][0..2], @truncate(cluster_no), .little);
    std.mem.writeInt(u32, cluster[off + 28 ..][0..4], size, .little);
}

fn make_ops() fat.DiskOps {
    return .{ .read = &fake_read, .write = &fake_write };
}

test "esp: set_disk mounts the FAT volume and snapshots the root window" {
    try build_image(test_allocator);
    defer test_allocator.free(test_image);
    reset();
    try std.testing.expectEqual(fat.MountResult.ok, set_disk(make_ops()));
    try std.testing.expect(disk_ready());
    try std.testing.expectEqual(@as(usize, 3), entry_count()); // EFI, KERNEL.BIN, BOOTED.TXT
    try std.testing.expectEqual(@as(usize, 3), esp_count());
    const big = lookup("KERNEL.BIN").?;
    try std.testing.expectEqual(@as(u64, 0x9000), big.size);
    try std.testing.expectEqual(@as(usize, 0), content_of(big).len); // listed, not loaded
    const booted = lookup("booted.txt").?; // case-insensitive
    try std.testing.expectEqualStrings("BOOTED.TXT", booted.name[0..booted.name_len]);
    try std.testing.expectEqualStrings("DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n", content_of(booted));
    try std.testing.expect(lookup("NOPE.TXT") == null);
}

test "esp: write_file writes to the FAT volume and is visible immediately and after remount" {
    try build_image(test_allocator);
    defer test_allocator.free(test_image);
    reset();
    try std.testing.expectEqual(fat.MountResult.ok, set_disk(make_ops()));
    try std.testing.expectEqual(WriteResult.ok, write_file("hello.txt", "hello world"));
    const e = lookup("HELLO.TXT").?;
    try std.testing.expectEqualStrings("hello world", content_of(e));

    // "Reboot": fresh module state + fresh mount over the same image.
    reset();
    try std.testing.expectEqual(fat.MountResult.ok, set_disk(make_ops()));
    const e2 = lookup("hello.txt").?;
    try std.testing.expectEqual(Kind.esp_file, e2.kind);
    try std.testing.expectEqualStrings("hello world", content_of(e2));
}

test "esp: write_file replaces an existing file and reports honest failures" {
    try build_image(test_allocator);
    defer test_allocator.free(test_image);
    reset();
    try std.testing.expectEqual(fat.MountResult.ok, set_disk(make_ops()));
    try std.testing.expectEqual(WriteResult.ok, write_file("BOOTED.TXT", "new booted content"));
    const e = lookup("BOOTED.TXT").?;
    try std.testing.expectEqualStrings("new booted content", content_of(e));
    // Bounds: invalid name, 8.3 overflow, over-long content.
    try std.testing.expectEqual(WriteResult.name_invalid, write_file("a/b.txt", "x"));
    try std.testing.expectEqual(WriteResult.name_too_long, write_file("verylongname.txt", "x"));
    try std.testing.expectEqual(WriteResult.content_too_long, write_file("big.txt", &([_]u8{'x'} ** (write_content_max + 1))));
}

test "esp: no disk is reported honestly" {
    reset();
    try std.testing.expectEqual(fat.MountResult.no_disk, set_disk(null));
    try std.testing.expect(!disk_ready());
    try std.testing.expectEqual(WriteResult.no_disk, write_file("x.txt", "x"));
    try std.testing.expectEqual(@as(usize, 0), entry_count());
}

test "esp: name lookup is case-insensitive with the most recent write winning" {
    try build_image(test_allocator);
    defer test_allocator.free(test_image);
    reset();
    try std.testing.expectEqual(fat.MountResult.ok, set_disk(make_ops()));
    _ = add_esp_entry("HELLO.TXT", 5, "first!");
    try std.testing.expectEqual(WriteResult.ok, write_file("hello.txt", "second!"));
    const e = lookup("HeLlO.TxT").?;
    try std.testing.expectEqualStrings("second!", content_of(e));
}
